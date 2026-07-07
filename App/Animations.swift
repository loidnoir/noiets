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

    /// One-shot accent outline that swells and fades over `pane` — marks a
    /// keyboard focus jump (⌃h/⌃l/Esc) so the eye lands with the cursor.
    static func pulseFocus(of pane: NSView) {
        guard enabled, pane.window != nil else { return }
        let flash = PassthroughView(frame: pane.bounds.insetBy(dx: 6, dy: 6))
        flash.autoresizingMask = [.width, .height]
        flash.wantsLayer = true
        pane.addSubview(flash, positioned: .above, relativeTo: nil)
        guard let layer = flash.layer else {
            flash.removeFromSuperview()
            return
        }
        layer.cornerRadius = 10
        layer.borderWidth = 2
        var accent = UITheme.informationColor.cgColor
        pane.effectiveAppearance.performAsCurrentDrawingAppearance {
            accent = UITheme.informationColor.cgColor
        }
        layer.borderColor = accent
        layer.opacity = 0

        let pulse = CAKeyframeAnimation(keyPath: "opacity")
        pulse.values = [0, 0.55, 0]
        pulse.keyTimes = [0, 0.2, 1]
        pulse.duration = 0.4
        pulse.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(pulse, forKey: "focusPulse")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            flash.removeFromSuperview()
        }
    }
}

/// Overlay that never eats clicks meant for the pane under it.
private final class PassthroughView: NSView {
    override func hitTest(_: NSPoint) -> NSView? { nil }
}
