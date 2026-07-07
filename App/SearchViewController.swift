import AppKit
import EditorKit
import IndexKit

/// The list view behind the Search / Recent sidebar items (and tag browsing
/// from the palette). Lives in the editor pane; opening a row swaps back to
/// the editor.
@MainActor
final class SearchViewController: NSViewController {
    enum Mode: Equatable {
        case search
        case tag(String)
        case view(ViewRef)
    }

    private let session: VaultSession
    var onOpenNote: ((URL) -> Void)?
    /// Esc / ⌃h → back to the sidebar tree.
    var onFocusSidebar: (() -> Void)?

    /// A list line: a note result, or a section header from `layout:`.
    private enum ListRow {
        case header(String)
        case note(title: String, detail: String, relPath: String)

        var relPath: String? {
            if case .note(_, _, let relPath) = self { return relPath }
            return nil
        }
    }

    private var mode: Mode = .search
    private let searchField = NSSearchField()
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let headerLabel = NSTextField(labelWithString: "")
    private let tableView = VimTableView()
    private let scrollView = NSScrollView()
    private var rows: [ListRow] = []

    /// The query as last saved — the Save affordance appears when the live
    /// field differs from it.
    private var savedBaseline = ""
    /// Plain-search text, cached across mode switches so a NoQL query never
    /// leaks into FTS search and vice versa.
    private var lastSearchText = ""

