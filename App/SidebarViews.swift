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
        let rect = bounds.insetBy(dx: 7, dy: 1.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        UITheme.sidebarSelection.setFill()
        path.fill()
    }
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
        stack.spacing = 6
        stack.addArrangedSubview(icon)
        stack.addArrangedSubview(label)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
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
        label.font = .systemFont(ofSize: 13, weight: isFolder ? .semibold : .regular)
        label.textColor = UITheme.sidebarPrimaryText
        if let symbol {
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
                .withSymbolConfiguration(config)
            icon.isHidden = false
        } else {
            icon.image = nil
            icon.isHidden = true
        }
    }
}

/// The hairline divider between the fixed items and the folder tree.
final class SeparatorCellView: NSView {
    static let reuseID = NSUserInterfaceItemIdentifier("SidebarSeparator")

    private let line = ColorView(color: UITheme.hairline)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            line.centerYAnchor.constraint(equalTo: centerYAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    static func make(in outlineView: NSOutlineView) -> SeparatorCellView {
        let cell = outlineView.makeView(withIdentifier: reuseID, owner: nil) as? SeparatorCellView
            ?? SeparatorCellView(frame: .zero)
        cell.identifier = reuseID
        return cell
    }
}
