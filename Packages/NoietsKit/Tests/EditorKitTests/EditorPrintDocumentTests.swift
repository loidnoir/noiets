import AppKit
import Testing
import EditorKit

@Suite @MainActor
struct EditorPrintDocumentTests {
    private func fixture(width: Int = 120, height: Int = 80) throws -> URL {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noiets-print-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Notes"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Attachments"), withIntermediateDirectories: true)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for x in 0..<width { for y in 0..<height {
            let offset = y * bitmap.bytesPerRow + x * 4
            bitmap.bitmapData![offset] = 255
            bitmap.bitmapData![offset + 1] = 0
            bitmap.bitmapData![offset + 2] = 0
            bitmap.bitmapData![offset + 3] = 255
        } }
        try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("Attachments/Diagram image.png"))
        return root
    }

    @Test func localImagesUseEditorResolutionAndAreEmbeddedAtNaturalSize() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let html = await EditorPrintDocument.html(from: "# Heading\n\n![](../Attachments/Diagram%20image.png)\n\n![[Diagram image.png]]",
                                                 title: "T", noteURL: root.appendingPathComponent("Notes/Test.md"), vaultRoot: root)
        #expect(html.components(separatedBy: "<img src=\"data:image/png;base64,").count == 3)
        #expect(html.contains("width=\"120.0\" height=\"80.0\""))
        #expect(!html.contains("Image unavailable:"))
        #expect(html.contains("color-scheme: light"))
        #expect(html.contains("'Noiets Libron'"))
        #expect(html.contains("font-size: 24.0px"))
        #expect(html.contains("class=\"blank-line\""))
    }

    @Test func largeImagesKeepTheirAspectRatioAndEditorSizeLimit() async throws {
        let root = try fixture(width: 1200, height: 600)
        defer { try? FileManager.default.removeItem(at: root) }
        let html = await EditorPrintDocument.html(from: "![[Diagram image.png]]", title: "T",
                                                 noteURL: root.appendingPathComponent("Notes/Test.md"), vaultRoot: root)
        #expect(html.contains("width=\"560.0\" height=\"280.0\""))
        #expect(html.contains("height: auto"))
    }

    @Test func missingImageHasAnExplicitPlaceholderInsteadOfDisappearing() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let html = await EditorPrintDocument.html(from: "![](missing.png)", title: "T",
                                                 noteURL: root.appendingPathComponent("Notes/Test.md"), vaultRoot: root)
        #expect(html.contains("Image unavailable: missing.png"))
        #expect(!html.contains("<img"))
    }
}
