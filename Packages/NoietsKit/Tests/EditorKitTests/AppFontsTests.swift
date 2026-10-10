import AppKit
import CoreText
import Testing
import EditorKit
import RenderKit

@MainActor
struct AppFontsTests {
    @Test func bundledFacesAndSizes() {
        for (weight, italic, name) in [
            (NSFont.Weight.regular, false, "Libron-Regular"),
            (.medium, false, "Libron-Regular"),
            (.semibold, false, "Libron-Bold"),
            (.bold, false, "Libron-Bold"),
            (.regular, true, "Libron-Italic"),
            (.bold, true, "Libron-BoldItalic"),
        ] {
            let font = AppFonts.displayFont(ofSize: 17, weight: weight, italic: italic)
            #expect(font.fontName == name)
            #expect(font.pointSize == 17)
            let bodyFont = AppFonts.font(ofSize: 17, weight: weight, italic: italic)
            #expect(bodyFont.pointSize == 17)
            if NSFont(name: "SFPro-Regular", size: 17) != nil {
                #expect(bodyFont.familyName == "SF Pro")
            } else {
                #expect(bodyFont.familyName != "Libron")
            }
            #expect(bodyFont.fontDescriptor.symbolicTraits.contains(.italic) == italic)
        }
        let theme = EditorTheme.standard()
        #expect(theme.baseFont.familyName != "Libron")
        if NSFont(name: "SFPro-Regular", size: 15) != nil {
            #expect(theme.baseFont.familyName == "SF Pro")
        }
        #expect(theme.quoteFont.fontName == "Libron-Regular")
        for level in 1...6 {
            let heading = theme.headingFont(level: level)
            #expect(heading.familyName != "Libron")
            if NSFont(name: "SFPro-Regular", size: 15) != nil {
                #expect(heading.fontName == (level <= 2 ? "SFPro-Bold" : "SFPro-Semibold"))
            }
        }
        #expect(theme.monoFont.fontDescriptor.symbolicTraits.contains(.monoSpace))
    }

    @Test func installedSFWeightsAndOpticalSizing() {
        guard NSFont(name: "SFPro-Regular", size: 15) != nil else { return }
        for (weight, style) in [
            (NSFont.Weight.ultraLight, "Ultralight"), (.thin, "Thin"), (.light, "Light"),
            (.regular, "Regular"), (.medium, "Medium"), (.semibold, "Semibold"),
            (.bold, "Bold"), (.heavy, "Heavy"), (.black, "Black"),
        ] {
            for italic in [false, true] {
                let font = AppFonts.font(ofSize: 17, weight: weight, italic: italic)
                #expect(font.fontName == "SFPro-\(style)\(italic ? "Italic" : "")")
                // NSFont exposes only its name/size; inspect the actual
                // shaped CoreText font to verify variable optical sizing.
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Hello", attributes: [.font: font]))
                let run = (CTLineGetGlyphRuns(line) as! [CTRun])[0]
                let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
                let variation = CTFontCopyVariation(runFont) as? [NSNumber: NSNumber]
                #expect(variation?[NSNumber(value: 1869640570)]?.doubleValue == 17)
            }
        }
        #expect(AppFonts.webCSS.contains("local('SFPro-Regular')"))
        #expect(AppFonts.webCSS.contains("local('SFArmenian-Regular')"))
        #expect(!AppFonts.webCSS.contains("/Library/Fonts"))
    }

    @Test func mixedScriptsUseTheIntendedFonts() {
        for (weight, sfName, fallbackName) in [
            (NSFont.Weight.regular, "SFArmenian-Regular", "Montserratarm-Regular"),
            (.medium, "SFArmenian-Medium", "Montserratarm-Medium"),
            (.semibold, "SFArmenian-Semibold", "Montserratarm-SemiBold"),
            (.bold, "SFArmenian-Bold", "Montserratarm-Bold"),
        ] {
            let armenianName = NSFont(name: sfName, size: 15) != nil ? sfName : fallbackName
            for font in [AppFonts.font(ofSize: 15, weight: weight),
                         AppFonts.displayFont(ofSize: 15, weight: weight)] {
                let text = NSAttributedString(string: "Hello Հայերեն world", attributes: [.font: font])
                let line = CTLineCreateWithAttributedString(text)
                let runs = CTLineGetGlyphRuns(line) as! [CTRun]
                var names: [String] = []
                for run in runs {
                    let attributes = CTRunGetAttributes(run) as NSDictionary
                    let runFont = attributes[kCTFontAttributeName] as! CTFont
                    names.append(CTFontCopyPostScriptName(runFont) as String)
                    var glyphs = [CGGlyph](repeating: 0, count: CTRunGetGlyphCount(run))
                    CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
                    #expect(!glyphs.contains(0))
                }
                #expect(names.contains(font.fontName))
                #expect(names.contains(armenianName))
                #expect(names.allSatisfy { $0 == font.fontName || $0 == armenianName })
            }
        }
    }

    @Test func libronIsLimitedToQuotes() {
        let storage = NSTextStorage(string: "# Heading\n## Second\n### Third\n#### Fourth\n##### Fifth\n###### Sixth\nBody **bold Հայերեն** and *italic* and ***both*** and `code`\n> Quote **strong** and *slanted* and ***combined*** and `quotedCode`\n- List item\n")
        let highlighter = IncrementalHighlighter(theme: .standard())
        highlighter.livePreviewEnabled = false
        highlighter.restyleAll(storage)
        let text = storage.string as NSString
        func font(at word: String) -> NSFont {
            storage.attribute(.font, at: text.range(of: word).location, effectiveRange: nil) as! NSFont
        }
        let theme = EditorTheme.standard()
        for (index, word) in ["Heading", "Second", "Third", "Fourth", "Fifth", "Sixth"].enumerated() {
            #expect(font(at: word).fontName == theme.headingFont(level: index + 1).fontName)
            #expect(font(at: word).familyName != "Libron")
        }
        for (word, name) in [("Quote", "Libron-Regular"), ("strong", "Libron-Bold"),
                             ("slanted", "Libron-Italic"), ("combined", "Libron-BoldItalic")] {
            #expect(font(at: word).fontName == name)
        }
        for word in ["Body", "bold", "italic", "both", "List item"] {
            #expect(font(at: word).familyName != "Libron")
        }
        #expect(font(at: "bold").fontDescriptor.symbolicTraits.contains(.bold))
        #expect(font(at: "italic").fontDescriptor.symbolicTraits.contains(.italic))
        #expect(font(at: "both").fontDescriptor.symbolicTraits.contains([.bold, .italic]))
        for word in ["code", "quotedCode"] {
            #expect(font(at: word).fontDescriptor.symbolicTraits.contains(.monoSpace))
        }
        for word in ["bold", "strong"] {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Հայերեն", attributes: [.font: font(at: word)]))
            let run = (CTLineGetGlyphRuns(line) as! [CTRun])[0]
            let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
            let armenianName = NSFont(name: "SFArmenian-Bold", size: 15) != nil ? "SFArmenian-Bold" : "Montserratarm-Bold"
            #expect(CTFontCopyPostScriptName(runFont) as String == armenianName)
        }
    }
}
