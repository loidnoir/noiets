import AppKit
import WebKit

public extension Notification.Name {
    /// Posted after an async mermaid render lands in the cache — editors
    /// re-request layout so pending diagram blocks swap in.
    static let mermaidDidRender = Notification.Name("NoietsMermaidDidRender")
}

/// Renders ```mermaid fences to images via an offscreen WKWebView running the
/// vendored mermaid.js (no network). Rendering is async: `image(source:…)`
/// answers from cache or enqueues a render and returns nil; completion posts
/// `.mermaidDidRender`. Parse failures are remembered so broken sources don't
/// re-render on every layout pass.
@MainActor
public final class MermaidRenderer: NSObject {
    public static let shared = MermaidRenderer()

    private var cache: [String: NSImage] = [:]
    private var failed: Set<String> = []
    private var failureReasons: [String: String] = [:]
    private struct Job {
        let key: String
        let source: String
        let dark: Bool
        let background: NSColor
        let fontSize: CGFloat
    }
    private var queue: [Job] = []
    private var busy = false
    private var renderCount = 0 // unique per-render element id for mermaid

    private var webView: WKWebView?
    private var pageReady = false
    /// Web page canvas; diagrams larger than this are cropped, but the
    /// editor scales everything down to the text column anyway.
    private let canvas = CGSize(width: 6000, height: 9000)

    /// Cached diagram for `source`, or nil while a render is pending (kicked
    /// off here) or after the source failed to parse.
    public func image(source: String, background: NSColor, fontSize: CGFloat) -> NSImage? {
        let dark = Self.isDark(background)
        let key = "\(dark)|\(Int(fontSize))|\(source)"
        if let hit = cache[key] { return hit }
        guard !failed.contains(key) else { return nil }
        if !queue.contains(where: { $0.key == key }) {
            queue.append(Job(key: key, source: source, dark: dark,
                             background: background, fontSize: fontSize))
            pump()
        }
        return nil
    }

    /// Test/diagnostic hook: is a rendered (non-failed) image cached?
    public func hasCachedImage(source: String, background: NSColor, fontSize: CGFloat) -> Bool {
        let dark = Self.isDark(background)
        return cache["\(dark)|\(Int(fontSize))|\(source)"] != nil
    }

    /// Why this source failed to render, if it did — the editor shows this
    /// on the fence line so broken diagrams aren't silently just a code band.
    public func failureReason(source: String, background: NSColor, fontSize: CGFloat) -> String? {
        let dark = Self.isDark(background)
        return failureReasons["\(dark)|\(Int(fontSize))|\(source)"]
    }

    /// Test/diagnostic hook: where did this source end up in the pipeline?
    public func debugState(source: String, background: NSColor, fontSize: CGFloat) -> String {
        let dark = Self.isDark(background)
        let key = "\(dark)|\(Int(fontSize))|\(source)"
        if cache[key] != nil { return "cached" }
        if failed.contains(key) { return "failed: \(failureReasons[key] ?? "unknown")" }
        if queue.contains(where: { $0.key == key }) { return "pending" }
        return "untried"
    }

    /// The bundled mermaid.min.js source. PDF export inlines it in place of
    /// the HTML export's CDN reference so printing never needs the network.
    public static func vendoredScript() -> String? {
        guard let url = Bundle.module.url(forResource: "mermaid.min", withExtension: "js") else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: Pipeline

    private func pump() {
        guard !busy, !queue.isEmpty else { return }
        busy = true
        ensurePageLoaded { [weak self] ok in
            guard let self else { return }
            guard ok, let job = self.queue.first else {
                // Shell failed to load — fail the whole queue, don't retry
                // per keystroke.
                self.queue.forEach { self.failed.insert($0.key) }
                self.queue.removeAll()
                self.busy = false
                return
            }
            self.render(job)
        }
    }

    private func finish(_ job: Job, image: NSImage?, reason: String? = nil) {
        if let image {
            if cache.count > 100 { cache.removeAll() }
            cache[job.key] = image
        } else {
            failed.insert(job.key)
            failureReasons[job.key] = reason ?? "unknown"
        }
        queue.removeAll { $0.key == job.key }
        busy = false
        NotificationCenter.default.post(name: .mermaidDidRender, object: nil)
        pump()
    }

    private func render(_ job: Job) {
        guard let webView else {
            finish(job, image: nil)
            return
        }
        let js = """
        // PDF capture flattens onto an opaque page — paint it the editor
        // background so the captured image blends into the canvas. (A
        // 'transparent' body just comes out white.)
        document.body.style.background = bg;
        mermaid.initialize({
            startOnLoad: false,
            securityLevel: 'strict',
            suppressErrorRendering: true,
            theme: dark ? 'dark' : 'neutral',
            fontFamily: 'ui-sans-serif, -apple-system, Helvetica, sans-serif',
            themeVariables: { fontSize: size + 'px' },
        });
        let svg;
        try {
            svg = (await mermaid.render('m' + count, src)).svg;
        } catch (e) {
            return ['error', String((e && e.message) || e)];
        }
        const host = document.getElementById('host');
        host.innerHTML = svg;
        const el = host.firstElementChild;
        // Mermaid emits width:100%/max-width sizing tuned for responsive
        // pages; pin the svg to its exact content size so the capture rect
        // is the diagram, not the (huge) offscreen viewport.
        el.style.maxWidth = 'none';
        el.style.width = 'auto';
        el.style.height = 'auto';
        const vb = el.viewBox && el.viewBox.baseVal;
        if (vb && vb.width > 0 && vb.height > 0) {
            el.setAttribute('width', Math.ceil(vb.width));
            el.setAttribute('height', Math.ceil(vb.height));
        }
        const r = el.getBoundingClientRect();
        return [Math.ceil(r.width), Math.ceil(r.height)];
        """
        renderCount += 1
        webView.callAsyncJavaScript(
            js,
            arguments: [
                "src": job.source,
                "dark": job.dark,
                "bg": Self.cssColor(job.background),
                "size": Double(job.fontSize),
                "count": renderCount,
            ],
            in: nil, in: .page
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.finish(job, image: nil, reason: error.localizedDescription)
            case .success(let value):
                let dims = value as? [Any] ?? []
                if dims.count == 2, dims[0] as? String == "error" {
                    self.finish(job, image: nil, reason: dims[1] as? String ?? "mermaid error")
                    return
                }
                guard dims.count == 2,
                      let w = (dims[0] as? NSNumber)?.doubleValue,
                      let h = (dims[1] as? NSNumber)?.doubleValue,
                      w > 1, h > 1 else {
                    self.finish(job, image: nil, reason: "empty render result")
                    return
                }
                self.snapshot(job, width: w, height: h)
            }
        }
    }

