import Foundation
import Testing
import VaultStore
@testable import IndexKit

struct TrashOriginTests {
    /// Trash origins are user data in the project database: set/get/forget
    /// round-trips, re-setting a name overwrites, and rows persist across
    /// index reopens (unlike the rebuildable cache tables).
    @Test func originsRoundTripAndPersist() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("noiets-trash-origin-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let vault = Vault(rootURL: URL(fileURLWithPath: "/tmp/fake-vault"))

        let index = try NoteIndex(vault: vault, databaseURL: url)
        try index.setTrashOrigin(name: "Note.md", originFolder: "Projects")
        try index.setTrashOrigin(name: "Root.md", originFolder: "")
        #expect(try index.trashOrigin(name: "Note.md") == "Projects")
        #expect(try index.trashOrigin(name: "Root.md") == "")
        #expect(try index.trashOrigin(name: "Unknown.md") == nil)

        // Re-recording the same name overwrites (INSERT OR REPLACE).
        try index.setTrashOrigin(name: "Note.md", originFolder: "Archive")
        #expect(try index.trashOrigin(name: "Note.md") == "Archive")

        try index.forgetTrashOrigin(name: "Root.md")
        #expect(try index.trashOrigin(name: "Root.md") == nil)

        let reopened = try NoteIndex(vault: vault, databaseURL: url)
        #expect(try reopened.trashOrigin(name: "Note.md") == "Archive")
    }

    /// The legacy `.trash/.origins.json` sidecar imports once: entries land
    /// in the table (existing rows win), the file is deleted, and a second
    /// call is a no-op.
    @Test func legacySidecarImport() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("noiets-origins-import-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let sidecar = dir.appendingPathComponent(".origins.json")
        let map = ["Imported.md": "Ideas", "Existing.md": "FromSidecar"]
        try JSONEncoder().encode(map).write(to: sidecar)

        let vault = Vault(rootURL: URL(fileURLWithPath: "/tmp/fake-vault"))
        let index = try NoteIndex.temporary(vault: vault)
        try index.setTrashOrigin(name: "Existing.md", originFolder: "FromDB")

        try index.importLegacyTrashOrigins(from: sidecar)
        #expect(try index.trashOrigin(name: "Imported.md") == "Ideas")
        #expect(try index.trashOrigin(name: "Existing.md") == "FromDB") // DB row wins
        #expect(!fm.fileExists(atPath: sidecar.path))

        // Missing sidecar → no-op.
        try index.importLegacyTrashOrigins(from: sidecar)
        #expect(try index.trashOrigin(name: "Imported.md") == "Ideas")
    }
}
