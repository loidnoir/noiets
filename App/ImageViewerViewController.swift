import AppKit
import EditorKit

/// Shows an image file in the content pane — the same slot notes open in.
/// Fit-to-pane, never upscaled. ⌃h returns keyboard focus to the tree.
final class ImageViewerViewController: NSViewController {
    var onFocusSidebar: (() -> Void)?

    private(set) var currentURL: URL?
    private let imageView = NSImageView()

    override func loadView() {
        let pane = ImagePaneView()
        pane.onPaneLeft = { [weak self] in self?.onFocusSidebar?() }

        imageView.imageScaling = .scaleProportionallyDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: pane.topAnchor, constant: 28),
            imageView.bottomAnchor.constraint(equalTo: pane.bottomAnchor, constant: -28),
            imageView.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 28),
            imageView.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -28),
        ])
        view = pane
    }

    func display(url: URL) {
        currentURL = url
        _ = view // force load
        imageView.image = NSImage(contentsOf: url)
    }

    func focusImage() {
        view.window?.makeFirstResponder(view)
    }
}

/// Focusable canvas behind the image; matches the editor background so the
/// content pane reads as one surface.
private final class ImagePaneView: NSView {
    var onPaneLeft: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        EditorTheme.standard().background.setFill()
        dirtyRect.fill()
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control),
           let ch = event.charactersIgnoringModifiers,
           ["h", "j", "k"].contains(ch) {
            onPaneLeft?()
            return
        }
        super.keyDown(with: event)
    }
}
