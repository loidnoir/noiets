import AppKit

/// Row with a soft rounded-rect selection — quiet gray in both key and
/// non-key states. Deliberately not the system accent/vibrancy treatment.
final class SoftRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { false }
        set {}
    }

    override func drawSelection(in _: NSRect) {
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
    override var dividerColor: NSColor {
        .clear
    }
}

/// Outline view with the native disclosure triangle hidden by zeroing its
/// frame. (Returning false from shouldShowOutlineCellForItem instead makes
/// AppKit pin items expanded — collapseItem is silently ignored.)
final class SidebarOutlineView: NSOutlineView {
    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        .zero
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
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    static func make(in tableView: NSTableView, title: String, symbol: String?, isFolder: Bool)
        -> SidebarCellView
    {
        let cell =
            tableView.makeView(withIdentifier: reuseID, owner: nil) as? SidebarCellView
            ?? SidebarCellView(frame: .zero)
        cell.identifier = reuseID
        cell.configure(title: title, symbol: symbol, isFolder: isFolder)
        return cell
    }

    private func configure(title: String, symbol: String?, isFolder: Bool) {
        label.stringValue = title
        let hasIcon = symbol != nil
        label.font = .systemFont(
            ofSize: hasIcon ? 15 : 13.5,
            weight: hasIcon ? .medium : (isFolder ? .medium : .regular)
        )
        label.textColor = UITheme.sidebarPrimaryText
        if let symbol {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
                .withSymbolConfiguration(config)
            icon.isHidden = false
        } else {
            icon.image = nil
            icon.isHidden = true
        }
    }
}

/// Folder row: icon + title, with a right-side disclosure chevron that only
/// appears while hovering the row.
final class SidebarFolderCellView: NSTableCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("SidebarFolderCell")

    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private let chevronButton = NSButton(frame: .zero)
    private let stack = NSStackView()
    private var trackingArea: NSTrackingArea?
    private var showsChevron = false
    private var onToggle: (() -> Bool)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        icon.contentTintColor = UITheme.sidebarSecondaryText
        icon.setContentHuggingPriority(.required, for: .horizontal)

        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = UITheme.sidebarPrimaryText
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.addArrangedSubview(icon)
        stack.addArrangedSubview(label)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        chevronButton.isBordered = false
        chevronButton.imagePosition = .imageOnly
        chevronButton.contentTintColor = UITheme.sidebarSecondaryText
        chevronButton.target = self
        chevronButton.action = #selector(toggleFolder)
        chevronButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chevronButton)

        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.trailingAnchor.constraint(
                lessThanOrEqualTo: chevronButton.leadingAnchor, constant: -8),

            chevronButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            chevronButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevronButton.widthAnchor.constraint(equalToConstant: 22),
            chevronButton.heightAnchor.constraint(equalToConstant: 22),
        ])

        textField = label
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        chevronButton.isHidden = !showsChevron
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        chevronButton.isHidden = true
    }

    static func make(
        in tableView: NSTableView,
        title: String,
        isExpanded: Bool,
        isExpandable: Bool,
        onToggle: @escaping () -> Bool
    ) -> SidebarFolderCellView {
        let cell =
            tableView.makeView(withIdentifier: reuseID, owner: nil) as? SidebarFolderCellView
            ?? SidebarFolderCellView(frame: .zero)
        cell.identifier = reuseID
        cell.configure(
            title: title,
            isExpanded: isExpanded,
            isExpandable: isExpandable,
            onToggle: onToggle
        )
        return cell
    }

    private func configure(
        title: String,
        isExpanded: Bool,
        isExpandable: Bool,
        onToggle: @escaping () -> Bool
    ) {
        label.stringValue = title
        showsChevron = isExpandable
        self.onToggle = onToggle

        let folderConfig = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        icon.image = NSImage(systemSymbolName: "folder", accessibilityDescription: title)?
            .withSymbolConfiguration(folderConfig)

        setExpanded(isExpanded)
        chevronButton.isEnabled = isExpandable
        chevronButton.isHidden = true
    }

    private func setExpanded(_ isExpanded: Bool) {
        let symbol = isExpanded ? "chevron.down" : "chevron.right"
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        chevronButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }

    @objc private func toggleFolder() {
        setExpanded(onToggle?() ?? false)
        chevronButton.isHidden = !showsChevron
    }
}

/// Pure whitespace between the fixed items and the folder tree — no line,
/// just air (Things-style).
final class SeparatorCellView: NSView {
    static let reuseID = NSUserInterfaceItemIdentifier("SidebarSpacer")

    static func make(in outlineView: NSOutlineView) -> SeparatorCellView {
        let cell =
            outlineView.makeView(withIdentifier: reuseID, owner: nil) as? SeparatorCellView
            ?? SeparatorCellView(frame: .zero)
        cell.identifier = reuseID
        return cell
    }
}
