import AppKit
import Carbon
import CoreGraphics
import Foundation
import WordhandCore

protocol TextEventPosting: Sendable {
    func postUnicode(_ text: String)
    func postPasteShortcut() throws
    func postReturnKey() throws
}

struct TextInsertionCheckpoint: Equatable, Sendable {
    let id: UUID
    let selection: NSRange
    let allowsAutomaticPasteRetry: Bool

    init(
        id: UUID,
        selection: NSRange,
        allowsAutomaticPasteRetry: Bool = true
    ) {
        self.id = id
        self.selection = selection
        self.allowsAutomaticPasteRetry = allowsAutomaticPasteRetry
    }
}

struct TextInsertionUndoToken: Equatable, Sendable {
    let checkpointID: UUID
    let insertedRange: NSRange
    let expectedSelection: NSRange
}

enum TextInsertionVerification: Equatable, Sendable {
    case verified(TextInsertionUndoToken)
    case verifiedWithoutUndo
    case unchanged
    case unavailable
    case targetChanged
}

protocol TextInsertionObserving: Sendable {
    func captureCheckpoint() -> TextInsertionCheckpoint?
    func verify(
        _ checkpoint: TextInsertionCheckpoint,
        insertedUTF16Count: Int
    ) -> TextInsertionVerification
    func waitForVerification(
        _ checkpoint: TextInsertionCheckpoint,
        insertedUTF16Count: Int,
        timeoutNanoseconds: UInt64
    ) async -> TextInsertionVerification
    func undo(_ token: TextInsertionUndoToken) throws
}

struct CGTextEventPoster: TextEventPosting {
    func postUnicode(_ text: String) {
        TextInjector.inject(text)
    }

    func postPasteShortcut() throws {
        try TextInjector.postPasteShortcut()
    }

    func postReturnKey() throws {
        try TextInjector.postReturnKey()
    }
}

/// Posts a string of text at the current cursor location by synthesizing
/// keyboard events with `CGEventKeyboardSetUnicodeString`. Works in nearly
/// every text field on macOS; some Electron apps and secure password fields
/// can drop characters (platform constraint).
enum TextInjector {
    static func postReturnKey() throws {
        guard let down = CGEvent(
            keyboardEventSource: nil,
            virtualKey: 36,
            keyDown: true
        ), let up = CGEvent(
            keyboardEventSource: nil,
            virtualKey: 36,
            keyDown: false
        ) else {
            throw TextInsertionError.returnEventCreationFailed
        }
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }

    /// Inject the given text at the current cursor location.
    /// Splits long strings into chunks because the underlying API has a
    /// per-event character limit (~20 chars).
    static func inject(_ text: String) {
        guard !text.isEmpty else { return }

        let utf16 = Array(text.utf16)
        let chunkSize = 20
        var index = 0

        while index < utf16.count {
            let end = min(index + chunkSize, utf16.count)
            var chunk = Array(utf16[index..<end])
            postChunk(&chunk)
            index = end
        }
    }

    private static func postChunk(_ chunk: inout [UniChar]) {
        let length = chunk.count
        guard length > 0 else { return }

        let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
        down?.keyboardSetUnicodeString(stringLength: length, unicodeString: &chunk)
        down?.post(tap: .cgSessionEventTap)

        let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        up?.keyboardSetUnicodeString(stringLength: length, unicodeString: &chunk)
        up?.post(tap: .cgSessionEventTap)
    }
}

