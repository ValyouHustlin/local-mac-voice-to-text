import AppKit
import SwiftUI
import WordhandCore

@MainActor
final class SettingsController: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var settings: AppSettings
    @Published private(set) var saveError: String?
    @Published private(set) var capturingIndex: Int?

    var onSettingsChange: ((AppSettings) -> Void)?
    var onShortcutCaptureChange: ((Bool) -> Void)?

    private let store: SettingsStore
    private var windowController: NSWindowController?
    private var localKeyMonitor: Any?

    init(store: SettingsStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
        super.init()
    }

    deinit {
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
        }
    }

    func showSettings() {
        let controller = ensureWindowController()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func setAction(_ action: HotkeyBinding.Action, at index: Int) {
        update { $0.hotkeys[index].action = action }
    }

    func addShortcut() {
        guard settings.hotkeys.count < 4 else { return }
        let candidates = [
            HotkeyBinding(
                key: "d",
                keyCode: 2,
                modifiers: ["control", "option"],
                action: .toggleRecording
            ),
            HotkeyBinding(
                key: "space",
                keyCode: 49,
                modifiers: ["command", "shift"],
                action: .toggleRecording
            ),
            HotkeyBinding(
                key: "d",
                keyCode: 2,
                modifiers: ["control", "shift"],
                action: .toggleRecording
            ),
            HotkeyBinding(
                key: "d",
                keyCode: 2,
                modifiers: ["command", "option"],
                action: .toggleRecording
            ),
        ]
        guard let candidate = candidates.first(where: { candidate in
            !settings.hotkeys.contains(where: {
                $0.keyCode == candidate.keyCode
                    && $0.resolvedModifiers == candidate.resolvedModifiers
            })
        }) else { return }
        update { $0.hotkeys.append(candidate) }
    }

    func removeShortcut(at index: Int) {
        guard settings.hotkeys.count > 1 else { return }
        update { $0.hotkeys.remove(at: index) }
    }

    func setShowOverlay(_ enabled: Bool) {
        update { $0.showOverlay = enabled }
    }

    func setSoundEffectsEnabled(_ enabled: Bool) {
        update { $0.soundEffectsEnabled = enabled }
    }

    func setFormattingProfile(_ profile: TranscriptFormattingProfile) {
        update { $0.formattingProfile = profile }
    }

    func setModelID(_ modelID: String) {
        update { $0.modelID = modelID }
    }

    func setInsertionMode(_ insertionMode: InsertionMode) {
        update { $0.insertionMode = insertionMode }
    }

    func beginShortcutCapture(at index: Int) {
        cancelShortcutCapture()
        capturingIndex = index
        saveError = nil
        onShortcutCaptureChange?(true)
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let self else { return event }
            return self.capture(event, at: index) ? nil : event
        }
    }

    func cancelShortcutCapture() {
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
        guard capturingIndex != nil else { return }
        capturingIndex = nil
        // The global CGEvent callback for the captured key is dispatched onto
        // the main queue. Stay suspended through that callback so saving a new
        // shortcut cannot also start a recording.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.capturingIndex == nil else { return }
            self.onShortcutCaptureChange?(false)
        }
    }

    func conflictMessage(for binding: HotkeyBinding) -> String? {
        ShortcutConflictDetector.message(for: binding)
    }

    private func capture(_ event: NSEvent, at index: Int) -> Bool {
        if event.keyCode == 53 {
            cancelShortcutCapture()
            return true
        }

        let modifiers = Self.modifiers(from: event.modifierFlags)
        guard !modifiers.isEmpty else {
            saveError = "Include Control, Option, Shift, Command, or fn in the shortcut."
            NSSound.beep()
            return true
        }
        guard !Self.modifierOnlyKeyCodes.contains(event.keyCode) else {
            return true
        }

        let key = Self.keyName(for: event)
        guard !key.isEmpty else {
            saveError = "That key cannot be used as a global shortcut."
            NSSound.beep()
            return true
        }

        let action = settings.hotkeys[index].action
        let replacement = HotkeyBinding(
            key: key,
            keyCode: event.keyCode,
            modifiers: modifiers.map(\.rawValue).sorted(),
            action: action
        )
        cancelShortcutCapture()
        update { $0.hotkeys[index] = replacement }
        return true
    }

    private func update(_ mutation: (inout AppSettings) -> Void) {
        var candidate = settings
        mutation(&candidate)
        do {
            try store.save(candidate)
            settings = candidate
            saveError = nil
            onSettingsChange?(candidate)
        } catch SettingsError.duplicateHotkey {
            saveError = "That shortcut is already assigned."
            NSSound.beep()
        } catch SettingsError.invalidHotkey {
            saveError = "Every shortcut needs at least one modifier key."
            NSSound.beep()
        } catch {
            saveError = "Couldn’t save settings: \(error.localizedDescription)"
            NSSound.beep()
        }
    }

    private func ensureWindowController() -> NSWindowController {
        if let windowController { return windowController }

        let view = SettingsView(controller: self)
        let hostingController = NSHostingController(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 440),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.subtitle = "Wordhand"
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        let created = NSWindowController(window: window)
        windowController = created
        return created
    }

    func windowWillClose(_ notification: Notification) {
        cancelShortcutCapture()
    }

    func windowDidResignKey(_ notification: Notification) {
        cancelShortcutCapture()
    }

    private static let modifierOnlyKeyCodes: Set<UInt16> = [
        54, 55, 56, 57, 58, 59, 60, 61, 62, 63,
    ]

    private static func modifiers(from flags: NSEvent.ModifierFlags) -> Set<HotkeyModifier> {
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        var result = Set<HotkeyModifier>()
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.function) { result.insert(.function) }
        return result
    }

    private static func keyName(for event: NSEvent) -> String {
        let special: [UInt16: String] = [
            36: "return", 48: "tab", 49: "space", 51: "delete", 53: "escape",
            115: "home", 116: "page up", 117: "forward delete", 119: "end",
            121: "page down", 123: "left", 124: "right", 125: "down", 126: "up",
        ]
        if let name = special[event.keyCode] { return name }
        return event.charactersIgnoringModifiers?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
    }
}

