import AppKit

/// Row with a soft rounded-rect selection — quiet gray in both key and
/// non-key states. Deliberately not the system accent/vibrancy treatment.
final class SoftRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { false }
        set {}
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let rect = bounds.insetBy(dx: 10, dy: 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        UITheme.sidebarSelection.setFill()
        path.fill()
    }
}

/// The seamless split view: panes meet with no drawn divider — the color
/// change itself is the separation (resizing still works on the 1px seam).
final class SeamlessSplitView: NSSplitView {
    override var dividerColor: NSColor { .clear }
}

/// Standard sidebar cell: optional small SF Symbol + 13pt label.
final class SidebarCellView: NSTableCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("SidebarCell")

    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private let stack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.contentTintColor = UITheme.sidebarSecondaryText
        icon.setContentHuggingPriority(.required, for: .horizontal)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.addArrangedSubview(icon)
        stack.addArrangedSubview(label)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        textField = label
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    static func make(in tableView: NSTableView, title: String, symbol: String?, isFolder: Bool) -> SidebarCellView {
        let cell = tableView.makeView(withIdentifier: reuseID, owner: nil) as? SidebarCellView
            ?? SidebarCellView(frame: .zero)
        cell.identifier = reuseID
        cell.configure(title: title, symbol: symbol, isFolder: isFolder)
        return cell
    }

    private func configure(title: String, symbol: String?, isFolder: Bool) {
        label.stringValue = title
        label.font = .systemFont(ofSize: 13.5, weight: isFolder ? .semibold : .regular)
        label.textColor = UITheme.sidebarPrimaryText
        if let symbol {
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
                .withSymbolConfiguration(config)
            icon.isHidden = false
        } else {
            icon.image = nil
            icon.isHidden = true
        }
    }
}

/// Pure whitespace between the fixed items and the folder tree — no line,
/// just air (Things-style).
final class SeparatorCellView: NSView {
    static let reuseID = NSUserInterfaceItemIdentifier("SidebarSpacer")

    static func make(in outlineView: NSOutlineView) -> SeparatorCellView {
        let cell = outlineView.makeView(withIdentifier: reuseID, owner: nil) as? SeparatorCellView
            ?? SeparatorCellView(frame: .zero)
        cell.identifier = reuseID
        return cell
    }
}
