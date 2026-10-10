import AppKit
import Testing
@testable import RenderKit

@MainActor
struct WindowBackgroundBlurTests {
    private func makeWindow() -> NSWindow {
        _ = NSApplication.shared
        return NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
                        styleMask: [.borderless], backing: .buffered, defer: false)
    }

    @Test func appliesRealRadiiCachesDuplicatesAndClearsOnDisable() {
        let window = makeWindow()
        var radii: [Int] = []
        let blur = WindowBackgroundBlur { number, radius in
            #expect(number == window.windowNumber)
            radii.append(radius)
            return true
        }
        #expect(blur.apply(radius: 0, to: window))
        #expect(radii.isEmpty) // Never invoke private API in ordinary opaque startup.
        #expect(blur.apply(radius: 20, to: window))
        #expect(blur.apply(radius: 20, to: window))
        #expect(radii == [20])
        #expect(blur.apply(radius: 35, to: window))
        #expect(blur.clear(from: window))
        #expect(blur.clear(from: window))
        #expect(radii == [20, 35, 0])
        #expect(blur.apply(radius: Int.max, to: window))
        #expect(radii.last == EditorBackdropSettings.maximumBlurRadius)
        #expect(blur.apply(radius: -1, to: window))
        #expect(radii.last == 0)
    }

    @Test func failuresDoNotPretendToApplyAndFailedResetsRemainRetryable() {
        let window = makeWindow()
        var accepting = false
        var radii: [Int] = []
        let blur = WindowBackgroundBlur { _, radius in
            radii.append(radius)
            return accepting
        }
        #expect(!blur.apply(radius: 20, to: window))
        #expect(blur.clear(from: window))
        #expect(radii == [20]) // No blur applied, so fallback needs no reset.
        accepting = true
        #expect(blur.apply(radius: 20, to: window))
        accepting = false
        #expect(!blur.apply(radius: 35, to: window))
        #expect(!blur.clear(from: window))
        accepting = true
        #expect(blur.clear(from: window))
        #expect(radii == [20, 20, 35, 0, 0])
    }

    @Test func privateAPIHiddenWindowSmokeTest() {
        let window = makeWindow()
        window.isOpaque = false
        window.backgroundColor = NSColor.white.withAlphaComponent(0.001)
        let blur = WindowBackgroundBlur()
        let accepted = blur.apply(radius: 20, to: window)
        // Optional private symbols are not a portability requirement, but
        // an accepted native blur must always be reset before releasing it.
        print("Ghostty WindowServer blur radius 20 accepted:", accepted)
        if accepted { #expect(blur.clear(from: window)) }
    }

    @Test func stateIsScopedToEachWindow() {
        let first = makeWindow()
        let second = makeWindow()
        var calls: [(Int, Int)] = []
        let blur = WindowBackgroundBlur { number, radius in calls.append((number, radius)); return true }
        #expect(blur.apply(radius: 20, to: first))
        #expect(blur.apply(radius: 40, to: second))
        #expect(blur.clear(from: first))
        #expect(blur.apply(radius: 40, to: second))
        #expect(calls.count == 3)
        #expect(calls.last?.0 == first.windowNumber)
        #expect(calls.last?.1 == 0)
    }
}