private struct SettingsView: View {
    @ObservedObject var controller: SettingsController

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    modelCard
                    insertionCard
                    formattingCard
                    shortcutsCard
                    recordingCard
                    privacyNote
                }
                .padding(32)
            }
        }
        .frame(width: 680, height: 440)
    }

    private var insertionCard: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Insert transcript")
                            .font(.headline)
                        Text(insertionDescription)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker(
                        "Insertion mode",
                        selection: Binding(
                            get: { controller.settings.insertionMode },
                            set: { controller.setInsertionMode($0) }
                        )
                    ) {
                        Text("Paste · Recommended").tag(InsertionMode.paste)
                        Text("Direct typing").tag(InsertionMode.unicode)
                        Text("Copy only").tag(InsertionMode.copyOnly)
                    }
                    .labelsHidden()
                    .frame(width: 205)
                }
            }
        }
    }

    private var insertionDescription: String {
        switch controller.settings.insertionMode {
        case .paste:
            return "Works reliably in native, browser, Electron, and Java apps. Your clipboard is restored."
        case .unicode:
            return "Types without touching the clipboard, but some browser and Electron fields reject it."
        case .copyOnly:
            return "Leaves each transcript on the clipboard without inserting it."
        }
    }

    private var modelCard: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Transcription model")
                            .font(.headline)
                        Text("Large v3 is the accuracy-first choice for this Mac.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker(
                        "Model",
                        selection: Binding(
                            get: { controller.settings.modelID },
                            set: { controller.setModelID($0) }
                        )
                    ) {
                        ForEach(ModelRegistry.shared, id: \.id) { model in
                            Text("\(model.displayName) · \(model.sizeMB) MB")
                                .tag(model.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 285)
                }

                Label(
                    "Model changes take effect the next time Wordhand launches.",
                    systemImage: "arrow.clockwise"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var formattingCard: some View {
        settingsCard {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Writing style")
                        .font(.headline)
                    Text(formattingDescription)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 20)
                Picker(
                    "Writing style",
                    selection: Binding(
                        get: { controller.settings.formattingProfile },
                        set: { controller.setFormattingProfile($0) }
                    )
                ) {
                    Text("Automatic · Recommended")
                        .tag(TranscriptFormattingProfile.automatic)
                    Text("Polished")
                        .tag(TranscriptFormattingProfile.polished)
                    Text("AI prompt")
                        .tag(TranscriptFormattingProfile.aiPrompt)
                    Text("Verbatim")
                        .tag(TranscriptFormattingProfile.verbatim)
                }
                .labelsHidden()
                .frame(width: 220)
            }
        }
    }

    private var formattingDescription: String {
        switch controller.settings.formattingProfile {
        case .automatic:
            return "Structures prompts in AI and coding apps; keeps everyday dictation naturally polished."
        case .polished:
            return "Cleans fillers, capitalization, punctuation, and sentence boundaries."
        case .aiPrompt:
            return "Uses Apple’s on-device model to turn spoken thoughts into scannable AI instructions."
        case .verbatim:
            return "Keeps your wording and structure exactly as transcribed."
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.15, green: 0.17, blue: 0.20), .black],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                HStack(spacing: 4) {
                    Text("W")
                        .font(.system(size: 22, weight: .medium, design: .rounded))
                        .foregroundStyle(.white)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color(red: 0.43, green: 0.88, blue: 0.75))
                        .frame(width: 2, height: 19)
                }
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 3) {
                Text("Wordhand")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                Text("Private dictation, tuned to you")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("ON DEVICE")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(1.1)
                .foregroundStyle(Color(red: 0.12, green: 0.49, blue: 0.39))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(Color(red: 0.43, green: 0.88, blue: 0.75).opacity(0.16))
                )
        }
    }

    private var shortcutsCard: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Dictation shortcuts")
                        .font(.headline)
                    Text("Use a shortcut while you’re in any app.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                ForEach(controller.settings.hotkeys.indices, id: \.self) { index in
                    if index > 0 {
                        Divider()
                    }
                    shortcutRow(index)
                }

                if let error = controller.saveError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Button {
                    controller.addShortcut()
                } label: {
                    Label("Add secondary shortcut", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .disabled(controller.settings.hotkeys.count >= 4)
            }
        }
    }

    private func shortcutRow(_ index: Int) -> some View {
        let binding = controller.settings.hotkeys[index]
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 14) {
                Button {
                    controller.beginShortcutCapture(at: index)
                } label: {
                    HStack(spacing: 8) {
                        Image(
                            systemName: controller.capturingIndex == index
                                ? "keyboard.badge.ellipsis" : "keyboard"
                        )
                        Text(
                            controller.capturingIndex == index
                                ? "Press shortcut…" : binding.displayName
                        )
                        .font(.system(.body, design: .rounded, weight: .semibold))
                    }
                    .frame(minWidth: 150)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Picker(
                    "Behavior",
                    selection: Binding(
                        get: { binding.action },
                        set: { controller.setAction($0, at: index) }
                    )
                ) {
                    Text("Hold to talk")
                        .tag(HotkeyBinding.Action.pushToTalk)
                    Text("Tap to start, tap to stop")
                        .tag(HotkeyBinding.Action.toggleRecording)
                }
                .labelsHidden()
                .frame(maxWidth: 245)

                Spacer()

                Button {
                    controller.removeShortcut(at: index)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Remove shortcut")
                .disabled(controller.settings.hotkeys.count == 1)
            }

            if let conflict = controller.conflictMessage(for: binding) {
                Label(conflict, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var recordingCard: some View {
        settingsCard {
            VStack(spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Recording indicator")
                            .font(.headline)
                        Text("Show the live waveform and cancel control.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { controller.settings.showOverlay },
                            set: { controller.setShowOverlay($0) }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                }

                Divider()

                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Sound cues")
                            .font(.headline)
                        Text("Play quiet start, finish, and cancel tones.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { controller.settings.soundEffectsEnabled },
                            set: { controller.setSoundEffectsEnabled($0) }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
            }
        }
    }

    private var privacyNote: some View {
        Label {
            Text("Audio and transcripts never leave this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } icon: {
            Image(systemName: "lock.shield")
                .foregroundStyle(Color(red: 0.12, green: 0.49, blue: 0.39))
        }
        .padding(.horizontal, 4)
    }

    private func settingsCard<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.05), radius: 12, y: 4)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.primary.opacity(0.07))
            )
    }
}

private enum ShortcutConflictDetector {
    static func message(for binding: HotkeyBinding) -> String? {
        guard
            binding.keyCode == 49,
            binding.resolvedModifiers == [.control],
            let domain = UserDefaults.standard.persistentDomain(
                forName: "com.apple.symbolichotkeys"
            ),
            let shortcuts = domain["AppleSymbolicHotKeys"] as? [String: Any],
            let inputSource = shortcuts["60"] as? [String: Any],
            inputSource["enabled"] as? Bool == true
        else {
            return nil
        }
        return "Control-Space is also assigned to macOS Input Sources."
    }
}
