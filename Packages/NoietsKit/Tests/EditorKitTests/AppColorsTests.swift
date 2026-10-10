import AppKit
import Testing
import EditorKit
import RenderKit
import MarkdownKit

@MainActor
struct AppColorsTests {
    @Test func hexInputIsStrictAndAlphaRoundTrips() {
        for hex in ["#14A4C4", "14a4c4", "#12345680", "#00000000", "#FFFFFF"] {
            #expect(AppColors.parseHex(hex) != nil)
        }
        for invalid in ["#123", "#12345", "#1234567", "#GG0000", "#123456789", "0x14A4C4", "", "#-00000"] {
            #expect(AppColors.parseHex(invalid) == nil)
        }
        #expect(AppColors.hex(AppColors.parseHex("#12345680")!) == "#12345680")
        #expect(AppColors.hex(AppColors.parseHex("14a4c4")!) == "#14A4C4")
    }

    @Test func overridesRequireDebugModeStayPerAppearanceAndReset() throws {
        AppColors.disableDebugMode()
        let theme = EditorTheme.standard()
        let dark = NSAppearance(named: .darkAqua)!
        var original = ""
        dark.performAsCurrentDrawingAppearance { original = AppColors.hex(theme.accentColor) }
        #expect(!AppColors.setOverride(.red, for: .primary, in: .dark))
        AppColors.enableDebugMode()
        defer { AppColors.disableDebugMode() }
        #expect(AppColors.setOverride(AppColors.parseHex("#123456")!, for: .primary, in: .dark))
        // Already-created theme objects must resolve the new color too.
        dark.performAsCurrentDrawingAppearance {
            #expect(AppColors.hex(theme.accentColor) == "#123456")
            #expect(AppColors.hex(AppColors.color(.sidebarFocusedSelection)).hasPrefix("#123456"))
        }
        #expect(AppColors.hex(AppColors.resolved(.primary, in: .light)) == "#14A4C4")
        let json = try #require(AppColors.paletteJSON().data(using: .utf8))
        let palette = try #require(JSONSerialization.jsonObject(with: json) as? [String: [String: String]])
        #expect(palette["dark"]?["primary"] == "#123456")
        #expect(palette["light"]?.count == AppColors.Role.allCases.count)
        AppColors.resetOverrides()
        dark.performAsCurrentDrawingAppearance { #expect(AppColors.hex(theme.accentColor) == original) }
    }

    @Test func refreshingEditorColorsPreservesTextSelectionModeViewportAndUndo() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        let editor = MarkdownEditorView()
        window.contentView = editor
        defer { window.contentView = nil; AppColors.disableDebugMode() }
        editor.layoutSubtreeIfNeeded()
        editor.load(text: "Body\n\n> Quote\n\n" + String(repeating: "More text\n", count: 80))
        window.makeFirstResponder(editor.textView)
        editor.textView.selection = NSRange(location: 1, length: 0)
        editor.vim.handleKey(.init(characters: "x"))
        let edited = editor.string
        let selection = editor.textView.selection
        let mode = editor.vim.mode
        let viewport = editor.scrollView.contentView.bounds.origin
        var edits = 0
        editor.onTextChange = { edits += 1 }
        AppColors.enableDebugMode()
        AppColors.setOverride(AppColors.parseHex("#123456")!, for: .editorText, in: AppColors.Appearance(editor.effectiveAppearance))
        editor.refreshThemeColors()
        #expect(editor.string == edited)
        #expect(editor.textView.selection == selection)
        #expect(editor.vim.mode == mode)
        #expect(editor.scrollView.contentView.bounds.origin == viewport)
        #expect(edits == 0)
        #expect(editor.textView.textLayoutManager != nil)
        editor.vim.handleKey(.init(characters: "u"))
        #expect(editor.string.hasPrefix("Body"))
    }

    @Test func primaryAccentIsTheRequestedColorInBothAppearances() {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                for color in [AppColors.primary, EditorTheme.standard().accentColor] {
                    let rgb = color.usingColorSpace(.sRGB)!
                    #expect(abs(rgb.redComponent - 20.0 / 255) < 0.0001)
                    #expect(abs(rgb.greenComponent - 164.0 / 255) < 0.0001)
                    #expect(abs(rgb.blueComponent - 196.0 / 255) < 0.0001)
                }
            }
        }
        #expect(HTMLExport.html(from: "[Link](https://example.com)", title: "Color").contains("a { color: #14a4c4;"))
    }
}
