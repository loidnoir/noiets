import AppKit
import VaultStore

/// The left pane: Search / Recent / Trash, a hairline divider, then the vault
/// folder tree with files as leaves. Flat NSOutlineView — no source-list
/// vibrancy, no bubbles.
@MainActor
final class SidebarViewController: NSViewController {
    private let session: VaultSession

    var onSelectNote: ((URL) -> Void)?
    var onSelectFixed: ((Fixed) -> Void)?
    var onCurrentNoteRemoved: (() -> Void)?
    /// ⌃l / Esc from the tree → give focus back to the editor.
    var onFocusEditor: (() -> Void)?

    private let scrollView = NSScrollView()
    private let outlineView = SidebarOutlineView()
    private let modeBar = ColorView(color: UITheme.sidebarBackground)
    private let modeBarLine = ColorView(color: UITheme.paneSeparator)
    private let modeLabel = NSTextField(labelWithString: "NORMAL")
    private var suppressSelectionCallback = false
    private var suppressExpansionBookkeeping = false

    // MARK: Model

    enum Fixed: Int, CaseIterable {
        case search, recent, trash

        var title: String {
            switch self {
            case .search: return "Search"
            case .recent: return "Recent"
            case .trash: return "Trash"
            }
        }

        var symbol: String {
            switch self {
            case .search: return "magnifyingglass"
            case .recent: return "clock"
            case .trash: return "trash"
            }
        }
    }

    final class Item {
        enum Kind {
            case fixed(Fixed)
            case separator
            case node(FileNode)
        }

        let kind: Kind
        var children: [Item] = []

        init(_ kind: Kind) {
            self.kind = kind
        }

        var fileNode: FileNode? {
            if case .node(let n) = kind { return n }
            return nil
        }
    }

    private var rootItems: [Item] = []
    private var itemsByURL: [URL: Item] = [:]
    private var expandedURLs: Set<URL> = []

