import Foundation

/// Device-local, app-wide backdrop preferences; never stored in the vault.
public enum EditorBackdropPreferences {
    private static let key = "editorBackdropSettings"

    public static func load(defaults: UserDefaults = .standard) -> EditorBackdropSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(EditorBackdropSettings.self, from: data) else {
            return EditorBackdropSettings()
        }
        return settings
    }

    public static func save(_ settings: EditorBackdropSettings, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(settings),
              defaults.data(forKey: key) != data else { return }
        defaults.set(data, forKey: key)
    }
}
