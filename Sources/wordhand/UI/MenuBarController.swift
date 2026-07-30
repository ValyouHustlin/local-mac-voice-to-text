import AppKit
import WordhandCore

/// Status bar item in the top-right of the menu bar. Shows recording state at
/// a glance and provides quick access alongside the Dock and native windows.
@MainActor
final class MenuBarController {
    private let statusItem: NSStatusItem
    private let modelLabel: NSMenuItem
    private let stateLabel: NSMenuItem
    private let correctLastItem: NSMenuItem
    private let improveLastItem: NSMenuItem
    private let undoLastItem: NSMenuItem
    private let modelID: String
    private var settings: AppSettings
    private let onOpenSettings: () -> Void
    private let onOpenHistory: () -> Void
    private let onOpenDictionary: () -> Void
    private let onCorrectLast: () -> Void
    private let onImproveLast: () -> Void
    private let onUndoLast: () -> Void

    init(
        modelID: String,
        settings: AppSettings,
        onOpenSettings: @escaping () -> Void,
        onOpenHistory: @escaping () -> Void,
        onOpenDictionary: @escaping () -> Void,
        onCorrectLast: @escaping () -> Void,
        onImproveLast: @escaping () -> Void,
        onUndoLast: @escaping () -> Void
    ) {
        self.modelID = modelID
        self.settings = settings
        self.onOpenSettings = onOpenSettings
        self.onOpenHistory = onOpenHistory
        self.onOpenDictionary = onOpenDictionary
        self.onCorrectLast = onCorrectLast
        self.onImproveLast = onImproveLast
        self.onUndoLast = onUndoLast
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.correctLastItem = NSMenuItem(
            title: "Correct Last Transcript…",
            action: #selector(correctLastClicked),
            keyEquivalent: ""
        )
        self.improveLastItem = NSMenuItem(
            title: "Improve Last Transcript Accuracy…",
            action: #selector(improveLastClicked),
            keyEquivalent: ""
        )
        self.undoLastItem = NSMenuItem(
            title: "Undo Last Insertion",
            action: #selector(undoLastClicked),
            keyEquivalent: "z"
        )
        undoLastItem.keyEquivalentModifierMask = [.command, .shift]

        let menu = NSMenu()
        menu.autoenablesItems = false

        stateLabel = NSMenuItem(
            title: Self.idleTitle(for: settings),
            action: nil,
            keyEquivalent: ""
        )
        stateLabel.isEnabled = false
        menu.addItem(stateLabel)

        modelLabel = NSMenuItem(title: "model: \(modelID)", action: nil, keyEquivalent: "")
        modelLabel.isEnabled = false
        menu.addItem(modelLabel)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(settingsClicked),
            keyEquivalent: ","
        )
        settingsItem.keyEquivalentModifierMask = [.command]
        settingsItem.target = self
        menu.addItem(settingsItem)

        let history = NSMenuItem(
            title: "Transcript History…",
            action: #selector(historyClicked),
            keyEquivalent: "h"
        )
        history.keyEquivalentModifierMask = [.command, .shift]
        history.target = self
        menu.addItem(history)

        let dictionary = NSMenuItem(
            title: "Custom Dictionary…",
            action: #selector(dictionaryClicked),
            keyEquivalent: "d"
        )
        dictionary.keyEquivalentModifierMask = [.command, .shift]
        dictionary.target = self
        menu.addItem(dictionary)

        correctLastItem.target = self
        correctLastItem.isEnabled = false
        menu.addItem(correctLastItem)
        improveLastItem.target = self
        improveLastItem.isEnabled = false
        menu.addItem(improveLastItem)
        undoLastItem.target = self
        undoLastItem.isEnabled = false
        menu.addItem(undoLastItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit Wordhand",
            action: #selector(quitClicked),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        configureButton(recording: false)
    }

    func setRecording(_ recording: Bool) {
        stateLabel.title = recording ? "● recording" : Self.idleTitle(for: settings)
    }

    func setLoadingModel(_ modelID: String) {
        stateLabel.title = "loading \(modelID)…"
    }

    func setReady() {
        stateLabel.title = Self.idleTitle(for: settings)
    }

    func setTranscribing() {
        stateLabel.title = "transcribing…"
    }

    func setHasLatestTranscript(_ available: Bool) {
        correctLastItem.isEnabled = available
        improveLastItem.isEnabled = available
    }

    func setCanUndoLastInsertion(_ available: Bool) {
        undoLastItem.isEnabled = available
    }

    func setFailure(_ message: String) {
        stateLabel.title = message
    }

    func updateSettings(_ settings: AppSettings) {
        self.settings = settings
        stateLabel.title = Self.idleTitle(for: settings)
    }

    private func configureButton(recording: Bool) {
        guard let button = statusItem.button else { return }
        let image = Self.wordhandImage()
        image?.isTemplate = true
        button.image = image
        button.toolTip = "Wordhand"
    }

    // The Wordhand W plus text cursor, simplified for a monochrome 18pt menu icon.
    private static let wordhandSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" \
    viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" \
    stroke-linecap="round" stroke-linejoin="round">\
    <path d="M2.5 5.5 6.8 18 12 9.5 17.2 18 21.5 5.5"/>\
    <path d="M22.5 8v8"/>\
    </svg>
    """

    private static func wordhandImage() -> NSImage? {
        guard let data = wordhandSVG.data(using: .utf8),
              let image = NSImage(data: data)
        else { return nil }
        image.size = NSSize(width: 18, height: 18)
        return image
    }

    private static func idleTitle(for settings: AppSettings) -> String {
        guard let binding = settings.hotkeys.first else { return "idle" }
        let instruction = binding.action == .toggleRecording ? "tap" : "hold"
        return "idle · \(instruction) \(binding.displayName) to dictate"
    }

    @objc private func quitClicked() {
        NSApp.terminate(nil)
    }

    @objc private func dictionaryClicked() {
        onOpenDictionary()
    }

    @objc private func settingsClicked() {
        onOpenSettings()
    }

    @objc private func historyClicked() {
        onOpenHistory()
    }

    @objc private func correctLastClicked() {
        onCorrectLast()
    }

    @objc private func improveLastClicked() {
        onImproveLast()
    }

    @objc private func undoLastClicked() {
        onUndoLast()
    }
}
