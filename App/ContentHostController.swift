import AppKit
import EditorKit
import RenderKit

enum ContentBackdropRenderMode {
    case opaque, ghostty, appKitFallback
}

/// One shared backdrop for every page in the right-hand split pane.
/// Only child content crossfades: the backdrop stays stable during navigation.
@MainActor
final class ContentHostController: NSViewController {
    private(set) var current: NSViewController?
    var onChange: (() -> Void)?
    private let content = NSView()
    private let material = NSVisualEffectView()
    private let tint = ColorView(color: .clear)
    private var settings = EditorBackdropSettings()
    private var renderMode: ContentBackdropRenderMode = .opaque

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        content.wantsLayer = true
        material.material = .underWindowBackground
        material.blendingMode = .behindWindow
        material.state = .active
        // Siblings, not children of the material: text never becomes vibrant
        // or translucent, and the sidebar is outside this entire hierarchy.
        for child in [material, tint, content] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
            NSLayoutConstraint.activate([
                child.topAnchor.constraint(equalTo: view.topAnchor),
                child.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                child.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                child.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ])
        }
        applyBackdrop()
    }

    func setBackdrop(_ settings: EditorBackdropSettings, mode: ContentBackdropRenderMode) {
        self.settings = settings
        renderMode = mode
        if isViewLoaded { applyBackdrop() }
    }

    private func applyBackdrop() {
        let transparent = renderMode != .opaque
        material.isHidden = renderMode != .appKitFallback || settings.blurRadius == 0
        tint.color = EditorTheme.standard().background.withAlphaComponent(
            transparent ? CGFloat(settings.backgroundOpacity) : 1)
    }

    func show(_ vc: NSViewController) {
        guard vc !== current else { return }
        _ = view
        if current != nil { UIAnimation.fadeNextChange(of: content) }
        if let current {
            current.view.removeFromSuperview()
            current.removeFromParent()
        }
        addChild(vc)
        vc.view.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(vc.view)
        NSLayoutConstraint.activate([
            vc.view.topAnchor.constraint(equalTo: content.topAnchor),
            vc.view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            vc.view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            vc.view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
        current = vc
        onChange?()
    }
}
