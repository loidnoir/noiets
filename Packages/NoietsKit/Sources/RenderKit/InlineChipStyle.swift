import AppKit

/// Shared compact geometry for document code chips and every tag badge.
public enum InlineChipStyle {
    public static let horizontalPadding: CGFloat = 2
    public static let verticalPadding: CGFloat = 1.5
    public static let cornerRadius: CGFloat = 4

    public static func tagBackground(_ colour: NSColor, selected: Bool = false) -> NSColor {
        colour.withAlphaComponent(selected ? 0.24 : 0.14)
    }
}

/// A tag label, not a pill/button: normal text over a compact inline-code-style chip.
@MainActor
public final class TagBadgeView: NSView {
    public var name = "" { didSet { invalidateIntrinsicContentSize(); needsDisplay = true; setAccessibilityLabel(name) } }
    public var colour = NSColor.controlAccentColor { didSet { needsDisplay = true } }
    public var selected = false { didSet { needsDisplay = true; setAccessibilityValue(selected ? "Selected" : "") } }
    public var font = AppFonts.font(ofSize: 13) { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    public override var intrinsicContentSize: NSSize {
        let size = (name as NSString).size(withAttributes: [.font: font])
        return NSSize(width: ceil(size.width) + InlineChipStyle.horizontalPadding * 2 + 2,
                      height: ceil(size.height) + InlineChipStyle.verticalPadding * 2 + 2)
    }
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func draw(_ dirtyRect: NSRect) {
        let size = intrinsicContentSize
        let height = size.height - 2
        let rect = NSRect(x: 1, y: (bounds.height - height) / 2,
                          width: min(max(0, bounds.width - 2), size.width - 2), height: height)
        let path = NSBezierPath(roundedRect: rect, xRadius: InlineChipStyle.cornerRadius, yRadius: InlineChipStyle.cornerRadius)
        InlineChipStyle.tagBackground(colour, selected: selected).setFill()
        path.fill()
        if selected {
            colour.withAlphaComponent(0.8).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: AppColors.color(.editorText), .paragraphStyle: style]
        (name as NSString).draw(in: rect.insetBy(dx: InlineChipStyle.horizontalPadding, dy: InlineChipStyle.verticalPadding), withAttributes: attributes)
    }
}
