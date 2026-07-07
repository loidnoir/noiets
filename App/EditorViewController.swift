import AppKit
import EditorKit

/// Hosts the EditorKit editing surface and connects it to the session's
/// autosave pipeline.
@MainActor
final class EditorViewController: NSViewController {
    private let session: VaultSession
    let editor = MarkdownEditorView()
    private let emptyLabel = NSTextField(labelWithString: "No note selected")

    /// Fired (with the current text) on every edit — inspector outline refresh.
    var onEdited: ((String) -> Void)?

    init(session: VaultSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let container = ColorView(color: editor.theme.background)
        view = container

        editor.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(editor)
        emptyLabel.font = .systemFont(ofSize: 15)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            editor.topAnchor.constraint(equalTo: container.topAnchor),
            editor.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            editor.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        editor.isHidden = true
        editor.resourceRoot = session.vault.rootURL
        editor.onTextChange = { [weak self] in
            guard let self, !self.isReadOnly else { return }
            let editorView = self.editor
            self.session.noteEdited { editorView.string }
            self.onEdited?(editorView.string)
        }
    }

    /// Read-only display (the built-in docs): rendered like a note, never
    /// typed into, never saved anywhere.
    private(set) var isReadOnly = false

    /// Selects + reveals a source range (outline/backlink navigation).
    func jump(to range: NSRange) {
        let length = (editor.string as NSString).length
        guard range.location <= length else { return }
        let clamped = NSRange(location: range.location,
                              length: min(range.length, length - range.location))
        editor.textView.setSelectedRange(clamped)
        editor.textView.scrollRangeToVisible(clamped)
        focusEditor()
    }

    func display(text: String, readOnly: Bool = false, animated: Bool = false) {
        if animated, !editor.isHidden {
            UIAnimation.fadeNextChange(of: view)
        }
        editor.isHidden = false
        emptyLabel.isHidden = true
        editor.load(text: text)
        setReadOnly(readOnly)
    }

    /// Flips the lock state in place — no reload, caret and scroll stay put.
    func setReadOnly(_ readOnly: Bool) {
        isReadOnly = readOnly
        editor.setLocked(readOnly)
    }

    func displayEmpty(animated: Bool = false) {
        if animated, !editor.isHidden {
            UIAnimation.fadeNextChange(of: view)
        }
        editor.isHidden = true
        emptyLabel.isHidden = false
    }

    func focusEditor() {
        editor.focus()
    }
}
