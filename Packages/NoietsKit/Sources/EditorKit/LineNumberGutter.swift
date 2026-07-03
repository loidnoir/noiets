import AppKit

/// Transient line-number gutter shown while the vim `:` command line is open:
/// low-opacity logical line numbers in the left margin of the writing column.
/// Lives as a subview of the text view (scrolls with content); mouse events
/// pass through.
final class LineNumberGutter: NSView {
    private weak var textView: NoietsTextView?
    private let theme: EditorTheme
    private var lineStarts: [Int] = []

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

    /// Called on show and whenever the text changes while visible.
    func recomputeLines() {
        guard let textView else { return }
        let ns = textView.string as NSString
        var starts: [Int] = []
        var location = 0
        while location <= ns.length {
            starts.append(location)
            if location == ns.length { break }
            let line = ns.lineRange(for: NSRange(location: location, length: 0))
            let next = line.location + line.length
            if next == location { break }
            location = next
        }
        lineStarts = starts
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let textView, let window = textView.window, !lineStarts.isEmpty else { return }

        let font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: theme.mutedColor.withAlphaComponent(0.45),
        ]
        let gutterRight = textView.textContainerInset.width - 10

        func lineRect(_ index: Int) -> NSRect? {
            let screen = textView.firstRect(
                forCharacterRange: NSRange(location: lineStarts[index], length: 0),
                actualRange: nil
            )
            guard screen != .zero else { return nil }
            return textView.convert(window.convertFromScreen(screen), from: nil)
        }

        // Binary-search the first line whose rect reaches the dirty area,
        // then walk forward until we pass it.
        var lo = 0
        var hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if let rect = lineRect(mid), rect.maxY < dirtyRect.minY {
                lo = mid + 1
            } else {
                hi = mid
            }
        }

        var index = lo
        while index < lineStarts.count {
            guard let rect = lineRect(index) else { index += 1; continue }
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
