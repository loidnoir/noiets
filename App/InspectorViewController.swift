import AppKit
import IndexKit
import MarkdownKit
import VaultStore

/// The toggleable right panel: document outline (headings) + backlinks.
/// Flat, quiet, keyboard-light — informational, not chrome.
@MainActor
final class InspectorViewController: NSViewController {
    private let session: VaultSession
    var onOpenNote: ((URL, NSRange?) -> Void)?
    var onJumpToHeading: ((NSRange) -> Void)?

    private let outlineView = NSOutlineView()

    private final class Row {
        enum Kind {
            case group(String)
            case heading(text: String, level: Int, range: NSRange)
            case backlink(IndexKit.NoteIndex.Backlink, context: String)
            case empty(String)
        }

        let kind: Kind
        var children: [Row] = []
        init(_ kind: Kind) { self.kind = kind }
    }

    private var groups: [Row] = []
    private var currentNoteURL: URL?
    private var currentText: String = ""

    init(session: VaultSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        view = ColorView(color: UITheme.sidebarBackground)

        let column = NSTableColumn(identifier: .init("inspector"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .fullWidth
        outlineView.rowHeight = 24
        outlineView.backgroundColor = .clear
        outlineView.focusRingType = .none
        outlineView.indentationPerLevel = 10
        outlineView.intercellSpacing = NSSize(width: 0, height: 1)
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(rowClicked)

        let scroll = NSScrollView()
        scroll.documentView = outlineView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    // MARK: Updates

    func update(noteURL: URL?, text: String) {
        currentNoteURL = noteURL
        currentText = text
        rebuild()
    }

    func noteEdited(text: String) {
        currentText = text
        rebuild()
    }

    func indexChanged() {
        rebuild()
    }

    private func rebuild() {
        guard isViewLoaded else { return }

        let outlineGroup = Row(.group("Outline"))
        let ns = currentText as NSString
        let scan = BlockScan.scan(ns)
        for line in scan.lines {
            if case .heading(let level, _, let textRange) = line.kind, textRange.length > 0 {
                let text = ns.substring(with: textRange)
                outlineGroup.children.append(Row(.heading(text: text, level: level, range: line.range)))
            }
        }
        if outlineGroup.children.isEmpty {
            outlineGroup.children.append(Row(.empty("No headings")))
        }

        let backlinksGroup = Row(.group("Backlinks"))
        if let url = currentNoteURL, let index = session.index {
            let relPath = session.vault.relativePath(of: url)
            let backlinks = (try? index.backlinks(to: relPath)) ?? []
            for backlink in backlinks {
                let context = contextLine(for: backlink)
                backlinksGroup.children.append(Row(.backlink(backlink, context: context)))
            }
        }
        if backlinksGroup.children.isEmpty {
            backlinksGroup.children.append(Row(.empty("No backlinks")))
        }

        groups = [outlineGroup, backlinksGroup]
        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)
    }

    private func contextLine(for backlink: NoteIndex.Backlink) -> String {
        let url = session.url(forRelPath: backlink.sourceRelPath)
        guard let text = try? NoteIO.read(url) else { return "" }
        let ns = text as NSString
        guard backlink.rangeStart < ns.length else { return "" }
        let line = ns.lineRange(for: NSRange(location: backlink.rangeStart, length: 0))
        return ns.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @objc private func rowClicked() {
        guard outlineView.clickedRow >= 0,
              let row = outlineView.item(atRow: outlineView.clickedRow) as? Row else { return }
        switch row.kind {
        case .heading(_, _, let range):
            onJumpToHeading?(range)
        case .backlink(let backlink, _):
            let url = session.url(forRelPath: backlink.sourceRelPath)
            onOpenNote?(url, NSRange(location: backlink.rangeStart, length: backlink.rangeLength))
        default:
            break
        }
    }
}

// MARK: - Outline plumbing

extension InspectorViewController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let row = item as? Row else { return groups.count }
        return row.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let row = item as? Row else { return groups[index] }
        return row.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let row = item as? Row else { return false }
        if case .group = row.kind { return true }
        return false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let row = item as? Row else { return false }
        switch row.kind {
        case .heading, .backlink: return true
        default: return false
        }
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        SoftRowView()
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let row = item as? Row else { return 24 }
        if case .backlink = row.kind { return 40 }
        if case .group = row.kind { return 28 }
        return 24
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let row = item as? Row else { return nil }
        switch row.kind {
        case .group(let title):
            return InspectorCells.group(in: outlineView, title: title)
        case .heading(let text, let level, _):
            return InspectorCells.line(
                in: outlineView, title: text,
                subtitle: nil,
                weight: level <= 2 ? .semibold : .regular,
                indent: CGFloat(level - 1) * 10
            )
        case .backlink(let backlink, let context):
            return InspectorCells.line(in: outlineView, title: backlink.sourceTitle,
                                       subtitle: context, weight: .medium, indent: 0)
        case .empty(let text):
            return InspectorCells.empty(in: outlineView, text: text)
        }
    }
}

@MainActor
private enum InspectorCells {
    static func group(in table: NSTableView, title: String) -> NSView {
        let id = NSUserInterfaceItemIdentifier("InspectorGroup")
        let cell = (table.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? {
            let c = NSTableCellView()
            c.identifier = id
            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = UITheme.sidebarSecondaryText
            label.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(label)
            c.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 10),
                label.bottomAnchor.constraint(equalTo: c.bottomAnchor, constant: -4),
            ])
            return c
        }()
        cell.textField?.stringValue = title.uppercased()
        return cell
    }

    static func line(in table: NSTableView, title: String, subtitle: String?,
                     weight: NSFont.Weight, indent: CGFloat) -> NSView {
        let id = NSUserInterfaceItemIdentifier(subtitle == nil ? "InspectorLine" : "InspectorTwoLine")
        let cell = (table.makeView(withIdentifier: id, owner: nil) as? TwoLineCell) ?? {
            let c = TwoLineCell(hasSubtitle: subtitle != nil)
            c.identifier = id
            return c
        }()
        cell.configure(title: title, subtitle: subtitle, weight: weight, indent: indent)
        return cell
    }

    static func empty(in table: NSTableView, text: String) -> NSView {
        let id = NSUserInterfaceItemIdentifier("InspectorEmpty")
        let cell = (table.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? {
            let c = NSTableCellView()
            c.identifier = id
            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 12)
            label.textColor = .tertiaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(label)
            c.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 10),
                label.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
        cell.textField?.stringValue = text
        return cell
    }
}

private final class TwoLineCell: NSTableCellView {
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private var leadingConstraint: NSLayoutConstraint?

    init(hasSubtitle: Bool) {
        super.init(frame: .zero)
        title.font = .systemFont(ofSize: 12.5)
        title.textColor = UITheme.sidebarPrimaryText
        title.lineBreakMode = .byTruncatingTail
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = UITheme.sidebarSecondaryText
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.isHidden = !hasSubtitle

        let stack = NSStackView(views: hasSubtitle ? [title, subtitle] : [title])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let leading = stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10)
        leadingConstraint = leading
        NSLayoutConstraint.activate([
            leading,
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(title: String, subtitle: String?, weight: NSFont.Weight, indent: CGFloat) {
        self.title.stringValue = title
        self.title.font = .systemFont(ofSize: 12.5, weight: weight)
        if let subtitle {
            self.subtitle.stringValue = subtitle
        }
        leadingConstraint?.constant = 10 + indent
    }
}
