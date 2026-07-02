import AppKit

/// Dev-only self-screenshot: when NOIETS_SNAPSHOT=<path.png> is set, the app
/// renders its own key window to PNG shortly after launch (no screen-recording
/// permission needed), then quits if NOIETS_SNAPSHOT_QUIT=1. Used by the
/// build/verify loop; inert in normal runs.
@MainActor
enum DebugSnapshot {
    static func armIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["NOIETS_SNAPSHOT"], !path.isEmpty else { return }
        let delay = Double(env["NOIETS_SNAPSHOT_DELAY"] ?? "") ?? 1.2
        let quit = env["NOIETS_SNAPSHOT_QUIT"] == "1"
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            capture(to: path)
            if quit { NSApp.terminate(nil) }
        }
    }

    private static func capture(to path: String) {
        guard let window = NSApp.windows.first(where: { $0.isVisible }),
              let frameView = window.contentView?.superview else { return }
        let bounds = frameView.bounds
        window.displayIfNeeded()

        // Primary: re-draw the hierarchy into a bitmap.
        if let rep = frameView.bitmapImageRepForCachingDisplay(in: bounds) {
            frameView.cacheDisplay(in: bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }

        // Secondary: composite the layer tree (captures layer-only content).
        if let layer = frameView.layer {
            let scale = window.backingScaleFactor
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(bounds.width * scale),
                pixelsHigh: Int(bounds.height * scale),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ) else { return }
            rep.size = bounds.size
            guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ctx
            ctx.cgContext.scaleBy(x: scale, y: scale)
            layer.render(in: ctx.cgContext)
            NSGraphicsContext.restoreGraphicsState()
            if let data = rep.representation(using: .png, properties: [:]) {
                let alt = (path as NSString).deletingPathExtension + "-layer.png"
                try? data.write(to: URL(fileURLWithPath: alt))
            }
        }
    }
}
