import AppKit
import IndexKit
import MarkdownKit
import UniformTypeIdentifiers
import VaultStore
import VimKit

/// The single main window: two-pane split (sidebar | content host). The host
/// swaps between the editor and the Search/Recent/Trash views; ⌘O/⌘P overlay
/// panels ride on top. Owns note-routing and the first-responder menu actions.
@MainActor
final class MainWindowController: NSWindowController {
    let session: VaultSession
    private let splitVC = NSSplitViewController()
    private let sidebarVC: SidebarViewController
    private let editorVC: EditorViewController
    private let searchVC: SearchViewController
    private let trashVC: TrashViewController
    private let inspectorVC: InspectorViewController
    private let hostVC = ContentHostController()
    private lazy var imageVC: ImageViewerViewController = {
        let vc = ImageViewerViewController()
        vc.onFocusSidebar = { [weak self] in self?.sidebarVC.focusTree() }
        return vc
    }()
    private var sidebarItem: NSSplitViewItem?
    private var inspectorItem: NSSplitViewItem?

    init(session: VaultSession) {
        self.session = session
        sidebarVC = SidebarViewController(session: session)
        editorVC = EditorViewController(session: session)
        searchVC = SearchViewController(session: session)
        trashVC = TrashViewController(session: session)
        inspectorVC = InspectorViewController(session: session)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.title = session.vault.name
        window.minSize = NSSize(width: 760, height: 480)
        window.center()
        window.setFrameAutosaveName("NoietsMainWindow")
        window.isRestorable = false
        window.tabbingMode = .disallowed

        super.init(window: window)

        // Seamless panes: no drawn divider, the color edge is the separation.
        let seamless = SeamlessSplitView()
        seamless.isVertical = true
        seamless.dividerStyle = .thin
        splitVC.splitView = seamless

        let sidebar = NSSplitViewItem(viewController: sidebarVC)
        sidebar.minimumThickness = 300
        sidebar.maximumThickness = 500
        sidebar.canCollapse = true
        sidebar.holdingPriority = NSLayoutConstraint.Priority(261)
        sidebarItem = sidebar

        let contentItem = NSSplitViewItem(viewController: hostVC)
        contentItem.minimumThickness = 420

        let inspector = NSSplitViewItem(viewController: inspectorVC)
        inspector.minimumThickness = 210
        inspector.maximumThickness = 320
        inspector.canCollapse = true
        inspector.holdingPriority = NSLayoutConstraint.Priority(262)
        inspector.isCollapsed = true
        inspectorItem = inspector

        splitVC.addSplitViewItem(sidebar)
        splitVC.addSplitViewItem(contentItem)
        splitVC.addSplitViewItem(inspector)
        splitVC.splitView.dividerStyle = .thin
        window.contentViewController = splitVC
        hostVC.show(editorVC)

        sidebarVC.onSelectNote = { [weak self] url in self?.open(noteAt: url) }
        sidebarVC.onSelectFixed = { [weak self] fixed in self?.showFixed(fixed) }
        sidebarVC.onSelectView = { [weak self] ref in self?.showView(ref) }
        sidebarVC.onCurrentNoteRemoved = { [weak self] in self?.showEmpty() }
        searchVC.onOpenNote = { [weak self] url in
            self?.open(noteAt: url)
            self?.sidebarVC.select(url: url, notify: false)
        }
        session.onIndexChanged = { [weak self] in
            self?.searchVC.indexChanged()
            self?.inspectorVC.indexChanged()
        }
        // Trash contents change from anywhere (tree dd, editor, FSEvents) —
        // keep the view live while it's the visible content.
        session.onTreeChange { [weak self] in
            guard let self, self.hostVC.current === self.trashVC else { return }
            self.trashVC.reload()
        }

        // Wiki-links, tags, inspector navigation.
        editorVC.editor.onOpenWikiLink = { [weak self] target in
            self?.openWikiLink(target)
        }
        editorVC.editor.onOpenTag = { [weak self] tag in
            self?.showTag(tag)
        }
        editorVC.editor.wikiCompletionProvider = { [weak self] query in
            guard let index = self?.session.index else { return [] }
            let rows = (try? index.quickOpen(query, limit: 8)) ?? []
            return rows.map(\.title)
        }
        editorVC.onEdited = { [weak self] text in
            self?.inspectorVC.noteEdited(text: text)
        }
        editorVC.editor.onVimModeChange = { [weak self] mode in
            self?.updateVimBar(mode: mode)
        }
        editorVC.editor.onVimStatus = { [weak self] status in
            self?.vimStatusSuffix = status
            self?.updateVimBar(mode: nil)
        }
        updateVimBar(mode: .normal)

        // Pane navigation: ⌃h from the editor → tree; ⌃l/Esc in tree → editor.
        editorVC.editor.textView.onPaneNavigate = { [weak self] direction in
            if direction == "h" || direction == "j" || direction == "k" {
                self?.sidebarVC.focusTree()
            }
        }
        sidebarVC.onFocusEditor = { [weak self] in
            self?.focusCurrentContent()
        }
        searchVC.onFocusSidebar = { [weak self] in self?.sidebarVC.focusTree() }
        trashVC.onFocusSidebar = { [weak self] in self?.sidebarVC.focusTree() }
        // Vault image files open in the content pane; everything else falls
        // back to the system default.
        editorVC.editor.onOpenImageFile = { [weak self] url in
            guard let self else { return }
            if Vault.isImageFile(url) {
                self.open(noteAt: url)
            } else {
                NSWorkspace.shared.open(url)
            }
        }
        inspectorVC.onJumpToHeading = { [weak self] range in
            self?.editorVC.jump(to: range)
        }
        inspectorVC.onOpenNote = { [weak self] url, range in
            self?.open(noteAt: url)
            self?.sidebarVC.select(url: url, notify: false)
            if let range { self?.editorVC.jump(to: range) }
        }

        // Index first: lock state lives in the project database, and the
        // first open below already needs it.
        session.startIndexing()

        if let first = session.firstNote() {
            open(noteAt: first)
            sidebarVC.select(url: first, notify: false)
        }
        startObservingFocus()

        if ProcessInfo.processInfo.environment["NOIETS_SHOW_INSPECTOR"] == "1" {
            inspector.isCollapsed = false
        }
        applyDevHooks()
    }

