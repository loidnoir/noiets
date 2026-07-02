import AppKit
import EditorKit
import IndexKit

/// The list view behind the Search / Recent sidebar items (and tag browsing
/// from the palette). Lives in the editor pane; opening a row swaps back to
/// the editor.
@MainActor
final class SearchViewController: NSViewController {
    enum Mode: Equatable {
        case search
        case recent
        case tag(String)
    }

    private let session: VaultSession
    var onOpenNote: ((URL) -> Void)?

    private var mode: Mode = .search
    private let searchField = NSSearchField()
    private let headerLabel = NSTextField(labelWithString: "")
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private var rows: [(title: String, detail: String, relPath: String)] = []

    init(session: VaultSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let theme = EditorTheme.standard()
        let container = ColorView(color: theme.background)
        view = container

        searchField.placeholderString = "Search vault"
        searchField.font = .systemFont(ofSize: 15)
        searchField.focusRingType = .none
        searchField.target = self
        searchField.action = #selector(queryChanged)
        searchField.sendsSearchStringImmediately = true
        searchField.translatesAutoresizingMaskIntoConstraints = false

        headerLabel.font = .systemFont(ofSize: 22, weight: .bold)
        headerLabel.textColor = theme.textColor
        headerLabel.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: .init("hit"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .fullWidth
        tableView.rowHeight = 46
        tableView.backgroundColor = .clear
        tableView.focusRingType = .none
        tableView.intercellSpacing = .zero
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(openClicked)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(headerLabel)
        container.addSubview(searchField)
        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 18),
            headerLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 28),
            searchField.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 26),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -26),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    // MARK: Modes

    func show(mode: Mode) {
        self.mode = mode
        _ = view // force load
        switch mode {
        case .search:
            headerLabel.stringValue = "Search"
            searchField.isHidden = false
        case .recent:
            headerLabel.stringValue = "Recent"
            searchField.isHidden = true
        case .tag(let name):
            headerLabel.stringValue = "#\(name)"
            searchField.isHidden = true
        }
        reload()
    }

    func focusSearch() {
        view.window?.makeFirstResponder(searchField)
    }

    /// Called when the index updates underneath us.
    func indexChanged() {
        reload()
    }

    @objc private func queryChanged() {
        reload()
    }

    private func reload() {
        guard let index = session.index else { return }
        switch mode {
        case .search:
            let query = searchField.stringValue
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                rows = []
            } else {
                let hits = (try? index.searchNotes(query)) ?? []
                rows = hits.map { ($0.title, $0.snippet, $0.relPath) }
            }
        case .recent:
            let recents = (try? index.recentNotes()) ?? []
            rows = recents.map { ($0.title, $0.relPath, $0.relPath) }
        case .tag(let name):
            let notes = (try? index.notes(withTag: name)) ?? []
            rows = notes.map { ($0.title, $0.relPath, $0.relPath) }
        }
        tableView.reloadData()
    }

    @objc private func openClicked() {
        openRow(tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow)
    }

    private func openRow(_ row: Int) {
        guard row >= 0, row < rows.count else { return }
        onOpenNote?(session.url(forRelPath: rows[row].relPath))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 { // return opens selection
            openRow(tableView.selectedRow)
            return
        }
        super.keyDown(with: event)
    }
}

extension SearchViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SoftRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let r = rows[row]
        return SearchHitCellView.make(in: tableView, title: r.title, detail: r.detail)
    }
}

/// Two-line row: note title + muted snippet/path.
private final class SearchHitCellView: NSTableCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("SearchHitCell")

    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title.font = .systemFont(ofSize: 14, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [title, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    static func make(in tableView: NSTableView, title: String, detail: String) -> SearchHitCellView {
        let cell = tableView.makeView(withIdentifier: reuseID, owner: nil) as? SearchHitCellView
            ?? SearchHitCellView(frame: .zero)
        cell.identifier = reuseID
        cell.title.stringValue = title
        cell.detail.stringValue = detail.replacingOccurrences(of: "\n", with: " ")
        return cell
    }
}
