import AppKit

/// Small completion popup that appears while typing inside `[[…`. Suggestion
/// data comes from an injected provider (the app backs it with the index).
@MainActor
public final class WikiLinkAutocomplete: NSPanel {
    private let tableView = NSTableView()
    private var suggestions: [String] = []
    private var onPick: ((String) -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        becomesKeyOnlyIfNeeded = true

        let theme = EditorTheme.standard()
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = theme.background.cgColor
        container.layer?.cornerRadius = 8
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.separatorColor.cgColor

        let column = NSTableColumn(identifier: .init("suggestion"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .fullWidth
        tableView.rowHeight = 26
        tableView.backgroundColor = .clear
        tableView.focusRingType = .none
        tableView.intercellSpacing = .zero
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(pickClicked)
        tableView.refusesFirstResponder = true

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        contentView = container
    }

    public var isActive: Bool { isVisible }

    /// Routes editor keys while visible. Returns true when consumed.
    public func handleKeyDown(_ event: NSEvent) -> Bool {
        guard isVisible else { return false }
        switch event.keyCode {
        case 53: // esc
            hide()
            return true
        case 36, 76: // return
            pick(row: tableView.selectedRow)
            return true
        case 125: // down
            move(1)
            return true
        case 126: // up
            move(-1)
            return true
        case 48: // tab completes too
            pick(row: tableView.selectedRow)
            return true
        default:
            return false
        }
    }

    func show(suggestions: [String], at screenRect: NSRect, parent: NSWindow, onPick: @escaping (String) -> Void) {
        self.suggestions = Array(suggestions.prefix(8))
        self.onPick = onPick
        guard !self.suggestions.isEmpty else {
            hide()
            return
        }
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        let height = min(CGFloat(self.suggestions.count) * 26 + 8, 180)
        let origin = NSPoint(x: screenRect.minX, y: screenRect.minY - height - 4)
        setFrame(NSRect(x: origin.x, y: origin.y, width: 320, height: height), display: false)
        if parent != self.parent {
            parent.addChildWindow(self, ordered: .above)
        }
        orderFront(nil)
    }

    func hide() {
        parent?.removeChildWindow(self)
        orderOut(nil)
        suggestions = []
        onPick = nil
    }

    private func move(_ delta: Int) {
        guard !suggestions.isEmpty else { return }
        let next = min(max(tableView.selectedRow + delta, 0), suggestions.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    private func pick(row: Int) {
        guard row >= 0, row < suggestions.count else {
            hide()
            return
        }
        let value = suggestions[row]
        let action = onPick
        hide()
        action?(value)
    }

    @objc private func pickClicked() {
        pick(row: tableView.clickedRow)
    }
}

extension WikiLinkAutocomplete: NSTableViewDataSource, NSTableViewDelegate {
    public func numberOfRows(in tableView: NSTableView) -> Int { suggestions.count }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("WikiSuggestion")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? {
            let c = NSTableCellView()
            c.identifier = id
            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 13)
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(label)
            c.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 10),
                label.trailingAnchor.constraint(lessThanOrEqualTo: c.trailingAnchor, constant: -10),
                label.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
        cell.textField?.stringValue = suggestions[row]
        return cell
    }
}
