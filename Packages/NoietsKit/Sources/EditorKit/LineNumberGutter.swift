import AppKit

/// Transient line-number gutter shown while the vim `:` command line is open:
/// low-opacity logical line numbers in the left margin of the writing column.
/// Lives as a subview of the text view (scrolls with content); mouse events
/// pass through.
final class LineNumberGutter: NSView {
    private weak var textView: NoietsTextView?
    private let theme: EditorTheme

    init(textView: NoietsTextView, theme: EditorTheme) {
        self.textView = textView
        self.theme = theme
        super.init(frame: textView.bounds)
        autoresizingMask = [.width, .height]
        recomputeLines()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private var rows: [(location: Int, rect: CGRect)] = []

    /// Called on show and whenever the text changes while visible. Numbers
    /// VISUAL rows — a wrapped paragraph contributes one number per rendered
    /// row, consistent with what j/k traverse and what :N jumps to.
    func recomputeLines() {
        guard let textView else { return }
        rows = textView.visualRows()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !rows.isEmpty else { return }

        let font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: theme.mutedColor.withAlphaComponent(0.45),
        ]
        guard let inset = textView?.textContainerInset.width else { return }
        let gutterRight = inset - 10

        // Rows are in draw order; binary-search the first one in the dirty
        // area, then walk until past it.
        var lo = 0
        var hi = rows.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if rows[mid].rect.maxY < dirtyRect.minY {
                lo = mid + 1
            } else {
                hi = mid
            }
        }

        var index = lo
        while index < rows.count {
            let rect = rows[index].rect
            if rect.minY > dirtyRect.maxY { break }
            let label = "\(index + 1)" as NSString
            let size = label.size(withAttributes: attrs)
            label.draw(
                at: NSPoint(x: gutterRight - size.width,
                            y: rect.midY - size.height / 2),
                withAttributes: attrs
            )
            index += 1
        }
    }
}
