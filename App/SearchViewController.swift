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
    /// Esc / ⌃h → back to the sidebar tree.
    var onFocusSidebar: (() -> Void)?

    private var mode: Mode = .search
    private let searchField = NSSearchField()
    private let headerLabel = NSTextField(labelWithString: "")
    private let tableView = VimTableView()
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
        searchField.delegate = self // ↓/Return → list, Esc → sidebar
        searchField.translatesAutoresizingMaskIntoConstraints = false

        tableView.onKey = { [weak self] event in
            self?.handleListKey(event) ?? false
        }

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

    // MARK: Keyboard (vim list navigation)

    private var pendingKey: Character?
    private var listCount = 0

    /// Focus the results list, selecting the first row if nothing is.
    func focusList() {
        _ = view
        view.window?.makeFirstResponder(tableView)
        if tableView.selectedRow < 0, !rows.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
        }
    }

    /// Where activation should put focus: the field for empty searches, the
    /// list everywhere else.
    func focusPreferred() {
        if case .search = mode, searchField.stringValue.isEmpty {
            focusSearch()
        } else {
            focusList()
        }
    }

    private func selectRow(_ row: Int) {
        guard !rows.isEmpty else { return }
        let clamped = min(max(row, 0), rows.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: clamped), byExtendingSelection: false)
        tableView.scrollRowToVisible(clamped)
    }

    private func handleListKey(_ event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.control) {
            if event.charactersIgnoringModifiers == "h" {
                onFocusSidebar?()
                return true
            }
            return false
        }
        if event.keyCode == 53 { // esc: cancel pending chord/count, stay in the list
            pendingKey = nil
            listCount = 0
            return true
        }
        if event.keyCode == 36 || event.keyCode == 76 { // return
            listCount = 0
            openRow(tableView.selectedRow)
            return true
        }
        guard let ch = event.charactersIgnoringModifiers?.first else { return false }

        // Count multiplier (5j, 3k, NG).
        if let digit = ch.wholeNumberValue, ch.isNumber, !(digit == 0 && listCount == 0) {
            pendingKey = nil
            listCount = listCount * 10 + digit
            return true
        }
        let hadCount = listCount > 0
        let count = max(listCount, 1)
        listCount = 0

        if let pending = pendingKey {
            pendingKey = nil
            switch (pending, ch) {
            case ("g", "g"):
                selectRow(hadCount ? count - 1 : 0)
                return true
            case ("d", "d"):
                confirmTrashSelected()
                return true
            default:
                break
            }
        }

        switch ch {
        case "j": selectRow(tableView.selectedRow + count)
        case "k": selectRow(tableView.selectedRow - count)
        case "G": selectRow(hadCount ? count - 1 : rows.count - 1)
        case "g", "d": pendingKey = ch
        case "l": openRow(tableView.selectedRow)
        case "/":
            if case .search = mode { focusSearch() } else { return false }
        default:
            return false
        }
        return true
    }

    private func confirmTrashSelected() {
        let row = tableView.selectedRow
        guard row >= 0, row < rows.count, let window = view.window else { return }
        let entry = rows[row]
        let alert = NSAlert()
        alert.messageText = "Move “\(entry.title)” to Trash?"
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else {
                self?.focusList()
                return
            }
            self.session.trashNote(self.session.url(forRelPath: entry.relPath))
            self.reload()
            self.selectRow(min(row, self.rows.count - 1))
            self.focusList()
        }
    }
}

// MARK: - Search field keys

extension SearchViewController: NSSearchFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertNewline(_:)):
            focusList()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            focusList() // esc leaves the field but stays in this view
            return true
        default:
            return false
        }
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

/// Two-line row: type icon + note title + muted snippet/path.
private final class SearchHitCellView: NSTableCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("SearchHitCell")

    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.image = AppIcons.document(size: 15)
        icon.contentTintColor = .secondaryLabelColor
        title.font = .systemFont(ofSize: 14, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        // Long titles must truncate on one line — never wrap, never crush
        // the icon out of the row.
        title.maximumNumberOfLines = 1
        detail.maximumNumberOfLines = 1
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 15),
            icon.heightAnchor.constraint(equalToConstant: 15),
        ])

        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        let stack = NSStackView(views: [icon, text])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 9
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