    /// Dev-only: NOIETS_OPEN=<link target> opens a note by name;
    /// NOIETS_SCROLL_TO=<needle> scrolls the editor to the first occurrence;
    /// NOIETS_SHOW=search|views|trash opens a fixed sidebar view;
    /// NOIETS_VIEW_QUERY=<noql> opens a probe view with that query.
    private func applyDevHooks() {
        let env = ProcessInfo.processInfo.environment
        if let name = env["NOIETS_OPEN"], !name.isEmpty {
            openWikiLink(name)
        }
        switch env["NOIETS_SHOW"] {
        case "search": showFixed(.search)
        case "views", "recent": showFixed(.views)
        case "trash": showFixed(.trash)
        case "docs": openDocs()
        default: break
        }
        if let query = env["NOIETS_VIEW_QUERY"], !query.isEmpty {
            showView(ViewRef(name: "Probe", query: query, isBuiltin: false))
        }
        if let needle = env["NOIETS_SCROLL_TO"], !needle.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self else { return }
                let text = self.editorVC.editor.string as NSString
                let range = text.range(of: needle)
                if range.location != NSNotFound {
                    self.editorVC.jump(to: NSRange(location: range.location, length: 0))
                }
            }
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: Routing

    func open(noteAt url: URL) {
        if Vault.isImageFile(url) {
            imageVC.display(url: url)
            hostVC.show(imageVC)
            window?.title = url.lastPathComponent
            imageVC.focusImage()
            return
        }
        let locked = session.isLocked(url)
        guard let text = session.readNote(at: url) else {
            NSSound.beep()
            return
        }
        session.noteOpened(url)
        hostVC.show(editorVC)
        editorVC.editor.noteFolderURL = url.deletingLastPathComponent()
        editorVC.display(text: text, readOnly: locked)
        window?.title = url.deletingPathExtension().lastPathComponent
        editorVC.focusEditor()
        inspectorVC.update(noteURL: url, text: text)
        updateVimBar(mode: nil)
    }

