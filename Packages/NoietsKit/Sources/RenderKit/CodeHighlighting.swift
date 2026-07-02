import Foundation

/// Line-level code syntax spans for fenced blocks. The built-in engine is a
/// fast native scanner (keywords/strings/comments/numbers) — deliberately
/// dependency-free; a tree-sitter backend can replace it behind this protocol.
public enum CodeSpanKind: Sendable {
    case keyword, type, string, comment, number, property
}

public struct CodeSpan: Sendable, Equatable {
    public let kind: CodeSpanKind
    public let range: NSRange // relative to the scanned line

    public init(kind: CodeSpanKind, range: NSRange) {
        self.kind = kind
        self.range = range
    }
}

public protocol CodeHighlighting: Sendable {
    func spans(forLine line: String, language: String) -> [CodeSpan]
    func supports(language: String) -> Bool
}

// MARK: - Built-in scanner

public struct BuiltinCodeHighlighter: CodeHighlighting {
    public init() {}

    public func supports(language: String) -> Bool {
        LanguageSpec.spec(for: language) != nil
    }

    public func spans(forLine line: String, language: String) -> [CodeSpan] {
        guard let spec = LanguageSpec.spec(for: language) else { return [] }
        var spans: [CodeSpan] = []
        let ns = line as NSString
        let length = ns.length
        var i = 0

        func char(_ index: Int) -> unichar { ns.character(at: index) }
        func isWordChar(_ c: unichar) -> Bool {
            (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F
        }

        while i < length {
            let c = char(i)

            // Line comment?
            if let marker = spec.lineComment, matches(ns, at: i, marker) {
                spans.append(CodeSpan(kind: .comment, range: NSRange(location: i, length: length - i)))
                break
            }
            // Block comment fragment on one line?
            if let (open, close) = spec.blockComment, matches(ns, at: i, open) {
                var j = i + (open as NSString).length
                while j < length, !matches(ns, at: j, close) { j += 1 }
                let end = min(j + (close as NSString).length, length)
                spans.append(CodeSpan(kind: .comment, range: NSRange(location: i, length: end - i)))
                i = end
                continue
            }
            // String literal.
            if spec.stringDelimiters.contains(c) {
                var j = i + 1
                while j < length {
                    if char(j) == 0x5C { j += 2; continue } // escape
                    if char(j) == c { break }
                    j += 1
                }
                let end = min(j + 1, length)
                spans.append(CodeSpan(kind: .string, range: NSRange(location: i, length: end - i)))
                i = end
                continue
            }
            // Number.
            if c >= 0x30, c <= 0x39, i == 0 || !isWordChar(char(i - 1)) {
                var j = i + 1
                while j < length, isWordChar(char(j)) || char(j) == 0x2E { j += 1 }
                spans.append(CodeSpan(kind: .number, range: NSRange(location: i, length: j - i)))
                i = j
                continue
            }
            // Word: keyword / type / plain.
            if isWordChar(c), c < 0x30 || c > 0x39 {
                var j = i + 1
                while j < length, isWordChar(char(j)) { j += 1 }
                let word = ns.substring(with: NSRange(location: i, length: j - i))
                if spec.keywords.contains(word) {
                    spans.append(CodeSpan(kind: .keyword, range: NSRange(location: i, length: j - i)))
                } else if spec.capitalizedTypes, let first = word.unicodeScalars.first,
                          CharacterSet.uppercaseLetters.contains(first) {
                    spans.append(CodeSpan(kind: .type, range: NSRange(location: i, length: j - i)))
                }
                i = j
                continue
            }
            i += 1
        }
        return spans
    }

    private func matches(_ ns: NSString, at i: Int, _ needle: String) -> Bool {
        let n = needle as NSString
        guard i + n.length <= ns.length else { return false }
        return ns.substring(with: NSRange(location: i, length: n.length)) == needle
    }
}

// MARK: - Language table

struct LanguageSpec: Sendable {
    let keywords: Set<String>
    let lineComment: String?
    let blockComment: (String, String)?
    let stringDelimiters: Set<unichar>
    let capitalizedTypes: Bool

    private static func quotes(_ s: String) -> Set<unichar> {
        Set(s.utf16)
    }

