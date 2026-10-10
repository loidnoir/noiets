import Foundation

/// Session-only Ghostty-style backdrop: independent background opacity and
/// WindowServer blur radius. Transparency remains off on normal launches.
public struct EditorBackdropSettings: Equatable, Sendable {
    public static let maximumBlurRadius = 100
    public var isEnabled: Bool
    public let backgroundOpacity: Double
    public let blurRadius: Int

    public init(isEnabled: Bool = false, backgroundOpacity: Double = 0.90, blurRadius: Int = 20) {
        self.isEnabled = isEnabled
        self.backgroundOpacity = backgroundOpacity.isFinite ? min(max(backgroundOpacity, 0), 1) : 0.90
        self.blurRadius = min(max(blurRadius, 0), Self.maximumBlurRadius)
    }
}
