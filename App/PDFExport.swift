import AppKit
import WebKit

/// Renders the HTML export in an offscreen web view and prints it to a
/// paginated PDF, so the PDF carries the exact same styling as the HTML
/// export. The exporter keeps itself alive until the print job finishes.
@MainActor
final class PDFExport: NSObject, WKNavigationDelegate {
    private static var active: [PDFExport] = []

    private let webView: WKWebView
    private let destination: URL
    private weak var window: NSWindow?
    private let completion: (Bool) -> Void

    static func export(html: String, baseURL: URL?, to destination: URL,
                       for window: NSWindow, completion: @escaping (Bool) -> Void = { _ in }) {
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
        // Give WebKit one beat to finish layout before paginating.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.runPrintOperation()
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
