import Foundation
import Testing
@testable import VaultStore

private func makeVault() throws -> Vault {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("noiets-views-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return Vault(rootURL: dir)
}

@Suite struct ViewsStoreTests {
    @Test func missingFileLoadsEmpty() throws {
        let vault = try makeVault()
        #expect(ViewsStore.load(vault: vault).isEmpty)
    }

    @Test func saveLoadRoundTripPreservesOrder() throws {
        let vault = try makeVault()
        let views = [
            SavedView(name: "Work", query: "folder:Work sort:modified"),
            SavedView(name: "Drafts", query: "status:draft"),
        ]
        ViewsStore.save(views, vault: vault)
        #expect(ViewsStore.load(vault: vault) == views)
    }

    @Test func upsertUpdatesInPlaceOrAppends() throws {
        let vault = try makeVault()
        ViewsStore.upsert(name: "A", query: "tag:a", vault: vault)
        ViewsStore.upsert(name: "B", query: "tag:b", vault: vault)
        ViewsStore.upsert(name: "A", query: "tag:a2", vault: vault)
        let views = ViewsStore.load(vault: vault)
        #expect(views == [SavedView(name: "A", query: "tag:a2"),
                          SavedView(name: "B", query: "tag:b")])
    }

    @Test func renameGuardsCollisions() throws {
        let vault = try makeVault()
        ViewsStore.upsert(name: "A", query: "tag:a", vault: vault)
        ViewsStore.upsert(name: "B", query: "tag:b", vault: vault)
        #expect(ViewsStore.rename("A", to: "B", vault: vault) == false)
        #expect(ViewsStore.rename("missing", to: "C", vault: vault) == false)
        #expect(ViewsStore.rename("A", to: "C", vault: vault) == true)
        #expect(ViewsStore.load(vault: vault).map(\.name) == ["C", "B"])
    }

    @Test func deleteRemoves() throws {
        let vault = try makeVault()
        ViewsStore.upsert(name: "A", query: "tag:a", vault: vault)
        ViewsStore.delete(name: "A", vault: vault)
        #expect(ViewsStore.load(vault: vault).isEmpty)
    }

    @Test func corruptFileLoadsEmpty() throws {
        let vault = try makeVault()
        let dir = vault.rootURL.appendingPathComponent(".noiets", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("views.json"))
        #expect(ViewsStore.load(vault: vault).isEmpty)
    }
}

@Suite struct LocksStoreTests {
    @Test func roundTripAndToggle() throws {
        let vault = try makeVault()
        #expect(LocksStore.load(vault: vault).isEmpty)
        LocksStore.setLocked("Work/Plan.md", true, vault: vault)
        LocksStore.setLocked("Note.md", true, vault: vault)
        #expect(LocksStore.load(vault: vault) == ["Work/Plan.md", "Note.md"])
        LocksStore.setLocked("Note.md", false, vault: vault)
        #expect(LocksStore.load(vault: vault) == ["Work/Plan.md"])
    }
}

@Suite struct HiddenComponentTests {
    @Test func detectsDotComponents() {
        #expect(Vault.hasHiddenComponent(".trash/a.md"))
        #expect(Vault.hasHiddenComponent(".noiets/views.json"))
        #expect(Vault.hasHiddenComponent("a/.b/c.md"))
        #expect(!Vault.hasHiddenComponent("Notes/a.md"))
        #expect(!Vault.hasHiddenComponent("a.b.md"))
        #expect(!Vault.hasHiddenComponent(""))
    }
}
