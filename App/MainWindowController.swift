import AppKit
import VaultStore

/// The single main window: two-pane split (sidebar | editor), toggleable
/// right panel arrives in M5. Owns note-opening and the first-responder
/// actions behind the File/View menus.
@MainActor
final class MainWindowController: NSWindowController {
    let session: VaultSession
    private let splitVC = NSSplitViewController()
    private let sidebarVC: SidebarViewController
    private let editorVC: EditorViewController
    private var sidebarItem: NSSplitViewItem?

    init(session: VaultSession) {
        self.session = session
        self.sidebarVC = SidebarViewController(session: session)
        self.editorVC = EditorViewController(session: session)

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

        let sidebar = NSSplitViewItem(viewController: sidebarVC)
        sidebar.minimumThickness = 190
        sidebar.maximumThickness = 360
        sidebar.canCollapse = true
        sidebar.holdingPriority = NSLayoutConstraint.Priority(261)
        sidebarItem = sidebar

        let editorItem = NSSplitViewItem(viewController: editorVC)
        editorItem.minimumThickness = 420

        splitVC.addSplitViewItem(sidebar)
        splitVC.addSplitViewItem(editorItem)
        splitVC.splitView.dividerStyle = .thin
        window.contentViewController = splitVC

        sidebarVC.onSelectNote = { [weak self] url in self?.open(noteAt: url) }
        sidebarVC.onCurrentNoteRemoved = { [weak self] in self?.showEmpty() }

        if let first = session.firstNote() {
            open(noteAt: first)
            sidebarVC.select(url: first, notify: false)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Note routing

    func open(noteAt url: URL) {
        guard let text = session.readNote(at: url) else {
            NSSound.beep()
            return
        }
        session.noteOpened(url)
        editorVC.display(text: text)
        window?.title = url.deletingPathExtension().lastPathComponent
        editorVC.focusEditor()
    }

    private func showEmpty() {
        editorVC.displayEmpty()
        window?.title = session.vault.name
    }

    // MARK: Menu actions (first responder)

    @objc func newNote(_ sender: Any?) {
        guard let url = session.createNote(in: sidebarVC.selectedFolderURL) else { return }
        sidebarVC.select(url: url, notify: false)
        open(noteAt: url)
    }

    @objc func newFolder(_ sender: Any?) {
        _ = session.createFolder(in: sidebarVC.selectedFolderURL)
    }

    @objc func saveNote(_ sender: Any?) {
        session.flushPendingSave()
    }

    @objc func revealInFinder(_ sender: Any?) {
        guard let url = session.currentNoteURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc func moveNoteToTrash(_ sender: Any?) {
        guard let url = session.currentNoteURL else { return }
        session.trashNote(url)
        showEmpty()
    }

    @objc func toggleSidebarPane(_ sender: Any?) {
        guard let sidebarItem else { return }
        sidebarItem.animator().isCollapsed.toggle()
    }
}

// MARK: - Menu validation

extension MainWindowController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let needsOpenNote: Set<Selector> = [
            #selector(MainWindowController.saveNote(_:)),
            #selector(MainWindowController.revealInFinder(_:)),
            #selector(MainWindowController.moveNoteToTrash(_:)),
        ]
        if let action = menuItem.action, needsOpenNote.contains(action) {
            return session.currentNoteURL != nil
        }
        return true
    }
}
