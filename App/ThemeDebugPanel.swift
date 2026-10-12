import AppKit
import RenderKit

/// Opt-in, session-only palette lab. Never reads/writes theme preferences.
@MainActor
final class ThemeDebugPanel: NSWindowController, NSTextFieldDelegate {
    static var isRequested: Bool { CommandLine.arguments.contains("--debug-theme") }
    private var wells: [AppColors.Role: NSColorWell] = [:]
    private var fields: [AppColors.Role: NSTextField] = [:]
    private let appearanceLabel = NSTextField(labelWithString: "")
    private var updating = false
    private let readBackdropSettings: () -> EditorBackdropSettings
    private let onBackdropChange: (EditorBackdropSettings) -> Void
    private let readBackdropBackend: () -> String
    private let transparencyToggle = NSButton(checkboxWithTitle: "Transparency enabled", target: nil, action: nil)
    private let opacitySlider = NSSlider(value: 85, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let blurSlider = NSSlider(value: 12, minValue: 0, maxValue: Double(EditorBackdropSettings.maximumBlurRadius), target: nil, action: nil)
    private let opacityValue = NSTextField(labelWithString: "")
    private let blurValue = NSTextField(labelWithString: "")
    private let backdropHelp = NSTextField(wrappingLabelWithString: "")

    init(backdropSettings: @escaping () -> EditorBackdropSettings,
         backendDescription: @escaping () -> String,
         onBackdropChange: @escaping (EditorBackdropSettings) -> Void) {
        self.readBackdropSettings = backdropSettings
        self.readBackdropBackend = backendDescription
        self.onBackdropChange = onBackdropChange
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 760),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.title = "Theme Colors — Session Only"
        panel.minSize = NSSize(width: 440, height: 500)
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        buildContent(in: panel)
        NotificationCenter.default.addObserver(self, selector: #selector(colorsChanged), name: AppColors.didChange, object: nil)
        syncControls()
        syncBackdropControls()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present(over mainWindow: NSWindow?) {
        if !window!.isVisible {
            if let mainWindow {
                let screen = mainWindow.screen?.visibleFrame ?? mainWindow.frame
                window!.setFrameTopLeftPoint(NSPoint(x: max(screen.minX, min(mainWindow.frame.maxX + 8, screen.maxX - window!.frame.width)),
                                                    y: min(screen.maxY, mainWindow.frame.maxY)))
            } else { window!.center() }
        }
        showWindow(nil)
    }

    private var appearance: AppColors.Appearance { AppColors.Appearance(window!.effectiveAppearance) }

    private func buildContent(in panel: NSPanel) {
        let root = AppearanceView()
        root.onAppearanceChange = { [weak self] in
            self?.syncControls()
            self?.syncBackdropControls()
        }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let document = AppearanceView(frame: NSRect(x: 0, y: 0, width: 460, height: 900))
        document.autoresizingMask = [.width]
        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 8
        rows.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(rows)
        for (index, role) in AppColors.Role.allCases.enumerated() {
            let label = NSTextField(labelWithString: role.label)
            label.font = AppFonts.font(ofSize: 12)
            let well = NSColorWell()
            well.colorWellStyle = .minimal
            well.tag = index
            well.target = self
            well.action = #selector(pickedColor(_:))
            well.isContinuous = true
            let field = NSTextField()
            field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            field.placeholderString = "#RRGGBB"
            field.tag = index
            field.delegate = self
            let row = NSStackView(views: [label, well, field])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 10
            rows.addArrangedSubview(row)
            NSLayoutConstraint.activate([
                row.widthAnchor.constraint(equalTo: rows.widthAnchor),
                row.heightAnchor.constraint(equalToConstant: 32),
                well.widthAnchor.constraint(equalToConstant: 42),
                well.heightAnchor.constraint(equalToConstant: 26),
                field.widthAnchor.constraint(equalToConstant: 110),
            ])
            wells[role] = well
            fields[role] = field
        }
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 14),
            rows.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -14),
            rows.topAnchor.constraint(equalTo: document.topAnchor, constant: 10),
            rows.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -10),
        ])
        document.frame.size.height = CGFloat(AppColors.Role.allCases.count * 40 - 8 + 20)
        scroll.documentView = document
        appearanceLabel.font = AppFonts.font(ofSize: 12)
        let help = NSTextField(wrappingLabelWithString: "Live preview · #RRGGBB or #RRGGBBAA. Colors are session-only; backdrop settings are saved.")
        help.font = AppFonts.font(ofSize: 11)
        help.textColor = .secondaryLabelColor
        let reset = NSButton(title: "Reset All", target: self, action: #selector(resetColors))
        let copy = NSButton(title: "Copy Palette", target: self, action: #selector(copyPalette))
        reset.font = AppFonts.font(ofSize: 12)
        copy.font = AppFonts.font(ofSize: 12)
        let buttons = NSStackView(views: [reset, copy])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let backdropControls = makeBackdropControls()
        for view in [appearanceLabel, help, backdropControls, scroll, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            appearanceLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            appearanceLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            help.topAnchor.constraint(equalTo: appearanceLabel.bottomAnchor, constant: 6),
            help.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            help.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            backdropControls.topAnchor.constraint(equalTo: help.bottomAnchor, constant: 12),
            backdropControls.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            backdropControls.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: backdropControls.bottomAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -12),
            buttons.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
        ])
        panel.contentView = root
        NSColorPanel.shared.showsAlpha = true
    }

    private func makeBackdropControls() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        transparencyToggle.font = AppFonts.font(ofSize: 12, weight: .semibold)
        transparencyToggle.target = self
        transparencyToggle.action = #selector(backdropChanged(_:))
        stack.addArrangedSubview(transparencyToggle)
        for (title, slider, value) in [("Background opacity", opacitySlider, opacityValue), ("Blur radius", blurSlider, blurValue)] {
            let label = NSTextField(labelWithString: title)
            label.font = AppFonts.font(ofSize: 12)
            slider.target = self
            slider.action = #selector(backdropChanged(_:))
            slider.isContinuous = true
            value.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            value.isSelectable = true
            let row = NSStackView(views: [label, slider, value])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 10
            stack.addArrangedSubview(row)
            NSLayoutConstraint.activate([
                row.widthAnchor.constraint(equalTo: stack.widthAnchor),
                row.heightAnchor.constraint(equalToConstant: 26),
                label.widthAnchor.constraint(equalToConstant: 140),
                value.widthAnchor.constraint(equalToConstant: 88),
            ])
        }
        backdropHelp.font = AppFonts.font(ofSize: 10)
        backdropHelp.textColor = .secondaryLabelColor
        stack.addArrangedSubview(backdropHelp)
        backdropHelp.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    func syncBackdropControls() {
        guard !updating else { return }
        updating = true
        defer { updating = false }
        let settings = readBackdropSettings()
        transparencyToggle.state = settings.isEnabled ? .on : .off
        opacitySlider.doubleValue = settings.backgroundOpacity * 100
        blurSlider.doubleValue = Double(settings.blurRadius)
        opacityValue.stringValue = String(format: "%.0f%% (%.2f)", settings.backgroundOpacity * 100, settings.backgroundOpacity)
        blurValue.stringValue = "\(settings.blurRadius)"
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        opacitySlider.isEnabled = !reduced
        blurSlider.isEnabled = !reduced
        backdropHelp.stringValue = reduced
            ? "Reduce Transparency is on: macOS keeps the content pane opaque. Your backdrop settings are saved."
            : "\(readBackdropBackend()). Radius 0 removes blur. Moving a slider enables transparency; unavailable private API uses a material fallback."
    }

    @objc private func backdropChanged(_ sender: NSControl) {
        guard !updating else { return }
        onBackdropChange(EditorBackdropSettings(
            isEnabled: sender is NSSlider || transparencyToggle.state == .on,
            backgroundOpacity: opacitySlider.doubleValue.rounded() / 100,
            blurRadius: Int(blurSlider.doubleValue.rounded())
        ))
    }

    @objc private func colorsChanged() { syncControls() }

    private func syncControls() {
        guard !updating else { return }
        updating = true
        defer { updating = false }
        appearanceLabel.stringValue = "Editing \(appearance.rawValue.capitalized) appearance"
        for role in AppColors.Role.allCases {
            let color = AppColors.resolved(role, in: appearance)
            wells[role]?.color = color
            if fields[role]?.currentEditor() == nil {
                fields[role]?.stringValue = AppColors.hex(color)
                fields[role]?.textColor = .labelColor
            }
        }
    }

    @objc private func pickedColor(_ sender: NSColorWell) {
        guard !updating else { return }
        let role = AppColors.Role.allCases[sender.tag]
        fields[role]?.stringValue = AppColors.hex(sender.color)
        fields[role]?.textColor = .labelColor
        AppColors.setOverride(sender.color, for: role, in: appearance)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard !updating, let field = notification.object as? NSTextField else { return }
        guard let color = AppColors.parseHex(field.stringValue) else {
            field.textColor = .systemRed
            return
        }
        field.textColor = .labelColor
        AppColors.setOverride(color, for: AppColors.Role.allCases[field.tag], in: appearance)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        let role = AppColors.Role.allCases[field.tag]
        field.stringValue = AppColors.hex(AppColors.resolved(role, in: appearance))
        field.textColor = .labelColor
    }

    @objc private func resetColors() {
        window?.makeFirstResponder(nil)
        onBackdropChange(EditorBackdropSettings())
        AppColors.resetOverrides()
    }

    @objc private func copyPalette() {
        guard let colors = AppColors.paletteJSON().data(using: .utf8),
              var palette = (try? JSONSerialization.jsonObject(with: colors)) as? [String: Any] else { return }
        let backdrop = readBackdropSettings()
        palette["editorBackdrop"] = ["isEnabled": backdrop.isEnabled,
                                    "backgroundOpacity": backdrop.backgroundOpacity,
                                    "blurRadius": backdrop.blurRadius,
                                    "blurBackend": readBackdropBackend()]
        guard let data = try? JSONSerialization.data(withJSONObject: palette, options: [.prettyPrinted, .sortedKeys]) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(String(decoding: data, as: UTF8.self), forType: .string)
    }
}

private final class AppearanceView: NSView {
    var onAppearanceChange: (() -> Void)?
    override var isFlipped: Bool { true }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}