    /// ⌘L: toggles write-lock on the open note (locked notes render fully —
    /// no raw source on the caret line — and reject every edit). The state
    /// flips in place: caret and scroll position stay where they are.
    @objc func toggleNoteLock(_: Any?) {
        guard let url = session.currentNoteURL else {
            NSSound.beep() // the built-in docs page can't be unlocked
            return
        }
        session.flushPendingSave()
        let locked = !session.isLocked(url)
        session.setLocked(url, locked)
        editorVC.setReadOnly(locked)
        updateVimBar(mode: nil)
    }

    /// [[target]] navigation with Obsidian-style create-on-missing.
    func openWikiLink(_ target: String) {
        // Index first (matches titles too), live tree as the fallback so a
        // still-warming index never causes a duplicate note.
        let resolved =
            (try? session.index?.note(matchingLinkTarget: target))
            .flatMap { $0 }
            .map { session.url(forRelPath: $0.relPath) }
            ?? session.noteInTree(matching: target)
        if let url = resolved {
            open(noteAt: url)
            sidebarVC.select(url: url, notify: false)
            return
        }
        // Create in the vault root, named after the link target.
        guard
            let url = try? NoteIO.createNote(
                in: session.vault.rootURL,
                baseName: target,
                contents: "# \(target)\n\n"
            )
        else { return }
        session.rescan()
        sidebarVC.select(url: url, notify: false)
        open(noteAt: url)
    }

    private func showFixed(_ fixed: SidebarViewController.Fixed) {
        session.flushPendingSave()
        switch fixed {
        case .search:
            searchVC.show(mode: .search)
            hostVC.show(searchVC)
            searchVC.focusSearch()
        case .views:
            showView(.unnamed) // empty query = everything, newest first
        case .trash:
            trashVC.reload()
            hostVC.show(trashVC)
            trashVC.focusList()
        }
        window?.title = session.vault.name
    }