    init(session: VaultSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let theme = EditorTheme.standard()
        let container = ColorView(color: theme.background)
        view = container

        searchField.placeholderString = "Search project"
        searchField.font = .systemFont(ofSize: 15)
        searchField.focusRingType = .none
        searchField.target = self
        searchField.action = #selector(queryChanged)
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self // ↓/Return → list, Esc → sidebar
        searchField.translatesAutoresizingMaskIntoConstraints = false

        tableView.onKey = { [weak self] event in
            self?.handleListKey(event) ?? false
        }

        headerLabel.font = .systemFont(ofSize: 22, weight: .bold)
        headerLabel.textColor = theme.textColor
        headerLabel.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: .init("hit"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .fullWidth
        tableView.rowHeight = 46
        tableView.backgroundColor = .clear
        tableView.focusRingType = .none
        tableView.intercellSpacing = .zero
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(openClicked)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // Quiet save affordance for view queries; ⌘⏎ triggers it from
        // anywhere in the window while visible (⌘S is Toggle Sidebar).
        saveButton.bezelStyle = .inline
        saveButton.isBordered = false
        saveButton.font = .systemFont(ofSize: 12, weight: .medium)
        saveButton.contentTintColor = UITheme.modeNormalText
        saveButton.target = self
        saveButton.action = #selector(saveViewQuery)
        saveButton.keyEquivalent = "\r"
        saveButton.keyEquivalentModifierMask = [.command]
        saveButton.isHidden = true
        saveButton.setContentHuggingPriority(.required, for: .horizontal)

        let fieldRow = NSStackView(views: [searchField, saveButton])
        fieldRow.orientation = .horizontal
        fieldRow.spacing = 8
        fieldRow.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(headerLabel)
        container.addSubview(fieldRow)
        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 18),
            headerLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 28),
            fieldRow.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 12),
            fieldRow.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 26),
            fieldRow.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -26),
            scrollView.topAnchor.constraint(equalTo: fieldRow.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    // MARK: Modes

    func show(mode: Mode) {
        _ = view // force load
        if case .search = self.mode, case .search = mode {} else if case .search = self.mode {
            lastSearchText = searchField.stringValue // leaving plain search
        }
        self.mode = mode
        switch mode {
        case .search:
            headerLabel.stringValue = "Search"
            searchField.isHidden = false
            searchField.placeholderString = "Search project"
            searchField.stringValue = lastSearchText
        case .tag(let name):
            headerLabel.stringValue = "#\(name)"
            searchField.isHidden = true
        case .view(let ref):
            headerLabel.stringValue = ref.name
            searchField.isHidden = false
            searchField.placeholderString = "tag:x folder:Notes words… sort:modified"
            searchField.stringValue = ref.query
            savedBaseline = ref.query
        }
        updateSaveButton()
        reload()
    }

    func focusSearch() {
        view.window?.makeFirstResponder(searchField)
        // The field editor exists once focused — style the prefilled query.
        DispatchQueue.main.async { [weak self] in self?.styleQueryTokens() }
    }

    /// Called when the index updates underneath us.
    func indexChanged() {
        reload()
    }

    @objc private func queryChanged() {
        updateSaveButton()
        styleQueryTokens()
        reload()
    }

    /// Chips valid filter tokens in the query field (code-block style,
    /// secondary color) — malformed tokens visibly stay plain.
    private func styleQueryTokens() {
        guard case .view = mode,
              let editor = searchField.currentEditor() as? NSTextView,
              let storage = editor.textStorage else { return }
        let text = searchField.stringValue
        let full = NSRange(location: 0, length: (text as NSString).length)
        guard storage.length == full.length else { return }
        let theme = EditorTheme.standard()
        storage.beginEditing()
        storage.removeAttribute(.backgroundColor, range: full)
        storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: full)
        for range in ViewQuery.filterTokenRanges(text) {
            storage.addAttribute(.backgroundColor, value: theme.codeBackground, range: range)
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
        }
        storage.endEditing()
    }

    // MARK: Saving views

    private func updateSaveButton() {
        guard case .view = mode else {
            saveButton.isHidden = true
            return
        }
        let text = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        saveButton.isHidden = text == savedBaseline.trimmingCharacters(in: .whitespaces)
    }

    @objc private func saveViewQuery() {
        guard case .view(let ref) = mode, !saveButton.isHidden else { return }
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces)

        if !ref.isBuiltin {
            session.upsertView(name: ref.name, query: query)
            mode = .view(ViewRef(name: ref.name, query: query, isBuiltin: false))
            savedBaseline = query
            updateSaveButton()
            return
        }

        // Saving from the built-in Recent view creates a new named view.
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Save View"
        alert.informativeText = "The query is saved to this project and listed in the sidebar."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: "")
        field.placeholderString = "View name"
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard response == .alertFirstButtonReturn, !name.isEmpty else {
                self.focusList()
                return
            }
            self.session.upsertView(name: name, query: query)
            self.show(mode: .view(ViewRef(name: name, query: query, isBuiltin: false)))
            self.focusList()
        }
    }

    private func reload() {
        guard let index = session.index else { return }
        switch mode {
        case .search:
            let query = searchField.stringValue
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                rows = []
            } else {
                let hits = (try? index.searchNotes(query)) ?? []
                rows = hits.map { .note(title: $0.title, detail: $0.snippet, relPath: $0.relPath) }
            }
        case .tag(let name):
            let notes = (try? index.notes(withTag: name)) ?? []
            rows = notes.map { .note(title: $0.title, detail: $0.relPath, relPath: $0.relPath) }
        case .view:
            // The live field is the source of truth, so an index-change
            // reload never clobbers in-flight edits.
            let query = ViewQuery.parse(searchField.stringValue)
            let hits = (try? index.notes(matching: query)) ?? []
            if let layout = query.layout {
                rows = sectioned(hits, layout: layout)
            } else {
                rows = hits.map { noteRow($0) }
            }
        }
        tableView.reloadData()
    }

    private func noteRow(_ hit: NoteIndex.SearchHit) -> ListRow {
        .note(title: hit.title,
              detail: hit.snippet.isEmpty ? hit.relPath : hit.snippet,
              relPath: hit.relPath)
    }

    /// `layout:` rendering: sections in order of first appearance (tag
    /// sections alphabetical), each holding its hits in query order.
    private func sectioned(_ hits: [NoteIndex.SearchHit],
                           layout: ViewQuery.Layout) -> [ListRow] {
        var order: [String] = []
        var buckets: [String: [NoteIndex.SearchHit]] = [:]
        for hit in hits {
            for key in sectionTitles(for: hit, layout: layout) {
                if buckets[key] == nil { order.append(key) }
                buckets[key, default: []].append(hit)
            }
        }
        if layout == .tag || layout == .folder {
            order.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        }
        return order.flatMap { key in
            [.header(key)] + (buckets[key] ?? []).map { noteRow($0) }
        }
    }

    private func sectionTitles(for hit: NoteIndex.SearchHit,
                               layout: ViewQuery.Layout) -> [String] {
        let date = Date(timeIntervalSince1970: hit.mtime)
        let formatter = DateFormatter()
        switch layout {
        case .year:
            formatter.dateFormat = "yyyy"
            return [formatter.string(from: date)]
        case .month:
            return [DateSectionTitle.month(for: date)]
        case .week:
            let calendar = Calendar.current
            guard let week = calendar.dateInterval(of: .weekOfYear, for: date) else {
                return [DateSectionTitle.month(for: date)]
            }
            let last = week.end.addingTimeInterval(-1)
            formatter.dateFormat = "d MMM"
            let start = formatter.string(from: week.start)
            let end = formatter.string(from: last)
            return ["\(start) – \(end)"]
        case .tag:
            return hit.tags.isEmpty ? ["No tag"] : hit.tags
        case .folder:
            let parent = (hit.relPath as NSString).deletingLastPathComponent
            return [parent.isEmpty ? session.vault.name : parent]
        }
    }

    @objc private func openClicked() {
        openRow(tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow)
    }

    private func openRow(_ row: Int) {
        guard row >= 0, row < rows.count, let relPath = rows[row].relPath else { return }
        onOpenNote?(session.url(forRelPath: relPath))
    }

    private func isNoteRow(_ row: Int) -> Bool {
        row >= 0 && row < rows.count && rows[row].relPath != nil
    }

    private var firstNoteRow: Int? { rows.indices.first(where: isNoteRow) }
    private var lastNoteRow: Int? { rows.indices.last(where: isNoteRow) }

    // MARK: Keyboard (vim list navigation)

    private var pendingKey: Character?
    private var listCount = 0

    /// The list cursor's pill rect in window coordinates (pane-jump smears).
    var cursorWindowRect: NSRect? {
        tableView.cursorWindowRect
    }

    /// Focus the results list, selecting the first note row if nothing is.
    func focusList() {
        _ = view
        view.window?.makeFirstResponder(tableView)
        if tableView.selectedRow < 0, let first = firstNoteRow {
            tableView.selectRowIndexes(IndexSet(integer: first), byExtendingSelection: false)
            tableView.scrollRowToVisible(first)
        }
    }

    /// Where activation should put focus: the field for empty searches, the
    /// list everywhere else.
    func focusPreferred() {
        if case .search = mode, searchField.stringValue.isEmpty {
            focusSearch()
        } else {
            focusList()
        }
    }

    private func selectRow(_ row: Int) {
        guard let first = firstNoteRow, let last = lastNoteRow else { return }
        var clamped = min(max(row, first), last)
        // Section headers are not selectable: continue in the direction of
        // travel, falling back the other way at the edges.
        if !isNoteRow(clamped) {
            let forward = row >= tableView.selectedRow
            var probe = clamped
            while probe >= first, probe <= last, !isNoteRow(probe) {
                probe += forward ? 1 : -1
            }
            clamped = isNoteRow(probe) ? probe : (forward ? last : first)
        }
        tableView.selectRowIndexes(IndexSet(integer: clamped), byExtendingSelection: false)
        tableView.scrollRowToVisible(clamped)
    }

    /// Moves the selection by `steps` note rows (headers don't count).
    private func moveSelection(by steps: Int) {
        guard steps != 0, firstNoteRow != nil else { return }
        var row = tableView.selectedRow
        var remaining = abs(steps)
        let direction = steps > 0 ? 1 : -1
        var landed = row
        while remaining > 0 {
            var probe = row + direction
            while probe >= 0, probe < rows.count, !isNoteRow(probe) {
                probe += direction
            }
            guard probe >= 0, probe < rows.count else { break }
            landed = probe
            row = probe
            remaining -= 1
        }
        selectRow(landed)
    }

    private func handleListKey(_ event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.control) {
            if event.charactersIgnoringModifiers == "h" {
                onFocusSidebar?()
                return true
            }
            return false
        }
        if event.keyCode == 53 { // esc: cancel pending chord/count, stay in the list
            pendingKey = nil
            listCount = 0
            return true
        }
        if event.keyCode == 36 || event.keyCode == 76 { // return
            listCount = 0
            openRow(tableView.selectedRow)
            return true
        }
        guard let ch = event.charactersIgnoringModifiers?.first else { return false }

        // Count multiplier (5j, 3k, NG).
        if let digit = ch.wholeNumberValue, ch.isNumber, !(digit == 0 && listCount == 0) {
            pendingKey = nil
            listCount = listCount * 10 + digit
            return true
        }
        let hadCount = listCount > 0
        let count = max(listCount, 1)
        listCount = 0

        if let pending = pendingKey {
            pendingKey = nil
            switch (pending, ch) {
            case ("g", "g"):
                selectRow(hadCount ? count - 1 : 0)
                return true
            case ("d", "d"):
                confirmTrashSelected()
                return true
            default:
                break
            }
        }

        switch ch {
        case "j": moveSelection(by: count)
        case "k": moveSelection(by: -count)
        case "G": selectRow(hadCount ? count - 1 : rows.count - 1)
        case "g", "d": pendingKey = ch
        case "l": openRow(tableView.selectedRow)
        case "/":
            switch mode {
            case .search, .view: focusSearch()
            case .tag: return false
            }
        default:
            return false
        }
        return true
    }

    private func confirmTrashSelected() {
        let row = tableView.selectedRow
        guard row >= 0, row < rows.count, let window = view.window,
              case .note(let title, _, let relPath) = rows[row] else { return }
        let alert = NSAlert()
        alert.messageText = "Move “\(title)” to Trash?"
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else {
                self?.focusList()
                return
            }
            self.session.trashNote(self.session.url(forRelPath: relPath))
            self.reload()
            self.selectRow(min(row, self.rows.count - 1))
            self.focusList()
        }
    }
}

// MARK: - Search field keys

extension SearchViewController: NSSearchFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertNewline(_:)):
            focusList()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            focusList() // esc leaves the field but stays in this view
            return true
        default:
            return false
        }
    }
}

extension SearchViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SoftRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let title):
            return SectionHeaderCellView.make(in: tableView, title: title)
        case .note(let title, let detail, _):
            return SearchHitCellView.make(in: tableView, title: title, detail: detail)
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        isNoteRow(row)
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = rows[row] { return 44 }
        return 46
    }
}

