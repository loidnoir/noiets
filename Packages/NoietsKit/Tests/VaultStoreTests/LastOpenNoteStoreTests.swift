import Foundation
import Testing
@testable import VaultStore

struct LastOpenNoteStoreTests {
    private struct Fixture {
        let vault: Vault
        let suite = "noiets-last-note-tests-\(UUID().uuidString)"
        var defaults: UserDefaults { UserDefaults(suiteName: suite)! }

        init() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            vault = Vault(rootURL: root)
        }

        func note(_ path: String) throws -> URL {
            let url = vault.rootURL.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("# Note\n".utf8).write(to: url)
            return url
        }

        func cleanup() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: vault.rootURL)
        }
    }

    @Test func latestOpenSurvivesAnotherDefaultsInstance() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let first = try fixture.note("A.md")
        let last = try fixture.note("日本語/Last note.markdown")
        LastOpenNoteStore.save(first, vault: fixture.vault, defaults: fixture.defaults)
        LastOpenNoteStore.save(last, vault: fixture.vault, defaults: fixture.defaults)
        #expect(LastOpenNoteStore.load(vault: fixture.vault, defaults: fixture.defaults) == last)
        #expect(fixture.defaults.string(forKey: LastOpenNoteStore.preferenceKey(for: fixture.vault)) == "日本語/Last note.markdown")
        #expect(!FileManager.default.fileExists(atPath: fixture.vault.rootURL.appendingPathComponent(".noiets").path))
    }

    @Test func eachVaultKeepsItsOwnNoteAndNilClearsOnlyThatVault() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let one = Vault(rootURL: fixture.vault.rootURL.appendingPathComponent("One"))
        let two = Vault(rootURL: fixture.vault.rootURL.appendingPathComponent("Two"))
        let first = try fixture.note("One/a.md")
        let second = try fixture.note("Two/b.md")
        LastOpenNoteStore.save(first, vault: one, defaults: fixture.defaults)
        LastOpenNoteStore.save(second, vault: two, defaults: fixture.defaults)
        #expect(LastOpenNoteStore.load(vault: one, defaults: fixture.defaults) == first)
        #expect(LastOpenNoteStore.load(vault: two, defaults: fixture.defaults) == second)
        LastOpenNoteStore.save(nil, vault: one, defaults: fixture.defaults)
        #expect(LastOpenNoteStore.load(vault: one, defaults: fixture.defaults) == nil)
        #expect(LastOpenNoteStore.load(vault: two, defaults: fixture.defaults) == second)
    }

    @Test func movedNoteCanBeRememberedAndMissingNoteDoesNotRestore() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let old = try fixture.note("Old.md")
        let new = fixture.vault.rootURL.appendingPathComponent("Renamed.md")
        LastOpenNoteStore.save(old, vault: fixture.vault, defaults: fixture.defaults)
        try FileManager.default.moveItem(at: old, to: new)
        #expect(LastOpenNoteStore.load(vault: fixture.vault, defaults: fixture.defaults) == nil)
        LastOpenNoteStore.save(new, vault: fixture.vault, defaults: fixture.defaults)
        #expect(LastOpenNoteStore.load(vault: fixture.vault, defaults: fixture.defaults) == new)
        try FileManager.default.removeItem(at: new)
        #expect(LastOpenNoteStore.load(vault: fixture.vault, defaults: fixture.defaults) == nil)
    }

    @Test func invalidOpensDoNotReplaceTheLastRealNote() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let valid = try fixture.note("Note.md")
        LastOpenNoteStore.save(valid, vault: fixture.vault, defaults: fixture.defaults)
        let outside = fixture.vault.rootURL.deletingLastPathComponent()
            .appendingPathComponent(fixture.vault.rootURL.lastPathComponent + "-other/Outside.md")
        for invalid in [outside, fixture.vault.rootURL.appendingPathComponent(".trash/Deleted.md"),
                        fixture.vault.rootURL.appendingPathComponent("image.png"), URL(string: "https://example.com/note.md")!] {
            LastOpenNoteStore.save(invalid, vault: fixture.vault, defaults: fixture.defaults)
            #expect(LastOpenNoteStore.load(vault: fixture.vault, defaults: fixture.defaults) == valid)
        }
    }

    @Test func malformedPreferencesHiddenNotesAndDirectoriesAreRejected() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let defaults = fixture.defaults
        let key = LastOpenNoteStore.preferenceKey(for: fixture.vault)
        _ = try fixture.note(".trash/Deleted.md")
        _ = try fixture.note(".noiets/Internal.md")
        _ = try fixture.note("image.png")
        try FileManager.default.createDirectory(at: fixture.vault.rootURL.appendingPathComponent("Folder.md"), withIntermediateDirectories: true)
        #expect(LastOpenNoteStore.load(vault: fixture.vault, defaults: defaults) == nil)
        for invalid in ["", "../Outside.md", "/tmp/Outside.md", ".trash/Deleted.md", ".noiets/Internal.md", "image.png", "Folder.md", "Missing.md"] {
            defaults.set(invalid, forKey: key)
            #expect(LastOpenNoteStore.load(vault: fixture.vault, defaults: defaults) == nil)
        }
        defaults.set(["not": "a path"], forKey: key)
        #expect(LastOpenNoteStore.load(vault: fixture.vault, defaults: defaults) == nil)
    }
}