    static func spec(for language: String) -> LanguageSpec? {
        switch language.lowercased() {
        case "swift":
            return LanguageSpec(
                keywords: ["func", "let", "var", "if", "else", "guard", "return", "class", "struct",
                           "enum", "protocol", "extension", "import", "for", "in", "while", "switch",
                           "case", "default", "break", "continue", "public", "private", "internal",
                           "fileprivate", "static", "final", "override", "init", "deinit", "self",
                           "super", "nil", "true", "false", "try", "catch", "throw", "throws", "async",
                           "await", "actor", "some", "any", "where", "defer", "typealias", "lazy",
                           "weak", "unowned", "mutating", "do", "as", "is", "inout"],
                lineComment: "//", blockComment: ("/*", "*/"),
                stringDelimiters: quotes("\""), capitalizedTypes: true
            )
        case "python", "py":
            return LanguageSpec(
                keywords: ["def", "class", "return", "if", "elif", "else", "for", "while", "in",
                           "import", "from", "as", "with", "try", "except", "finally", "raise",
                           "lambda", "pass", "break", "continue", "and", "or", "not", "is", "None",
                           "True", "False", "yield", "global", "nonlocal", "del", "assert", "async",
                           "await", "match", "case", "self"],
                lineComment: "#", blockComment: nil,
                stringDelimiters: quotes("\"'"), capitalizedTypes: true
            )
        case "javascript", "js", "typescript", "ts", "jsx", "tsx":
            return LanguageSpec(
                keywords: ["function", "const", "let", "var", "return", "if", "else", "for", "while",
                           "do", "switch", "case", "default", "break", "continue", "class", "extends",
                           "new", "this", "super", "import", "export", "from", "as", "async", "await",
                           "try", "catch", "finally", "throw", "typeof", "instanceof", "in", "of",
                           "null", "undefined", "true", "false", "void", "delete", "yield", "static",
                           "get", "set", "interface", "type", "enum", "implements", "readonly",
                           "public", "private", "protected", "namespace", "declare"],
                lineComment: "//", blockComment: ("/*", "*/"),
                stringDelimiters: quotes("\"'`"), capitalizedTypes: true
            )
        case "rust", "rs":
            return LanguageSpec(
                keywords: ["fn", "let", "mut", "if", "else", "match", "loop", "while", "for", "in",
                           "return", "struct", "enum", "trait", "impl", "pub", "use", "mod", "crate",
                           "self", "Self", "super", "where", "async", "await", "move", "ref", "static",
                           "const", "unsafe", "dyn", "Box", "Some", "None", "Ok", "Err", "true", "false"],
                lineComment: "//", blockComment: ("/*", "*/"),
                stringDelimiters: quotes("\""), capitalizedTypes: true
            )
        case "go":
            return LanguageSpec(
                keywords: ["func", "var", "const", "if", "else", "for", "range", "return", "switch",
                           "case", "default", "break", "continue", "type", "struct", "interface",
                           "map", "chan", "go", "defer", "select", "package", "import", "nil", "true",
                           "false", "make", "new", "len", "cap", "append", "error"],
                lineComment: "//", blockComment: ("/*", "*/"),
                stringDelimiters: quotes("\"`"), capitalizedTypes: true
            )
        case "c", "cpp", "c++", "objc", "objective-c", "h":
            return LanguageSpec(
                keywords: ["int", "char", "float", "double", "void", "long", "short", "unsigned",
                           "signed", "struct", "union", "enum", "typedef", "static", "extern", "const",
                           "volatile", "if", "else", "for", "while", "do", "switch", "case", "default",
                           "break", "continue", "return", "goto", "sizeof", "class", "public",
                           "private", "protected", "virtual", "override", "template", "typename",
                           "namespace", "using", "new", "delete", "nullptr", "true", "false", "auto",
                           "self", "nil", "id", "instancetype"],
                lineComment: "//", blockComment: ("/*", "*/"),
                stringDelimiters: quotes("\"'"), capitalizedTypes: true
            )
        case "sh", "bash", "zsh", "shell":
            return LanguageSpec(
                keywords: ["if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case",
                           "esac", "function", "return", "local", "export", "echo", "cd", "source",
                           "alias", "set", "unset", "in"],
                lineComment: "#", blockComment: nil,
                stringDelimiters: quotes("\"'"), capitalizedTypes: false
            )
        case "json":
            return LanguageSpec(
                keywords: ["true", "false", "null"],
                lineComment: nil, blockComment: nil,
                stringDelimiters: quotes("\""), capitalizedTypes: false
            )
        case "yaml", "yml", "toml", "ini":
            return LanguageSpec(
                keywords: ["true", "false", "null", "yes", "no"],
                lineComment: "#", blockComment: nil,
                stringDelimiters: quotes("\"'"), capitalizedTypes: false
            )
        case "sql":
            return LanguageSpec(
                keywords: ["SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "UPDATE", "SET",
                           "DELETE", "CREATE", "TABLE", "INDEX", "VIEW", "DROP", "ALTER", "JOIN",
                           "LEFT", "RIGHT", "INNER", "OUTER", "ON", "AS", "AND", "OR", "NOT", "NULL",
                           "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "ORDER", "BY", "GROUP", "HAVING",
                           "LIMIT", "OFFSET", "DISTINCT", "UNION", "ALL", "EXISTS", "IN", "LIKE",
                           "BETWEEN", "IS", "CASE", "WHEN", "THEN", "ELSE", "END",
                           "select", "from", "where", "insert", "into", "values", "update", "set",
                           "delete", "create", "table", "join", "on", "as", "and", "or", "not", "null",
                           "order", "by", "group", "limit"],
                lineComment: "--", blockComment: ("/*", "*/"),
                stringDelimiters: quotes("'"), capitalizedTypes: false
            )
        case "html", "xml", "css", "markdown", "md":
            return LanguageSpec(
                keywords: [],
                lineComment: nil, blockComment: ("<!--", "-->"),
                stringDelimiters: quotes("\"'"), capitalizedTypes: false
            )
        default:
            return nil
        }
    }
}
