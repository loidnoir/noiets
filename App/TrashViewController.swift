import AppKit
import EditorKit
import VaultStore

/// Lists the vault's `.trash` folder with restore / delete-permanently,
/// grouped into month sections by deletion date.
@MainActor
final class TrashViewController: NSViewController {
    private enum Row {
        case header(String)
        case item(URL, isFolder: Bool, title: String, detail: String)

        var url: URL? {
            if case .item(let url, _, _, _) = self { return url }
            return nil
        }
    }

    private let session: VaultSession
    private let tableView = VimTableView()
    private let headerLabel = NSTextField(labelWithString: "Trash")
    private let emptyLabel = NSTextField(labelWithString: "Trash is empty")
    private var rows: [Row] = []
    private var pendingKey: Character?
    private var listCount = 0

    private func isItemRow(_ row: Int) -> Bool {
        row >= 0 && row < rows.count && rows[row].url != nil
    }

    private var firstItemRow: Int? { rows.indices.first(where: isItemRow) }
    private var lastItemRow: Int? { rows.indices.last(where: isItemRow) }

    /// Esc / ⌃h → back to the sidebar tree.
    var onFocusSidebar: (() -> Void)?

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
        tableView.rowHeight = 46
        tableView.backgroundColor = .clear
        tableView.focusRingType = .none
        tableView.intercellSpacing = .zero
        tableView.dataSource = self
        tableView.delegate = self
        tableView.menu = buildMenu()
        tableView.onKey = { [weak self] event in
            self?.handleListKey(event) ?? false
        }

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
        let previous = tableView.selectedRow >= 0 && tableView.selectedRow < rows.count
            ? rows[tableView.selectedRow].url : nil
        let fm = FileManager.default
        let keys: Set<URLResourceKey> =
            [.isDirectoryKey, .addedToDirectoryDateKey, .contentModificationDateKey]
        // No .skipsHiddenFiles: everything inside the dot-prefixed .trash
        // inherits the hidden flag (iCloud Drive), which would hide it all.
        // Dot-named entries are filtered out by name instead.
        let items = ((try? fm.contentsOfDirectory(
            at: session.vault.trashURL,
            includingPropertiesForKeys: Array(keys)
        )) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .map { url -> (url: URL, deleted: Date, isFolder: Bool) in
                let values = try? url.resourceValues(forKeys: keys)
                // mtime survives the move into .trash; the added-to-directory
                // date is the actual deletion time (also for items trashed by
                // other apps sharing the vault).
                let deleted = values?.addedToDirectoryDate
                    ?? values?.contentModificationDate ?? .distantPast
                return (url, deleted, values?.isDirectory ?? false)
            }
            .sorted { $0.deleted > $1.deleted }

        rows = []
        var currentMonth: String?
        for item in items {
            let month = DateSectionTitle.month(for: item.deleted)
            if month != currentMonth {
                rows.append(.header(month))
                currentMonth = month
            }
            let name = item.url.lastPathComponent
            let title = item.isFolder ? name : item.url.deletingPathExtension().lastPathComponent
            // Detail = where the item goes back to on restore.
            let origin = ((try? session.index?.trashOrigin(name: name)) ?? nil) ?? ""
            let detail = origin.isEmpty ? name : "\(origin)/\(name)"
            rows.append(.item(item.url, isFolder: item.isFolder, title: title, detail: detail))
        }
        emptyLabel.isHidden = !items.isEmpty
        tableView.reloadData()
        // Keep the cursor on the same item across live refreshes.
        if let previous, let row = rows.firstIndex(where: { $0.url == previous }) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
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
        restore(row: tableView.clickedRow)
    }

    @objc private func deleteClicked() {
        confirmDelete(row: tableView.clickedRow)
    }

    private func restore(row: Int) {
        guard isItemRow(row), let url = rows[row].url else { return }
        // Back to the folder it was deleted from, when it still exists;
        // otherwise the vault root.
        session.restoreFromTrash(url)
        reload()
        selectRow(min(row, rows.count - 1))
    }

    private func confirmDelete(row: Int) {
        guard isItemRow(row), let url = rows[row].url, let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Delete “\(url.lastPathComponent)” permanently?"
        alert.informativeText = "This cannot be undone."
        alert.addButton(withTitle: "Delete Permanently")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .alertFirstButtonReturn {
                self.session.deleteFromTrashPermanently(url)
                self.reload()
                self.selectRow(min(row, self.rows.count - 1))
            }
            self.focusList()
        }
    }

    // MARK: Keyboard (vim list navigation; Enter restores, dd deletes)

    func focusList() {
        _ = view
        view.window?.makeFirstResponder(tableView)
        if tableView.selectedRow < 0, let first = firstItemRow {
            selectRow(first)
        }
    }

    private func selectRow(_ row: Int) {
        guard let first = firstItemRow, let last = lastItemRow else { return }
        var clamped = min(max(row, first), last)
        // Section headers are not selectable: continue in the direction of
        // travel, falling back the other way at the edges.
        if !isItemRow(clamped) {
            let forward = row >= tableView.selectedRow
            var probe = clamped
            while probe >= first, probe <= last, !isItemRow(probe) {
                probe += forward ? 1 : -1
            }
            clamped = isItemRow(probe) ? probe : (forward ? last : first)
        }
        tableView.selectRowIndexes(IndexSet(integer: clamped), byExtendingSelection: false)
        tableView.scrollRowToVisible(clamped)
    }

    /// Moves the selection by `steps` item rows (headers don't count).
    private func moveSelection(by steps: Int) {
        guard steps != 0, firstItemRow != nil else { return }
        var row = tableView.selectedRow
        var remaining = abs(steps)
        let direction = steps > 0 ? 1 : -1
        var landed = row
        while remaining > 0 {
            var probe = row + direction
            while probe >= 0, probe < rows.count, !isItemRow(probe) {
                probe += direction
            }
            guard probe >= 0, probe < rows.count else { break }
            landed = probe
            row = probe
            remaining -= 1
        }
        selectRow(landed)
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
        if event.keyCode == 36 || event.keyCode == 76 { // return = restore
            listCount = 0
            restore(row: tableView.selectedRow)
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
            if pending == "d", ch == "d" {
                confirmDelete(row: tableView.selectedRow)
                return true
            }
            if pending == "g", ch == "g" {
                selectRow(hadCount ? count - 1 : 0)
                return true
            }
        }

        switch ch {
        case "j": moveSelection(by: count)
        case "k": moveSelection(by: -count)
        case "G": selectRow(hadCount ? count - 1 : rows.count - 1)
        case "g", "d": pendingKey = ch
        case "r": restore(row: tableView.selectedRow)
        default: return false
        }
        return true
    }
}

extension TrashViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SoftRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let title):
            return SectionHeaderCellView.make(in: tableView, title: title)
        case .item(_, let isFolder, let title, let detail):
            return SearchHitCellView.make(
                in: tableView, title: title, detail: detail,
                image: isFolder ? AppIcons.folder(size: 18) : AppIcons.document(size: 18)
            )
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        isItemRow(row)
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = rows[row] { return 44 }
        return 46
    }
}
