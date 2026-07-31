import AppKit
import SwiftUI
import WordhandCore

enum RecentActivityPhase: Equatable {
    case idle
    case loading
    case loaded
    case unavailable
}

enum ModelPreparationPhase: Equatable {
    case preparing
    case ready
    case unavailable
    case repairableCache
    case repairFailed
}

@MainActor
final class SettingsController: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var settings: AppSettings
    @Published private(set) var saveError: String?
    @Published private(set) var capturingIndex: Int?
    @Published private(set) var launchAtLoginState: LaunchAtLoginState
    @Published private(set) var launchAtLoginError: String?
    @Published private(set) var permissionStatus: WordhandPermissionStatus
    @Published private(set) var requiresRelaunch: Bool
    @Published private(set) var relaunchError: String?
    @Published private(set) var diagnosticsMessage: String?
    @Published private(set) var recentActivitySnapshot: WordhandHealthSnapshot?
    @Published private(set) var recentActivityPhase: RecentActivityPhase = .idle
    @Published private(set) var modelPreparationPhase: ModelPreparationPhase =
        .preparing
    @Published private(set) var availableApplication: TranscriptTarget?

    var onSettingsChange: ((AppSettings) -> Void)?
    var onShortcutCaptureChange: ((Bool) -> Void)?
    var onPermissionsRefresh: ((WordhandPermissionStatus) -> Void)?
    var onRelaunchRequested: (() throws -> Void)?
    var onRevealQualityAudio: (() -> Void)?
    var onDeleteQualityAudio: (() throws -> Void)?
    var onRevealDiagnostics: (() -> Void)?
    var onDiagnosticsReport: (() async throws -> String)?
    var onRecentActivitySnapshot: (() async throws -> WordhandHealthSnapshot)?
    var onRetryModelPreparation: (() -> Void)?
    var onRepairModelCache: (() -> Void)?

    private let store: SettingsStore
    private let launchAtLoginManager: any LaunchAtLoginManaging
    private let permissionManager: any PermissionManaging
    private let frameAutosaveName: String
    private let activeModelID: String
    private let currentTarget: @MainActor () -> TranscriptTarget
    private var windowController: NSWindowController?
    private var onboardingWindowController: NSWindowController?
    private var localKeyMonitor: Any?
    private var recentActivityTask: Task<Void, Never>?
    private var recentActivityGeneration = 0
    private static let defaultWindowContentSize = NSSize(width: 760, height: 620)

    init(
        store: SettingsStore,
        settings: AppSettings,
        launchAtLoginManager: any LaunchAtLoginManaging = SystemLaunchAtLoginManager(),
        permissionManager: any PermissionManaging = SystemPermissionManager(),
        frameAutosaveName: String = "Wordhand.Settings",
        activeModelID: String? = nil,
        currentTarget: @escaping @MainActor () -> TranscriptTarget =
            currentTranscriptTarget
    ) {
        self.store = store
        self.settings = settings
        self.launchAtLoginManager = launchAtLoginManager
        self.launchAtLoginState = launchAtLoginManager.state()
        self.permissionManager = permissionManager
        self.permissionStatus = permissionManager.status()
        self.frameAutosaveName = frameAutosaveName
        self.activeModelID = activeModelID ?? settings.modelID
        self.currentTarget = currentTarget
        self.requiresRelaunch = settings.modelID != (activeModelID ?? settings.modelID)
        super.init()
    }

    deinit {
        recentActivityTask?.cancel()
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
        }
    }

    func showSettings() {
        refreshAvailableApplication()
        refreshPermissions()
        refreshRecentActivity()
        let controller = ensureWindowController()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showOnboardingIfNeeded(isBundledApplication: Bool) {
        guard OnboardingPresentationPolicy.shouldPresent(
            isBundledApplication: isBundledApplication,
            completedVersion: settings.completedOnboardingVersion
        ) else {
            return
        }
        refreshPermissions()
        let controller = ensureOnboardingWindowController()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    var onboardingReadiness: OnboardingReadiness {
        OnboardingReadiness(
            accessibilityGranted: permissionStatus.accessibilityGranted,
            inputMonitoringGranted: permissionStatus.inputMonitoringGranted,
            microphoneGranted: permissionStatus.microphone == .granted,
            modelReady: modelPreparationPhase == .ready
        )
    }

    var activeModel: TranscriptionModel? {
        ModelRegistry.find(activeModelID)
    }

    func setModelPreparationPhase(_ phase: ModelPreparationPhase) {
        modelPreparationPhase = phase
    }

    func retryModelPreparation() {
        guard modelPreparationPhase == .unavailable,
              let onRetryModelPreparation
        else {
            return
        }
        modelPreparationPhase = .preparing
        onRetryModelPreparation()
    }

    func repairModelCache() {
        guard modelPreparationPhase == .repairableCache
                || modelPreparationPhase == .repairFailed,
              let onRepairModelCache
        else {
            return
        }
        modelPreparationPhase = .preparing
        onRepairModelCache()
    }

    func completeOnboarding() {
        guard onboardingReadiness.canFinish else { return }
        update {
            $0.completedOnboardingVersion =
                OnboardingPresentationPolicy.currentVersion
        }
        guard settings.completedOnboardingVersion
            >= OnboardingPresentationPolicy.currentVersion
        else {
            return
        }
        onboardingWindowController?.close()
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

    func addAvailableApplicationFormattingRule(
        profile: TranscriptFormattingProfile
    ) {
        guard let target = availableApplication,
              let bundleIdentifier = target.bundleIdentifier,
              let applicationName = target.applicationName
        else {
            return
        }
        update { settings in
            if let index = settings.applicationFormattingRules.firstIndex(where: {
                $0.bundleIdentifier.compare(
                    bundleIdentifier,
                    options: [.caseInsensitive]
                ) == .orderedSame
            }) {
                settings.applicationFormattingRules[index].applicationName =
                    applicationName
                settings.applicationFormattingRules[index].profile = profile
            } else if settings.applicationFormattingRules.count
                < AppSettings.maximumApplicationFormattingRules
            {
                settings.applicationFormattingRules.append(
                    ApplicationFormattingRule(
                        bundleIdentifier: bundleIdentifier,
                        applicationName: applicationName,
                        profile: profile
                    )
                )
            }
        }
    }

    func setApplicationFormattingProfile(
        _ profile: TranscriptFormattingProfile,
        bundleIdentifier: String
    ) {
        update { settings in
            guard let index = settings.applicationFormattingRules.firstIndex(where: {
                $0.bundleIdentifier.compare(
                    bundleIdentifier,
                    options: [.caseInsensitive]
                ) == .orderedSame
            }) else {
                return
            }
            settings.applicationFormattingRules[index].profile = profile
        }
    }

    func removeApplicationFormattingRule(bundleIdentifier: String) {
        update { settings in
            settings.applicationFormattingRules.removeAll {
                $0.bundleIdentifier.compare(
                    bundleIdentifier,
                    options: [.caseInsensitive]
                ) == .orderedSame
            }
        }
    }

    func setPerformanceMode(_ mode: ProcessingPerformanceMode) {
        update { $0.performanceMode = mode }
    }

    func setModelID(_ modelID: String) {
        update { $0.modelID = modelID }
    }

    func relaunch() {
        guard requiresRelaunch, let onRelaunchRequested else { return }
        do {
            try onRelaunchRequested()
            relaunchError = nil
        } catch {
            relaunchError = "Couldn’t relaunch Wordhand: \(error.localizedDescription)"
            NSSound.beep()
        }
    }

    func setInsertionMode(_ insertionMode: InsertionMode) {
        update { $0.insertionMode = insertionMode }
    }

    func setSubmitAfterDictation(_ enabled: Bool) {
        update { $0.submitAfterDictation = enabled }
    }

    func setQualityAudioRetentionEnabled(_ enabled: Bool) {
        update { $0.qualityAudioRetentionEnabled = enabled }
    }

    func setQualityAudioRetentionDays(_ days: Int) {
        update { $0.qualityAudioRetentionDays = days }
    }

    func setQualityAudioMaximumBytes(_ bytes: Int64) {
        update { $0.qualityAudioMaximumBytes = bytes }
    }

    func revealQualityAudio() {
        onRevealQualityAudio?()
    }

    func deleteQualityAudio() {
        let alert = NSAlert()
        alert.messageText = "Delete all retained recordings?"
        alert.informativeText = """
        This permanently removes the local Quality Lab audio. Transcript history \
        and your custom dictionary are not affected.
        """
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Delete Recordings")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try onDeleteQualityAudio?()
            saveError = nil
            refreshRecentActivity()
        } catch {
            saveError = "Couldn’t delete recordings: \(error.localizedDescription)"
            NSSound.beep()
        }
    }

    func revealDiagnostics() {
        onRevealDiagnostics?()
    }

    func copyDiagnosticsReport() {
        guard let onDiagnosticsReport else { return }
        diagnosticsMessage = "Building health report…"
        Task {
            do {
                let report = try await onDiagnosticsReport()
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                guard pasteboard.setString(report, forType: .string) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                diagnosticsMessage = "Health report copied."
            } catch {
                diagnosticsMessage =
                    "Couldn’t create the health report: \(error.localizedDescription)"
                NSSound.beep()
            }
        }
    }

    func refreshRecentActivity() {
        recentActivityGeneration += 1
        let generation = recentActivityGeneration
        recentActivityTask?.cancel()
        guard let onRecentActivitySnapshot else {
            recentActivityPhase = .unavailable
            return
        }
        recentActivityPhase = .loading
        recentActivityTask = Task { [weak self] in
            do {
                let snapshot = try await onRecentActivitySnapshot()
                guard !Task.isCancelled,
                      let self,
                      generation == self.recentActivityGeneration
                else {
                    return
                }
                recentActivitySnapshot = snapshot
                recentActivityPhase = .loaded
            } catch {
                guard !Task.isCancelled,
                      let self,
                      generation == self.recentActivityGeneration
                else {
                    return
                }
                recentActivitySnapshot = nil
                recentActivityPhase = .unavailable
            }
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try launchAtLoginManager.setEnabled(enabled)
            launchAtLoginState = launchAtLoginManager.state()
            launchAtLoginError = nil
            if launchAtLoginState == .requiresApproval {
                launchAtLoginManager.openSystemSettings()
            }
        } catch {
            launchAtLoginState = launchAtLoginManager.state()
            launchAtLoginError = error.localizedDescription
            NSSound.beep()
        }
    }

    func openLoginItemSettings() {
        launchAtLoginManager.openSystemSettings()
    }

    func refreshPermissions() {
        permissionStatus = permissionManager.status()
        onPermissionsRefresh?(permissionStatus)
    }

    func repairAccessibilityPermission() {
        permissionManager.requestAccessibility()
        permissionManager.openAccessibilitySettings()
        refreshPermissions()
    }

    func repairInputMonitoringPermission() {
        permissionManager.requestInputMonitoring()
        permissionManager.openInputMonitoringSettings()
        refreshPermissions()
    }

    func repairMicrophonePermission() {
        switch permissionStatus.microphone {
        case .granted:
            refreshPermissions()
        case .notDetermined:
            Task { @MainActor [weak self] in
                guard let self else { return }
                _ = await permissionManager.requestMicrophone()
                refreshPermissions()
            }
        case .denied:
            permissionManager.openMicrophoneSettings()
            refreshPermissions()
        }
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
            requiresRelaunch = candidate.modelID != activeModelID
            if !requiresRelaunch {
                relaunchError = nil
            }
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

    func refreshAvailableApplication() {
        let target = currentTarget()
        availableApplication = nil
        guard let bundleIdentifier = target.bundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !bundleIdentifier.isEmpty,
              let applicationName = target.applicationName?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !applicationName.isEmpty
        else {
            return
        }
        availableApplication = TranscriptTarget(
            bundleIdentifier: bundleIdentifier,
            applicationName: applicationName
        )
    }

    func ensureWindowController() -> NSWindowController {
        if let windowController { return windowController }

        let view = SettingsView(controller: self)
        let hostingController = NSHostingController(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.subtitle = "Wordhand"
        window.minSize = NSSize(width: 620, height: 440)
        window.contentViewController = hostingController
        window.setContentSize(Self.defaultWindowContentSize)
        window.setFrameAutosaveName(frameAutosaveName)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        let created = NSWindowController(window: window)
        windowController = created
        return created
    }

    func ensureOnboardingWindowController() -> NSWindowController {
        if let onboardingWindowController {
            return onboardingWindowController
        }
        let view = OnboardingView(controller: self)
        let hostingController = NSHostingController(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Wordhand"
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        let created = NSWindowController(window: window)
        onboardingWindowController = created
        return created
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === windowController?.window {
            saveWindowFrame(from: notification)
        }
        cancelShortcutCapture()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        saveWindowFrame(from: notification)
    }

    func windowDidResignKey(_ notification: Notification) {
        cancelShortcutCapture()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if notification.object as? NSWindow === onboardingWindowController?.window {
            refreshPermissions()
            return
        }
        guard recentActivityPhase != .loading else { return }
        refreshRecentActivity()
    }

    private func saveWindowFrame(from notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        window.saveFrame(usingName: frameAutosaveName)
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

struct ModelPreparationStatusView: View {
    let phase: ModelPreparationPhase
    let modelName: String
    let modelSizeMB: Int
    let onRetry: () -> Void
    let onRepair: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            switch phase {
            case .preparing:
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Preparing the on-device transcription model")
            case .ready:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color(red: 0.12, green: 0.49, blue: 0.39))
            case .unavailable, .repairableCache, .repairFailed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if phase == .unavailable {
                Button("Try Again", action: onRetry)
                    .buttonStyle(.bordered)
            } else if phase == .repairableCache {
                Button("Repair Model", action: onRepair)
                    .buttonStyle(.bordered)
            } else if phase == .repairFailed {
                Button("Try Repair Again", action: onRepair)
                    .buttonStyle(.bordered)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var title: String {
        switch phase {
        case .preparing: return "Preparing \(modelName)…"
        case .ready: return "On-device model ready"
        case .unavailable: return "Model unavailable"
        case .repairableCache: return "Local model needs repair"
        case .repairFailed: return "Model repair could not start"
        }
    }

    private var detail: String {
        switch phase {
        case .preparing:
            return "\(modelSizeMB) MB · Wordhand stays responsive while this finishes."
        case .ready:
            return "Transcription stays private on this Mac."
        case .unavailable:
            return "Check your connection and available storage, then retry."
        case .repairableCache:
            return "Wordhand will preserve this copy and download a clean "
                + "\(modelSizeMB) MB replacement."
        case .repairFailed:
            return "The incomplete copy is still safe. Check storage and try again."
        }
    }
}

struct OnboardingView: View {
    @ObservedObject var controller: SettingsController

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Color(red: 0.12, green: 0.49, blue: 0.39))
                Text("Welcome to Wordhand")
                    .font(.largeTitle.weight(.semibold))
                Text("Hold Control–Space, speak, then release.")
                    .font(.title3)
                Text(
                    "Wordhand works across your Mac and keeps your voice, "
                        + "transcripts, and corrections private."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 0) {
                permissionRow(
                    title: "Accessibility",
                    detail: "Inserts finished text at your cursor.",
                    granted: controller.permissionStatus.accessibilityGranted,
                    buttonTitle: "Open Settings",
                    action: controller.repairAccessibilityPermission
                )
                Divider()
                permissionRow(
                    title: "Input Monitoring",
                    detail: "Detects Control–Space in every app.",
                    granted: controller.permissionStatus.inputMonitoringGranted,
                    buttonTitle: "Allow",
                    action: controller.repairInputMonitoringPermission
                )
                Divider()
                permissionRow(
                    title: "Microphone",
                    detail: "Records only while dictation is active.",
                    granted: controller.permissionStatus.microphone == .granted,
                    buttonTitle: controller.permissionStatus.microphone == .notDetermined
                        ? "Allow" : "Open Settings",
                    action: controller.repairMicrophonePermission
                )
                Divider()
                ModelPreparationStatusView(
                    phase: controller.modelPreparationPhase,
                    modelName: controller.activeModel?.displayName ?? "transcription model",
                    modelSizeMB: controller.activeModel?.sizeMB ?? 0,
                    onRetry: controller.retryModelPreparation,
                    onRepair: controller.repairModelCache
                )
                .padding(.vertical, 12)
            }
            .padding(.horizontal, 16)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.08))
            )

            HStack {
                Text(
                    controller.onboardingReadiness.canFinish
                        ? "Wordhand is ready."
                        : "Complete each item to start dictating."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                Spacer()
                Button("Start Dictating") {
                    controller.completeOnboarding()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!controller.onboardingReadiness.canFinish)
            }
        }
        .padding(28)
        .frame(width: 560, height: 560, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("wordhand-onboarding")
    }

    private func permissionRow(
        title: String,
        detail: String,
        granted: Bool,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(
                    granted
                        ? Color(red: 0.12, green: 0.49, blue: 0.39)
                        : Color.secondary
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button(buttonTitle, action: action)
                    .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 12)
    }
}

struct RecentActivityCard<Details: View>: View {
    let snapshot: WordhandHealthSnapshot?
    let phase: RecentActivityPhase
    let onRetry: () -> Void
    @ViewBuilder let details: () -> Details

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recent activity")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Text(
                        "Activity from the last 7 days · "
                            + "Private and stored only on this Mac."
                    )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if phase == .loading, snapshot != nil {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Refreshing recent activity")
                }
            }

            if let snapshot {
                if snapshot.completedDictationCount == 0 {
                    Text("No recent dictations yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .top, spacing: 24) {
                    metric(
                        String(snapshot.completedDictationCount),
                        label: "Completed"
                    )
                    metric(
                        String(snapshot.failureEventCount),
                        label: "Issue events"
                    )
                    metric(
                        Self.duration(snapshot.medianCompletionSeconds),
                        label: "Typical completion"
                    )
                    metric(
                        String(snapshot.tailRecoveryDictationCount),
                        label: "Endings recovered"
                    )
                }
                .accessibilityElement(children: .contain)

                Divider()

                HStack(alignment: .firstTextBaseline) {
                    Text("All retained quality evidence")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(snapshot.correctedReferenceCount) corrected transcripts")
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text("\(snapshot.pairedRecordingCount) paired recordings")
                }
                .font(.subheadline)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "Quality evidence, "
                        + "\(snapshot.correctedReferenceCount) corrected transcripts, "
                        + "\(snapshot.pairedRecordingCount) paired recordings"
                )
            } else {
                initialState
            }

            Divider()

            Label(
                "No transcript or audio content enters this activity summary.",
                systemImage: "lock.fill"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Diagnostics")
                        .font(.caption.weight(.semibold))
                    Text("90 days · 250 MB maximum")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                details()
            }
        }
        .accessibilityIdentifier("recent-activity-card")
    }

    @ViewBuilder
    private var initialState: some View {
        switch phase {
        case .idle, .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading recent activity and quality evidence…")
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Loading recent activity and quality evidence")
        case .unavailable:
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Activity unavailable")
                        .font(.subheadline.weight(.semibold))
                    Text("Wordhand couldn’t read its private local evidence.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Try Again", action: onRetry)
                    .accessibilityLabel("Try loading recent activity again")
            }
        case .loaded:
            Text("No recent dictations yet.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func metric(_ value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(value)")
    }

    private static func duration(_ seconds: Double?) -> String {
        guard let seconds else { return "—" }
        return String(format: "%.1fs", seconds)
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
                    startupCard
                    permissionCard
                    modelCard
                    performanceCard
                    insertionCard
                    formattingCard
                    shortcutsCard
                    recordingCard
                    qualityLabCard
                    recentActivityCard
                    privacyNote
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(32)
            }
        }
        .frame(minWidth: 620, minHeight: 440)
    }

    private var startupCard: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Launch at login")
                            .font(.headline)
                        Text(controller.launchAtLoginState.detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { controller.launchAtLoginState.isEnabled },
                            set: { controller.setLaunchAtLogin($0) }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(!controller.launchAtLoginState.canChange)
                }

                if controller.launchAtLoginState == .requiresApproval {
                    Button("Open Login Items") {
                        controller.openLoginItemSettings()
                    }
                    .buttonStyle(.link)
                }

                if let error = controller.launchAtLoginError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var recentActivityCard: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 8) {
                RecentActivityCard(
                    snapshot: controller.recentActivitySnapshot,
                    phase: controller.recentActivityPhase,
                    onRetry: controller.refreshRecentActivity,
                    details: {
                        Button("Open Diagnostics Folder") {
                            controller.revealDiagnostics()
                        }
                        .buttonStyle(.bordered)
                        Button("Copy Health Report") {
                            controller.copyDiagnosticsReport()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                )
                if let message = controller.diagnosticsMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var permissionCard: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Permissions")
                            .font(.headline)
                        Text(
                            controller.permissionStatus.isReady
                                ? "Wordhand is ready in every app."
                                : "All three permissions stay under your control."
                        )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Check again") {
                        controller.refreshPermissions()
                    }
                    .buttonStyle(.borderless)
                }

                Divider()

                permissionRow(
                    title: "Accessibility",
                    detail: "Inserts the finished transcript at the cursor.",
                    granted: controller.permissionStatus.accessibilityGranted,
                    buttonTitle: "Open Settings",
                    action: controller.repairAccessibilityPermission
                )

                Divider()

                permissionRow(
                    title: "Input Monitoring",
                    detail: "Detects your shortcut while you work in another app.",
                    granted: controller.permissionStatus.inputMonitoringGranted,
                    buttonTitle: "Allow",
                    action: controller.repairInputMonitoringPermission
                )

                Divider()

                permissionRow(
                    title: "Microphone",
                    detail: microphonePermissionDetail,
                    granted: controller.permissionStatus.microphone == .granted,
                    buttonTitle: controller.permissionStatus.microphone == .notDetermined
                        ? "Allow" : "Open Settings",
                    action: controller.repairMicrophonePermission
                )
            }
        }
    }

    private var microphonePermissionDetail: String {
        switch controller.permissionStatus.microphone {
        case .granted:
            return "Records only while dictation is active."
        case .notDetermined:
            return "Permission has not been requested yet."
        case .denied:
            return "Enable Wordhand under Privacy & Security → Microphone."
        }
    }

    private func permissionRow(
        title: String,
        detail: String,
        granted: Bool,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(
                    granted
                        ? Color(red: 0.12, green: 0.49, blue: 0.39)
                        : Color.secondary
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button(buttonTitle, action: action)
                    .buttonStyle(.bordered)
            }
        }
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
                Divider()
                Toggle(
                    "Press Return after confirmed insertion",
                    isOn: Binding(
                        get: { controller.settings.submitAfterDictation },
                        set: { controller.setSubmitAfterDictation($0) }
                    )
                )
                .disabled(controller.settings.insertionMode != .paste)
                Text(
                    "Optional. Return may send a message, submit a form, "
                        + "or run a command. Wordhand skips it unless paste "
                        + "delivery is confirmed."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
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
                        Text(
                            "Parakeet is fastest for English. Whisper Large v3 "
                                + "prioritizes accuracy and vocabulary hints."
                        )
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

                if controller.requiresRelaunch {
                    HStack(spacing: 12) {
                        Label(
                            "Model saved. Relaunch to load it.",
                            systemImage: "arrow.clockwise"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        Spacer()
                        Button("Relaunch Wordhand") {
                            controller.relaunch()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                } else {
                    Divider()
                    ModelPreparationStatusView(
                        phase: controller.modelPreparationPhase,
                        modelName:
                            controller.activeModel?.displayName
                            ?? "transcription model",
                        modelSizeMB: controller.activeModel?.sizeMB ?? 0,
                        onRetry: controller.retryModelPreparation,
                        onRepair: controller.repairModelCache
                    )
                }

                if let error = controller.relaunchError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var performanceCard: some View {
        settingsCard {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Processing speed")
                        .font(.headline)
                    Text(performanceDescription)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 20)
                Picker(
                    "Processing speed",
                    selection: Binding(
                        get: { controller.settings.performanceMode },
                        set: { controller.setPerformanceMode($0) }
                    )
                ) {
                    Text("Adaptive").tag(ProcessingPerformanceMode.adaptive)
                    Text("Maximum · Apple silicon").tag(ProcessingPerformanceMode.maximum)
                }
                .labelsHidden()
                .frame(width: 230)
            }
        }
    }

    private var performanceDescription: String {
        switch controller.settings.performanceMode {
        case .adaptive:
            return "Uses the local writing model for richer restructuring."
        case .maximum:
            return "Inserts faster with immediate, meaning-safe cleanup."
        }
    }

    private var formattingCard: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 14) {
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
                    formattingPicker(
                        selection: Binding(
                            get: { controller.settings.formattingProfile },
                            set: { controller.setFormattingProfile($0) }
                        ),
                        label: "Default writing style"
                    )
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("App-specific styles")
                            .font(.subheadline.weight(.semibold))
                        Text(
                            "Optional. Each app uses the default above unless "
                                + "you add it here."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    ForEach(controller.settings.applicationFormattingRules) {
                        rule in
                        HStack(spacing: 12) {
                            Image(systemName: "app.fill")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(rule.applicationName)
                                    .font(.subheadline)
                                Text(rule.bundleIdentifier)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 12)
                            formattingPicker(
                                selection: Binding(
                                    get: { rule.profile },
                                    set: {
                                        controller.setApplicationFormattingProfile(
                                            $0,
                                            bundleIdentifier: rule.bundleIdentifier
                                        )
                                    }
                                ),
                                label: "\(rule.applicationName) writing style",
                                width: 170
                            )
                            Button {
                                controller.removeApplicationFormattingRule(
                                    bundleIdentifier: rule.bundleIdentifier
                                )
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Use the default style in \(rule.applicationName)")
                        }
                    }

                    if let application = addableApplication {
                        Menu {
                            ForEach(TranscriptFormattingProfile.allCases, id: \.self) {
                                profile in
                                Button(styleName(profile)) {
                                    controller.addAvailableApplicationFormattingRule(
                                        profile: profile
                                    )
                                }
                            }
                        } label: {
                            Label(
                                "Use a different style in \(application.applicationName ?? "current app")",
                                systemImage: "plus"
                            )
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    } else if controller.settings.applicationFormattingRules.isEmpty {
                        Text(
                            "Open Settings from the menu bar while working in "
                                + "another app to add it."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func formattingPicker(
        selection: Binding<TranscriptFormattingProfile>,
        label: String,
        width: CGFloat = 220
    ) -> some View {
        Picker(label, selection: selection) {
            Text("Casual").tag(TranscriptFormattingProfile.casual)
            Text("Formatted · Recommended").tag(TranscriptFormattingProfile.formatted)
            Text("Professional").tag(TranscriptFormattingProfile.professional)
            Text("AI Communication").tag(TranscriptFormattingProfile.aiCommunication)
        }
        .labelsHidden()
        .frame(width: width)
    }

    private var addableApplication: TranscriptTarget? {
        guard controller.settings.applicationFormattingRules.count
            < AppSettings.maximumApplicationFormattingRules,
              let application = controller.availableApplication,
              let bundleIdentifier = application.bundleIdentifier,
              !controller.settings.applicationFormattingRules.contains(where: {
                  $0.bundleIdentifier.compare(
                      bundleIdentifier,
                      options: [.caseInsensitive]
                  ) == .orderedSame
              })
        else {
            return nil
        }
        return application
    }

    private func styleName(_ profile: TranscriptFormattingProfile) -> String {
        switch profile {
        case .casual: return "Casual"
        case .formatted: return "Formatted"
        case .professional: return "Professional"
        case .aiCommunication: return "AI Communication"
        }
    }

    private var formattingDescription: String {
        switch controller.settings.formattingProfile {
        case .casual:
            return "Fast cleanup for natural messages: fillers, capitalization, punctuation, and sentence boundaries."
        case .formatted:
            return "Uses Apple’s on-device model to organize your words into clear, readable text without changing your tone."
        case .professional:
            return "Produces concise, polished communication with stronger wording and organization while preserving your meaning."
        case .aiCommunication:
            return "Structures goals, context, requirements, and constraints for clear communication with AI agents."
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

    private var qualityLabCard: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Quality Lab")
                            .font(.headline)
                        Text(
                            "Keep audio locally so you can compare mistakes and improve accuracy over time."
                        )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { controller.settings.qualityAudioRetentionEnabled },
                            set: { controller.setQualityAudioRetentionEnabled($0) }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                }

                if controller.settings.qualityAudioRetentionEnabled {
                    Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Automatic deletion")
                                .font(.subheadline.weight(.semibold))
                            Text("Raw recordings expire even if transcript history remains.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker(
                            "Retention",
                            selection: Binding(
                                get: { controller.settings.qualityAudioRetentionDays },
                                set: { controller.setQualityAudioRetentionDays($0) }
                            )
                        ) {
                            Text("1 day").tag(1)
                            Text("3 days").tag(3)
                            Text("7 days").tag(7)
                            Text("14 days").tag(14)
                            Text("30 days").tag(30)
                        }
                        .labelsHidden()
                        .frame(width: 110)
                    }

                    Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Maximum storage")
                                .font(.subheadline.weight(.semibold))
                            Text("Oldest recordings are removed after capture to stay under this limit.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker(
                            "Maximum storage",
                            selection: Binding(
                                get: { controller.settings.qualityAudioMaximumBytes },
                                set: { controller.setQualityAudioMaximumBytes($0) }
                            )
                        ) {
                            Text("250 MB").tag(Int64(250_000_000))
                            Text("500 MB").tag(Int64(500_000_000))
                            Text("1 GB").tag(Int64(1_000_000_000))
                            Text("2 GB · Recommended").tag(Int64(2_000_000_000))
                            Text("5 GB").tag(Int64(5_000_000_000))
                            Text("10 GB").tag(Int64(10_000_000_000))
                        }
                        .labelsHidden()
                        .frame(width: 190)
                    }
                }

                Divider()
                HStack {
                    Label("Stored only in Wordhand’s private data folder.", systemImage: "lock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Show Files") {
                        controller.revealQualityAudio()
                    }
                    .buttonStyle(.borderless)
                    Button("Delete All…") {
                        controller.deleteQualityAudio()
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
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