    init(session: VaultSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: View

    override func loadView() {
        view = ColorView(color: UITheme.sidebarBackground)

        let column = NSTableColumn(identifier: .init("main"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .fullWidth
        outlineView.rowHeight = 28
        outlineView.intercellSpacing = NSSize(width: 0, height: 0)
        outlineView.backgroundColor = .clear
        outlineView.focusRingType = .none
        // Folder cell text sits at leading 8 + icon 18 + gap 4 = 30; one
        // indent level (22) + the child cell's own leading 8 lands children's
        // text at exactly 30 too — names align at every depth.
        outlineView.indentationPerLevel = 22
        outlineView.autoresizesOutlineColumn = false
        outlineView.allowsEmptySelection = true
        outlineView.allowsMultipleSelection = true  // tree visual mode (v)
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.menu = buildContextMenu()

        // Click anywhere on a folder row to open/close it.
        outlineView.target = self
        outlineView.action = #selector(rowClicked)

        // Vim-style tree navigation (j/k/h/l, Enter, dd, r, m, a, gg/G…).
        outlineView.onKey = { [weak self] event in
            self?.handleTreeKey(event) ?? false
        }

        // Drag & drop: move notes/folders between folders (and to the root).
        outlineView.registerForDraggedTypes([.fileURL])
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
        outlineView.draggingDestinationFeedbackStyle = .regular

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        // Vim mode bar: flat Things-style strip across the sidebar bottom,
        // separated from the content by a hairline (no pill).
        modeBar.translatesAutoresizingMaskIntoConstraints = false
        modeBarLine.translatesAutoresizingMaskIntoConstraints = false
        modeLabel.font = .monospacedSystemFont(ofSize: 12.5, weight: .bold)
        modeLabel.textColor = UITheme.modeNormalText
        modeLabel.alignment = .center
        modeLabel.lineBreakMode = .byTruncatingTail
        modeLabel.translatesAutoresizingMaskIntoConstraints = false
        modeBar.addSubview(modeBarLine)
        modeBar.addSubview(modeLabel)
        view.addSubview(modeBar)

        NSLayoutConstraint.activate([
            // Content starts a breath below the titlebar, like Things.
            scrollView.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10
            ),
            scrollView.bottomAnchor.constraint(equalTo: modeBar.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            modeBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            modeBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            modeBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            modeBar.heightAnchor.constraint(equalToConstant: 45),

            modeBarLine.topAnchor.constraint(equalTo: modeBar.topAnchor),
            modeBarLine.leadingAnchor.constraint(equalTo: modeBar.leadingAnchor),
            modeBarLine.trailingAnchor.constraint(equalTo: modeBar.trailingAnchor),
            modeBarLine.heightAnchor.constraint(equalToConstant: 1),

            modeLabel.centerXAnchor.constraint(equalTo: modeBar.centerXAnchor),
            modeLabel.centerYAnchor.constraint(equalTo: modeBar.centerYAnchor),
            modeLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: modeBar.leadingAnchor, constant: 8
            ),
        ])

        rebuildItems()
        outlineView.reloadData()
        session.onTreeChange { [weak self] in self?.reload() }
    }

    // MARK: Items

    private func rebuildItems() {
        itemsByURL.removeAll()
        var items: [Item] = Fixed.allCases.map { Item(.fixed($0)) }
        items.append(Item(.separator))
        items += session.tree.children.map(makeItem)
        rootItems = items
    }

    private func makeItem(for node: FileNode) -> Item {
        let item = Item(.node(node))
        item.children = node.children.map(makeItem)
        itemsByURL[node.url] = item
        return item
    }

    func reload() {
        let selected = selectedNodeURL()
        rebuildItems()
        outlineView.reloadData()
        restoreExpansion(items: rootItems)
        if let selected, itemsByURL[selected] != nil {
            select(url: selected, notify: false)
        }
    }

    private func restoreExpansion(items: [Item]) {
        for item in items {
            if let node = item.fileNode, node.isFolder, expandedURLs.contains(node.url) {
                outlineView.expandItem(item)
            }
            restoreExpansion(items: item.children)
        }
    }

    // MARK: Selection

    func select(url: URL, notify: Bool = true) {
        guard let item = itemsByURL[url] else { return }
        expandParents(of: url)
        let row = outlineView.row(forItem: item)
        guard row >= 0 else { return }
        suppressSelectionCallback = !notify
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        suppressSelectionCallback = false
        outlineView.scrollRowToVisible(row)
    }

    private func expandParents(of url: URL) {
        var chain: [Item] = []
        var dir = url.deletingLastPathComponent().standardizedFileURL
        let root = session.vault.rootURL
        while dir.path.count > root.path.count, dir.path.hasPrefix(root.path) {
            if let item = itemsByURL[dir] { chain.append(item) }
            dir = dir.deletingLastPathComponent().standardizedFileURL
        }
        for item in chain.reversed() {
            outlineView.expandItem(item)
        }
    }

    func selectedNodeURL() -> URL? {
        guard outlineView.selectedRow >= 0,
            let item = outlineView.item(atRow: outlineView.selectedRow) as? Item
        else { return nil }
        return item.fileNode?.url
    }

    /// The folder new notes should land in, based on the current selection.
    var selectedFolderURL: URL? {
        guard let item = outlineView.item(atRow: outlineView.selectedRow) as? Item,
            let node = item.fileNode
        else { return nil }
        return node.isFolder ? node.url : node.url.deletingLastPathComponent()
    }

    // MARK: Context menu

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = true
        menu.addItem(item("New Note", #selector(ctxNewNote(_:))))
        menu.addItem(item("New Folder", #selector(ctxNewFolder(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Reveal in Finder", #selector(ctxReveal(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Move to Trash", #selector(ctxTrash(_:))))
        return menu
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        return i
    }

    private func clickedNode() -> FileNode? {
        guard outlineView.clickedRow >= 0,
            let item = outlineView.item(atRow: outlineView.clickedRow) as? Item
        else { return nil }
        return item.fileNode
    }

    private func clickedFolderURL() -> URL {
        guard let node = clickedNode() else { return session.vault.rootURL }
        return node.isFolder ? node.url : node.url.deletingLastPathComponent()
    }

    @objc private func ctxNewNote(_: Any?) {
        guard let url = session.createNote(in: clickedFolderURL()) else { return }
        select(url: url, notify: false)
        onSelectNote?(url)
    }

    @objc private func ctxNewFolder(_: Any?) {
        _ = session.createFolder(in: clickedFolderURL())
    }

    @objc private func ctxReveal(_: Any?) {
        guard let node = clickedNode() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([node.url])
    }

    @objc private func ctxTrash(_: Any?) {
        guard let node = clickedNode() else { return }
        session.trashNote(node.url)
        if session.currentNoteURL == nil {
            onCurrentNoteRemoved?()
        }
    }

    // MARK: Keyboard tree navigation (nvim-tree essentials)

    private var pendingTreeKey: Character?  // for dd / gg chords
    private var treeCount = 0  // count multiplier (5j, 3k, NG…)

    // Tree visual mode: v anchors, j/k extend, dd/r/m act on the selection.
    private var treeVisualAnchor: Int?
    private var treeVisualCursor = 0

    private var isTreeVisual: Bool {
        treeVisualAnchor != nil
    }

    /// Focuses the tree, ensuring something is selected for j/k to move from.
    func focusTree() {
        _ = view  // ensure loaded
        view.window?.makeFirstResponder(outlineView)
        if outlineView.selectedRow < 0 {
            moveSelection(from: -1, direction: 1)
        }
    }

    private func handleTreeKey(_ event: NSEvent) -> Bool {
        // ⌃l (or Esc) hands focus to the editor pane.
        if event.modifierFlags.contains(.control) {
            switch event.charactersIgnoringModifiers {
            case "l", "j", "k":
                onFocusEditor?()
                return true
            case "h":
                return true  // already here
            default:
                return false
            }
        }
        if event.keyCode == 53 {  // esc
            pendingTreeKey = nil
            clearTreeCount()
            if isTreeVisual {
                exitTreeVisual()  // first esc leaves visual, second leaves the tree
            } else {
                onFocusEditor?()
            }
            return true
        }
        if event.keyCode == 36 || event.keyCode == 76 {  // return
            pendingTreeKey = nil
            clearTreeCount()
            if isTreeVisual { exitTreeVisual() }
            activateSelectedRow()
            return true
        }
        guard let ch = event.charactersIgnoringModifiers?.first else { return false }

        // Count multiplier: digits accumulate (5j, 12G…).
        if let digit = ch.wholeNumberValue, ch.isNumber, !(digit == 0 && treeCount == 0) {
            pendingTreeKey = nil
            treeCount = treeCount * 10 + digit
            setVimStatus("TREE \(treeCount)")
            return true
        }
        let hadCount = treeCount > 0
        let count = max(treeCount, 1)
        clearTreeCount()

        // Two-key chords: dd (delete), gg (top / Nth row).
        if let pending = pendingTreeKey {
            pendingTreeKey = nil
            switch (pending, ch) {
            case ("d", "d"):
                confirmTrashSelected()
                return true
            case ("g", "g"):
                if hadCount {
                    selectNthSelectableRow(count)
                } else {
                    moveSelection(from: -1, direction: 1)
                }
                return true
            default:
                break  // fall through to treat ch fresh
            }
        }

        switch ch {
        case "v":
            if isTreeVisual {
                exitTreeVisual()
            } else if outlineView.selectedRow >= 0 {
                treeVisualAnchor = outlineView.selectedRow
                treeVisualCursor = outlineView.selectedRow
                applyTreeVisualSelection()
                setVimStatus("TREE VISUAL")
            }
        case "j":
            if isTreeVisual {
                extendTreeVisual(direction: 1, steps: count)
            } else {
                moveSelection(from: outlineView.selectedRow, direction: 1, steps: count)
            }
        case "k":
            if isTreeVisual {
                extendTreeVisual(direction: -1, steps: count)
            } else {
                moveSelection(from: outlineView.selectedRow, direction: -1, steps: count)
            }
        case "l":
            if isTreeVisual { exitTreeVisual() }
            expandOrOpenSelected()
        case "h":
            if isTreeVisual { exitTreeVisual() }
            for _ in 0..<count {
                collapseOrParentSelected()
            }
        case "G":
            if isTreeVisual {
                extendTreeVisual(direction: 1, steps: outlineView.numberOfRows)
            } else if hadCount {
                selectNthSelectableRow(count)
            } else {
                moveSelection(from: outlineView.numberOfRows, direction: -1)
            }
        case "g", "d":
            pendingTreeKey = ch
        case "r":
            renameSelected()
        case "m":
            moveSelectedViaPicker()
        case "a":
            if isTreeVisual { exitTreeVisual() }
            createNoteAtSelection()
        case "A":
            if isTreeVisual { exitTreeVisual() }
            createFolderAtSelection()
        case "R":
            session.rescan()
        default:
            return false
        }
        return true
    }

    // MARK: Tree visual mode

    private func exitTreeVisual() {
        guard isTreeVisual else { return }
        treeVisualAnchor = nil
        setVimStatus("TREE")
        let cursor = min(max(treeVisualCursor, 0), max(outlineView.numberOfRows - 1, 0))
        suppressSelectionCallback = true
        outlineView.selectRowIndexes(IndexSet(integer: cursor), byExtendingSelection: false)
        suppressSelectionCallback = false
    }

    private func extendTreeVisual(direction: Int, steps: Int) {
        var cursor = treeVisualCursor
        var remaining = max(steps, 1)
        while remaining > 0 {
            var next = cursor + direction
            var found = false
            while next >= 0, next < outlineView.numberOfRows {
                if let item = outlineView.item(atRow: next) as? Item,
                    case .separator = item.kind
                {
                    next += direction
                    continue
                }
                found = true
                break
            }
            if !found { break }
            cursor = next
            remaining -= 1
        }
        treeVisualCursor = cursor
        applyTreeVisualSelection()
    }

    /// Selects the contiguous anchor…cursor range (file/folder rows only).
    private func applyTreeVisualSelection() {
        guard let anchor = treeVisualAnchor else { return }
        let lo = min(anchor, treeVisualCursor)
        let hi = max(anchor, treeVisualCursor)
        var set = IndexSet()
        for row in lo...hi {
            if let item = outlineView.item(atRow: row) as? Item, item.fileNode != nil {
                set.insert(row)
            }
        }
        guard !set.isEmpty else { return }
        suppressSelectionCallback = true
        outlineView.selectRowIndexes(set, byExtendingSelection: false)
        suppressSelectionCallback = false
        outlineView.scrollRowToVisible(treeVisualCursor)
    }

    /// All file/folder nodes in the selection, in row order.
    private var selectedFileNodes: [FileNode] {
        outlineView.selectedRowIndexes.compactMap {
            (outlineView.item(atRow: $0) as? Item)?.fileNode
        }
    }

    private func clearTreeCount() {
        if treeCount != 0 {
            treeCount = 0
            setVimStatus("TREE")
        }
    }

    /// Selects the Nth selectable row (1-based), vim's NG / Ngg.
    private func selectNthSelectableRow(_ n: Int) {
        var remaining = n
        for row in 0..<outlineView.numberOfRows {
            guard let item = outlineView.item(atRow: row) as? Item else { continue }
            if case .separator = item.kind { continue }
            remaining -= 1
            if remaining == 0 {
                suppressSelectionCallback = true
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                suppressSelectionCallback = false
                outlineView.scrollRowToVisible(row)
                return
            }
        }
        moveSelection(from: outlineView.numberOfRows, direction: -1)  // past end → last
    }

    /// Moves the selection cursor without activating rows (Enter activates).
    /// `steps` applies the vim count: 5j hops five selectable rows.
    private func moveSelection(from row: Int, direction: Int, steps: Int = 1) {
        let count = outlineView.numberOfRows
        guard count > 0 else { return }
        var landed: Int?
        var next = row
        var remaining = max(steps, 1)
        while remaining > 0 {
            next += direction
            var found = false
            while next >= 0, next < count {
                if let item = outlineView.item(atRow: next) as? Item {
                    switch item.kind {
                    case .separator: break  // skip
                    case .fixed, .node:
                        landed = next
                        found = true
                    }
                }
                if found { break }
                next += direction
            }
            if !found { break }  // ran off the end: keep the furthest hit
            remaining -= 1
        }
        if let landed {
            suppressSelectionCallback = true
            outlineView.selectRowIndexes(IndexSet(integer: landed), byExtendingSelection: false)
            suppressSelectionCallback = false
            outlineView.scrollRowToVisible(landed)
        }
    }

    private var selectedItem: Item? {
        guard outlineView.selectedRow >= 0 else { return nil }
        return outlineView.item(atRow: outlineView.selectedRow) as? Item
    }

    private func activateSelectedRow() {
        guard let item = selectedItem else { return }
        switch item.kind {
        case .fixed(let fixed):
            onSelectFixed?(fixed)
        case .node(let node) where node.isFolder:
            toggle(item)
        case .node(let node):
            onSelectNote?(node.url)  // opens + focuses the editor
        case .separator:
            break
        }
    }

    private func expandOrOpenSelected() {
        guard let item = selectedItem else { return }
        switch item.kind {
        case .node(let node) where node.isFolder:
            if !outlineView.isItemExpanded(item), !item.children.isEmpty {
                outlineView.expandItem(item)
            }
        default:
            activateSelectedRow()
        }
    }

    private func collapseOrParentSelected() {
        guard let item = selectedItem, let node = item.fileNode else { return }
        if node.isFolder, outlineView.isItemExpanded(item) {
            outlineView.collapseItem(item)
            return
        }
        // Jump to the parent folder row.
        let parent = node.url.deletingLastPathComponent().standardizedFileURL
        if let parentItem = itemsByURL[parent] {
            let row = outlineView.row(forItem: parentItem)
            if row >= 0 {
                suppressSelectionCallback = true
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                suppressSelectionCallback = false
                outlineView.scrollRowToVisible(row)
            }
        }
    }

    // MARK: Tree actions (dd / r / m / a / A)

    private var selectionContextFolder: URL {
        guard let node = selectedItem?.fileNode else { return session.vault.rootURL }
        return node.isFolder ? node.url : node.url.deletingLastPathComponent()
    }

    private func confirmTrashSelected() {
        let nodes = selectedFileNodes
        guard !nodes.isEmpty, let window = view.window else { return }
        let alert = NSAlert()
        if nodes.count == 1 {
            let node = nodes[0]
            alert.messageText = "Move “\(node.title)” to Trash?"
            alert.informativeText =
                node.isFolder
                ? "The folder and everything inside it moves to the vault’s .trash."
                : "The note moves to the vault’s .trash and can be restored from there."
        } else {
            alert.messageText = "Move \(nodes.count) items to Trash?"
            let names = nodes.prefix(5).map(\.title).joined(separator: ", ")
            alert.informativeText = nodes.count > 5 ? "\(names), …" : names
        }
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        let row = outlineView.selectedRowIndexes.first ?? outlineView.selectedRow
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.exitTreeVisual()
            guard response == .alertFirstButtonReturn else {
                self.focusTree()
                return
            }
            for node in nodes {
                self.session.trashNote(node.url)
            }
            if self.session.currentNoteURL == nil {
                self.onCurrentNoteRemoved?()
            }
            self.moveSelection(from: min(row, self.outlineView.numberOfRows), direction: -1)
            self.focusTree()
        }
    }

    private func renameSelected() {
        let nodes = selectedFileNodes
        guard !nodes.isEmpty, let window = view.window else { return }
        let alert = NSAlert()
        let batch = nodes.count > 1
        if batch {
            alert.messageText = "Rename \(nodes.count) items"
            alert.informativeText = "They become name-1, name-2, … in list order."
        } else {
            alert.messageText = "Rename “\(nodes[0].title)”"
        }
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: batch ? "" : nodes[0].title)
        field.placeholderString = batch ? "base name" : nil
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.exitTreeVisual()
            guard response == .alertFirstButtonReturn else {
                self.focusTree()
                return
            }
            let base = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard !base.isEmpty else {
                self.focusTree()
                return
            }
            if batch {
                var failures = 0
                for (index, node) in nodes.enumerated() {
                    if self.session.rename(node.url, to: "\(base)-\(index + 1)") == nil {
                        failures += 1
                    }
                }
                if failures > 0 { NSSound.beep() }
            } else if let renamed = self.session.rename(nodes[0].url, to: base) {
                self.select(url: renamed, notify: false)
            } else {
                NSSound.beep()
            }
            self.focusTree()
        }
    }

    private func moveSelectedViaPicker() {
        let nodes = selectedFileNodes
        guard !nodes.isEmpty, let window = view.window else { return }
        let sources = nodes.map(\.url)
        let folders = session.allFolders().filter { folder in
            // Exclude any source itself and anything inside a source.
            !sources.contains { source in
                folder.url.standardizedFileURL == source.standardizedFileURL
                    || folder.url.path.hasPrefix(source.path + "/")
            }
        }
        let title =
            nodes.count == 1 ? "Move “\(nodes[0].title)” to…" : "Move \(nodes.count) items to…"
        PalettePanel.shared.present(over: window, placeholder: title) { [weak self] query in
            let q = query.lowercased()
            return
                folders
                .filter { q.isEmpty || $0.title.lowercased().contains(q) }
                .map { folder in
                    PalettePanel.Item(symbol: nil, title: folder.title, subtitle: nil,
                                      image: AppIcons.folder(size: 14)) {
                        guard let self else { return }
                        self.exitTreeVisual()
                        var lastMoved: URL?
                        for source in sources {
                            if let moved = self.session.moveItem(at: source, into: folder.url) {
                                lastMoved = moved
                            }
                        }
                        if let lastMoved {
                            self.expandedURLs.insert(folder.url)
                            self.select(url: lastMoved, notify: false)
                        }
                        self.focusTree()
                    }
                }
        }
    }

    private func createNoteAtSelection() {
        guard let url = session.createNote(in: selectionContextFolder) else { return }
        select(url: url, notify: false)
        onSelectNote?(url)
    }

    private func createFolderAtSelection() {
        if let url = session.createFolder(in: selectionContextFolder) {
            select(url: url, notify: false)
            focusTree()
        }
    }

    // MARK: Folder toggling

    @objc private func rowClicked() {
        guard outlineView.clickedRow >= 0,
            let item = outlineView.item(atRow: outlineView.clickedRow) as? Item,
            let node = item.fileNode, node.isFolder, !item.children.isEmpty
        else { return }
        toggle(item)
    }

    private func toggle(_ item: Item) {
        // Plain calls — the animator() proxy silently swallows expand/collapse,
        // and NSOutlineView animates these implicitly anyway.
        if outlineView.isItemExpanded(item) {
            outlineView.collapseItem(item)
        } else {
            outlineView.expandItem(item)
        }
    }

    /// Diagnostics for the self-test: exercises toggling + drag wiring.
    var sidebarDebugInfo: [String: Any] {
        var info: [String: Any] = [:]
        info["actionWired"] =
            outlineView.action == #selector(rowClicked)
            && outlineView.target === self
        let folderItem = rootItems.first {
            $0.fileNode?.isFolder == true && !$0.children.isEmpty
        }
        if let folderItem {
            info["rowForItem"] = outlineView.row(forItem: folderItem)  // -1 = identity unknown
            info["before"] = outlineView.isItemExpanded(folderItem)
            outlineView.collapseItem(folderItem)
            info["plainCollapse"] = !outlineView.isItemExpanded(folderItem)

            // Sub-test A: notification side-effects (reloadItem) suppressed.
            suppressExpansionBookkeeping = true
            outlineView.expandItem(folderItem)
            outlineView.collapseItem(folderItem)
            info["collapseNoSideEffects"] = !outlineView.isItemExpanded(folderItem)
            suppressExpansionBookkeeping = false

            // Sub-test B: selection moved out of the subtree first.
            outlineView.expandItem(folderItem)
            outlineView.deselectAll(nil)
            outlineView.collapseItem(folderItem)
            info["collapseAfterDeselect"] = !outlineView.isItemExpanded(folderItem)
            outlineView.expandItem(folderItem)
        }
        let ds = outlineView.dataSource
        info["dragSourceExposed"] =
            ds?.responds(
                to: #selector(NSOutlineViewDataSource.outlineView(_:pasteboardWriterForItem:))
            ) ?? false
        info["dropValidateExposed"] =
            ds?.responds(
                to: #selector(
                    NSOutlineViewDataSource.outlineView(
                        _:validateDrop:proposedItem:proposedChildIndex:
                    )
                )
            ) ?? false
        info["dropAcceptExposed"] =
            ds?.responds(
                to: #selector(NSOutlineViewDataSource.outlineView(_:acceptDrop:item:childIndex:))
            ) ?? false
        info["registeredForFileURL"] = outlineView.registeredDraggedTypes.contains(.fileURL)
        return info
    }
}

// MARK: - Data source

extension SidebarViewController: NSOutlineViewDataSource {
    func outlineView(_: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item = item as? Item else { return rootItems.count }
        return item.children.count
    }

