import AppKit
import RenderKit

/// Opt-in directional navigation between existing controls, scoped to a page.
@MainActor
final class FocusRegionCoordinator {
    private struct Region {
        weak var view: NSView?
        let available: () -> Bool
        let focus: () -> Void
    }
    private weak var root: NSView?
    private var regions: [Region] = []
    private var monitor: MonitorToken?
    var beforeMove: (() -> Void)?
    var onLeftBoundary: (() -> Void)?

    init(root: NSView) { self.root = root }

    func register(_ view: NSView, available: @escaping () -> Bool = { true }, focus: @escaping () -> Void) {
        regions.append(Region(view: view, available: available, focus: focus))
    }

    func start() {
        stop()
        let token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.modifierFlags.intersection([.control, .command, .option, .shift]) == [.control],
                  let key = event.charactersIgnoringModifiers,
                  let direction = DirectionalFocus.Direction(rawValue: key),
                  self.move(direction, eventWindow: event.window) else { return event }
            return nil
        }
        monitor = token.map(MonitorToken.init)
    }

    func stop() { monitor = nil }

    /// Immutable token wrapper gives the observer a bounded lifetime, including
    /// when a controller is released without an appearance callback.
    private final class MonitorToken: @unchecked Sendable {
        let value: Any
        init(_ value: Any) { self.value = value }
        deinit { NSEvent.removeMonitor(value) }
    }

    @discardableResult
    func move(_ direction: DirectionalFocus.Direction, eventWindow: NSWindow? = nil) -> Bool {
        guard let root, let window = root.window, window.attachedSheet == nil,
              eventWindow == nil || eventWindow === window else { return false }
        let eligible = regions.filter { region in
            guard let view = region.view else { return false }
            return view.window === window && !view.isHiddenOrHasHiddenAncestor && region.available()
        }
        guard let responder = window.firstResponder,
              let source = eligible.first(where: { region in
                  guard let view = region.view else { return false }
                  if let control = view as? NSControl, control.currentEditor() === responder { return true }
                  guard let focused = responder as? NSView else { return false }
                  return focused === view || focused.isDescendant(of: view)
              }), let sourceView = source.view else { return false }
        let candidates = eligible.filter { $0.view !== sourceView }
        let rects = candidates.compactMap { $0.view.map { $0.convert($0.bounds, to: nil) } }
        if let index = DirectionalFocus.nearest(from: sourceView.convert(sourceView.bounds, to: nil),
                                                candidates: rects, direction: direction) {
            beforeMove?()
            candidates[index].focus()
            if let target = candidates[index].view { UIAnimation.pulseFocus(of: target) }
        } else if direction == .left {
            beforeMove?()
            onLeftBoundary?()
        }
        // Consume directional keys at edges: never delete query text by accident.
        return true
    }
}

/// Save is keyboard-focusable even when macOS Full Keyboard Access is off.
final class FocusableSaveButton: NSButton {
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.control, .command, .option]).isEmpty,
           [36, 76, 49].contains(event.keyCode) {
            // Dispatch directly: NSButton's simulated-click animation runs a
            // nested event loop, unnecessary for an already focused control.
            if isEnabled { _ = sendAction(action, to: target) }
        } else { super.keyDown(with: event) }
    }
}