final class MacTextInserter:
    PostActionTextInserting,
    InsertionDiagnosticsProviding,
    @unchecked Sendable
{
    private let eventPoster: any TextEventPosting
    private let observer: any TextInsertionObserving
    private let secureInputEnabled: @Sendable () -> Bool
    private let now: @Sendable () -> TimeInterval
    private let compatibilityWait: @Sendable (UInt64) async -> Void
    private let lock = NSLock()
    private var undoToken: TextInsertionUndoToken?
    private var hasPostedPaste = false
    private var latestDiagnostics = InsertionRunDiagnostics(mode: .paste)
    var onUndoAvailabilityChange: (@Sendable (Bool) -> Void)?

    init(
        eventPoster: any TextEventPosting = CGTextEventPoster(),
        observer: any TextInsertionObserving = AXTextInsertionObserver(),
        secureInputEnabled: @escaping @Sendable () -> Bool = {
            IsSecureEventInputEnabled()
        },
        now: @escaping @Sendable () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        },
        compatibilityWait:
            @escaping @Sendable (UInt64) async -> Void = { nanoseconds in
                try? await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        self.eventPoster = eventPoster
        self.observer = observer
        self.secureInputEnabled = secureInputEnabled
        self.now = now
        self.compatibilityWait = compatibilityWait
    }

    func insert(_ text: String, mode: InsertionMode) async throws {
        try await insert(text, mode: mode, postAction: .none)
    }

    func insert(
        _ text: String,
        mode: InsertionMode,
        postAction: InsertionPostAction
    ) async throws {
        guard !text.isEmpty else { return }
        clearUndo()
        setDiagnostics(InsertionRunDiagnostics(mode: mode))

        switch mode {
        case .unicode:
            guard !secureInputEnabled() else {
                setDiagnostics(InsertionRunDiagnostics(
                    mode: mode,
                    verification: .failed,
                    secureInputBlocked: true
                ))
                throw TextInsertionError.secureInputEnabled
            }
            let checkpoint = observer.captureCheckpoint()
            eventPoster.postUnicode(text)
            try? await Task.sleep(nanoseconds: 200_000_000)
            do {
                let verification = try finalizeObservation(
                    checkpoint,
                    insertedUTF16Count: text.utf16.count
                )
                setDiagnostics(InsertionRunDiagnostics(
                    mode: mode,
                    verification: verification,
                    checkpointAvailable: checkpoint != nil,
                    undoAvailable: canUndoLastInsertion,
                    postActionOutcome:
                        postAction == .none ? .notRequested : .unsupportedMode
                ))
            } catch {
                setDiagnostics(InsertionRunDiagnostics(
                    mode: mode,
                    verification: .failed,
                    checkpointAvailable: checkpoint != nil
                ))
                throw error
            }

        case .copyOnly:
            do {
                try await MainActor.run {
                    let pasteboard = NSPasteboard.general
                    let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
                    pasteboard.clearContents()
                    guard pasteboard.setString(text, forType: .string) else {
                        snapshot.restore(to: pasteboard)
                        throw TextInsertionError.clipboardWriteFailed
                    }
                }
            } catch {
                setDiagnostics(InsertionRunDiagnostics(
                    mode: mode,
                    verification: .failed
                ))
                throw error
            }
            setDiagnostics(InsertionRunDiagnostics(
                mode: mode,
                verification: .copyOnly,
                postActionOutcome:
                    postAction == .none ? .notRequested : .unsupportedMode
            ))

        case .paste:
            guard !secureInputEnabled() else {
                setDiagnostics(InsertionRunDiagnostics(
                    mode: mode,
                    verification: .failed,
                    secureInputBlocked: true
                ))
                throw TextInsertionError.secureInputEnabled
            }

            let transaction: PasteboardTransaction
            do {
                transaction = try await MainActor.run {
                    let pasteboard = NSPasteboard.general
                    let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
                    pasteboard.clearContents()
                    guard pasteboard.setString(text, forType: .string) else {
                        snapshot.restore(to: pasteboard)
                        throw TextInsertionError.clipboardWriteFailed
                    }
                    let ownedChangeCount = pasteboard.changeCount
                    return PasteboardTransaction(
                        snapshot: snapshot,
                        ownedChangeCount: ownedChangeCount
                    )
                }
            } catch {
                setDiagnostics(InsertionRunDiagnostics(
                    mode: mode,
                    verification: .failed
                ))
                throw error
            }
            let checkpoint = observer.captureCheckpoint()

            // A newly launched app can reach the pasteboard before macOS has
            // made the first write visible to the target process. Let that
            // transaction settle before posting a complete Command-V chord.
            let pasteboardSettleNanoseconds: UInt64 = lock.withLock {
                let isFirstPaste = !hasPostedPaste
                hasPostedPaste = true
                return isFirstPaste ? 120_000_000 : 40_000_000
            }
            do {
                try await Task.sleep(nanoseconds: pasteboardSettleNanoseconds)
            } catch {
                await MainActor.run {
                    let pasteboard = NSPasteboard.general
                    guard PasteboardRestorationPolicy.shouldRestore(
                        ownedChangeCount: transaction.ownedChangeCount,
                        currentChangeCount: pasteboard.changeCount
                    ) else {
                        return
                    }
                    transaction.snapshot.restore(to: pasteboard)
                }
                setDiagnostics(InsertionRunDiagnostics(
                    mode: mode,
                    verification: .failed,
                    checkpointAvailable: checkpoint != nil
                ))
                throw error
            }
            do {
                try await MainActor.run {
                    try eventPoster.postPasteShortcut()
                }
            } catch {
                await MainActor.run {
                    transaction.snapshot.restore(to: NSPasteboard.general)
                }
                setDiagnostics(InsertionRunDiagnostics(
                    mode: mode,
                    verification: .failed,
                    checkpointAvailable: checkpoint != nil
                ))
                throw error
            }

            // Accessibility notifications can confirm delivery as soon as the
            // cursor moves. The 360 ms bound remains a compatibility timeout,
            // not an unconditional delay. A proven no-op gets one retry only
            // when the target exposes a reliable editor cursor.
            // Terminal accessibility surfaces can leave their reported cursor
            // unchanged after a successful paste, so retrying there duplicates
            // the transcript.
            var observationError: Error?
            var verification: InsertionVerificationOutcome =
                checkpoint == nil ? .unavailable : .notAttempted
            var retryCount = 0
            var verificationWaitSeconds: TimeInterval = 0
            if let checkpoint {
                do {
                    let waitStarted = now()
                    let firstVerification = await observer.waitForVerification(
                        checkpoint,
                        insertedUTF16Count: text.utf16.count,
                        timeoutNanoseconds: 360_000_000
                    )
                    verificationWaitSeconds += max(0, now() - waitStarted)
                    switch firstVerification {
                    case .unchanged:
                        if checkpoint.allowsAutomaticPasteRetry {
                            retryCount = 1
                            try await MainActor.run {
                                try eventPoster.postPasteShortcut()
                            }
                            let retryWaitStarted = now()
                            let retryObservation =
                                await observer.waitForVerification(
                                    checkpoint,
                                    insertedUTF16Count: text.utf16.count,
                                    timeoutNanoseconds: 360_000_000
                                )
                            verificationWaitSeconds += max(
                                0,
                                now() - retryWaitStarted
                            )
                            let retryVerification = try finalizeObservation(
                                checkpoint,
                                insertedUTF16Count: text.utf16.count,
                                observed: retryObservation
                            )
                            verification = retryVerification == .verified
                                ? .verifiedAfterRetry
                                : retryVerification
                        } else {
                            verification = .unchangedWithoutRetry
                        }
                    case .verified(let token):
                        setUndo(token)
                        verification = .verified
                    case .verifiedWithoutUndo:
                        verification = .verifiedWithoutUndo
                    case .unavailable:
                        verification = .unavailable
                    case .targetChanged:
                        throw TextInsertionError.insertionTargetChanged
                    }
                } catch {
                    observationError = error
                }
            } else {
                // Without a readable AX selection there is no event that can
                // prove consumption. Preserve the former compatibility bound
                // before restoring the user's clipboard.
                let waitStarted = now()
                await compatibilityWait(360_000_000)
                verificationWaitSeconds += max(0, now() - waitStarted)
            }
            await MainActor.run {
                let pasteboard = NSPasteboard.general
                guard PasteboardRestorationPolicy.shouldRestore(
                    ownedChangeCount: transaction.ownedChangeCount,
                    currentChangeCount: pasteboard.changeCount
                ) else {
                    return
                }
                transaction.snapshot.restore(to: pasteboard)
            }
            if let observationError {
                setDiagnostics(InsertionRunDiagnostics(
                    mode: mode,
                    verification: .failed,
                    retryCount: retryCount,
                    checkpointAvailable: checkpoint != nil,
                    verificationWaitSeconds: verificationWaitSeconds
                ))
                throw observationError
            }
            let postActionOutcome = await performPostActionIfSafe(
                postAction,
                verification: verification,
                checkpoint: checkpoint,
                insertedUTF16Count: text.utf16.count
            )
            setDiagnostics(InsertionRunDiagnostics(
                mode: mode,
                verification: verification,
                retryCount: retryCount,
                checkpointAvailable: checkpoint != nil,
                undoAvailable: canUndoLastInsertion,
                postActionOutcome: postActionOutcome,
                verificationWaitSeconds: verificationWaitSeconds
            ))
        }
    }

    private func performPostActionIfSafe(
        _ action: InsertionPostAction,
        verification: InsertionVerificationOutcome,
        checkpoint: TextInsertionCheckpoint?,
        insertedUTF16Count: Int
    ) async -> InsertionPostActionOutcome {
        guard action != .none else { return .notRequested }
        guard action == .returnKey else { return .unsupportedMode }
        guard verification == .verified
                || verification == .verifiedAfterRetry
                || verification == .verifiedWithoutUndo
              , let checkpoint
        else {
            return .skippedUnverified
        }
        return await MainActor.run {
            // Clipboard restoration awaits the main actor after the first
            // delivery check. Revalidate the exact AX element and expected
            // selection without yielding before Return so a focus change
            // cannot submit in another app or field.
            switch observer.verify(
                checkpoint,
                insertedUTF16Count: insertedUTF16Count
            ) {
            case .verified, .verifiedWithoutUndo:
                do {
                    try eventPoster.postReturnKey()
                    return .performed
                } catch {
                    return .failed
                }
            case .unchanged, .unavailable, .targetChanged:
                return .skippedUnverified
            }
        }
    }

    func lastInsertionDiagnostics() async -> InsertionRunDiagnostics {
        lock.withLock { latestDiagnostics }
    }

    var canUndoLastInsertion: Bool {
        lock.withLock { undoToken != nil }
    }

    func undoLastInsertion() throws {
        guard let token = lock.withLock({ undoToken }) else {
            throw TextInsertionError.nothingSafeToUndo
        }
        try observer.undo(token)
        clearUndo()
    }

    private func finalizeObservation(
        _ checkpoint: TextInsertionCheckpoint?,
        insertedUTF16Count: Int,
        observed: TextInsertionVerification? = nil
    ) throws -> InsertionVerificationOutcome {
        guard let checkpoint else { return .unavailable }
        let result = observed ?? observer.verify(
            checkpoint,
            insertedUTF16Count: insertedUTF16Count
        )
        switch result {
        case .verified(let token):
            setUndo(token)
            return .verified
        case .verifiedWithoutUndo:
            return .verifiedWithoutUndo
        case .unavailable:
            return .unavailable
        case .unchanged:
            throw TextInsertionError.deliveryNotConfirmed
        case .targetChanged:
            throw TextInsertionError.insertionTargetChanged
        }
    }

    private func setDiagnostics(_ diagnostics: InsertionRunDiagnostics) {
        lock.withLock {
            latestDiagnostics = diagnostics
        }
    }

    private func setUndo(_ token: TextInsertionUndoToken) {
        lock.withLock { undoToken = token }
        onUndoAvailabilityChange?(true)
    }

    private func clearUndo() {
        let hadUndo = lock.withLock {
            let hadUndo = undoToken != nil
            undoToken = nil
            return hadUndo
        }
        if hadUndo {
            onUndoAvailabilityChange?(false)
        }
    }
}

