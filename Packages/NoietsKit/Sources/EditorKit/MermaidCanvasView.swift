import AppKit
import RenderKit

/// Interactive viewport for a rendered mermaid diagram — a small canvas in
/// the document: drag or scroll to pan, pinch or ⌘-scroll to zoom,
/// double-click to re-fit. Hovering shows Fit / Edit pills; Edit drops the
/// caret into the opening fence so the block reverts to raw source.
///
/// The view draws from zoom-bucketed bitmap rasters of the (vector, PDF-
/// backed) diagram image, so continuous zoom never re-rasterizes the PDF
/// per frame but text still sharpens at higher zoom levels.
final class MermaidCanvasView: NSView {
    private let theme: EditorTheme
    private var image: NSImage?
    private(set) var sourceKey = ""
    var onEdit: (() -> Void)?

    /// 1 = fitted to the view; pan offset in view points from the centered fit.
    private var zoom: CGFloat = 1
    private var offset: CGPoint = .zero

    private var hovering = false
    private var dragging = false
    private var lastDragPoint: CGPoint = .zero
    private var fitPillRect = CGRect.zero
    private var editPillRect = CGRect.zero
    private var rasterCache: [CGFloat: NSImage] = [:]

    init(theme: EditorTheme) {
        self.theme = theme
        super.init(frame: .zero)
        wantsLayer = true
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    func setImage(_ image: NSImage, sourceKey: String) {
        if sourceKey != self.sourceKey {
            self.sourceKey = sourceKey
            zoom = 1
            offset = .zero
            rasterCache.removeAll()
        }
        self.image = image
        needsDisplay = true
    }

    // MARK: Geometry

    private var fitScale: CGFloat {
        guard let image, image.size.width > 0, image.size.height > 0 else { return 1 }
        let margin: CGFloat = 12
        let avail = CGSize(width: bounds.width - margin * 2, height: bounds.height - margin * 2)
        guard avail.width > 0, avail.height > 0 else { return 1 }
        // Never blow small diagrams past natural size just to fill the area.
        return min(1, min(avail.width / image.size.width, avail.height / image.size.height))
    }

    private var imageFrame: CGRect {
        guard let image else { return .zero }
        let scale = fitScale * zoom
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return CGRect(x: bounds.midX - size.width / 2 + offset.x,
                      y: bounds.midY - size.height / 2 + offset.y,
                      width: size.width, height: size.height)
    }

    private func resetFit() {
        zoom = 1
        offset = .zero
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Same fill (and same sRGB conversion) as the diagram's rendered page
        // background, so the image extent is invisible and only the border
        // outlines the canvas.
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        MermaidRenderer.pageBackground(for: theme.background).setFill()
        path.fill()

        if let image {
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            bitmap(of: image).draw(
                in: imageFrame, from: .zero, operation: .sourceOver, fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high.rawValue]
            )
            NSGraphicsContext.restoreGraphicsState()
        }

        NSColor.separatorColor.withAlphaComponent(0.5).setStroke()
        path.lineWidth = 1
        path.stroke()

        if hovering {
            editPillRect = drawPill("Edit", trailing: bounds.maxX - 10)
            fitPillRect = drawPill("Fit", trailing: editPillRect.minX - 6)
        } else {
            fitPillRect = .zero
            editPillRect = .zero
        }
    }

    private func drawPill(_ label: String, trailing: CGFloat) -> CGRect {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: theme.textColor.withAlphaComponent(0.9),
        ]
        let size = (label as NSString).size(withAttributes: attrs)
        let rect = CGRect(x: trailing - size.width - 16, y: 10,
                          width: size.width + 16, height: size.height + 8)
        let pill = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        theme.background.withAlphaComponent(0.88).setFill()
        pill.fill()
        NSColor.separatorColor.withAlphaComponent(0.6).setStroke()
        pill.stroke()
        (label as NSString).draw(at: NSPoint(x: rect.minX + 8, y: rect.minY + 4), withAttributes: attrs)
        return rect
    }

    /// Bitmap raster of the diagram at a power-of-two zoom bucket (capped by
    /// a pixel budget so extreme zoom on huge diagrams can't balloon memory).
    private func bitmap(of image: NSImage) -> NSImage {
        let backing = window?.backingScaleFactor ?? 2
        let target = max(fitScale * zoom * backing, 0.01)
        var bucket = pow(2, ceil(log2(target)))
        let maxPixels: CGFloat = 8_000_000
        let cap = (maxPixels / max(image.size.width * image.size.height, 1)).squareRoot()
        bucket = min(max(bucket, 0.25), max(cap, 0.25))
        if let hit = rasterCache[bucket] { return hit }

        let size = CGSize(width: max(image.size.width * bucket, 1),
                          height: max(image.size.height * bucket, 1))
        let raster = NSImage(size: size)
        raster.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: CGRect(origin: .zero, size: size))
        raster.unlockFocus()
        if rasterCache.count > 2 { rasterCache.removeAll() }
        rasterCache[bucket] = raster
        return raster
    }

    // MARK: Pan & zoom

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            zoom(by: 1 + event.scrollingDeltaY * 0.01,
                 at: convert(event.locationInWindow, from: nil))
        } else if zoom == 1, offset == .zero {
            // Fitted diagrams don't hijack the page: scrolling keeps moving
            // the note until the user actually zooms or pans.
            super.scrollWheel(with: event)
        } else {
            offset.x += event.scrollingDeltaX
            offset.y += event.scrollingDeltaY
            needsDisplay = true
        }
    }

    override func magnify(with event: NSEvent) {
        zoom(by: 1 + event.magnification, at: convert(event.locationInWindow, from: nil))
    }

    private func zoom(by factor: CGFloat, at point: CGPoint) {
        guard let image else { return }
        let old = imageFrame
        let newZoom = min(max(zoom * factor, 0.2), 10)
        let applied = newZoom / zoom
        guard applied != 1 else { return }
        zoom = newZoom
        // Keep the diagram point under the cursor stationary.
        let origin = CGPoint(x: point.x + (old.origin.x - point.x) * applied,
                             y: point.y + (old.origin.y - point.y) * applied)
        let scale = fitScale * zoom
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        offset = CGPoint(x: origin.x - (bounds.midX - size.width / 2),
                         y: origin.y - (bounds.midY - size.height / 2))
        needsDisplay = true
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        lastDragPoint = convert(event.locationInWindow, from: nil)
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        offset.x += point.x - lastDragPoint.x
        offset.y += point.y - lastDragPoint.y
        lastDragPoint = point
        dragging = true
        NSCursor.closedHand.set()
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragging = false
            NSCursor.openHand.set()
        }
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2 {
            resetFit()
            return
        }
        guard !dragging else { return }
        if fitPillRect.contains(point) {
            resetFit()
        } else if editPillRect.contains(point) {
            onEdit?()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}
