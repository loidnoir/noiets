import Foundation

/// The shared markdown token taxonomy. Emitted by MarkdownKit's tokenizer with
/// exact, delimiter-inclusive UTF-16 source ranges; consumed by EditorKit's
/// highlighter/live-preview and by IndexKit's link/tag extraction.
public enum TokenKind: Equatable, Hashable, Sendable {
    // MARK: Block-level
    case frontmatterDelimiter          // the `---` fence lines at document start
    case frontmatterContent
    case headingMarker(level: Int)     // "# " … "###### " including the trailing space
    case headingText(level: Int)
    case listMarker(ordered: Bool)     // "- ", "* ", "+ ", "1. " (marker chars only)
    case taskMarker(checked: Bool)     // "[ ]" / "[x]" following a list marker
    case blockquoteMarker              // leading "> " run(s)
    case codeFenceDelimiter            // the whole ``` / ~~~ line, including info string
    case codeContent(language: String?)
    case horizontalRule                // ---, ***, ___ line
    case tablePipe                     // a single | in a table row
    case tableDelimiterRow             // the |---|---| row

    // MARK: Inline
    case emphasisMarker                // *, **, ***, _, __, ~~, ==
    case bold
    case italic
    case boldItalic
    case strikethrough
    case highlight                     // ==text==
    case inlineCodeMarker              // ` runs
    case inlineCode
    case linkBracket                   // [, ], (, ) of a markdown link/image, incl. leading !
    case linkText
    case linkURL
    case wikiLinkMarker                // [[, ]], and the | before an alias
    case wikiLinkTarget
    case wikiLinkAlias
    case tagMarker                     // the # of #tag
    case tagName
    case mathMarker                    // $ or $$
    case mathContent(display: Bool)
}

/// A token span in the raw markdown source.
public struct Token: Equatable, Hashable, Sendable {
    public let kind: TokenKind
    public let range: NSRange

    public init(_ kind: TokenKind, _ range: NSRange) {
        self.kind = kind
        self.range = range
    }
}

public extension TokenKind {
    /// Tokens Live Preview unconditionally hides on inactive lines. (The `#` of
    /// a tag and fence/table/task markers stay visible; linkURL/wikiLinkTarget
    /// hide conditionally based on neighboring tokens — see the highlighter.)
    var hiddenInPreview: Bool {
        switch self {
        case .headingMarker, .emphasisMarker, .inlineCodeMarker, .linkBracket,
             .wikiLinkMarker, .mathMarker:
            return true
        default:
            return false
        }
    }
}