enum TextInsertionError: LocalizedError {
    case secureInputEnabled
    case clipboardWriteFailed
    case pasteEventCreationFailed
    case returnEventCreationFailed
    case deliveryNotConfirmed
    case insertionTargetChanged
    case nothingSafeToUndo
    case undoTargetChanged
    case undoFailed

    var errorDescription: String? {
        switch self {
        case .secureInputEnabled:
            return "Secure Input is active. The transcript is safe in History, but macOS blocked insertion."
        case .clipboardWriteFailed:
            return "Wordhand couldn’t place the transcript on the clipboard."
        case .pasteEventCreationFailed:
            return "Wordhand couldn’t create the Command-V event."
        case .returnEventCreationFailed:
            return "Wordhand inserted the transcript but couldn’t press Return."
        case .deliveryNotConfirmed:
            return "The target didn’t acknowledge the paste. The transcript is safe in History."
        case .insertionTargetChanged:
            return "The active text field changed before Wordhand could confirm insertion."
        case .nothingSafeToUndo:
            return "There is no verified Wordhand insertion to undo."
        case .undoTargetChanged:
            return "Wordhand won’t undo because the cursor moved after insertion."
        case .undoFailed:
            return "The current text field refused Wordhand’s safe undo."
        }
    }
}

protocol AXVerificationNotificationToken: AnyObject, Sendable {
    @MainActor
    func invalidate()
}

