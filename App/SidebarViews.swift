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
        // Adjacent selected rows merge into one slab: only the outermost
        // edges of a contiguous run keep their gap and rounded corners.
        let joinAbove = isPreviousRowSelected
        let joinBelow = isNextRowSelected
        let topGap: CGFloat = (isFlipped ? joinAbove : joinBelow) ? 0 : 2
        let bottomGap: CGFloat = (isFlipped ? joinBelow : joinAbove) ? 0 : 2
        let rect = NSRect(
            x: bounds.minX + 10,
            y: bounds.minY + topGap,
            width: bounds.width - 20,
            height: bounds.height - topGap - bottomGap
        )

        // Accent tint while the enclosing list has keyboard focus — this is
        // the pane-focus indicator.
        var container: NSView? = superview
        while container != nil, !(container is NSTableView) {
            container = container?.superview
        }
        let focused = container != nil && window?.firstResponder === container
        (focused ? UITheme.sidebarSelectionFocused : UITheme.sidebarSelection).setFill()

        // One compound path, one fill — the tint is translucent, so separate
        // overlapping fills would compound into visible seams.
        let radius: CGFloat = 7
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        if joinAbove { // square off the joined edge
            let edge = isFlipped ? rect.minY : rect.maxY - radius
            path.appendRect(NSRect(x: rect.minX, y: edge, width: rect.width, height: radius))
        }
        if joinBelow {
            let edge = isFlipped ? rect.maxY - radius : rect.minY
            path.appendRect(NSRect(x: rect.minX, y: edge, width: rect.width, height: radius))
        }
        path.windingRule = .nonZero
        path.fill()
    }
}

/// Repaints row selections when keyboard focus enters/leaves the list, so
/// the focus tint updates immediately.
private func repaintSelections(of table: NSTableView) {
    table.enumerateAvailableRowViews { rowView, _ in
        rowView.needsDisplay = true
    }
}

/// Split view with a quiet hairline divider matching the mode bar's outline.
final class SeamlessSplitView: NSSplitView {
    override var dividerColor: NSColor {
        UITheme.paneSeparator
    }
}

/// Outline view with the native disclosure triangle hidden by zeroing its
/// frame. (Returning false from shouldShowOutlineCellForItem instead makes
/// AppKit pin items expanded — collapseItem is silently ignored.)
/// Keyboard events route to the controller first (vim-style tree navigation).
final class SidebarOutlineView: NSOutlineView {
    var onKey: ((NSEvent) -> Bool)?

    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        .zero
    }

    override func keyDown(with event: NSEvent) {
        if let onKey, onKey(event) {
            return
        }
        super.keyDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { repaintSelections(of: self) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { repaintSelections(of: self) }
        return ok
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
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1 // long names truncate with …, never wrap
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

    static func make(in tableView: NSTableView, title: String, symbol: String?, isFolder: Bool,
                     image: NSImage? = nil, prominent: Bool? = nil,
                     tint: NSColor? = nil) -> SidebarCellView
    {
        let cell =
            tableView.makeView(withIdentifier: reuseID, owner: nil) as? SidebarCellView
            ?? SidebarCellView(frame: .zero)
        cell.identifier = reuseID
        cell.configure(title: title, symbol: symbol, isFolder: isFolder,
                       image: image, prominent: prominent, tint: tint)
        return cell
    }

    private func configure(title: String, symbol: String?, isFolder: Bool,
                           image: NSImage?, prominent: Bool?, tint: NSColor?) {
        icon.contentTintColor = tint ?? UITheme.sidebarSecondaryText
        label.stringValue = title
        // Prominent rows (the fixed sidebar items) use the larger label; list
        // rows keep the compact one even when they carry a type icon.
        let isProminent = prominent ?? (symbol != nil || image != nil)
        label.font = .systemFont(
            ofSize: isProminent ? 15 : 13.5,
            weight: isProminent ? .medium : (isFolder ? .medium : .regular)
        )
        label.textColor = UITheme.sidebarPrimaryText
        if let image {
            icon.image = image
            icon.isHidden = false
        } else if let symbol {
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

        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = UITheme.sidebarPrimaryText
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1 // long names truncate with …, never wrap
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

        icon.image = AppIcons.folder(size: 17) ?? {
            let folderConfig = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
            return NSImage(systemSymbolName: "folder", accessibilityDescription: title)?
                .withSymbolConfiguration(folderConfig)
        }()

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

/// Plain table with a keyboard hook — the Search/Recent/Trash lists reuse the
/// tree's vim navigation through it.
final class VimTableView: NSTableView {
    var onKey: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if let onKey, onKey(event) {
            return
        }
        super.keyDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { repaintSelections(of: self) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { repaintSelections(of: self) }
        return ok
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

/// Section header for date/tag-grouped lists (Views layouts, Trash):
/// primary-accent title over a hairline.
final class SectionHeaderCellView: NSTableCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("SectionHeaderCell")

    private let title = NSTextField(labelWithString: "")
    private let line = ColorView(color: UITheme.hairline)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.textColor = UITheme.modeNormalText
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        title.translatesAutoresizingMaskIntoConstraints = false
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(title)
        addSubview(line)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
            title.bottomAnchor.constraint(equalTo: line.topAnchor, constant: -6),
            line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            line.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            line.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    static func make(in tableView: NSTableView, title: String) -> SectionHeaderCellView {
        let cell = tableView.makeView(withIdentifier: reuseID, owner: nil) as? SectionHeaderCellView
            ?? SectionHeaderCellView(frame: .zero)
        cell.identifier = reuseID
        cell.title.stringValue = title
        return cell
    }
}

/// Two-line row: type icon + note title + muted snippet/path
/// (Search/Views results, Trash).
final class SearchHitCellView: NSTableCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("SearchHitCell")

    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.image = AppIcons.document(size: 15)
        icon.contentTintColor = .secondaryLabelColor
        title.font = .systemFont(ofSize: 14, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        // Long titles must truncate on one line — never wrap, never crush
        // the icon out of the row.
        title.maximumNumberOfLines = 1
        detail.maximumNumberOfLines = 1
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 15),
            icon.heightAnchor.constraint(equalToConstant: 15),
        ])

        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        let stack = NSStackView(views: [icon, text])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    static func make(in tableView: NSTableView, title: String, detail: String,
                     image: NSImage? = nil) -> SearchHitCellView {
        let cell = tableView.makeView(withIdentifier: reuseID, owner: nil) as? SearchHitCellView
            ?? SearchHitCellView(frame: .zero)
        cell.identifier = reuseID
        cell.title.stringValue = title
        cell.detail.stringValue = detail.replacingOccurrences(of: "\n", with: " ")
        cell.icon.image = image ?? AppIcons.document(size: 15)
        return cell
    }
}

/// Shared "MMMM yyyy" month-section title used by list groupings.
enum DateSectionTitle {
    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter
    }()

    static func month(for date: Date) -> String {
        monthFormatter.string(from: date)
    }
}
