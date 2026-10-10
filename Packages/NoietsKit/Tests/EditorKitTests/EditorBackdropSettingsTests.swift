import Testing
import RenderKit

struct EditorBackdropSettingsTests {
    @Test func ghosttyDefaultsRemainOpaqueUntilEnabledAndTogglesPreserveLevels() {
        var settings = EditorBackdropSettings()
        #expect(!settings.isEnabled)
        #expect(settings.backgroundOpacity == 0.90)
        #expect(settings.blurRadius == 20)
        settings = EditorBackdropSettings(isEnabled: true, backgroundOpacity: 0.42, blurRadius: 35)
        settings.isEnabled = false
        #expect(settings.backgroundOpacity == 0.42)
        #expect(settings.blurRadius == 35)
        #expect(settings != EditorBackdropSettings())
    }

    @Test func sliderEndpointsAndInvalidValuesStayBounded() {
        let sharpClear = EditorBackdropSettings(isEnabled: true, backgroundOpacity: 0, blurRadius: 0)
        #expect(sharpClear.backgroundOpacity == 0)
        #expect(sharpClear.blurRadius == 0)
        let clamped = EditorBackdropSettings(backgroundOpacity: -1, blurRadius: Int.max)
        #expect(clamped.backgroundOpacity == 0)
        #expect(clamped.blurRadius == EditorBackdropSettings.maximumBlurRadius)
        let invalid = EditorBackdropSettings(backgroundOpacity: .nan, blurRadius: -20)
        #expect(invalid.backgroundOpacity == 0.90)
        #expect(invalid.blurRadius == 0)
    }
}
