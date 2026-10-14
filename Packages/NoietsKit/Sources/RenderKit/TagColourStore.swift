import AppKit

/// One device-local assignment map shared by all tag presentations in a vault.
@MainActor
public final class TagColourStore {
    private let defaults: UserDefaults
    private let key: String
    private var slots: [String: Int]

    public init(namespace: String, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.key = "Noiets.TagColours." + namespace
        self.slots = ((defaults.dictionary(forKey: key) as? [String: Int]) ?? [:])
            .filter { (0..<TagPalette.count).contains($0.value) }
    }

    public func prepare(_ names: [String]) {
        var used = Set(slots.values)
        var changed = false
        for name in Set(names.map { $0.lowercased() }).sorted() where slots[name] == nil {
            let slot = (0..<TagPalette.count).first { !used.contains($0) } ?? slots.count % TagPalette.count
            slots[name] = slot
            used.insert(slot)
            changed = true
        }
        if changed { defaults.set(slots, forKey: key) }
    }

    public func colour(for name: String) -> NSColor {
        let name = name.lowercased()
        prepare([name])
        return TagPalette.color(at: slots[name]!)
    }
}
