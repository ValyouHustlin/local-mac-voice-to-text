import AppKit
import WordhandCore

@MainActor
final class HistoryController {
    private let store: TranscriptHistoryStore
    private unowned let dictionary: DictionaryController
    private let inserter: TextInserting
    private var windowController: HistoryWindowController?
    private var previousApplication: NSRunningApplication?

    init(
        store: TranscriptHistoryStore,
        dictionary: DictionaryController,
        inserter: TextInserting
    ) {
        self.store = store
        self.dictionary = dictionary
        self.inserter = inserter
    }

    func showHistory() {
        rememberPreviousApplication()
        let controller = ensureWindowController()
        controller.reload()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func reloadIfVisible() {
        guard windowController?.window?.isVisible == true else { return }
        windowController?.reload()
    }

    func records(matching query: String) throws -> [TranscriptRecord] {
        try store.records(matching: query)
    }

    @discardableResult
    func copy(_ record: TranscriptRecord) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(record.text, forType: .string)
    }

    func reinsert(_ record: TranscriptRecord) {
        guard let target = previousApplication, !target.isTerminated else {
            presentError(
                title: "Choose a target first",
                message: "Open History from the app where you want this transcript inserted."
            )
            return
        }

        windowController?.window?.orderOut(nil)
        target.activate(options: [.activateAllWindows])

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard let self else { return }
            do {
                try await inserter.insert(record.text, mode: .paste)
            } catch {
                showHistory()
                presentError(
                    title: "Couldn’t reinsert",
                    message: "The transcript is still safe in History. \(error)"
                )
            }
        }
    }

    func createCorrection(from record: TranscriptRecord) {
        dictionary.showEditor(prefill: record.text)
    }

    func delete(_ record: TranscriptRecord) {
        let alert = NSAlert()
        alert.messageText = "Delete this transcript?"
        alert.informativeText = "This removes it from local history and cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try store.delete(id: record.id)
            windowController?.reload()
        } catch {
            presentError(title: "Couldn’t delete transcript", message: String(describing: error))
        }
    }

    func clearAll() {
        let count = (try? store.records(limit: 5_000).count) ?? 0
        guard count > 0 else { return }

        let alert = NSAlert()
        alert.messageText = "Clear all transcript history?"
        alert.informativeText = """
        This permanently removes \(count) local \(count == 1 ? "transcript" : "transcripts").
        Your custom dictionary is not affected.
        """
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try store.clear()
            windowController?.reload()
        } catch {
            presentError(title: "Couldn’t clear history", message: String(describing: error))
        }
    }

    private func rememberPreviousApplication() {
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else {
            return
        }
        previousApplication = frontmost
    }

    private func ensureWindowController() -> HistoryWindowController {
        if let windowController { return windowController }
        let created = HistoryWindowController(history: self)
        windowController = created
        return created
    }

    private func presentError(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}

@MainActor
func currentTranscriptTarget() -> TranscriptTarget {
    guard let application = NSWorkspace.shared.frontmostApplication,
          application.processIdentifier != ProcessInfo.processInfo.processIdentifier
    else {
        return .unknown
    }
    return TranscriptTarget(
        bundleIdentifier: application.bundleIdentifier,
        applicationName: application.localizedName
    )
}

