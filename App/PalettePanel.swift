import AppKit
import EditorKit

/// The shared overlay for ⌘O quick-open and ⌘P command palette: a flat,
/// borderless panel with a query field and a keyboard-driven result list.
@MainActor
final class PalettePanel: NSPanel {
    struct Item {
        let symbol: String?
        let title: String
        let subtitle: String?
        var image: NSImage? // custom template icon; wins over `symbol`
        let action: @MainActor () -> Void

        init(symbol: String?, title: String, subtitle: String?,
             image: NSImage? = nil, action: @escaping @MainActor () -> Void) {
            self.symbol = symbol
            self.title = title
            self.subtitle = subtitle
            self.image = image
            self.action = action
        }
    }

    private let field = NSTextField()
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private var items: [Item] = []
    private var provider: (@MainActor (String) -> [Item])?
    private var onClose: (@MainActor () -> Void)?

    static let shared = PalettePanel()

    private init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 380),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        hidesOnDeactivate = true
        setupContent()
    }

    override var canBecomeKey: Bool { true }

    private func setupContent() {
        let theme = EditorTheme.standard()
        let container = ColorView(color: theme.background)
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 1
        container.layer?.borderColor = UITheme.hairline.cgColor

        field.isBordered = false
        field.isBezeled = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 17)
        field.backgroundColor = .clear
        field.placeholderString = "Search…"
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false

        let divider = ColorView(color: UITheme.hairline)
        divider.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: .init("item"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .fullWidth
        tableView.rowHeight = 36
        tableView.backgroundColor = .clear
        tableView.focusRingType = .none
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(activateClicked)
        tableView.refusesFirstResponder = true

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(field)
        container.addSubview(divider)
        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            field.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            field.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            divider.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 14),
            divider.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),
            scrollView.topAnchor.constraint(equalTo: divider.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
        ])
        contentView = container
    }

    // MARK: Presentation

    func present(
        over window: NSWindow,
        placeholder: String,
        provider: @escaping @MainActor (String) -> [Item],
        onClose: (@MainActor () -> Void)? = nil
    ) {
        self.provider = provider
        self.onClose = onClose
        field.placeholderString = placeholder
        field.stringValue = ""

        let width: CGFloat = 560
        let height: CGFloat = 380
        let frame = window.frame
        let origin = NSPoint(
            x: frame.midX - width / 2,
            y: frame.maxY - height - 96
        )
        setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: false)

        window.addChildWindow(self, ordered: .above)
        makeKeyAndOrderFront(nil)
        makeFirstResponder(field)
        refresh()
    }

    func dismiss() {
        parent?.removeChildWindow(self)
        orderOut(nil)
        provider = nil
        items = []
        let close = onClose
        onClose = nil
        close?()
    }

    override func resignKey() {
        super.resignKey()
        if isVisible { dismiss() }
    }

    // MARK: Data

    private func refresh() {
        items = provider?(field.stringValue) ?? []
        tableView.reloadData()
        if !items.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
        }
    }

    private func activate(row: Int) {
        guard row >= 0, row < items.count else { return }
        let action = items[row].action
        dismiss()
        action()
    }

    @objc private func activateClicked() {
        activate(row: tableView.clickedRow)
    }

    private func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        let current = tableView.selectedRow
        let next = min(max(current + delta, 0), items.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }
}

// MARK: - Field events

extension PalettePanel: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        refresh()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            activate(row: tableView.selectedRow)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss()
            return true
        default:
            return false
        }
    }
}

// MARK: - Table

extension PalettePanel: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SoftRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        return PaletteCellView.make(in: tableView, item: item)
    }
}

/// Row: small symbol + title + muted subtitle.
private final class PaletteCellView: NSTableCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("PaletteCell")

    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.contentTintColor = .secondaryLabelColor
        icon.setContentHuggingPriority(.required, for: .horizontal)
        title.font = .systemFont(ofSize: 14)
        title.lineBreakMode = .byTruncatingTail
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .tertiaryLabelColor
        subtitle.lineBreakMode = .byTruncatingHead

        let stack = NSStackView(views: [icon, title, subtitle])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    static func make(in tableView: NSTableView, item: PalettePanel.Item) -> PaletteCellView {
        let cell = tableView.makeView(withIdentifier: reuseID, owner: nil) as? PaletteCellView
            ?? PaletteCellView(frame: .zero)
        cell.identifier = reuseID
        cell.title.stringValue = item.title
        cell.subtitle.stringValue = item.subtitle ?? ""
        if let image = item.image {
            cell.icon.image = image
            cell.icon.isHidden = false
        } else if let symbol = item.symbol {
            cell.icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
            cell.icon.isHidden = false
        } else {
            cell.icon.isHidden = true
        }
        return cell
    }
}