protocol AXVerificationNotificationDriving: Sendable {
    @MainActor
    func register(
        element: AXUIElement,
        onChange: @escaping @Sendable (AXUIElement) -> Void
    ) -> (any AXVerificationNotificationToken)?
}

private final class SystemAXVerificationNotificationToken:
    AXVerificationNotificationToken,
    @unchecked Sendable
{
    let observer: AXObserver
    let element: AXUIElement
    private(set) var notifications: [CFString] = []
    let onChange: @Sendable (AXUIElement) -> Void
    private var isValid = true

    init(
        observer: AXObserver,
        element: AXUIElement,
        onChange: @escaping @Sendable (AXUIElement) -> Void
    ) {
        self.observer = observer
        self.element = element
        self.onChange = onChange
    }

    @MainActor
    func setNotifications(_ notifications: [CFString]) {
        self.notifications = notifications
    }

    @MainActor
    func invalidate() {
        guard isValid else { return }
        isValid = false
        for notification in notifications {
            AXObserverRemoveNotification(observer, element, notification)
        }
        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )
    }
}

private let axVerificationNotificationCallback: AXObserverCallback = {
    _,
    element,
    _,
    context
in
    guard let context else { return }
    let token = Unmanaged<SystemAXVerificationNotificationToken>
        .fromOpaque(context)
        .takeUnretainedValue()
    token.onChange(element)
}

