import Foundation

/// Ghostty-style backdrop: independent background opacity and WindowServer
/// blur radius. Fresh installs start opaque; app preferences restore choices.
public struct EditorBackdropSettings: Equatable, Sendable, Codable {
    public static let maximumBlurRadius = 100
    public var isEnabled: Bool
    public let backgroundOpacity: Double
    public let blurRadius: Int

    public init(isEnabled: Bool = false, backgroundOpacity: Double = 0.90, blurRadius: Int = 20) {
        self.isEnabled = isEnabled
        self.backgroundOpacity = backgroundOpacity.isFinite ? min(max(backgroundOpacity, 0), 1) : 0.90
        self.blurRadius = min(max(blurRadius, 0), Self.maximumBlurRadius)
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, backgroundOpacity, blurRadius
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Restored values go through the same bounds checks as live controls.
        self.init(isEnabled: try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false,
                  backgroundOpacity: try values.decodeIfPresent(Double.self, forKey: .backgroundOpacity) ?? 0.90,
                  blurRadius: try values.decodeIfPresent(Int.self, forKey: .blurRadius) ?? 20)
    }
}