    /// Bitmap snapshots of offscreen web views clip near screen width, so
    /// wide diagrams lost their right edge — capture as PDF instead: layout-
    /// based (no raster surface limit) and vector, so it stays crisp at any
    /// display scale with no 2× tricks.
    private func snapshot(_ job: Job, width: CGFloat, height: CGFloat) {
        guard let webView else {
            finish(job, image: nil)
            return
        }
        let config = WKPDFConfiguration()
        config.rect = CGRect(x: 0, y: 0,
                             width: min(width, canvas.width),
                             height: min(height, canvas.height))
        webView.createPDF(configuration: config) { [weak self] result in
            switch result {
            case .success(let data):
                if let image = NSImage(data: data) {
                    self?.finish(job, image: image)
                } else {
                    self?.finish(job, image: nil, reason: "PDF decode failed")
                }
            case .failure(let error):
                self?.finish(job, image: nil, reason: error.localizedDescription)
            }
        }
    }

    // MARK: Shell page

    private var pageLoadWaiters: [(Bool) -> Void] = []

    private func ensurePageLoaded(_ completion: @escaping (Bool) -> Void) {
        if pageReady {
            completion(true)
            return
        }
        pageLoadWaiters.append(completion)
        guard webView == nil else { return } // load already in flight
        guard let jsURL = Bundle.module.url(forResource: "mermaid.min", withExtension: "js"),
              let mermaidJS = try? String(contentsOf: jsURL, encoding: .utf8) else {
            flushWaiters(false)
            return
        }
        let configuration = WKWebViewConfiguration()
        let view = WKWebView(frame: CGRect(origin: .zero, size: canvas),
                             configuration: configuration)
        view.navigationDelegate = self
        webView = view
        let html = """
        <!DOCTYPE html><html><head><meta charset="utf-8">
        <style>body { margin: 0 } #host { display: inline-block }</style>
        <script>\(mermaidJS)</script>
        </head><body><div id="host"></div></body></html>
        """
        view.loadHTMLString(html, baseURL: nil)
    }

    private func flushWaiters(_ ok: Bool) {
        pageReady = ok
        let waiters = pageLoadWaiters
        pageLoadWaiters = []
        waiters.forEach { $0(ok) }
    }

    // MARK: Colors

    private static func isDark(_ color: NSColor) -> Bool {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        let luminance = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent
            + 0.114 * rgb.blueComponent
        return luminance < 0.5
    }

    /// The exact color the rendered page is painted with. Surfaces that host
    /// a diagram (the editor's canvas) fill with this same conversion so
    /// image extent and surround are pixel-identical.
    public static func pageBackground(for background: NSColor) -> NSColor {
        background.usingColorSpace(.sRGB) ?? background
    }

    private static func cssColor(_ color: NSColor) -> String {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        return String(format: "#%02X%02X%02X",
                      Int(round(rgb.redComponent * 255)),
                      Int(round(rgb.greenComponent * 255)),
                      Int(round(rgb.blueComponent * 255)))
    }
}

extension MermaidRenderer: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        flushWaiters(true)
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        flushWaiters(false)
    }

    public func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        flushWaiters(false)
    }
}