struct SystemAXVerificationNotificationDriver:
    AXVerificationNotificationDriving
{
    @MainActor
    func register(
        element: AXUIElement,
        onChange: @escaping @Sendable (AXUIElement) -> Void
    ) -> (any AXVerificationNotificationToken)? {
        var processIdentifier: pid_t = 0
        var observer: AXObserver?
        guard AXUIElementGetPid(
            element,
            &processIdentifier
        ) == .success,
        AXObserverCreate(
            processIdentifier,
            axVerificationNotificationCallback,
            &observer
        ) == .success,
        let observer
        else {
            return nil
        }

        let requestedNotifications = [
            kAXSelectedTextChangedNotification as CFString,
            kAXValueChangedNotification as CFString,
        ]
        var registeredNotifications: [CFString] = []
        let token = SystemAXVerificationNotificationToken(
            observer: observer,
            element: element,
            onChange: onChange
        )
        let context = Unmanaged.passUnretained(token).toOpaque()
        for notification in requestedNotifications where
            AXObserverAddNotification(
                observer,
                element,
                notification,
                context
            ) == .success
        {
            registeredNotifications.append(notification)
        }
        guard !registeredNotifications.isEmpty else { return nil }
        token.setNotifications(registeredNotifications)
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )
        return token
    }
}

final class AXTextInsertionObserver: TextInsertionObserving, @unchecked Sendable {
    private struct StoredCheckpoint {
        let element: AXUIElement
        let selection: NSRange
    }

