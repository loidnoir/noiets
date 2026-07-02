import Foundation

/// VimKit's own key abstraction — the editor maps NSEvent to this, keeping
/// AppKit out of the engine (and the engine headless-testable).
public struct VimKey: Equatable, Sendable {
    public let characters: String
    public let isEscape: Bool
    public let isReturn: Bool
    public let isBackspace: Bool
    public let hasCommand: Bool
    public let hasControl: Bool
    public let hasOption: Bool

    public init(
        characters: String,
        isEscape: Bool = false,
        isReturn: Bool = false,
        isBackspace: Bool = false,
        hasCommand: Bool = false,
        hasControl: Bool = false,
        hasOption: Bool = false
    ) {
        self.characters = characters
        self.isEscape = isEscape
        self.isReturn = isReturn
        self.isBackspace = isBackspace
        self.hasCommand = hasCommand
        self.hasControl = hasControl
        self.hasOption = hasOption
    }

    /// Convenience for tests: turns "dw" into [d, w] key events.
    public static func sequence(_ s: String) -> [VimKey] {
        s.map { ch in
            switch ch {
            case "\u{1B}": return VimKey(characters: "", isEscape: true)
            case "\n", "\r": return VimKey(characters: "\n", isReturn: true)
            default: return VimKey(characters: String(ch))
            }
        }
    }

    public var char: Character? {
        characters.count == 1 ? characters.first : nil
    }
}
