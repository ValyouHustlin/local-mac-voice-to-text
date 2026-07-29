import AppKit
import Foundation
import WordhandCore

@MainActor
final class DictionaryController {
    let processor: MutableTranscriptProcessor
    let vocabulary: DictionaryVocabularySource
    private let store: DictionaryStore
    private(set) var entries: [DictionaryEntry]
    private(set) var latestTranscript: String?
    private var windowController: DictionaryWindowController?

    init(store: DictionaryStore = DictionaryStore(fileURL: DictionaryStore.defaultFileURL())) {
        self.store = store
        let loadedEntries: [DictionaryEntry]
        do {
            loadedEntries = try store.installBundledDefaults().entries
        } catch {
            loadedEntries = (try? store.load().entries) ?? []
            FileHandle.standardError.write(Data(
                "dictionary defaults/load failed: \(error)\n".utf8
            ))
        }
        entries = loadedEntries
        processor = MutableTranscriptProcessor(dictionaryEntries: entries)
        vocabulary = DictionaryVocabularySource(entries: entries)
    }

    func rememberLatestTranscript(_ text: String) {
        latestTranscript = text
    }

    func showDictionary() {
        let controller = ensureWindowController()
        controller.reload()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func correctLatestTranscript() {
        guard let latestTranscript else {
            NSSound.beep()
            return
        }
        showEditor(prefill: latestTranscript)
    }

    func showEditor(for entry: DictionaryEntry? = nil, prefill: String? = nil) {
        let spokenField = NSTextField(string: entry?.spokenForm ?? prefill ?? "")
        let replacementField = NSTextField(string: entry?.replacement ?? "")
        let modePicker = NSPopUpButton()
        modePicker.addItems(withTitles: ["Phrase", "Whole word"])
        modePicker.selectItem(at: entry?.matchMode == .word ? 1 : 0)
        let caseCheckbox = NSButton(
            checkboxWithTitle: "Match capitalization exactly",
            target: nil,
            action: nil
        )
        caseCheckbox.state = entry?.isCaseSensitive == true ? .on : .off

        let form = NSGridView(views: [
            [NSTextField(labelWithString: "Heard as"), spokenField],
            [NSTextField(labelWithString: "Replace with"), replacementField],
            [NSTextField(labelWithString: "Match"), modePicker],
            [NSView(), caseCheckbox],
        ])
        form.rowSpacing = 10
        form.columnSpacing = 12
        form.column(at: 0).xPlacement = .trailing
        form.column(at: 1).width = 300
        form.frame = NSRect(x: 0, y: 0, width: 400, height: 126)

        let alert = NSAlert()
        alert.messageText = entry == nil ? "Add Dictionary Correction" : "Edit Dictionary Correction"
        alert.informativeText = """
        The canonical spelling teaches the local recognizer before decoding. \
        The correction also runs afterward as a fallback.
        """
        alert.accessoryView = form
        alert.addButton(withTitle: entry == nil ? "Add" : "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = spokenField

        while true {
            guard alert.runModal() == .alertFirstButtonReturn else { return }

            let spoken = spokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let replacement = replacementField.stringValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !spoken.isEmpty, !replacement.isEmpty else {
                presentError("Both “Heard as” and “Replace with” are required.")
                continue
            }

            let selectedMode: DictionaryEntry.MatchMode =
                modePicker.indexOfSelectedItem == 1 ? .word : .phrase
            if selectedMode == .phrase {
                let preview = NSAlert()
                preview.messageText = "Preview Phrase Replacement"
                preview.informativeText = """
                Any occurrence of:
                “\(spoken)”

                becomes:
                “\(replacement)”
                """
                preview.addButton(withTitle: entry == nil ? "Add Correction" : "Save Correction")
                preview.addButton(withTitle: "Go Back")
                guard preview.runModal() == .alertFirstButtonReturn else { continue }
            }

            var updated = entry ?? DictionaryEntry(spokenForm: spoken, replacement: replacement)
            updated.spokenForm = spoken
            updated.replacement = replacement
            updated.matchMode = selectedMode
            updated.isCaseSensitive = caseCheckbox.state == .on
            if entry != nil {
                updated.origin = nil
                updated.starterVocabularyOrder = nil
            }
            updated.updatedAt = Date()

            do {
                let document = try store.upsert(updated)
                apply(document.entries)
                return
            } catch {
                presentError("Couldn’t save the correction: \(error)")
            }
        }
    }

    func delete(_ entry: DictionaryEntry) {
        let alert = NSAlert()
        alert.messageText = "Delete this correction?"
        alert.informativeText = "“\(entry.spokenForm)” will no longer become “\(entry.replacement)”."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            let document = try store.delete(id: entry.id)
            apply(document.entries)
        } catch {
            presentError("Couldn’t delete the correction: \(error)")
        }
    }

    private func apply(_ newEntries: [DictionaryEntry]) {
        entries = newEntries.sorted {
            $0.spokenForm.localizedCaseInsensitiveCompare($1.spokenForm) == .orderedAscending
        }
        processor.update(dictionaryEntries: entries)
        vocabulary.update(entries: entries)
        windowController?.reload()
    }

    private func ensureWindowController() -> DictionaryWindowController {
        if let windowController { return windowController }
        let created = DictionaryWindowController(dictionary: self)
        windowController = created
        return created
    }

    private func presentError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Custom Dictionary"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}

@MainActor
private final class DictionaryWindowController: NSWindowController, NSTableViewDataSource,
    NSTableViewDelegate
{
    private unowned let dictionary: DictionaryController
    private let tableView = NSTableView()
    private let countLabel = NSTextField(labelWithString: "")

    init(dictionary: DictionaryController) {
        self.dictionary = dictionary

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 440),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Custom Dictionary"
        window.minSize = NSSize(width: 520, height: 320)
        window.center()
        super.init(window: window)
        buildContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func reload() {
        tableView.reloadData()
        let count = dictionary.entries.count
        countLabel.stringValue = count == 1 ? "1 correction" : "\(count) corrections"
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        dictionary.entries.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < dictionary.entries.count, let identifier = tableColumn?.identifier else {
            return nil
        }
        let entry = dictionary.entries[row]
        let value = identifier.rawValue == "heard" ? entry.spokenForm : entry.replacement
        let field = NSTextField(labelWithString: value)
        field.lineBreakMode = .byTruncatingTail
        field.toolTip = value
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        // Selection is read when edit/delete is invoked.
    }

    private func buildContent() {
        guard let content = window?.contentView else { return }

        let heard = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("heard"))
        heard.title = "Heard as"
        heard.minWidth = 180
        let replacement = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("replacement"))
        replacement.title = "Replace with"
        replacement.minWidth = 180
        tableView.addTableColumn(heard)
        tableView.addTableColumn(replacement)
        tableView.delegate = self
        tableView.dataSource = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.doubleAction = #selector(editClicked)
        tableView.target = self

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let add = NSButton(title: "Add…", target: self, action: #selector(addClicked))
        let edit = NSButton(title: "Edit…", target: self, action: #selector(editClicked))
        let delete = NSButton(title: "Delete", target: self, action: #selector(deleteClicked))
        let buttons = NSStackView(views: [add, edit, delete, NSView(), countLabel])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let heading = NSTextField(wrappingLabelWithString:
            "Teach Wordhand the names, acronyms, and technical terms it mishears."
        )
        heading.font = .systemFont(ofSize: 13)
        heading.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [heading, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        buttons.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        reload()
    }

    private var selectedEntry: DictionaryEntry? {
        let row = tableView.selectedRow
        guard row >= 0, row < dictionary.entries.count else { return nil }
        return dictionary.entries[row]
    }

    @objc private func addClicked() {
        dictionary.showEditor()
    }

    @objc private func editClicked() {
        guard let selectedEntry else {
            NSSound.beep()
            return
        }
        dictionary.showEditor(for: selectedEntry)
    }

    @objc private func deleteClicked() {
        guard let selectedEntry else {
            NSSound.beep()
            return
        }
        dictionary.delete(selectedEntry)
    }
}