    private final class ActiveVerificationWait: @unchecked Sendable {
        let checkpoint: TextInsertionCheckpoint
        let insertedUTF16Count: Int
        let element: AXUIElement
        let notificationToken: (any AXVerificationNotificationToken)?
        let continuation: CheckedContinuation<
            TextInsertionVerification,
            Never
        >

        init(
            checkpoint: TextInsertionCheckpoint,
            insertedUTF16Count: Int,
            element: AXUIElement,
            notificationToken: (any AXVerificationNotificationToken)?,
            continuation: CheckedContinuation<
                TextInsertionVerification,
                Never
            >
        ) {
            self.checkpoint = checkpoint
            self.insertedUTF16Count = insertedUTF16Count
            self.element = element
            self.notificationToken = notificationToken
            self.continuation = continuation
        }
    }

    private let lock = NSLock()
    private let focusedElementProvider: @Sendable () -> AXUIElement?
    private let selectionProvider:
        @Sendable (AXUIElement) -> NSRange?
    private let automaticPasteRetryPolicy:
        @Sendable (AXUIElement) -> Bool
    private let notificationDriver: any AXVerificationNotificationDriving
    private let timeoutSleep: @Sendable (UInt64) async -> Void
    private var checkpoints: [UUID: StoredCheckpoint] = [:]
    private var activeVerificationWaits: [UUID: ActiveVerificationWait] = [:]
    private var pendingVerificationWaits: Set<UUID> = []
    private var cancelledVerificationWaits: Set<UUID> = []

    init(
        focusedElementProvider:
            @escaping @Sendable () -> AXUIElement? = {
                AXTextInsertionObserver.focusedElement()
            },
        selectionProvider:
            @escaping @Sendable (AXUIElement) -> NSRange? = {
                AXTextInsertionObserver.selection(of: $0)
            },
        automaticPasteRetryPolicy:
            @escaping @Sendable (AXUIElement) -> Bool = {
                AXTextInsertionObserver.allowsAutomaticPasteRetry(for: $0)
            },
        notificationDriver:
            any AXVerificationNotificationDriving =
                SystemAXVerificationNotificationDriver(),
        timeoutSleep:
            @escaping @Sendable (UInt64) async -> Void = { nanoseconds in
                try? await Task.sleep(nanoseconds: nanoseconds)
            }
    ) {
        self.focusedElementProvider = focusedElementProvider
        self.selectionProvider = selectionProvider
        self.automaticPasteRetryPolicy = automaticPasteRetryPolicy
        self.notificationDriver = notificationDriver
        self.timeoutSleep = timeoutSleep
    }

    func captureCheckpoint() -> TextInsertionCheckpoint? {
        guard let element = focusedElementProvider(),
              let selection = selectionProvider(element)
        else {
            return nil
        }
        let id = UUID()
        lock.withLock {
            checkpoints = [id: StoredCheckpoint(element: element, selection: selection)]
        }
        return TextInsertionCheckpoint(
            id: id,
            selection: selection,
            allowsAutomaticPasteRetry: automaticPasteRetryPolicy(element)
        )
    }

    func verify(
        _ checkpoint: TextInsertionCheckpoint,
        insertedUTF16Count: Int
    ) -> TextInsertionVerification {
        guard let stored = lock.withLock({ checkpoints[checkpoint.id] }),
              let focused = focusedElementProvider()
        else {
            return .unavailable
        }
        guard CFEqual(stored.element, focused) else {
            return .targetChanged
        }
        guard let selection = selectionProvider(focused) else {
            return .unavailable
        }
        if selection == stored.selection {
            return .unchanged
        }
        let replacementStart = stored.selection.location
        let expectedLocation = replacementStart + insertedUTF16Count
        guard selection == NSRange(location: expectedLocation, length: 0) else {
            return .targetChanged
        }
        guard stored.selection.length == 0 else {
            // Replacing a selection destroys pre-existing user text. We can
            // acknowledge the paste, but must not call deleting the new range
            // an undo because it would not restore the replaced content.
            return .verifiedWithoutUndo
        }
        return .verified(TextInsertionUndoToken(
            checkpointID: checkpoint.id,
            insertedRange: NSRange(
                location: replacementStart,
                length: insertedUTF16Count
            ),
            expectedSelection: selection
        ))
    }

