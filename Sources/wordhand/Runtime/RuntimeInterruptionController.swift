import AppKit
import Foundation
import WordhandCore

@MainActor
final class DeferredTerminationPreparation {
    private let prepare: @MainActor () async -> Void
    private var task: Task<Void, Never>?
    private var didPrepare = false

    init(prepare: @escaping @MainActor () async -> Void) {
        self.prepare = prepare
    }

    func begin(completion: @escaping @MainActor () -> Void) {
        guard !didPrepare, task == nil else { return }
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            await prepare()
            didPrepare = true
            task = nil
            completion()
        }
    }
}

@MainActor
final class RuntimeInterruptionController {
    private let preserve:
        @MainActor (CaptureInterruptionReason) async -> Bool
    private let recoverPending: @MainActor () async -> Void
    private var sleepPreservationTask: Task<Bool, Never>?
    private var wakeRecoveryTask: Task<Void, Never>?
    private var isTerminating = false

    init(
        preserve: @escaping @MainActor (CaptureInterruptionReason) async -> Bool,
        recoverPending: @escaping @MainActor () async -> Void
    ) {
        self.preserve = preserve
        self.recoverPending = recoverPending
    }

    func prepareForApplicationQuit() async {
        isTerminating = true
        if let wakeRecoveryTask {
            await wakeRecoveryTask.value
            return
        }
        if let sleepPreservationTask {
            _ = await sleepPreservationTask.value
            return
        }
        _ = await preserve(.applicationQuit)
    }

    func systemWillSleep() {
        guard !isTerminating, sleepPreservationTask == nil else { return }
        sleepPreservationTask = Task { @MainActor [weak self] in
            guard let self else { return false }
            return await preserve(.systemSleep)
        }
    }

    func systemDidWake() {
        guard !isTerminating,
              let sleepPreservationTask,
              wakeRecoveryTask == nil
        else {
            return
        }
        wakeRecoveryTask = Task { @MainActor [weak self] in
            let didPreserve = await sleepPreservationTask.value
            guard let self else { return }
            guard !isTerminating else {
                self.sleepPreservationTask = nil
                wakeRecoveryTask = nil
                return
            }
            if didPreserve {
                await recoverPending()
            }
            self.sleepPreservationTask = nil
            wakeRecoveryTask = nil
        }
    }
}

@MainActor
final class SystemSleepObserver {
    private let notificationCenter: NotificationCenter
    private var tokens: [NSObjectProtocol] = []

    init(
        notificationCenter: NotificationCenter =
            NSWorkspace.shared.notificationCenter,
        willSleepName: Notification.Name = NSWorkspace.willSleepNotification,
        didWakeName: Notification.Name = NSWorkspace.didWakeNotification,
        onWillSleep: @escaping @MainActor () -> Void,
        onDidWake: @escaping @MainActor () -> Void
    ) {
        self.notificationCenter = notificationCenter
        tokens.append(notificationCenter.addObserver(
            forName: willSleepName,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                onWillSleep()
            }
        })
        tokens.append(notificationCenter.addObserver(
            forName: didWakeName,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                onDidWake()
            }
        })
    }

    deinit {
        for token in tokens {
            notificationCenter.removeObserver(token)
        }
    }
}
