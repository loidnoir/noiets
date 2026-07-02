import AppKit
import EditorKit
import VaultStore

/// Lists the vault's `.trash` folder with restore / delete-permanently.
@MainActor
final class TrashViewController: NSViewController {
    private let session: VaultSession
    private let tableView = NSTableView()
    private let headerLabel = NSTextField(labelWithString: "Trash")
    private let emptyLabel = NSTextField(labelWithString: "Trash is empty")
    private var items: [URL] = []

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

        headerLabel.font = .systemFont(ofSize: 22, weight: .bold)
        headerLabel.textColor = theme.textColor
        headerLabel.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = .systemFont(ofSize: 14)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: .init("trash"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .fullWidth
        tableView.rowHeight = 30
        tableView.backgroundColor = .clear
        tableView.focusRingType = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.menu = buildMenu()

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(headerLabel)
        container.addSubview(scrollView)
        container.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 18),
            headerLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 28),
            scrollView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
    }

    func reload() {
        _ = view
        let fm = FileManager.default
        items = (try? fm.contentsOfDirectory(
            at: session.vault.trashURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: []
        ).sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }) ?? []
        emptyLabel.isHidden = !items.isEmpty
        tableView.reloadData()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let restore = NSMenuItem(title: "Restore", action: #selector(restoreClicked), keyEquivalent: "")
        restore.target = self
        let delete = NSMenuItem(title: "Delete Permanently", action: #selector(deleteClicked), keyEquivalent: "")
        delete.target = self
        menu.addItem(restore)
        menu.addItem(.separator())
        menu.addItem(delete)
        return menu
    }

    @objc private func restoreClicked() {
        guard tableView.clickedRow >= 0, tableView.clickedRow < items.count else { return }
        let url = items[tableView.clickedRow]
        var dest = session.vault.rootURL.appendingPathComponent(url.lastPathComponent)
        let fm = FileManager.default
        var counter = 2
        while fm.fileExists(atPath: dest.path) {
            let base = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            let name = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            dest = session.vault.rootURL.appendingPathComponent(name)
            counter += 1
        }
        try? fm.moveItem(at: url, to: dest)
        session.rescan()
        reload()
    }

    @objc private func deleteClicked() {
        guard tableView.clickedRow >= 0, tableView.clickedRow < items.count else { return }
        try? FileManager.default.removeItem(at: items[tableView.clickedRow])
        reload()
    }
}

extension TrashViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SoftRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let url = items[row]
        return SidebarCellView.make(
            in: tableView,
            title: url.lastPathComponent, symbol: "doc.text", isFolder: false
        )
    }
}