    func waitForVerification(
        _ checkpoint: TextInsertionCheckpoint,
        insertedUTF16Count: Int,
        timeoutNanoseconds: UInt64
    ) async -> TextInsertionVerification {
        let immediate = verify(
            checkpoint,
            insertedUTF16Count: insertedUTF16Count
        )
        if Self.isTerminalVerification(immediate) {
            return immediate
        }

        let waitID = UUID()
        _ = lock.withLock {
            pendingVerificationWaits.insert(waitID)
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                Task { @MainActor [self] in
                    installVerificationWait(
                        id: waitID,
                        checkpoint: checkpoint,
                        insertedUTF16Count: insertedUTF16Count,
                        timeoutNanoseconds: timeoutNanoseconds,
                        continuation: continuation
                    )
                }
            }
        } onCancel: { [weak self] in
            self?.cancelVerificationWait(id: waitID)
        }
    }

    func undo(_ token: TextInsertionUndoToken) throws {
        guard let stored = lock.withLock({ checkpoints[token.checkpointID] }),
              let focused = focusedElementProvider(),
              CFEqual(stored.element, focused),
              selectionProvider(focused) == token.expectedSelection
        else {
            throw TextInsertionError.undoTargetChanged
        }
        var range = CFRange(
            location: token.insertedRange.location,
            length: token.insertedRange.length
        )
        guard let rangeValue = AXValueCreate(.cfRange, &range),
              AXUIElementSetAttributeValue(
                focused,
                kAXSelectedTextRangeAttribute as CFString,
                rangeValue
              ) == .success,
              AXUIElementSetAttributeValue(
                focused,
                kAXSelectedTextAttribute as CFString,
                "" as CFString
              ) == .success,
              selectionProvider(focused) == NSRange(
                  location: token.insertedRange.location,
                  length: 0
              )
        else {
            throw TextInsertionError.undoFailed
        }
    }

    @MainActor
    private func installVerificationWait(
        id: UUID,
        checkpoint: TextInsertionCheckpoint,
        insertedUTF16Count: Int,
        timeoutNanoseconds: UInt64,
        continuation: CheckedContinuation<
            TextInsertionVerification,
            Never
        >
    ) {
        let wasCancelled = lock.withLock {
            guard cancelledVerificationWaits.remove(id) != nil else {
                return false
            }
            pendingVerificationWaits.remove(id)
            return true
        }
        guard !wasCancelled else {
            continuation.resume(returning: .unavailable)
            return
        }
        guard let stored = lock.withLock({
            checkpoints[checkpoint.id]
        }) else {
            lock.withLock {
                pendingVerificationWaits.remove(id)
                cancelledVerificationWaits.remove(id)
            }
            continuation.resume(returning: .unavailable)
            return
        }

        let notificationToken = notificationDriver.register(
            element: stored.element
        ) { [weak self] element in
            self?.handleVerificationNotification(for: element)
        }

        let registration = ActiveVerificationWait(
            checkpoint: checkpoint,
            insertedUTF16Count: insertedUTF16Count,
            element: stored.element,
            notificationToken: notificationToken,
            continuation: continuation
        )
        let activated = lock.withLock {
            if cancelledVerificationWaits.remove(id) != nil {
                pendingVerificationWaits.remove(id)
                return false
            }
            guard pendingVerificationWaits.remove(id) != nil else {
                return false
            }
            activeVerificationWaits[id] = registration
            return true
        }
        guard activated else {
            finishVerificationWait(
                registration,
                result: .unavailable
            )
            return
        }

        // Close the race where delivery lands after the first verification
        // but before notification registration completes.
        let afterRegistration = verify(
            checkpoint,
            insertedUTF16Count: insertedUTF16Count
        )
        if Self.isTerminalVerification(afterRegistration) {
            completeVerificationWait(id: id, result: afterRegistration)
            return
        }

        Task { [weak self] in
            guard let self else { return }
            await self.timeoutSleep(timeoutNanoseconds)
            let result = self.verify(
                checkpoint,
                insertedUTF16Count: insertedUTF16Count
            )
            self.completeVerificationWait(id: id, result: result)
        }
    }

    private func handleVerificationNotification(for element: AXUIElement) {
        let waits = lock.withLock {
            activeVerificationWaits.filter {
                CFEqual($0.value.element, element)
            }
        }
        for (id, wait) in waits {
            let result = verify(
                wait.checkpoint,
                insertedUTF16Count: wait.insertedUTF16Count
            )
            if Self.isTerminalVerification(result) {
                completeVerificationWait(id: id, result: result)
            }
        }
    }

    private static func isTerminalVerification(
        _ result: TextInsertionVerification
    ) -> Bool {
        switch result {
        case .verified, .verifiedWithoutUndo, .targetChanged:
            true
        case .unchanged, .unavailable:
            false
        }
    }

    private func cancelVerificationWait(id: UUID) {
        let registration: ActiveVerificationWait? = lock.withLock {
            if let registration = activeVerificationWaits.removeValue(
                forKey: id
            ) {
                return registration
            }
            if pendingVerificationWaits.remove(id) != nil {
                cancelledVerificationWaits.insert(id)
            }
            return nil
        }
        guard let registration else { return }
        finishVerificationWait(
            registration,
            result: .unavailable
        )
    }

    private func completeVerificationWait(
        id: UUID,
        result: TextInsertionVerification
    ) {
        guard let registration = lock.withLock({
            activeVerificationWaits.removeValue(forKey: id)
        }) else {
            return
        }
        finishVerificationWait(registration, result: result)
    }

    private func finishVerificationWait(
        _ registration: ActiveVerificationWait,
        result: TextInsertionVerification
    ) {
        Task { @MainActor in
            registration.notificationToken?.invalidate()
            registration.continuation.resume(returning: result)
        }
    }

    private static func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return nil
        }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func allowsAutomaticPasteRetry(for element: AXUIElement) -> Bool {
        var processIdentifier: pid_t = 0
        guard AXUIElementGetPid(element, &processIdentifier) == .success,
              let bundleIdentifier = NSRunningApplication(
                processIdentifier: processIdentifier
              )?.bundleIdentifier
        else {
            // An unknown accessibility surface is not enough evidence to
            // safely send the same paste a second time.
            return false
        }
        return !TerminalPastePolicy.bundleIdentifiers.contains(bundleIdentifier)
    }

    private static func selection(of element: AXUIElement) -> NSRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXValueGetTypeID()
        else {
            return nil
        }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }
}

