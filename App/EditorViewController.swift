import AppKit
import EditorKit

/// Hosts the EditorKit editing surface and connects it to the session's
/// autosave pipeline.
@MainActor
final class EditorViewController: NSViewController {
    private let session: VaultSession
    let editor = MarkdownEditorView()
    private let emptyLabel = NSTextField(labelWithString: "No note selected")

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
        editor.onTextChange = { [weak self] in
            guard let self else { return }
            let editorView = self.editor
            self.session.noteEdited { editorView.string }
        }
    }

    func display(text: String) {
        editor.isHidden = false
        emptyLabel.isHidden = true
        editor.load(text: text)
    }

    func displayEmpty() {
        editor.isHidden = true
        emptyLabel.isHidden = false
    }

    func focusEditor() {
        editor.focus()
    }
}
