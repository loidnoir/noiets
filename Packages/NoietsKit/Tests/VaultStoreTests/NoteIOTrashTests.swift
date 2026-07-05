import Foundation
import Testing
@testable import VaultStore

struct NoteIOTrashTests {
    private func makeVault() throws -> Vault {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("noiets-trash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return Vault(rootURL: root)
    }

    @Test func moveToTrashIsFlatAndDeduped() throws {
        let fm = FileManager.default
        let vault = try makeVault()
        defer { try? fm.removeItem(at: vault.rootURL) }
        let folder = vault.rootURL.appendingPathComponent("Sub", isDirectory: true)

        let first = try NoteIO.createNote(in: folder, baseName: "Note")
        let trashedFirst = try NoteIO.moveToTrash(first, vault: vault)
        #expect(trashedFirst == vault.trashURL.appendingPathComponent("Note.md"))

        // Same name again → de-duped, not overwritten.
        let second = try NoteIO.createNote(in: folder, baseName: "Note")
        let trashedSecond = try NoteIO.moveToTrash(second, vault: vault)
        #expect(trashedSecond.lastPathComponent == "Note 2.md")

        // Trash holds only the deleted content — no sidecar.
        let contents = try fm.contentsOfDirectory(atPath: vault.trashURL.path)
        #expect(Set(contents) == ["Note.md", "Note 2.md"])
    }

    @Test func restoreUsesOriginFolderWhenItExists() throws {
        let fm = FileManager.default
        let vault = try makeVault()
        defer { try? fm.removeItem(at: vault.rootURL) }
        let folder = vault.rootURL.appendingPathComponent("Sub", isDirectory: true)

        let note = try NoteIO.createNote(in: folder, baseName: "Note")
        let trashed = try NoteIO.moveToTrash(note, vault: vault)
        let restored = try NoteIO.restoreFromTrash(trashed, vault: vault, originFolder: "Sub")
        #expect(restored.deletingLastPathComponent().standardizedFileURL
            == folder.standardizedFileURL)
    }

    @Test func restoreFallsBackToRoot() throws {
        let fm = FileManager.default
        let vault = try makeVault()
        defer { try? fm.removeItem(at: vault.rootURL) }

        for origin in [nil, "", "Missing/Folder"] {
            let note = try NoteIO.createNote(in: vault.rootURL, baseName: "Note")
            let trashed = try NoteIO.moveToTrash(note, vault: vault)
            let restored = try NoteIO.restoreFromTrash(trashed, vault: vault, originFolder: origin)
            #expect(restored.deletingLastPathComponent().standardizedFileURL
                == vault.rootURL.standardizedFileURL)
            try fm.removeItem(at: restored)
        }
    }

    @Test func restoreDedupesOnNameCollision() throws {
        let fm = FileManager.default
        let vault = try makeVault()
        defer { try? fm.removeItem(at: vault.rootURL) }

        let note = try NoteIO.createNote(in: vault.rootURL, baseName: "Note")
        let trashed = try NoteIO.moveToTrash(note, vault: vault)
        _ = try NoteIO.createNote(in: vault.rootURL, baseName: "Note") // occupies Note.md
        let restored = try NoteIO.restoreFromTrash(trashed, vault: vault, originFolder: nil)
        #expect(restored.lastPathComponent == "Note 2.md")
    }
}
