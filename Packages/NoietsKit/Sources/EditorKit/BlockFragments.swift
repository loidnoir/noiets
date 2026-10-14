import AppKit
import MarkdownKit
import RenderKit

extension NSTextLayoutFragment {
    /// Width of the centered writing column (the text container tracks it).
    var columnWidth: CGFloat {
        textLayoutManager?.textContainer?.size.width ?? 760
    }
}

/// Code glyphs with a column-wide band drawn in the text view's background
/// pass, below native selection. Glyphs and error badges draw as usual.
/// The block's first/last lines round their outer corners (the band color is
/// opaque, so extending a rounded band into the neighbor line hides the
/// unrounded edge seamlessly).
final class CodeBandFragment: NSTextLayoutFragment {
    private let theme: EditorTheme
    private let roundTop: Bool
    private let roundBottom: Bool
    /// Right-aligned note on the line (mermaid render errors).
    private let badge: String?
    private let radius: CGFloat = 4 // matches the inline-code chips

    init(textElement: NSTextElement, range: NSTextRange?, theme: EditorTheme,
         roundTop: Bool = false, roundBottom: Bool = false, badge: String? = nil) {
        self.theme = theme
        self.roundTop = roundTop
        self.roundBottom = roundBottom
        self.badge = badge
        super.init(textElement: textElement, range: range)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var renderingSurfaceBounds: CGRect {
        super.renderingSurfaceBounds.union(bandRect)
    }

    private var bandRect: CGRect {
        // Band edges sit on the text column, flush with the other components;
        // the code text itself indents inside (paragraph head indent, which
        // also shifts the fragment origin — compensate so the band stays put).
        // The opening line leaves an 8pt gap above the band, clear of the
        // preceding text (the fence's paragraphSpacingBefore covers it).
        let pad = textLayoutManager?.textContainer?.lineFragmentPadding ?? 5
        let topGap: CGFloat = roundTop ? 8 : 0
        return CGRect(x: pad - layoutFragmentFrame.minX, y: topGap,
                      width: columnWidth - pad * 2,
                      height: layoutFragmentFrame.height - topGap)
    }

    /// Drawn by the text view's background pass, below native selection.
    /// Fragment drawing happens above selection and must only draw glyphs.
    func drawBand(at point: CGPoint, in context: CGContext) {
        context.saveGState()
        context.setFillColor(theme.codeBackground.cgColor)
        var rect = bandRect.offsetBy(dx: point.x, dy: point.y)
        if !roundTop, !roundBottom {
            context.fill(rect)
        } else {
            if !roundBottom { rect.size.height += radius } // corners hide under the next band
            if !roundTop {
                rect.origin.y -= radius
                rect.size.height += radius
            }
            context.addPath(CGPath(roundedRect: rect, cornerWidth: radius,
                                   cornerHeight: radius, transform: nil))
            context.fillPath()
        }
        context.restoreGState()
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        super.draw(at: point, in: context)

        if let badge {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: AppFonts.font(ofSize: theme.baseFontSize - 3),
                .foregroundColor: NSColor.systemRed.withAlphaComponent(0.85),
            ]
            let text = badge as NSString
            let size = text.size(withAttributes: attrs)
            let band = bandRect.offsetBy(dx: point.x, dy: point.y)
            text.draw(at: NSPoint(x: band.maxX - size.width - 10,
                                  y: band.minY + (roundTop ? 6 : 3)),
                      withAttributes: attrs)
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}

/// Replaces an image-only (or display-math) line with the rendered image.
/// The source text stays in the buffer; entering the line reverts to source.
final class ImageLineFragment: NSTextLayoutFragment {
    private let theme: EditorTheme
    private let image: NSImage
    private let isMath: Bool
    private let maxSize: CGSize?
    private let padding: CGFloat = 8

    init(textElement: NSTextElement, range: NSTextRange?, theme: EditorTheme,
         image: NSImage, isMath: Bool = false, maxSize: CGSize? = nil) {
        self.theme = theme
        self.image = image
        self.isMath = isMath
        self.maxSize = maxSize
        super.init(textElement: textElement, range: range)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var drawSize: CGSize {
        let natural = image.size
        guard natural.width > 0, natural.height > 0 else { return .zero }
        let maxWidth: CGFloat = maxSize?.width ?? (isMath ? 640 : 560)
        let maxHeight: CGFloat = maxSize?.height ?? (isMath ? 200 : 420)
        let scale = min(1, min(maxWidth / natural.width, maxHeight / natural.height))
        return CGSize(width: natural.width * scale, height: natural.height * scale)
    }

    override var layoutFragmentFrame: CGRect {
        var frame = super.layoutFragmentFrame
        frame.size.height = drawSize.height + padding * 2
        return frame
    }

    override var renderingSurfaceBounds: CGRect {
        let size = drawSize
        return super.renderingSurfaceBounds.union(
            CGRect(x: 0, y: 0, width: size.width + padding, height: size.height + padding * 2)
        )
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        // No super.draw: the raw source stays hidden; only the image renders.
        let size = drawSize
        guard size.width > 0 else { return }
        let rect = CGRect(x: point.x, y: point.y + padding, width: size.width, height: size.height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                   respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// One table row drawn on a shared column grid (widths computed table-wide).
final class TableRowFragment: NSTextLayoutFragment {
    private let theme: EditorTheme
    private let cells: [String]
    private let isHeader: Bool
    private let columns: [CGFloat]
    private let rowHeight: CGFloat = 30
    private let tagColourProvider: ((String) -> NSColor)?

    init(textElement: NSTextElement, range: NSTextRange?, theme: EditorTheme,
         cells: [String], isHeader: Bool, columns: [CGFloat], tagColourProvider: ((String) -> NSColor)? = nil) {
        self.theme = theme
        self.cells = cells
        self.isHeader = isHeader
        self.columns = columns
        self.tagColourProvider = tagColourProvider
        super.init(textElement: textElement, range: range)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var layoutFragmentFrame: CGRect {
        var frame = super.layoutFragmentFrame
        frame.size.height = rowHeight
        return frame
    }

    override var renderingSurfaceBounds: CGRect {
        let width = columns.reduce(0, +) + 16
        return super.renderingSurfaceBounds.union(
            CGRect(x: 0, y: 0, width: max(width, 200), height: rowHeight)
        )
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        // Custom grid rendering only — no raw glyphs.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)

        let font = isHeader
            ? AppFonts.font(ofSize: theme.baseFontSize - 1, weight: .semibold)
            : AppFonts.font(ofSize: theme.baseFontSize - 1)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: isHeader ? theme.textColor : theme.textColor.withAlphaComponent(0.92),
        ]

        var x = point.x + 2
        for (index, cell) in cells.enumerated() {
            let width = index < columns.count ? columns[index] : 100
            let cellRect = CGRect(x: x + 8, y: point.y + 6, width: width - 20, height: rowHeight - 10)
            let text = cell as NSString
            let tokens = InlineScanner.tokens(text, in: NSRange(location: 0, length: text.length))
            for (tokenIndex, token) in tokens.enumerated() where token.kind == .tagName {
                let start = tokenIndex > 0 && tokens[tokenIndex - 1].kind == .tagMarker ? tokens[tokenIndex - 1].range.location : token.range.location
                let range = NSRange(location: start, length: NSMaxRange(token.range) - start)
                let prefixWidth = (text.substring(to: start) as NSString).size(withAttributes: attrs).width
                let size = (text.substring(with: range) as NSString).size(withAttributes: attrs)
                let rect = CGRect(x: cellRect.minX + prefixWidth, y: cellRect.minY, width: size.width, height: size.height)
                    .insetBy(dx: -InlineChipStyle.horizontalPadding, dy: -InlineChipStyle.verticalPadding)
                let colour = tagColourProvider?(text.substring(with: token.range).lowercased()) ?? theme.accentColor
                InlineChipStyle.tagBackground(colour).setFill()
                NSBezierPath(roundedRect: rect, xRadius: InlineChipStyle.cornerRadius, yRadius: InlineChipStyle.cornerRadius).fill()
            }
            text.draw(in: cellRect, withAttributes: attrs)
            x += width
        }

        // Hairline under the row (stronger under the header).
        let totalWidth = max(columns.reduce(0, +), 120)
        let lineRect = CGRect(x: point.x + 2, y: point.y + rowHeight - 1,
                              width: totalWidth, height: isHeader ? 1.5 : 1)
        theme.mutedColor.withAlphaComponent(isHeader ? 0.55 : 0.25).setFill()
        lineRect.fill()

        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Accent bar alongside blockquote lines (glyphs still draw). Consecutive
/// quote paragraphs join into one continuous bar, just like wrapped visual
/// lines within a single paragraph.
final class QuoteBarFragment: OverlayLineFragment {
    private let theme: EditorTheme
    let joinsPrevious: Bool
    let joinsNext: Bool

    init(textElement: NSTextElement, range: NSTextRange?, theme: EditorTheme,
         spans: [OverlayLineFragment.Span], joinsPrevious: Bool, joinsNext: Bool) {
        self.theme = theme
        self.joinsPrevious = joinsPrevious
        self.joinsNext = joinsNext
        super.init(textElement: textElement, range: range, theme: theme, spans: spans)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var renderingSurfaceBounds: CGRect {
        let overlap: CGFloat = 1
        return super.renderingSurfaceBounds.union(
            CGRect(x: -24, y: joinsPrevious ? -overlap : 0, width: 28,
                   height: layoutFragmentFrame.height
                       + (joinsPrevious ? overlap : 0)
                       + (joinsNext ? overlap : 0))
        )
    }

    /// Fragment-local geometry shared with the short edit-entry fade overlay.
    var barRect: CGRect {
        // The fragment origin follows the paragraph indent, so anchor the bar
        // to the bullet-dot column; span exactly the text's visual extent
        // (caps to descenders) off the real rendered baseline, so bar and
        // text are centered on each other by construction.
        let font = AppFonts.displayFont(ofSize: theme.baseFontSize)
        let dashHalf = ("-" as NSString)
            .size(withAttributes: [.font: AppFonts.font(ofSize: theme.baseFontSize,
                                                            weight: .bold)]).width / 2
        let padding = textLayoutManager?.textContainer?.lineFragmentPadding ?? 5
        // Wrapped quotes span several visual lines — run the bar from the
        // first line's caps to the last line's descenders. Skip the empty
        // trailing line fragment the paragraph's newline can produce.
        let lines = textLineFragments.filter { lf in
            let s = lf.attributedString.string as NSString
            guard lf.characterRange.location + lf.characterRange.length <= s.length else {
                return false
            }
            return !s.substring(with: lf.characterRange)
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let firstLine = lines.first ?? textLineFragments.first
        let lastLine = lines.last ?? textLineFragments.last
        let firstBaseline = (firstLine?.typographicBounds.origin.y ?? 0)
            + (firstLine?.glyphOrigin.y ?? font.ascender)
        let lastBaseline = (lastLine?.typographicBounds.origin.y ?? 0)
            + (lastLine?.glyphOrigin.y ?? font.ascender)
        // Interior quote lines extend through their fragment edges. A small
        // overlap prevents an antialiasing seam where neighboring fragments
        // meet; only the outside ends of the complete quote block stay capped.
        let overlap: CGFloat = 1
        let top = joinsPrevious
            ? -overlap
            : firstBaseline - font.capHeight - 1.5
        let bottom = joinsNext
            ? layoutFragmentFrame.height + overlap
            : lastBaseline - font.descender + 1.5 // descender is negative
        return CGRect(x: -layoutFragmentFrame.minX + padding + dashHalf - 1.5,
                      y: top, width: 3, height: bottom - top)
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        context.saveGState()
        let bar = barRect.offsetBy(dx: point.x, dy: point.y)
        context.addPath(CGPath(roundedRect: bar, cornerWidth: 1.5, cornerHeight: 1.5,
                               transform: nil))
        context.setFillColor(theme.mutedColor.withAlphaComponent(0.5).cgColor)
        context.fillPath()
        context.restoreGState()
        super.draw(at: point, in: context)
    }
}

/// A horizontal rule renders as an actual thin line.
final class RuleFragment: NSTextLayoutFragment {
    private let theme: EditorTheme

    init(textElement: NSTextElement, range: NSTextRange?, theme: EditorTheme) {
        self.theme = theme
        super.init(textElement: textElement, range: range)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var layoutFragmentFrame: CGRect {
        var frame = super.layoutFragmentFrame
        frame.size.height = 24
        return frame
    }

    override var renderingSurfaceBounds: CGRect {
        super.renderingSurfaceBounds.union(CGRect(x: 0, y: 0, width: columnWidth, height: 24))
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        context.saveGState()
        context.setFillColor(theme.mutedColor.withAlphaComponent(0.35).cgColor)
        context.fill(CGRect(x: point.x, y: point.y + 12, width: columnWidth, height: 1))
        context.restoreGState()
    }
}

/// Reserves the interactive mermaid canvas area. It draws nothing itself —
/// the editor keeps a MermaidCanvasView overlay positioned over this frame
/// (fragments are plain CoreGraphics, so pan/zoom needs a real view).
final class MermaidAreaFragment: NSTextLayoutFragment {
    /// Diagram height/width; the area follows it within sane bounds.
    private let aspect: CGFloat

    init(textElement: NSTextElement, range: NSTextRange?, aspect: CGFloat) {
        self.aspect = aspect
        super.init(textElement: textElement, range: range)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var layoutFragmentFrame: CGRect {
        var frame = super.layoutFragmentFrame
        let pad = textLayoutManager?.textContainer?.lineFragmentPadding ?? 5
        let width = columnWidth - pad * 2
        frame.size.height = min(max(width * aspect, 220), 540) + 16
        return frame
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        // Intentionally empty — the overlay view draws the diagram.
    }
}

/// Fully hidden line — the body of a rendered ```mermaid block. Unlike the
/// 4pt table-delimiter gap, these blocks can be dozens of lines, so any
/// per-line height would pile up into a visible hole under the diagram.
final class CollapsedLineFragment: NSTextLayoutFragment {
    override var layoutFragmentFrame: CGRect {
        var frame = super.layoutFragmentFrame
        frame.size.height = 0
        return frame
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        // Intentionally empty.
    }
}

/// The |---|---| row collapses to a small gap (the header hairline stands in).
final class TableDelimiterFragment: NSTextLayoutFragment {
    private let theme: EditorTheme

    init(textElement: NSTextElement, range: NSTextRange?, theme: EditorTheme) {
        self.theme = theme
        super.init(textElement: textElement, range: range)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var layoutFragmentFrame: CGRect {
        var frame = super.layoutFragmentFrame
        frame.size.height = 4
        return frame
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        // Intentionally empty.
    }
}
