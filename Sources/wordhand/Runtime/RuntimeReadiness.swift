import Foundation
import WordhandCore

enum RuntimeReadinessPresentation: Equatable {
    case ready
    case permissionsRequired
    case microphoneRequired
    case modelPreparing
}

@MainActor
final class RuntimeReadiness {
    var hotkeyReady = false
    var microphoneReady = false
    var modelReady = false

    var canHandleDictation: Bool {
        hotkeyReady && microphoneReady && modelReady
    }

    func presentation(globalInputReady: Bool) -> RuntimeReadinessPresentation {
        guard globalInputReady, hotkeyReady else {
            return .permissionsRequired
        }
        guard microphoneReady else {
            return .microphoneRequired
        }
        guard modelReady else {
            return .modelPreparing
        }
        return .ready
    }

    func reconcilePermissions(
        globalInputReady: Bool,
        microphoneReady: Bool,
        startHotkey: () throws -> Void,
        stopHotkey: () -> Void
    ) throws -> RuntimeReadinessPresentation {
        self.microphoneReady = microphoneReady
        guard globalInputReady else {
            if hotkeyReady {
                stopHotkey()
                hotkeyReady = false
            }
            return .permissionsRequired
        }
        if !hotkeyReady {
            try startHotkey()
            hotkeyReady = true
        }
        return presentation(globalInputReady: true)
    }

    func route(
        _ event: HotkeyEvent,
        to handler: @MainActor (HotkeyEvent) async -> Void
    ) async {
        guard canHandleDictation else { return }
        await handler(event)
    }
}
