import AppKit
import MarkdownKit
import RenderKit
import WebKit

/// Prints the editor-styled, self-contained HTML document to a paginated PDF.
/// The exporter keeps itself alive until assets decode and printing finishes.
@MainActor
final class PDFExport: NSObject, WKNavigationDelegate {
    private static var active: [PDFExport] = []

    private let webView: WKWebView
    private let destination: URL
    private weak var window: NSWindow?
    private let completion: (Bool) -> Void

    static func export(html: String, baseURL: URL?, to destination: URL,
                       for window: NSWindow, completion: @escaping (Bool) -> Void = { _ in }) {
        var html = html
        // Mermaid documents: render offline with the vendored script instead
        // of the HTML export's CDN reference.
        if html.contains(HTMLExport.mermaidScriptTag),
           let js = MermaidRenderer.vendoredScript() {
            html = html.replacingOccurrences(of: HTMLExport.mermaidScriptTag,
                                             with: "<script>\(js)</script>")
        }
        let exporter = PDFExport(destination: destination, window: window, completion: completion)
        active.append(exporter)
        exporter.webView.loadHTMLString(html, baseURL: baseURL)
    }

    private init(destination: URL, window: NSWindow, completion: @escaping (Bool) -> Void) {
        self.destination = destination
        self.window = window
        self.completion = completion
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 612, height: 792))
        // Print on white regardless of the system theme; the export CSS only
        // switches to its dark palette under prefers-color-scheme.
        webView.appearance = NSAppearance(named: .aqua)
        super.init()
        webView.navigationDelegate = self
    }

    func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
        // Embedded images and fonts can finish decoding after navigation.
        // Wait for them and Mermaid before laying out the printed pages.
        waitForAssets(attempts: 50)
    }

    private func waitForAssets(attempts: Int) {
        webView.evaluateJavaScript(
            "document.fonts.status === 'loaded' && Array.from(document.images).every(img => img.complete && img.naturalWidth > 0) && Array.from(document.querySelectorAll('.mermaid')).every(el => el.querySelector('svg'))"
        ) { [weak self] value, _ in
            Task { @MainActor [weak self] in
                if (value as? Bool) == true {
                    // One more beat for WebKit to finish layout before paginating.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        self?.runPrintOperation()
                    }
                } else if attempts > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        self?.waitForAssets(attempts: attempts - 1)
                    }
                } else {
                    self?.finish(success: false)
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didFail _: WKNavigation!, withError _: Error) {
        finish(success: false)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError _: Error) {
        finish(success: false)
    }

    private func runPrintOperation() {
        guard let window else {
            finish(success: false)
            return
        }
        let info = NSPrintInfo()
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = destination
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.topMargin = 36
        info.bottomMargin = 36
        info.leftMargin = 36
        info.rightMargin = 36

        let op = webView.printOperation(with: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        // WKWebView's print view starts zero-sized; without this the PDF is blank.
        op.view?.frame = NSRect(origin: .zero, size: info.paperSize)
        op.runModal(for: window, delegate: self,
                    didRun: #selector(printOperationDidRun(_:success:contextInfo:)),
                    contextInfo: nil)
    }

    // NSPrintOperation delivers this on a background thread — hop back to
    // the main actor instead of trapping its executor assertion.
    @objc nonisolated private func printOperationDidRun(
        _: NSPrintOperation, success: Bool, contextInfo _: UnsafeMutableRawPointer?
    ) {
        Task { @MainActor in
            self.finish(success: success)
        }
    }

    private func finish(success: Bool) {
        completion(success)
        Self.active.removeAll { $0 === self }
    }
}