    func outlineView(_: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item = item as? Item else { return rootItems[index] }
        return item.children[index]
    }

    func outlineView(_: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let item = item as? Item else { return false }
        return !item.children.isEmpty
    }
}

// MARK: - Delegate

extension SidebarViewController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, viewFor _: NSTableColumn?, item: Any) -> NSView?
    {
        guard let item = item as? Item else { return nil }
        switch item.kind {
        case .separator:
            return SeparatorCellView.make(in: outlineView)
        case .fixed(let fixed):
            return SidebarCellView.make(
                in: outlineView, title: fixed.title, symbol: fixed.symbol, isFolder: false,
                image: fixed == .trash ? AppIcons.trash(size: 16) : nil
            )
        case .node(let node):
            if node.isFolder {
                return SidebarFolderCellView.make(
                    in: outlineView,
                    title: node.title,
                    isExpanded: outlineView.isItemExpanded(item),
                    isExpandable: !item.children.isEmpty
                ) { [weak outlineView, weak item] in
                    guard let outlineView, let item else { return false }
                    if outlineView.isItemExpanded(item) {
                        outlineView.collapseItem(item)
                        return false
                    }
                    outlineView.expandItem(item)
                    return true
                }
            }
            return SidebarCellView.make(
                in: outlineView, title: node.title, symbol: nil, isFolder: false
            )
        }
    }

    func outlineView(_: NSOutlineView, rowViewForItem _: Any) -> NSTableRowView? {
        SoftRowView()
    }

    func outlineView(_: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let item = item as? Item else { return false }
        switch item.kind {
        case .separator: return false
        case .fixed, .node: return true
        }
    }

    /// Programmatic selection of a fixed row (e.g. ⇧⌘F selects Search).
    func selectFixed(_ fixed: Fixed) {
        guard
            let item = rootItems.first(where: {
                if case .fixed(let f) = $0.kind { return f == fixed }
                return false
            })
        else { return }
        let row = outlineView.row(forItem: item)
        guard row >= 0 else { return }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    func outlineView(_: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        if let item = item as? Item {
            switch item.kind {
            case .separator: return 18  // pure air
            case .fixed: return 25
            case .node(let node) where node.isFolder: return 25
            case .node: return 23
            }
        }
        return 28
    }

    /// Vim mode/status display (driven by the window controller).
    func setVimStatus(_ text: String) {
        modeLabel.stringValue = text
        modeLabel.textColor = vimStatusColor(for: text)
    }

    private func vimStatusColor(for text: String) -> NSColor {
        if text == "INSERT" || text.hasPrefix("INSERT ") {
            return UITheme.modeInsertText
        }
        if text == "VISUAL" || text.hasPrefix("VISUAL ")
            || text == "V-LINE" || text.hasPrefix("V-LINE ")
            || text == "TREE VISUAL"
        {
            return UITheme.modeVisualText
        }
        if text == "NORMAL" || text.hasPrefix("NORMAL ")
            || text == "TREE" || text.hasPrefix("TREE ")
            || text == "LIST" || text.hasPrefix("LIST ")
        {
            return UITheme.modeNormalText
        }
        return UITheme.sidebarSecondaryText
    }

    func outlineViewSelectionDidChange(_: Notification) {
        guard !suppressSelectionCallback,
            let item = outlineView.item(atRow: outlineView.selectedRow) as? Item
        else { return }
        switch item.kind {
        case .fixed(let fixed):
            onSelectFixed?(fixed)
        case .node(let node) where !node.isFolder:
            onSelectNote?(node.url)
        default:
            break
        }
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !suppressExpansionBookkeeping,
            let item = notification.userInfo?["NSObject"] as? Item
        else { return }
        if let url = item.fileNode?.url {
            expandedURLs.insert(url)
        }
        outlineView.reloadItem(item)  // refresh the chevron direction
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !suppressExpansionBookkeeping,
            let item = notification.userInfo?["NSObject"] as? Item
        else { return }
        if let url = item.fileNode?.url {
            expandedURLs.remove(url)
        }
        outlineView.reloadItem(item)
    }
}