private enum TerminalPastePolicy {
    static let bundleIdentifiers: Set<String> = [
        "com.apple.Terminal",
        "com.github.wez.wezterm",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty",
    ]
}

private struct PasteboardTransaction: @unchecked Sendable {
    let snapshot: PasteboardSnapshot
    let ownedChangeCount: Int
}

private struct PasteboardSnapshot: @unchecked Sendable {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    init(pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }

        let restoredItems = items.map { contents in
            let item = NSPasteboardItem()
            for (type, data) in contents {
                item.setData(data, forType: type)
            }
            return item
        }
        _ = pasteboard.writeObjects(restoredItems)
    }
}

private extension TextInjector {
    static func postPasteShortcut() throws {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard
            let commandDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: 55,
                keyDown: true
            ),
            let pasteDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: 9,
                keyDown: true
            ),
            let pasteUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: 9,
                keyDown: false
            ),
            let commandUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: 55,
                keyDown: false
            )
        else {
            throw TextInsertionError.pasteEventCreationFailed
        }
        commandDown.flags = .maskCommand
        pasteDown.flags = .maskCommand
        pasteUp.flags = .maskCommand
        commandDown.post(tap: .cgSessionEventTap)
        pasteDown.post(tap: .cgSessionEventTap)
        pasteUp.post(tap: .cgSessionEventTap)
        commandUp.post(tap: .cgSessionEventTap)
    }
}
