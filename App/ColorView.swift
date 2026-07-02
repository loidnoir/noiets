import AppKit

/// A flat, opaque, appearance-aware background view. Used everywhere instead
/// of vibrancy/materials — Noiets chrome is calm solid color, not frosted.
final class ColorView: NSView {
    var color: NSColor {
        didSet { needsDisplay = true }
    }

    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = color.cgColor
    }

    /// Fallback for non-composited rendering (caching display, PDF, snapshots),
    /// where updateLayer-only views would come out empty.
    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        dirtyRect.fill()
    }
}
