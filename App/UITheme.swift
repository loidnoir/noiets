import AppKit
import RenderKit

/// App-chrome colors (sidebar, dividers). Editor colors live in EditorKit's
/// EditorTheme. Everything is flat and opaque — no vibrancy, no materials.
@MainActor
enum UITheme {
    static let sidebarBackground = AppColors.color(.sidebarBackground)
    static let sidebarSelection = AppColors.color(.sidebarSelection)
    static let sidebarSelectionFocused = AppColors.color(.sidebarFocusedSelection)
    static let modeNormalText = AppColors.color(.sidebarSecondaryText)
    static let modeInsertText = AppColors.color(.modeInsert)
    static let modeVisualText = AppColors.color(.modeVisual)
    // Accent is independent of the quiet NORMAL/TREE/LIST status color.
    static let accent = AppColors.primary
    static let informationColor = accent
    static let paneSeparator = AppColors.color(.paneSeparator)
    static let sidebarPrimaryText = AppColors.color(.sidebarText)
    static let sidebarSecondaryText = AppColors.color(.sidebarSecondaryText)
    static let hairline = AppColors.color(.hairline)

    /// Refresh cached cells/layers, without reloading controllers or changing
    /// note contents, selections, query text, or scroll positions.
    static func repaintColors(in view: NSView, excluding excludedView: NSView? = nil) {
        guard view !== excludedView else { return }
        view.needsDisplay = true
        if let field = view as? NSTextField {
            field.textColor = field.textColor
            if field.currentEditor() == nil {
                field.attributedStringValue = NSAttributedString(attributedString: field.attributedStringValue)
            }
        }
        if let image = view as? NSImageView { image.contentTintColor = image.contentTintColor }
        if let button = view as? NSButton { button.contentTintColor = button.contentTintColor }
        if let text = view as? NSTextView, let storage = text.textStorage, storage.length > 0 {
            // Invalidate shaped text colors (e.g. the search query editor).
            var runs: [(NSRange, [NSAttributedString.Key: Any])] = []
            storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attributes, range, _ in
                runs.append((range, attributes))
            }
            storage.beginEditing()
            for (range, attributes) in runs { storage.setAttributes(attributes, range: range) }
            storage.endEditing()
        }
        for child in view.subviews { repaintColors(in: child, excluding: excludedView) }
    }

    static func styleMenu(_ menu: NSMenu) {
        menu.font = AppFonts.font(ofSize: NSFont.systemFontSize)
        for item in menu.items {
            if let submenu = item.submenu { styleMenu(submenu) }
        }
    }

    static func styleAlert(_ alert: NSAlert) {
        alert.layout()
        if let content = alert.window.contentView { styleControls(in: content) }
    }

    private static func styleControls(in view: NSView) {
        if let control = view as? NSControl, let font = control.font {
            let traits = font.fontDescriptor.symbolicTraits
            control.font = AppFonts.font(ofSize: font.pointSize,
                                         weight: traits.contains(.bold) ? .bold : .regular,
                                         italic: traits.contains(.italic))
        }
        for subview in view.subviews { styleControls(in: subview) }
    }

}
