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
    private let outlineView = SidebarOutlineView()
    private let modeBar = ColorView(color: UITheme.modeBarBackground)
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
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.menu = buildContextMenu()

        // Click anywhere on a folder row to open/close it.
        outlineView.target = self
        outlineView.action = #selector(rowClicked)

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

        // Vim mode bar: pinned to the sidebar bottom, full width minus the
        // same margins the rows use.
        modeBar.wantsLayer = true
        modeBar.layer?.cornerRadius = 7
        modeBar.translatesAutoresizingMaskIntoConstraints = false
        modeLabel.font = .monospacedSystemFont(ofSize: 10.5, weight: .bold)
        modeLabel.textColor = UITheme.sidebarSecondaryText
        modeLabel.alignment = .center
        modeLabel.lineBreakMode = .byTruncatingTail
        modeLabel.translatesAutoresizingMaskIntoConstraints = false
        modeBar.addSubview(modeLabel)
        view.addSubview(modeBar)

        NSLayoutConstraint.activate([
            // Content starts a breath below the titlebar, like Things.
            scrollView.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10
            ),
            scrollView.bottomAnchor.constraint(equalTo: modeBar.topAnchor, constant: -8),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            modeBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            modeBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            modeBar.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
            modeBar.heightAnchor.constraint(equalToConstant: 26),
            modeLabel.centerXAnchor.constraint(equalTo: modeBar.centerXAnchor),
            modeLabel.centerYAnchor.constraint(equalTo: modeBar.centerYAnchor),
            modeLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: modeBar.leadingAnchor, constant: 8
            ),
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

    // MARK: Folder toggling

    @objc private func rowClicked() {
        guard outlineView.clickedRow >= 0,
              let item = outlineView.item(atRow: outlineView.clickedRow) as? Item,
              let node = item.fileNode, node.isFolder, !item.children.isEmpty else { return }
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
        info["actionWired"] = outlineView.action == #selector(rowClicked)
            && outlineView.target === self
        let folderItem = rootItems.first {
            $0.fileNode?.isFolder == true && !$0.children.isEmpty
        }
        if let folderItem {
            info["rowForItem"] = outlineView.row(forItem: folderItem) // -1 = identity unknown
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
        info["dragSourceExposed"] = ds?.responds(
            to: #selector(NSOutlineViewDataSource.outlineView(_:pasteboardWriterForItem:))) ?? false
        info["dropValidateExposed"] = ds?.responds(
            to: #selector(NSOutlineViewDataSource.outlineView(_:validateDrop:proposedItem:proposedChildIndex:))) ?? false
        info["dropAcceptExposed"] = ds?.responds(
            to: #selector(NSOutlineViewDataSource.outlineView(_:acceptDrop:item:childIndex:))) ?? false
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
                in: outlineView, title: fixed.title, symbol: fixed.symbol, isFolder: false
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
            case .separator: return 18 // pure air
            case .node(let node) where node.isFolder: return 34
            case .fixed, .node: return 28
            }
        }
        return 28
    }

    /// Vim mode/status display (driven by the window controller).
    func setVimStatus(_ text: String) {
        modeLabel.stringValue = text
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
              let item = notification.userInfo?["NSObject"] as? Item else { return }
        if let url = item.fileNode?.url {
            expandedURLs.insert(url)
        }
        outlineView.reloadItem(item) // refresh the chevron direction
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !suppressExpansionBookkeeping,
              let item = notification.userInfo?["NSObject"] as? Item else { return }
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
            if source.deletingLastPathComponent() == target { return [] } // no-op
            if target == source || target.path.hasPrefix(source.path + "/") {
                return [] // folder into itself / its own descendant
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
        expandedURLs.insert(folder) // reveal where things landed
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
