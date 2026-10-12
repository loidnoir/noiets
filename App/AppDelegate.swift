import AppKit
import Sparkle
import RenderKit
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
    private var themeDebugPanel: ThemeDebugPanel?
    private var themeRefreshScheduled = false
    private var editorBackdropSettings = EditorBackdropPreferences.load()

    /// Sparkle auto-updater: checks the GitHub-hosted appcast in the
    /// background and offers updates in place.
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // Dev hook: pin the appearance for screenshot verification runs.
        switch ProcessInfo.processInfo.environment["NOIETS_APPEARANCE"] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        if ThemeDebugPanel.isRequested {
            AppColors.enableDebugMode()
            NotificationCenter.default.addObserver(self, selector: #selector(themeColorsChanged), name: AppColors.didChange, object: nil)
        }
        NSApp.mainMenu = MainMenu.build(updaterController: updaterController)
        openVault(at: resolveVaultURL())
        NSApp.activate()
        DebugSnapshot.armIfRequested()
        SelfTest.armIfRequested(session: self.session)
        if ThemeDebugPanel.isRequested { showThemeDebug(nil) }
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
        wc.onBackdropSettingsChange = { [weak self, weak wc] settings in
            guard let self, let wc, self.windowController === wc else { return }
            if self.editorBackdropSettings != settings {
                self.editorBackdropSettings = settings
                EditorBackdropPreferences.save(settings)
            }
            self.themeDebugPanel?.syncBackdropControls()
        }
        wc.setEditorBackdropSettings(editorBackdropSettings)
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
        panel.message = "Choose a folder for your Noiets project. Notes live there as plain Markdown files."
        panel.prompt = "Use as Project"
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

    @objc func showThemeDebug(_ sender: Any?) {
        guard ThemeDebugPanel.isRequested else { return }
        if themeDebugPanel == nil {
            themeDebugPanel = ThemeDebugPanel(
                backdropSettings: { [weak self] in self?.editorBackdropSettings ?? EditorBackdropSettings() },
                backendDescription: { [weak self] in self?.windowController?.editorBackdropBackendDescription ?? "Open a project to preview" },
                onBackdropChange: { [weak self] settings in self?.windowController?.setEditorBackdropSettings(settings) }
            )
        }
        themeDebugPanel?.present(over: windowController?.window)
    }

    @objc private func themeColorsChanged() {
        // Coalesce continuous picker events, especially in large notes.
        guard !themeRefreshScheduled else { return }
        themeRefreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.themeRefreshScheduled = false
            self?.windowController?.refreshThemeColors()
        }
    }

    @objc func changeVault(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.message = "Choose a different project folder."
        panel.prompt = "Use as Project"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.path, forKey: "vaultPath")
        openVault(at: url)
    }
}
