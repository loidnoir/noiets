import AppKit

/// Quiet, fast motion for pane and content changes. Every helper is a no-op
/// when the system Reduce Motion accessibility setting is on.
@MainActor
enum UIAnimation {
    static var enabled: Bool {
        !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Crossfades whatever happens to `view`'s subtree in the current
    /// transaction (a CATransition snapshot fade) — call right before
    /// swapping content in or out.
    static func fadeNextChange(of view: NSView, duration: TimeInterval = 0.18) {
        guard enabled, view.window != nil else { return }
        view.wantsLayer = true
        let fade = CATransition()
        fade.type = .fade
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        view.layer?.add(fade, forKey: "contentFade")
    }

    /// Cursor trail for keyboard focus jumps (⌃h/⌃l/Esc): a quad stretched
    /// between the cursor's old home (one pane) and its new one (the other)
    /// collapses into the destination while fading — the same smear the
    /// editor caret leaves, but across panes. Rects are window coordinates.
    static func smearFocus(from source: NSRect?, to target: NSRect?, in window: NSWindow?) {
        guard enabled, let source, let target, let host = window?.contentView else { return }
        let from = host.convert(source, from: nil)
        let to = host.convert(target, from: nil)
        guard from != to else { return }

        let overlay = PassthroughView(frame: host.bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.wantsLayer = true
        host.addSubview(overlay, positioned: .above, relativeTo: nil)
        guard let hostLayer = overlay.layer else {
            overlay.removeFromSuperview()
            return
        }
        var accent = UITheme.informationColor
        host.effectiveAppearance.performAsCurrentDrawingAppearance {
            accent = UITheme.informationColor
        }
        let smear = CAShapeLayer()
        smear.fillColor = accent.withAlphaComponent(0.32).cgColor
        let (start, end) = smearQuads(from: from, to: to)
        smear.path = end
        smear.opacity = 0
        hostLayer.addSublayer(smear)

        let collapse = CABasicAnimation(keyPath: "path")
        collapse.fromValue = start
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        let group = CAAnimationGroup()
        group.animations = [collapse, fade]
        group.duration = 0.25
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        smear.add(group, forKey: "smear")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            overlay.removeFromSuperview()
        }
    }

    /// Start quad: leading edge on the target rect, trailing edge on the far
    /// side of the source; end state is the target rect itself, so the path
    /// animation sweeps the tail in behind the jump.
    private static func smearQuads(from old: NSRect, to new: NSRect) -> (CGPath, CGPath) {
        // Corner order tl → tr → br → bl (any consistent winding works).
        func corners(_ r: NSRect) -> [CGPoint] {
            [
                CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY),
            ]
        }
        let o = corners(old)
        let n = corners(new)
        let dx = new.midX - old.midX
        let dy = new.midY - old.midY
        let start: [CGPoint]
        if abs(dx) >= abs(dy) {
            start = dx >= 0 ? [o[0], n[1], n[2], o[3]] : [n[0], o[1], o[2], n[3]]
        } else {
            start = dy >= 0 ? [o[0], o[1], n[2], n[3]] : [n[0], n[1], o[2], o[3]]
        }
        func path(_ points: [CGPoint]) -> CGPath {
            let p = CGMutablePath()
            p.addLines(between: points)
            p.closeSubpath()
            return p
        }
        return (path(start), path(n))
    }
}

/// Overlay that never eats clicks meant for the pane under it.
private final class PassthroughView: NSView {
    override func hitTest(_: NSPoint) -> NSView? { nil }
}