@MainActor
private final class HistoryWindowController: NSWindowController, NSTableViewDataSource,
    NSTableViewDelegate
{
    private unowned let history: HistoryController
    private var records: [TranscriptRecord] = []

    private let searchField = NSSearchField()
    private let countLabel = NSTextField(labelWithString: "")
    private let tableView = NSTableView()
    private let clearButton = NSButton()

    private let emptyView = NSView()
    private let emptyIcon = NSImageView()
    private let emptyTitle = NSTextField(labelWithString: "")
    private let emptyMessage = NSTextField(wrappingLabelWithString: "")

    private let detailView = NSView()
    private let statusImage = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let dateLabel = NSTextField(labelWithString: "")
    private let transcriptTextView = NSTextView()
    private let metadataLabel = NSTextField(wrappingLabelWithString: "")
    private let failureLabel = NSTextField(wrappingLabelWithString: "")
    private let copyButton = NSButton()
    private let reinsertButton = NSButton()
    private let correctionButton = NSButton()
    private let deleteButton = NSButton()

    init(history: HistoryController) {
        self.history = history
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Transcript History"
        window.subtitle = "Wordhand"
        window.minSize = NSSize(width: 760, height: 500)
        window.center()
        super.init(window: window)
        buildContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func reload() {
        let selectedID = selectedRecord?.id
        do {
            records = try history.records(matching: searchField.stringValue)
            updateCount()
            tableView.reloadData()

            if let selectedID,
               let index = records.firstIndex(where: { $0.id == selectedID })
            {
                tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            } else if !records.isEmpty {
                tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            }
            updateDetail()
        } catch {
            records = []
            tableView.reloadData()
            countLabel.stringValue = "History unavailable"
            showEmptyState(
                symbol: "exclamationmark.triangle",
                title: "History couldn’t be loaded",
                message: String(describing: error)
            )
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        records.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard row < records.count else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("HistoryRow")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? HistoryRowView)
            ?? HistoryRowView(identifier: identifier)
        cell.configure(with: records[row])
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        78
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateDetail()
    }

    private func buildContent() {
        guard let content = window?.contentView else { return }

        let splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = false

        let sidebar = buildSidebar()
        let detail = buildDetailPane()
        splitView.addArrangedSubview(sidebar)
        splitView.addArrangedSubview(detail)
        sidebar.widthAnchor.constraint(equalToConstant: 324).isActive = true

        content.addSubview(splitView)
        NSLayoutConstraint.activate([
            splitView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            splitView.topAnchor.constraint(equalTo: content.topAnchor),
            splitView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    private func buildSidebar() -> NSView {
        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        sidebar.state = .active

        let title = NSTextField(labelWithString: "History")
        title.font = .systemFont(ofSize: 24, weight: .bold)

        countLabel.font = .systemFont(ofSize: 12, weight: .medium)
        countLabel.textColor = .secondaryLabelColor

        searchField.placeholderString = "Search transcripts"
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.setAccessibilityLabel("Search transcript history")

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("transcript"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.delegate = self
        tableView.dataSource = self
        tableView.allowsMultipleSelection = false
        tableView.style = .sourceList
        tableView.backgroundColor = .clear
        tableView.intercellSpacing = NSSize(width: 0, height: 4)
        tableView.focusRingType = .none

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        clearButton.title = "Clear All…"
        clearButton.bezelStyle = .inline
        clearButton.font = .systemFont(ofSize: 11, weight: .medium)
        clearButton.contentTintColor = .secondaryLabelColor
        clearButton.target = self
        clearButton.action = #selector(clearClicked)

        let header = NSStackView(views: [title, countLabel, searchField])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 4
        searchField.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true

        let footerSpacer = NSView()
        let footer = NSStackView(views: [footerSpacer, clearButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY

        let stack = NSStackView(views: [header, scroll, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        footer.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -12),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        return sidebar
    }

    private func buildDetailPane() -> NSView {
        let pane = NSView()
        pane.wantsLayer = true
        pane.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        buildEmptyView()
        buildPopulatedDetailView()
        for child in [emptyView, detailView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            pane.addSubview(child)
            NSLayoutConstraint.activate([
                child.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
                child.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
                child.topAnchor.constraint(equalTo: pane.topAnchor),
                child.bottomAnchor.constraint(equalTo: pane.bottomAnchor),
            ])
        }
        return pane
    }

    private func buildEmptyView() {
        emptyIcon.imageScaling = .scaleProportionallyDown
        emptyIcon.contentTintColor = .tertiaryLabelColor
        emptyIcon.widthAnchor.constraint(equalToConstant: 48).isActive = true
        emptyIcon.heightAnchor.constraint(equalToConstant: 48).isActive = true

        emptyTitle.font = .systemFont(ofSize: 19, weight: .semibold)
        emptyTitle.alignment = .center
        emptyMessage.font = .systemFont(ofSize: 13)
        emptyMessage.textColor = .secondaryLabelColor
        emptyMessage.alignment = .center
        emptyMessage.maximumNumberOfLines = 3

        let stack = NSStackView(views: [emptyIcon, emptyTitle, emptyMessage])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        emptyView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: emptyView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: emptyView.centerYAnchor, constant: -12),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 340),
        ])
    }

    private func buildPopulatedDetailView() {
        statusImage.imageScaling = .scaleProportionallyDown
        statusImage.widthAnchor.constraint(equalToConstant: 14).isActive = true
        statusImage.heightAnchor.constraint(equalToConstant: 14).isActive = true
        statusLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        dateLabel.font = .systemFont(ofSize: 12, weight: .medium)
        dateLabel.textColor = .secondaryLabelColor
        dateLabel.alignment = .right

        let headerSpacer = NSView()
        let header = NSStackView(views: [statusImage, statusLabel, headerSpacer, dateLabel])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6

        transcriptTextView.isEditable = false
        transcriptTextView.isSelectable = true
        transcriptTextView.isRichText = false
        transcriptTextView.drawsBackground = false
        transcriptTextView.font = .systemFont(ofSize: 17)
        transcriptTextView.textContainerInset = NSSize(width: 18, height: 16)
        transcriptTextView.textContainer?.lineFragmentPadding = 0
        transcriptTextView.setAccessibilityLabel("Selected transcript")

        let textScroll = NSScrollView()
        textScroll.documentView = transcriptTextView
        textScroll.hasVerticalScroller = true
        textScroll.borderType = .noBorder
        textScroll.drawsBackground = true
        textScroll.backgroundColor = .textBackgroundColor
        textScroll.wantsLayer = true
        textScroll.layer?.cornerRadius = 12
        textScroll.layer?.cornerCurve = .continuous

        metadataLabel.font = .systemFont(ofSize: 12)
        metadataLabel.textColor = .secondaryLabelColor
        failureLabel.font = .systemFont(ofSize: 12, weight: .medium)
        failureLabel.textColor = .systemOrange
        failureLabel.maximumNumberOfLines = 2

        configureActionButton(
            reinsertButton,
            title: "Reinsert",
            symbol: "arrow.turn.down.left",
            action: #selector(reinsertClicked),
            primary: true
        )
        reinsertButton.keyEquivalent = "\r"
        configureActionButton(
            copyButton,
            title: "Copy",
            symbol: "doc.on.doc",
            action: #selector(copyClicked)
        )
        configureActionButton(
            correctionButton,
            title: "Correct…",
            symbol: "text.badge.plus",
            action: #selector(correctionClicked)
        )
        configureActionButton(
            deleteButton,
            title: "Delete",
            symbol: "trash",
            action: #selector(deleteClicked)
        )
        deleteButton.contentTintColor = .systemRed

        let buttonSpacer = NSView()
        let actions = NSStackView(
            views: [reinsertButton, copyButton, correctionButton, buttonSpacer, deleteButton]
        )
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 8

        let stack = NSStackView(
            views: [header, textScroll, metadataLabel, failureLabel, actions]
        )
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.setCustomSpacing(8, after: metadataLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        textScroll.translatesAutoresizingMaskIntoConstraints = false
        header.translatesAutoresizingMaskIntoConstraints = false
        actions.translatesAutoresizingMaskIntoConstraints = false
        detailView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: detailView.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: detailView.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: detailView.topAnchor, constant: 26),
            stack.bottomAnchor.constraint(equalTo: detailView.bottomAnchor, constant: -24),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            textScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            textScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 250),
            metadataLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            failureLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    private func configureActionButton(
        _ button: NSButton,
        title: String,
        symbol: String,
        action: Selector,
        primary: Bool = false
    ) {
        button.title = title
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.target = self
        button.action = action
        if primary {
            button.keyEquivalentModifierMask = []
            button.bezelColor = .controlAccentColor
        }
    }

    private func updateCount() {
        let count = records.count
        if searchField.stringValue.isEmpty {
            countLabel.stringValue = count == 1 ? "1 transcript" : "\(count) transcripts"
        } else {
            countLabel.stringValue = count == 1 ? "1 match" : "\(count) matches"
        }
        clearButton.isEnabled = !records.isEmpty || !searchField.stringValue.isEmpty
    }

    private func updateDetail() {
        guard let record = selectedRecord else {
            let hasQuery = !searchField.stringValue
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            showEmptyState(
                symbol: hasQuery ? "magnifyingglass" : "text.bubble",
                title: hasQuery ? "No matches" : "No transcripts yet",
                message: hasQuery
                    ? "Try a different word, phrase, or application name."
                    : "Your local dictation history will appear here automatically."
            )
            return
        }

        emptyView.isHidden = true
        detailView.isHidden = false
        transcriptTextView.string = record.text
        dateLabel.stringValue = record.createdAt.formatted(date: .complete, time: .shortened)

        let status = statusPresentation(for: record.status)
        statusImage.image = NSImage(
            systemSymbolName: status.symbol,
            accessibilityDescription: status.title
        )
        statusImage.contentTintColor = status.color
        statusLabel.stringValue = status.title
        statusLabel.textColor = status.color

        var metadata: [String] = []
        if let app = record.target.applicationName, !app.isEmpty {
            metadata.append(app)
        }
        metadata.append(record.modelID)
        if let language = record.language, !language.isEmpty {
            metadata.append(language.uppercased())
        }
        metadata.append(String(format: "%.1fs audio", record.audioDuration))
        metadata.append(String(format: "%.2fs transcription", record.transcriptionDuration))
        metadataLabel.stringValue = metadata.joined(separator: "  ·  ")

        if case .insertionFailed(let reason) = record.status {
            failureLabel.stringValue = "Saved safely. Insertion failed: \(reason)"
            failureLabel.isHidden = false
        } else {
            failureLabel.stringValue = ""
            failureLabel.isHidden = true
        }
    }

    private func showEmptyState(symbol: String, title: String, message: String) {
        detailView.isHidden = true
        emptyView.isHidden = false
        emptyIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        emptyIcon.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 38,
            weight: .regular
        )
        emptyTitle.stringValue = title
        emptyMessage.stringValue = message
    }

    private var selectedRecord: TranscriptRecord? {
        let row = tableView.selectedRow
        guard row >= 0, row < records.count else { return nil }
        return records[row]
    }

    private func statusPresentation(for status: TranscriptInsertionStatus)
        -> (title: String, symbol: String, color: NSColor)
    {
        switch status {
        case .pendingInsertion:
            return ("Pending", "clock.fill", .secondaryLabelColor)
        case .inserted:
            return ("Inserted", "checkmark.circle.fill", .systemGreen)
        case .insertionFailed:
            return ("Not inserted", "exclamationmark.circle.fill", .systemOrange)
        }
    }

    @objc private func copyClicked() {
        guard let selectedRecord, history.copy(selectedRecord) else {
            NSSound.beep()
            return
        }
        copyButton.title = "Copied"
        copyButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.copyButton.title = "Copy"
            self?.copyButton.image = NSImage(
                systemSymbolName: "doc.on.doc",
                accessibilityDescription: nil
            )
        }
    }

    @objc private func searchChanged() {
        reload()
    }

    @objc private func reinsertClicked() {
        guard let selectedRecord else {
            NSSound.beep()
            return
        }
        history.reinsert(selectedRecord)
    }

    @objc private func correctionClicked() {
        guard let selectedRecord else {
            NSSound.beep()
            return
        }
        history.createCorrection(from: selectedRecord)
    }

    @objc private func deleteClicked() {
        guard let selectedRecord else {
            NSSound.beep()
            return
        }
        history.delete(selectedRecord)
    }

    @objc private func clearClicked() {
        history.clearAll()
    }
}

@MainActor
private final class HistoryRowView: NSTableCellView {
    private let transcriptLabel = NSTextField(wrappingLabelWithString: "")
    private let metadataLabel = NSTextField(labelWithString: "")
    private let statusImage = NSImageView()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        transcriptLabel.font = .systemFont(ofSize: 13, weight: .medium)
        transcriptLabel.maximumNumberOfLines = 2
        transcriptLabel.lineBreakMode = .byTruncatingTail
        metadataLabel.font = .systemFont(ofSize: 11)
        metadataLabel.textColor = .secondaryLabelColor
        metadataLabel.lineBreakMode = .byTruncatingTail
        statusImage.imageScaling = .scaleProportionallyDown

        let textStack = NSStackView(views: [transcriptLabel, metadataLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 5
        textStack.translatesAutoresizingMaskIntoConstraints = false
        statusImage.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textStack)
        addSubview(statusImage)

        NSLayoutConstraint.activate([
            statusImage.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            statusImage.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusImage.widthAnchor.constraint(equalToConstant: 12),
            statusImage.heightAnchor.constraint(equalToConstant: 12),
            textStack.leadingAnchor.constraint(equalTo: statusImage.trailingAnchor, constant: 9),
            textStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with record: TranscriptRecord) {
        transcriptLabel.stringValue = record.text
        let app = record.target.applicationName ?? "Unknown app"
        metadataLabel.stringValue = "\(HistoryDateFormatter.list(record.createdAt))  ·  \(app)"

        let status: (symbol: String, color: NSColor, description: String)
        switch record.status {
        case .pendingInsertion:
            status = ("clock.fill", .secondaryLabelColor, "Pending insertion")
        case .inserted:
            status = ("checkmark.circle.fill", .systemGreen, "Inserted")
        case .insertionFailed:
            status = ("exclamationmark.circle.fill", .systemOrange, "Not inserted")
        }
        statusImage.image = NSImage(
            systemSymbolName: status.symbol,
            accessibilityDescription: status.description
        )
        statusImage.contentTintColor = status.color
        setAccessibilityLabel("\(record.text), \(status.description), \(app)")
    }
}

private enum HistoryDateFormatter {
    static func list(_ date: Date, relativeTo now: Date = Date()) -> String {
        let elapsed = now.timeIntervalSince(date)
        if elapsed >= 0, elapsed < 60 {
            return "Just now"
        }
        if elapsed >= 60, elapsed < 86_400 {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            return formatter.localizedString(for: date, relativeTo: now)
        }

        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateStyle = Calendar.current.isDate(date, equalTo: now, toGranularity: .year)
            ? .medium
            : .long
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}