    /// The built-in docs: a read-only markdown page bundled with the app.
    func openDocs() {
        guard let url = Bundle.main.url(forResource: "Docs", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        session.flushPendingSave()
        hostVC.show(editorVC)
        editorVC.display(text: text, readOnly: true)
        window?.title = "Noiets Docs"
        editorVC.focusEditor()
    }

    /// Opens a sidebar view (built-in Recent or a saved query).
    func showView(_ ref: ViewRef) {
        session.flushPendingSave()
        searchVC.show(mode: .view(ref))
        hostVC.show(searchVC)
        searchVC.focusList() // j/k works straight away
        window?.title = session.vault.name
    }

    /// ⌃l from the tree focuses whatever the content pane currently shows.
    private func focusCurrentContent() {
        switch hostVC.current {
        case let vc where vc === searchVC:
            searchVC.focusPreferred()
        case let vc where vc === trashVC:
            trashVC.focusList()
        case let vc where vc === imageVC:
            imageVC.focusImage()
        default:
            editorVC.focusEditor()
        }
    }

    func showTag(_ name: String) {
        sidebarVC.selectFixed(.search)
        searchVC.show(mode: .tag(name))
        hostVC.show(searchVC)
    }

    private func showEmpty() {
        editorVC.displayEmpty()
        hostVC.show(editorVC)
        window?.title = session.vault.name
    }

    // MARK: Vim mode bar (lives in the sidebar)

    private var vimStatusSuffix = ""

    private var responderObservation: NSKeyValueObservation?

    /// The mode bar doubles as the pane indicator: TREE / LIST while a list
    /// owns the keyboard, the vim mode while the editor does.
    private func startObservingFocus() {
        responderObservation = window?.observe(\.firstResponder) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.updateVimBar(mode: nil)
            }
        }
    }

    private func updateVimBar(mode: VimMode?) {
        if let responder = window?.firstResponder {
            if responder is NSOutlineView {
                sidebarVC.setVimStatus("TREE")
                return
            }
            if responder is NSTableView {
                sidebarVC.setVimStatus("LIST")
                return
            }
        }
        // Locked documents (docs page, ⌘L-locked notes) read, never write —
        // but transient status (a /search prompt, the match counter, :N)
        // still shows next to the LOCKED badge.
        if hostVC.current === editorVC || hostVC.current == nil, editorVC.isReadOnly {
            sidebarVC.setVimStatus(
                vimStatusSuffix.isEmpty ? "LOCKED" : "LOCKED  \(vimStatusSuffix)"
            )
            return
        }
        let current = mode ?? editorVC.editor.vim.mode
        let text =
            vimStatusSuffix.isEmpty
            ? current.label
            : "\(current.label)  \(vimStatusSuffix)"
        sidebarVC.setVimStatus(text)
    }

    // MARK: Menu actions (first responder)

    @objc func newNote(_: Any?) {
        guard let url = session.createNote(in: sidebarVC.selectedFolderURL) else { return }
        sidebarVC.select(url: url, notify: false)
        open(noteAt: url)
    }

    @objc func newFolder(_: Any?) {
        _ = session.createFolder(in: sidebarVC.selectedFolderURL)
    }

    @objc func saveNote(_: Any?) {
        session.flushPendingSave()
    }

    @objc func revealInFinder(_: Any?) {
        guard let url = session.currentNoteURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc func moveNoteToTrash(_: Any?) {
        guard let url = session.currentNoteURL else { return }
        session.trashNote(url)
        showEmpty()
    }

    @objc func toggleSidebarPane(_: Any?) {
        guard let sidebarItem else { return }
        sidebarItem.animator().isCollapsed.toggle()
    }

    @objc func toggleRightPanel(_: Any?) {
        guard let inspectorItem else { return }
        inspectorItem.animator().isCollapsed.toggle()
    }

    @objc func searchVault(_: Any?) {
        sidebarVC.selectFixed(.search)  // triggers showFixed(.search)
    }

    @objc func exportHTML(_: Any?) {
        guard let url = session.currentNoteURL, let window else { return }
        session.flushPendingSave()
        let title = url.deletingPathExtension().lastPathComponent
        let markdown = editorVC.editor.string

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(title).html"
        panel.allowedContentTypes = [.html]
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let dest = panel.url else { return }
            let html = HTMLExport.html(from: markdown, title: title)
            try? Data(html.utf8).write(to: dest)
        }
    }

    @objc func exportPDF(_: Any?) {
        guard let url = session.currentNoteURL, let window else { return }
        session.flushPendingSave()
        let title = url.deletingPathExtension().lastPathComponent
        let markdown = editorVC.editor.string
        let baseURL = url.deletingLastPathComponent()

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(title).pdf"
        panel.allowedContentTypes = [.pdf]
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let dest = panel.url else { return }
            let html = HTMLExport.html(from: markdown, title: title)
            PDFExport.export(html: html, baseURL: baseURL, to: dest, for: window)
        }
    }

    // MARK: Overlays

    @objc func quickOpen(_: Any?) {
        guard let window, let index = session.index else { return }
        PalettePanel.shared.present(over: window, placeholder: "Open note…") { [weak self] query in
            guard let self else { return [] }
            let rows = (try? index.quickOpen(query)) ?? []
            return rows.map { row in
                PalettePanel.Item(symbol: nil, title: row.title, subtitle: row.relPath,
                                  image: AppIcons.document(size: 18)) {
                    let url = self.session.url(forRelPath: row.relPath)
                    self.open(noteAt: url)
                    self.sidebarVC.select(url: url, notify: false)
                }
            }
        }
    }

    @objc func commandPalette(_: Any?) {
        guard let window else { return }
        PalettePanel.shared.present(over: window, placeholder: "Type a command or # for tags…") {
            [weak self] query in
            self?.paletteItems(for: query) ?? []
        }
    }

    private func paletteItems(for query: String) -> [PalettePanel.Item] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)

        // Tag browsing: "#" prefix lists tags.
        if q.hasPrefix("#") {
            let filter = String(q.dropFirst())
            let tags = (try? session.index?.allTags()) ?? []
            return
                tags
                .filter { filter.isEmpty || $0.name.contains(filter) }
                .map { tag in
                    PalettePanel.Item(
                        symbol: "number", title: "#\(tag.name)",
                        subtitle: "\(tag.count) note\(tag.count == 1 ? "" : "s")"
                    ) { [weak self] in
                        self?.showTag(tag.name)
                    }
                }
        }

        // (title, SF fallback, custom icon, action)
        let commands: [(String, String, NSImage?, @MainActor () -> Void)] = [
            ("Add Note", "square.and.pencil", AppIcons.addDocument(size: 18),
             { [weak self] in self?.newNote(nil) }),
            ("Add Folder", "folder.badge.plus", AppIcons.addFolder(size: 18),
             { [weak self] in self?.newFolder(nil) }),
            ("Open Trash", "trash", AppIcons.trash(size: 18),
             { [weak self] in self?.sidebarVC.selectFixed(.trash) }),
            ("Toggle Sidebar", "sidebar.left", AppIcons.sidebar(size: 18),
             { [weak self] in self?.toggleSidebarPane(nil) }),
            ("Reveal in Finder", "finder", AppIcons.finder(size: 18),
             { [weak self] in self?.revealInFinder(nil) }),
            ("Open Docs", "book", AppIcons.docs(size: 18),
             { [weak self] in self?.openDocs() }),
            ("Save Note", "internaldrive", AppIcons.save(size: 18),
             { [weak self] in self?.saveNote(nil) }),
        ]
        return
            commands
            .filter { q.isEmpty || $0.0.lowercased().contains(q) }
            .map { cmd in
                PalettePanel.Item(symbol: cmd.1, title: cmd.0, subtitle: nil,
                                  image: cmd.2, action: cmd.3)
            }
    }
}

