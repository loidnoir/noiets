import AppKit
import IndexKit
import RenderKit

/// One pinned summary over the view's results, with a responsive tag selector.
@MainActor
final class HeatmapWidgetView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    let graph = HeatmapGridView()
    let graphScroll = NSScrollView()
    let tagTable = VimTableView()
    let tagPopup = FocusableTagPopup()
    let tagScroll = NSScrollView()
    private var tags: [String] = []
    private var showsTags = false
    private var updatingSelection = false
    private var colours: [String: NSColor] = [:]
    private(set) var selectedTag: String?
    var selectedDay: Date? { graph.selectedDay }
    var onSelectionChanged: (() -> Void)?
    var onHeightChanged: ((CGFloat) -> Void)?
    var onNavigate: ((DirectionalFocus.Direction) -> Void)?
    var onFocusSearch: (() -> Void)?
    var colourForTag: ((String) -> NSColor)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        graphScroll.documentView = graph
        graphScroll.hasHorizontalScroller = true
        graphScroll.autohidesScrollers = true
        graphScroll.drawsBackground = false
        graphScroll.automaticallyAdjustsContentInsets = false
        graph.onSelectionChanged = { [weak self] in self?.onSelectionChanged?() }
        graphScroll.setAccessibilityLabel("Note activity heatmap")
        let column = NSTableColumn(identifier: .init("tag"))
        tagTable.addTableColumn(column)
        tagTable.headerView = nil
        tagTable.style = .fullWidth
        tagTable.autoresizingMask = [.width]
        tagTable.rowHeight = 21
        tagTable.intercellSpacing = .zero
        tagTable.backgroundColor = .clear
        tagTable.selectionHighlightStyle = .none
        tagTable.dataSource = self
        tagTable.delegate = self
        tagTable.focusRingType = .none
        tagTable.setAccessibilityLabel("Heatmap tags")
        tagTable.onKey = { [weak self] event in self?.handleTagKey(event) ?? false }
        tagScroll.documentView = tagTable
        tagScroll.hasVerticalScroller = true
        tagScroll.autohidesScrollers = true
        tagScroll.drawsBackground = false
        tagScroll.automaticallyAdjustsContentInsets = false
        tagPopup.cell = TagPopupCell(textCell: "", pullsDown: false)
        tagPopup.onKey = { [weak self] event in self?.handleTagKey(event) ?? false }
        tagPopup.target = self
        tagPopup.action = #selector(popupChanged)
        tagPopup.font = AppFonts.font(ofSize: 12)
        tagPopup.setAccessibilityLabel("Heatmap tag")
        addSubview(graphScroll)
        addSubview(tagScroll)
        addSubview(tagPopup)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        let compact = showsTags && bounds.width < 780
        let wasTagTable = window?.firstResponder === tagTable
        let wasPopup = window?.firstResponder === tagPopup
        tagScroll.isHidden = !showsTags || compact
        tagPopup.isHidden = !compact
        let font = AppFonts.font(ofSize: 12)
        let widestTag = (["All"] + tags.map { "#" + $0 }).map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        let selectorWidth: CGFloat = showsTags && !compact ? min(180, max(72, ceil(widestTag) + 24)) : 0
        let gap: CGFloat = selectorWidth > 0 ? 8 : 0
        let graphWidth = min(graph.preferredWidth, max(0, bounds.width - selectorWidth - gap))
        let canvasWidth = max(640, graphWidth)
        graph.frame = NSRect(x: 0, y: 0, width: canvasWidth, height: 148)
        let graphHeight = graph.requiredHeight
        let scrollbar = graphScroll.scrollerStyle == .legacy && canvasWidth > graphWidth
            ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
        let totalHeight = graphHeight + scrollbar + (compact ? 30 : 0)
        onHeightChanged?(totalHeight)
        graphScroll.frame = NSRect(x: 0, y: 0, width: graphWidth, height: graphHeight + scrollbar)
        graph.frame.size.height = graphHeight
        // Keep the selector beside the actual grid, not at the far edge of a
        // stretched viewport, and give it exactly the grid's vertical extent.
        tagScroll.frame = NSRect(x: graphWidth + gap, y: bounds.height - graph.gridTop - graph.gridHeight,
                                 width: selectorWidth, height: graph.gridHeight)
        tagPopup.frame = NSRect(x: 8, y: bounds.height - 28, width: min(220, bounds.width - 16), height: 26)
        tagTable.frame.size.width = max(0, tagScroll.contentSize.width)
        tagTable.tableColumns.first?.width = max(0, tagScroll.contentSize.width)
        graph.needsDisplay = true
        // Never strand focus in the selector that a resize just hid.
        if compact, wasTagTable { window?.makeFirstResponder(tagPopup) }
        if !compact, wasPopup { window?.makeFirstResponder(tagTable) }
    }

    func configure(_ configuration: ViewQuery.Heatmap, hits: [NoteIndex.SearchHit]) {
        updatingSelection = true
        defer { updatingSelection = false }
        tags = HeatmapData.tagChoices(for: configuration, hits: hits)
        showsTags = configuration.tags != .none
        if let selectedTag, !tags.contains(selectedTag) { self.selectedTag = nil }
        colours = Dictionary(uniqueKeysWithValues: tags.map { ($0, colourForTag?($0) ?? UITheme.accent) })
        tagTable.reloadData()
        tagPopup.removeAllItems()
        let font = AppFonts.font(ofSize: 12)
        for index in 0...tags.count {
            let name = index == 0 ? "All" : "#" + tags[index - 1]
            tagPopup.addItem(withTitle: name)
            let colour = index == 0 ? UITheme.accent : colours[tags[index - 1]]!
            tagPopup.lastItem?.representedObject = colour
            tagPopup.lastItem?.attributedTitle = NSAttributedString(string: name, attributes: [.foregroundColor: AppColors.color(.editorText), .font: font])
        }
        synchroniseSelection()
        updateGraph(hits)
        needsLayout = true
    }

    func updateGraph(_ hits: [NoteIndex.SearchHit]) {
        graph.data = HeatmapData(hits: hits, tag: selectedTag)
        graph.colour = selectedTag.flatMap { colours[$0] } ?? UITheme.accent
        graph.needsDisplay = true
    }

    func resetSelection() {
        selectedTag = nil
        graph.clearSelection()
    }

    func focusGraph() {
        window?.makeFirstResponder(graph)
        graph.revealCursor()
    }

    func focusTags() {
        if tagScroll.isHidden { window?.makeFirstResponder(tagPopup) }
        else { window?.makeFirstResponder(tagTable) }
    }

    private func synchroniseSelection() {
        let wasUpdating = updatingSelection
        updatingSelection = true
        defer { updatingSelection = wasUpdating }
        let row = selectedTag.flatMap { tags.firstIndex(of: $0).map { $0 + 1 } } ?? 0
        tagTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tagPopup.selectItem(at: row)
        if row < tagTable.numberOfRows { tagTable.scrollRowToVisible(row) }
    }

    private func choose(_ row: Int) {
        guard !updatingSelection, row >= 0, row <= tags.count else { return }
        let next = row == 0 ? nil : tags[row - 1]
        guard next != selectedTag else { return }
        selectedTag = next
        graph.clearSelection()
        synchroniseSelection()
        onSelectionChanged?()
    }

    @objc private func popupChanged() { choose(tagPopup.indexOfSelectedItem) }

    func numberOfRows(in tableView: NSTableView) -> Int { tags.count + 1 }
    func tableViewSelectionDidChange(_ notification: Notification) { choose(tagTable.selectedRow) }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row <= tags.count else { return nil }
        let badge = TagBadgeView()
        badge.font = AppFonts.font(ofSize: 12)
        badge.name = row == 0 ? "All" : "#" + tags[row - 1]
        badge.colour = row == 0 ? UITheme.accent : colours[tags[row - 1]]!
        badge.selected = (row == 0 && selectedTag == nil) || (row > 0 && selectedTag == tags[row - 1])
        badge.setAccessibilityElement(true)
        badge.setAccessibilityRole(.staticText)
        badge.setAccessibilityLabel(badge.name)
        badge.setAccessibilityValue(badge.selected ? "Selected" : "")
        return badge
    }

    private func handleTagKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.control, .command, .option]).isEmpty else { return false }
        if event.characters == "/" {
            guard let onFocusSearch else { return false }
            onFocusSearch()
            return true
        }
        switch event.charactersIgnoringModifiers {
        case "j", "\u{F701}": choose(min(tags.count, tagTable.selectedRow + 1))
        case "k", "\u{F700}": choose(max(0, tagTable.selectedRow - 1))
        case "h": onNavigate?(.left)
        case "l": onNavigate?(.right)
        default: return false
        }
        return true
    }
}