// MARK: - Drag & drop (filesystem moves)

extension SidebarViewController {
    func outlineView(_: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = (item as? Item)?.fileNode else { return nil }
        return node.url as NSURL
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        validateDrop info: NSDraggingInfo,
        proposedItem item: Any?,
        proposedChildIndex _: Int
    ) -> NSDragOperation {
        guard let sources = draggedURLs(info), !sources.isEmpty else { return [] }
        let (targetItem, folder) = dropTarget(for: item)
        let target = folder.standardizedFileURL
        for source in sources.map(\.standardizedFileURL) {
            if source.deletingLastPathComponent() == target { return [] }  // no-op
            if target == source || target.path.hasPrefix(source.path + "/") {
                return []  // folder into itself / its own descendant
            }
        }
        // Always drop ON the resolved folder (order is alphabetical, not manual).
        outlineView.setDropItem(targetItem, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return .move
    }

    func outlineView(
        _: NSOutlineView,
        acceptDrop info: NSDraggingInfo,
        item: Any?,
        childIndex _: Int
    ) -> Bool {
        guard let sources = draggedURLs(info), !sources.isEmpty else { return false }
        let (_, folder) = dropTarget(for: item)
        expandedURLs.insert(folder)  // reveal where things landed
        var lastMoved: URL?
        for source in sources {
            if let dest = session.moveItem(at: source, into: folder) {
                lastMoved = dest
            }
        }
        guard let lastMoved else { return false }
        select(url: lastMoved, notify: false)
        return true
    }

    /// Resolves any proposed drop item to (folder item, folder URL): folders
    /// take the drop directly, files redirect to their parent, fixed rows and
    /// the gap mean the vault root.
    private func dropTarget(for proposed: Any?) -> (Item?, URL) {
        guard let item = proposed as? Item, let node = item.fileNode else {
            return (nil, session.vault.rootURL)
        }
        if node.isFolder {
            return (item, node.url)
        }
        let parent = node.url.deletingLastPathComponent().standardizedFileURL
        if parent == session.vault.rootURL.standardizedFileURL {
            return (nil, parent)
        }
        return (itemsByURL[parent], parent)
    }

    private func draggedURLs(_ info: NSDraggingInfo) -> [URL]? {
        info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]
    }
}
