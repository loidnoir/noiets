import Foundation
import Testing
import RenderKit

struct EditorBackdropPreferencesTests {
    @Test func freshInstallsUseGlassDefaultsWithoutWritingPreferences() {
        let name = "noiets.backdrop-test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = EditorBackdropPreferences.load(defaults: defaults)
        #expect(settings.isEnabled && settings.backgroundOpacity == 0.85 && settings.blurRadius == 12)
        #expect(defaults.persistentDomain(forName: name)?.isEmpty != false)
    }

    @Test(arguments: [true, false])
    func reopenedPreferencesRestoreToggleAndLevels(enabled: Bool) {
        let name = "noiets.backdrop-test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = EditorBackdropSettings(isEnabled: enabled, backgroundOpacity: 0.86, blurRadius: 35)
        EditorBackdropPreferences.save(settings, defaults: defaults)
        #expect(defaults.synchronize())
        let reopened = UserDefaults(suiteName: name)!
        #expect(EditorBackdropPreferences.load(defaults: reopened) == settings)
    }

    @Test func togglingOffRetainsLevelsAndResetRestoresDefaults() {
        let name = "noiets.backdrop-test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var settings = EditorBackdropSettings(isEnabled: true, backgroundOpacity: 0.86, blurRadius: 20)
        EditorBackdropPreferences.save(settings, defaults: defaults)
        settings.isEnabled = false
        EditorBackdropPreferences.save(settings, defaults: defaults)
        #expect(EditorBackdropPreferences.load(defaults: defaults) == settings)
        EditorBackdropPreferences.save(EditorBackdropSettings(), defaults: defaults)
        #expect(EditorBackdropPreferences.load(defaults: defaults) == EditorBackdropSettings())
    }

    @Test func invalidPreferencesFallBackAndStoredLevelsAreBounded() {
        let name = "noiets.backdrop-test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        for invalid in ["broken", #"{"isEnabled":"yes"}"#] {
            defaults.set(Data(invalid.utf8), forKey: "editorBackdropSettings")
            #expect(EditorBackdropPreferences.load(defaults: defaults) == EditorBackdropSettings())
        }
        defaults.set(Data(#"{"isEnabled":true,"backgroundOpacity":-1,"blurRadius":200}"#.utf8),
                     forKey: "editorBackdropSettings")
        #expect(EditorBackdropPreferences.load(defaults: defaults)
                == EditorBackdropSettings(isEnabled: true, backgroundOpacity: 0, blurRadius: 100))
        defaults.set(Data(#"{"isEnabled":true}"#.utf8), forKey: "editorBackdropSettings")
        #expect(EditorBackdropPreferences.load(defaults: defaults) == EditorBackdropSettings(isEnabled: true))
    }
}