private final class TagPopupCell: NSPopUpButtonCell {
    override func drawTitle(_ title: NSAttributedString, withFrame frame: NSRect, in controlView: NSView) -> NSRect {
        if let colour = selectedItem?.representedObject as? NSColor {
            let size = title.size()
            let rect = NSRect(x: frame.minX - InlineChipStyle.horizontalPadding,
                              y: frame.midY - size.height / 2 - InlineChipStyle.verticalPadding,
                              width: min(frame.width, size.width) + InlineChipStyle.horizontalPadding * 2,
                              height: size.height + InlineChipStyle.verticalPadding * 2)
            InlineChipStyle.tagBackground(colour).setFill()
            NSBezierPath(roundedRect: rect, xRadius: InlineChipStyle.cornerRadius, yRadius: InlineChipStyle.cornerRadius).fill()
        }
        return super.drawTitle(title, withFrame: frame, in: controlView)
    }
}

final class FocusableTagPopup: NSPopUpButton {
    var onKey: ((NSEvent) -> Bool)?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if onKey?(event) == true { return }
        super.keyDown(with: event)
    }
}

/// Monday-first grid. Plain hjkl navigate dates; Return toggles the day filter.
@MainActor
final class HeatmapGridView: NSView {
    var data = HeatmapData(hits: []) {
        didSet {
            if let selectedDay, !data.days.contains(where: { $0.date == selectedDay }) { self.selectedDay = nil }
            if cursor >= data.days.count { cursor = max(0, data.days.count - 1) }
            needsDisplay = true
        }
    }
    var colour = NSColor.controlAccentColor
    private(set) var selectedDay: Date?
    private var cursor = 0
    private var tracking: NSTrackingArea?
    var onSelectionChanged: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cursor = data.days.count - 1
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Note activity, last year. H J K L navigate days; Return filters notes; Escape clears the filter.")
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var offset: Int { (data.calendar.component(.weekday, from: data.days[0].date) + 5) % 7 }
    private var columns: Int { (offset + data.days.count + 6) / 7 }
    var preferredWidth: CGFloat { CGFloat(columns) * 15 + 42 }
    var gridTop: CGFloat { 24 }
    var gridHeight: CGFloat { 7 * step }
    var requiredHeight: CGFloat { ceil(gridTop + gridHeight + 18) }
    private var step: CGFloat { max(1, min(15, (bounds.width - 42) / CGFloat(columns))) }
    private func cell(_ index: Int) -> NSRect {
        let position = index + offset
        return NSRect(x: 34 + CGFloat(position / 7) * step, y: gridTop + CGFloat(position % 7) * step,
                      width: max(3, step - 3), height: max(3, step - 3))
    }
    private func day(at point: NSPoint) -> Int? { data.days.indices.first { cell($0).contains(point) } }
    private var focused: Bool { window?.firstResponder === self }

