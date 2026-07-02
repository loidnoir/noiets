import AppKit
import VaultStore

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        // Must run before any NSTextView is created: hard-block the silent
        // TextKit 2 → TextKit 1 downgrade on macOS 26 (a `.layoutManager`
        // access anywhere would otherwise degrade the editor and break
        // live preview / custom fragments).
        UserDefaults.standard.register(defaults: [
            "NSTextViewAllowsDowngradeToLayoutManager": false,
        ])
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    private var windowController: MainWindowController?
    private var session: VaultSession?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.mainMenu = MainMenu.build()
        openVault(at: resolveVaultURL())
        NSApp.activate()
        DebugSnapshot.armIfRequested()
        SelfTest.armIfRequested(session: self.session)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        session?.flushPendingSave()
    }

    // MARK: Vault bootstrap

    private func openVault(at url: URL) {
        session?.flushPendingSave()
        windowController?.close()

        let session = VaultSession(vault: Vault(rootURL: url))
        session.seedWelcomeNoteIfEmpty()
        self.session = session

        let wc = MainWindowController(session: session)
        windowController = wc
        wc.showWindow(nil)
    }

    private func resolveVaultURL() -> URL {
        let fm = FileManager.default

        // Dev/test override so automated runs bypass the picker.
        if let env = ProcessInfo.processInfo.environment["NOIETS_VAULT"], !env.isEmpty {
            let url = URL(fileURLWithPath: (env as NSString).expandingTildeInPath, isDirectory: true)
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        if let saved = UserDefaults.standard.string(forKey: "vaultPath") {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: saved, isDirectory: &isDir), isDir.boolValue {
                return URL(fileURLWithPath: saved, isDirectory: true)
            }
        }

        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser
        let defaultVault = documents.appendingPathComponent("Noiets", isDirectory: true)

        let panel = NSOpenPanel()
        panel.message = "Choose a folder for your Noiets vault. Notes live there as plain Markdown files."
        panel.prompt = "Use as Vault"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = documents

        let chosen = (panel.runModal() == .OK ? panel.url : nil) ?? defaultVault
        try? fm.createDirectory(at: chosen, withIntermediateDirectories: true)
        UserDefaults.standard.set(chosen.path, forKey: "vaultPath")
        return chosen
    }

    // MARK: Actions

    @objc func changeVault(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.message = "Choose a different vault folder."
        panel.prompt = "Use as Vault"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.path, forKey: "vaultPath")
        openVault(at: url)
    }
}
