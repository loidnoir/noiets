import Foundation
import Testing
@testable import VaultStore

struct MediaReferencesTests {
    private func makeVault() throws -> Vault {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("noiets-refs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return Vault(rootURL: root)
    }

    private func write(_ text: String, _ vault: Vault, _ relPath: String) throws -> URL {
        let url = vault.rootURL.appendingPathComponent(relPath)
        try NoteIO.write(text, to: url)
        return url
    }

    @Test func parsesMediaEmbedsOnly() {
        let text = """
        ![alt](assets/pic.png) and ![[clip.mp4]] and ![[Some Note]]
        ```
        ![](inside/fence.png)
        ```
        ![[shot.png|300]]
        """
        let refs = MediaReferences.references(in: text)
        #expect(refs.map(\.path) == ["assets/pic.png", "clip.mp4", "shot.png"])
    }

    /// A note moved away from its sibling media gets the reference rewritten
    /// to the media's vault-root-relative path.
    @Test func rewritesNeighborReferenceWhenNoteMoves() throws {
        let fm = FileManager.default
        let vault = try makeVault()
        defer { try? fm.removeItem(at: vault.rootURL) }
        _ = try write("img", vault, "A/pic.png")
        let old = try write("![](pic.png) and ![[pic.png]]", vault, "A/Note.md")

        let new = vault.rootURL.appendingPathComponent("B/Note.md")
        try fm.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: old, to: new)

        let fixed = MediaReferences.fixAfterMove([(old, new)], vault: vault)
        #expect(fixed.map { vault.relativePath(of: $0) } == ["B/Note.md"])
        #expect(try NoteIO.read(new) == "![](A/pic.png) and ![[A/pic.png]]")
    }

    /// Media moved together with the note keeps resolving — no rewrite.
    @Test func coMovedMediaStaysUntouched() throws {
        let fm = FileManager.default
        let vault = try makeVault()
        defer { try? fm.removeItem(at: vault.rootURL) }
        let oldPic = try write("img", vault, "A/pic.png")
        let oldNote = try write("![](pic.png)", vault, "A/Note.md")

        let dest = vault.rootURL.appendingPathComponent("B", isDirectory: true)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        let newPic = dest.appendingPathComponent("pic.png")
        let newNote = dest.appendingPathComponent("Note.md")
        try fm.moveItem(at: oldPic, to: newPic)
        try fm.moveItem(at: oldNote, to: newNote)

        let fixed = MediaReferences.fixAfterMove(
            [(oldPic, newPic), (oldNote, newNote)], vault: vault)
        #expect(fixed.isEmpty)
        #expect(try NoteIO.read(newNote) == "![](pic.png)")
    }

    /// Moving a whole folder fixes the notes inside it that reached outside.
    @Test func folderMoveFixesContainedNotes() throws {
        let fm = FileManager.default
        let vault = try makeVault()
        defer { try? fm.removeItem(at: vault.rootURL) }
        _ = try write("img", vault, "shared.png")
        _ = try write("inside", vault, "A/inner.png")
        _ = try write("![](../shared.png) ![](inner.png)", vault, "A/Note.md")

        let oldFolder = vault.rootURL.appendingPathComponent("A", isDirectory: true)
        let newFolder = vault.rootURL.appendingPathComponent("C/A", isDirectory: true)
        try fm.createDirectory(at: newFolder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: oldFolder, to: newFolder)

        let fixed = MediaReferences.fixAfterMove([(oldFolder, newFolder)], vault: vault)
        #expect(fixed.map { vault.relativePath(of: $0) } == ["C/A/Note.md"])
        // The out-of-folder reference is repointed; the co-moved one is kept.
        #expect(try NoteIO.read(newFolder.appendingPathComponent("Note.md"))
            == "![](shared.png) ![](inner.png)")
    }

    /// Remote and absolute references are never touched.
    @Test func remoteAndAbsoluteUntouched() throws {
        let fm = FileManager.default
        let vault = try makeVault()
        defer { try? fm.removeItem(at: vault.rootURL) }
        let body = "![](https://example.com/x.png) ![](/tmp/x.png)"
        let old = try write(body, vault, "Note.md")
        let new = vault.rootURL.appendingPathComponent("B/Note.md")
        try fm.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: old, to: new)

        #expect(MediaReferences.fixAfterMove([(old, new)], vault: vault).isEmpty)
        #expect(try NoteIO.read(new) == body)
    }

    /// Root-relative references (assets/, .cache/) survive any move as-is.
    @Test func rootRelativeReferencesSurvive() throws {
        let fm = FileManager.default
        let vault = try makeVault()
        defer { try? fm.removeItem(at: vault.rootURL) }
        _ = try write("img", vault, ".cache/pasted.png")
        _ = try write("img", vault, "assets/a.png")
        let body = "![](.cache/pasted.png) ![](assets/a.png)"
        let old = try write(body, vault, "Note.md")
        let new = vault.rootURL.appendingPathComponent("Deep/Nest/Note.md")
        try fm.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: old, to: new)

        #expect(MediaReferences.fixAfterMove([(old, new)], vault: vault).isEmpty)
        #expect(try NoteIO.read(new) == body)
    }
}
