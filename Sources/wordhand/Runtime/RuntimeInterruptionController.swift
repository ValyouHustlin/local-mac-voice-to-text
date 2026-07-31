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
    private var sleepTask: Task<Void, Never>?

    init(
        preserve: @escaping @MainActor (CaptureInterruptionReason) async -> Bool,
        recoverPending: @escaping @MainActor () async -> Void
    ) {
        self.preserve = preserve
        self.recoverPending = recoverPending
    }

    func prepareForApplicationQuit() async {
        if let sleepTask {
            await sleepTask.value
            return
        }
        _ = await preserve(.applicationQuit)
    }

    func systemWillSleep() {
        guard sleepTask == nil else { return }
        sleepTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let didPreserve = await preserve(.systemSleep)
            if didPreserve {
                await recoverPending()
            }
            sleepTask = nil
        }
    }
}

@MainActor
final class SystemSleepObserver {
    private let notificationCenter: NotificationCenter
    private var token: NSObjectProtocol?

    init(
        notificationCenter: NotificationCenter =
            NSWorkspace.shared.notificationCenter,
        name: Notification.Name = NSWorkspace.willSleepNotification,
        onWillSleep: @escaping @MainActor () -> Void
    ) {
        self.notificationCenter = notificationCenter
        token = notificationCenter.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                onWillSleep()
            }
        }
    }

    deinit {
        if let token {
            notificationCenter.removeObserver(token)
        }
    }
}