    override func draw(_ dirtyRect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [.font: AppFonts.font(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor]
        let month = DateFormatter()
        month.dateFormat = "MMM"
        var previousMonth = -1
        var previousLabelX: CGFloat = -100
        let maxCount = max(1, data.days.map(\.count).max() ?? 1)
        for (index, day) in data.days.enumerated() {
            let rect = cell(index)
            let currentMonth = data.calendar.component(.month, from: day.date)
            if currentMonth != previousMonth {
                if rect.minX - previousLabelX >= 30 {
                    (month.string(from: day.date) as NSString).draw(at: NSPoint(x: rect.minX, y: 4), withAttributes: attributes)
                    previousLabelX = rect.minX
                }
                previousMonth = currentMonth
            }
            let fill: NSColor
            if day.count == 0 { fill = NSColor.secondaryLabelColor.withAlphaComponent(0.10) }
            else {
                let level = min(4, max(1, Int(ceil(Double(day.count) / Double(maxCount) * 4))))
                fill = colour.withAlphaComponent(0.25 + CGFloat(level) * 0.1875)
            }
            fill.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
            if day.date == selectedDay || (focused && cursor == index) {
                NSColor.labelColor.setStroke()
                let outline = NSBezierPath(roundedRect: rect.insetBy(dx: -1, dy: -1), xRadius: 3, yRadius: 3)
                outline.lineWidth = 1.5
                outline.stroke()
            }
        }
        for (row, label) in [(0, "M"), (2, "W"), (4, "F"), (6, "S")] {
            (label as NSString).draw(at: NSPoint(x: 12, y: gridTop - 1 + CGFloat(row) * step), withAttributes: attributes)
        }
        let footer = selectedDay.map { "\(DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .none)) · Esc to clear" }
            ?? "\(data.days.reduce(0) { $0 + $1.count }) notes · last year · query results"
        (footer as NSString).draw(at: NSPoint(x: 34, y: gridTop + gridHeight + 4), withAttributes: attributes)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }
    override func mouseMoved(with event: NSEvent) {
        guard let index = day(at: convert(event.locationInWindow, from: nil)) else { toolTip = nil; return }
        let day = data.days[index]
        toolTip = "\(DateFormatter.localizedString(from: day.date, dateStyle: .full, timeStyle: .none)): \(day.count) note\(day.count == 1 ? "" : "s")"
    }
    override func mouseExited(with event: NSEvent) { toolTip = nil }
    override func mouseDown(with event: NSEvent) {
        guard let index = day(at: convert(event.locationInWindow, from: nil)) else { return }
        window?.makeFirstResponder(self)
        cursor = index
        toggleDay()
    }
    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return super.becomeFirstResponder()
    }
    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return super.resignFirstResponder()
    }
    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.control, .command, .option]).isEmpty else { super.keyDown(with: event); return }
        if event.keyCode == 53 { clearSelection(); onSelectionChanged?(); return }
        if event.keyCode == 36 || event.keyCode == 76 { toggleDay(); return }
        switch event.charactersIgnoringModifiers {
        case "h", "\u{F702}": cursor = max(0, cursor - 7)
        case "l", "\u{F703}": cursor = min(data.days.count - 1, cursor + 7)
        case "j", "\u{F701}": cursor = min(data.days.count - 1, cursor + 1)
        case "k", "\u{F700}": cursor = max(0, cursor - 1)
        default: super.keyDown(with: event); return
        }
        revealCursor()
    }
    func revealCursor() {
        scrollToVisible(cell(cursor).insetBy(dx: -6, dy: -6))
        needsDisplay = true
    }
    func clearSelection() { selectedDay = nil; needsDisplay = true }
    private func toggleDay() {
        let day = data.days[cursor].date
        selectedDay = selectedDay == day ? nil : day
        needsDisplay = true
        onSelectionChanged?()
    }
}