// MARK: - Menu validation

extension MainWindowController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let needsOpenNote: Set<Selector> = [
            #selector(MainWindowController.saveNote(_:)),
            #selector(MainWindowController.revealInFinder(_:)),
            #selector(MainWindowController.moveNoteToTrash(_:)),
            #selector(MainWindowController.exportHTML(_:)),
            #selector(MainWindowController.exportPDF(_:)),
            #selector(MainWindowController.toggleNoteLock(_:)),
        ]
        if menuItem.action == #selector(MainWindowController.toggleNoteLock(_:)),
           let url = session.currentNoteURL {
            menuItem.title = session.isLocked(url) ? "Unlock Note" : "Lock Note"
        }
        if let action = menuItem.action, needsOpenNote.contains(action) {
            return session.currentNoteURL != nil
        }
        return true
    }
}

/// Hosts one child view controller at a time in the second split pane.
@MainActor
final class ContentHostController: NSViewController {
    private(set) var current: NSViewController?

    override func loadView() {
        view = NSView()
    }

    func show(_ vc: NSViewController) {
        guard vc !== current else { return }
        if let current {
            current.view.removeFromSuperview()
            current.removeFromParent()
        }
        addChild(vc)
        vc.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(vc.view)
        NSLayoutConstraint.activate([
            vc.view.topAnchor.constraint(equalTo: view.topAnchor),
            vc.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            vc.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            vc.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        current = vc
    }
}
