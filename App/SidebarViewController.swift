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

    private let scrollView = NSScrollView()
    private let outlineView = NSOutlineView()
    private var suppressSelectionCallback = false

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

        init(_ kind: Kind) { self.kind = kind }

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
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: View

    override func loadView() {
        view = ColorView(color: UITheme.sidebarBackground)

        let column = NSTableColumn(identifier: .init("main"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .fullWidth
        outlineView.rowHeight = 26
        outlineView.intercellSpacing = NSSize(width: 0, height: 1)
        outlineView.backgroundColor = .clear
        outlineView.focusRingType = .none
        outlineView.indentationPerLevel = 12
        outlineView.autoresizesOutlineColumn = false
        outlineView.allowsEmptySelection = true
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.menu = buildContextMenu()

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        rebuildItems()
        outlineView.reloadData()
        session.onTreeChange = { [weak self] in self?.reload() }
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
              let item = outlineView.item(atRow: outlineView.selectedRow) as? Item else { return nil }
        return item.fileNode?.url
    }

    /// The folder new notes should land in, based on the current selection.
    var selectedFolderURL: URL? {
        guard let item = outlineView.item(atRow: outlineView.selectedRow) as? Item,
              let node = item.fileNode else { return nil }
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
              let item = outlineView.item(atRow: outlineView.clickedRow) as? Item else { return nil }
        return item.fileNode
    }

    private func clickedFolderURL() -> URL {
        guard let node = clickedNode() else { return session.vault.rootURL }
        return node.isFolder ? node.url : node.url.deletingLastPathComponent()
    }

    @objc private func ctxNewNote(_ sender: Any?) {
        guard let url = session.createNote(in: clickedFolderURL()) else { return }
        select(url: url, notify: false)
        onSelectNote?(url)
    }

    @objc private func ctxNewFolder(_ sender: Any?) {
        _ = session.createFolder(in: clickedFolderURL())
    }

    @objc private func ctxReveal(_ sender: Any?) {
        guard let node = clickedNode() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([node.url])
    }

    @objc private func ctxTrash(_ sender: Any?) {
        guard let node = clickedNode() else { return }
        session.trashNote(node.url)
        if session.currentNoteURL == nil {
            onCurrentNoteRemoved?()
        }
    }
}

// MARK: - Data source

extension SidebarViewController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item = item as? Item else { return rootItems.count }
        return item.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item = item as? Item else { return rootItems[index] }
        return item.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let item = item as? Item else { return false }
        return !item.children.isEmpty
    }
}

// MARK: - Delegate

extension SidebarViewController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? Item else { return nil }
        switch item.kind {
        case .separator:
            return SeparatorCellView.make(in: outlineView)
        case .fixed(let fixed):
            return SidebarCellView.make(in: outlineView, title: fixed.title, symbol: fixed.symbol, isFolder: false)
        case .node(let node):
            return SidebarCellView.make(in: outlineView, title: node.title, symbol: nil, isFolder: node.isFolder)
        }
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        SoftRowView()
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let item = item as? Item else { return false }
        switch item.kind {
        case .separator: return false
        case .fixed, .node: return true
        }
    }

    /// Programmatic selection of a fixed row (e.g. ⇧⌘F selects Search).
    func selectFixed(_ fixed: Fixed) {
        guard let item = rootItems.first(where: {
            if case .fixed(let f) = $0.kind { return f == fixed }
            return false
        }) else { return }
        let row = outlineView.row(forItem: item)
        guard row >= 0 else { return }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        if let item = item as? Item, case .separator = item.kind { return 11 }
        return 26
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelectionCallback,
              let item = outlineView.item(atRow: outlineView.selectedRow) as? Item else { return }
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
        if let url = ((notification.userInfo?["NSObject"] as? Item)?.fileNode?.url) {
            expandedURLs.insert(url)
        }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        if let url = ((notification.userInfo?["NSObject"] as? Item)?.fileNode?.url) {
            expandedURLs.remove(url)
        }
    }
}
