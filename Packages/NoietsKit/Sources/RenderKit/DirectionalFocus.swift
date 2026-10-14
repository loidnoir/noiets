import Foundation

/// Geometry-only focus selection in window coordinates (positive Y is up).
/// Controls retain responsibility for their internal keyboard behaviour.
public enum DirectionalFocus {
    public enum Direction: String, Sendable { case left = "h", down = "j", up = "k", right = "l" }

    public static func nearest(from source: CGRect, candidates: [CGRect], direction: Direction) -> Int? {
        var best: (index: Int, score: CGFloat)?
        for (index, rect) in candidates.enumerated() {
            guard rect.width > 0, rect.height > 0 else { continue }
            let dx = rect.midX - source.midX
            let dy = rect.midY - source.midY
            let primary: CGFloat
            let gap: CGFloat
            let forwardGap: CGFloat
            let offset: CGFloat
            switch direction {
            case .left, .right:
                primary = direction == .right ? dx : -dx
                gap = max(0, max(source.minY - rect.maxY, rect.minY - source.maxY))
                forwardGap = direction == .right ? max(0, rect.minX - source.maxX) : max(0, source.minX - rect.maxX)
                offset = abs(dy)
            case .up, .down:
                primary = direction == .up ? dy : -dy
                gap = max(0, max(source.minX - rect.maxX, rect.minX - source.maxX))
                forwardGap = direction == .up ? max(0, rect.minY - source.maxY) : max(0, source.minY - rect.maxY)
                offset = abs(dx)
            }
            guard primary > 1, gap == 0 || primary >= offset else { continue }
            // Measure edge distance, not centre distance: a wide text field
            // directly beside a small button must beat a nearby diagonal block.
            let score = forwardGap + gap * 4 + offset * 0.1
            if best == nil || score < best!.score { best = (index, score) }
        }
        return best?.index
    }
}
