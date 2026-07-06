import AppKit
import EditorKit

/// Shows an image file in the content pane — the same slot notes open in.
/// Opens fit-to-pane (never upscaled); a click zooms in around the click
/// point and a second click zooms back out. Pinch and smart-magnify work
/// through the scroll view. ⌃h returns keyboard focus to the tree.
final class ImageViewerViewController: NSViewController {
    var onFocusSidebar: (() -> Void)?

    private(set) var currentURL: URL?
    private let imageView = NSImageView()
    private let scrollView = NSScrollView()
    private var isZoomedIn = false

    override func loadView() {
        let pane = ImagePaneView()
        pane.onPaneLeft = { [weak self] in self?.onFocusSidebar?() }

        // The image view is the scroll document at the image's natural size;
        // magnification does the scaling, so 1.0 is always pixels-for-points.
        imageView.imageScaling = .scaleAxesIndependently
        scrollView.contentView = CenteringClipView()
        scrollView.documentView = imageView
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.02
        scrollView.maxMagnification = 8
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: pane.topAnchor, constant: 28),
            scrollView.bottomAnchor.constraint(equalTo: pane.bottomAnchor, constant: -28),
            scrollView.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 28),
            scrollView.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -28),
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(imageClicked(_:)))
        imageView.addGestureRecognizer(click)
        view = pane
    }

    func display(url: URL) {
        currentURL = url
        _ = view // force load
        let image = NSImage(contentsOf: url)
        imageView.image = image
        imageView.frame = NSRect(origin: .zero, size: image?.size ?? .zero)
        isZoomedIn = false
        view.layoutSubtreeIfNeeded()
        scrollView.magnification = fitMagnification
    }

    func focusImage() {
        view.window?.makeFirstResponder(view)
    }

    /// Keep the fit while the pane resizes, until the user zooms in.
    override func viewDidLayout() {
        super.viewDidLayout()
        if imageView.image != nil, !isZoomedIn {
            scrollView.magnification = fitMagnification
        }
    }

    /// Fit-to-pane, never upscaled (matches the old static behavior).
    private var fitMagnification: CGFloat {
        guard let size = imageView.image?.size, size.width > 0, size.height > 0,
              scrollView.frame.width > 0, scrollView.frame.height > 0
        else { return 1 }
        return min(1, scrollView.frame.width / size.width,
                   scrollView.frame.height / size.height)
    }

    @objc private func imageClicked(_ gesture: NSClickGestureRecognizer) {
        if isZoomedIn {
            isZoomedIn = false
            scrollView.animator().magnification = fitMagnification
        } else {
            isZoomedIn = true
            let target = max(1, fitMagnification * 2.5)
            scrollView.animator().setMagnification(
                target, centeredAt: gesture.location(in: imageView))
        }
    }
}

/// Keeps a smaller-than-pane document centered instead of pinned bottom-left.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return rect }
        if doc.frame.width < rect.width {
            rect.origin.x = doc.frame.midX - rect.width / 2
        }
        if doc.frame.height < rect.height {
            rect.origin.y = doc.frame.midY - rect.height / 2
        }
        return rect
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
