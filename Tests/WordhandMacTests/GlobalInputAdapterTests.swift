import Foundation
import Testing
import WordhandCore
@testable import wordhand

@Suite
struct GlobalInputAdapterTests {
    @Test
    func hotkeyMonitorUsesInjectedTapAndStopsItWithoutInstallingAGlobalTap() throws {
        let controller = FakeHotkeyTapController()
        let installer = FakeHotkeyTapInstaller(controller: controller)
        let monitor = HotkeyMonitor(
            bindings: [
                HotkeyBinding(
                    key: "z",
                    keyCode: 6,
                    modifiers: ["control", "option"],
                    action: .toggleRecording
                ),
            ],
            tapInstaller: installer
        )

        try monitor.start { _ in }
        #expect(installer.installCount == 1)
        #expect(!controller.didStop)

        monitor.stop()
        #expect(controller.didStop)
    }

    @Test
    func textInserterUsesInjectedPosterWithoutPostingSyntheticEvents() async throws {
        let poster = FakeTextEventPoster()
        let inserter = MacTextInserter(
            eventPoster: poster,
            secureInputEnabled: { false }
        )

        try await inserter.insert("local only", mode: .unicode)

        #expect(poster.unicodeTexts == ["local only"])
        #expect(poster.pasteShortcutCount == 0)
    }
}

private final class FakeHotkeyTapController: HotkeyTapControlling {
    private(set) var didStop = false

    func setEnabled(_ enabled: Bool) {}

    func stop() {
        didStop = true
    }
}

private final class FakeHotkeyTapInstaller: HotkeyTapInstalling {
    let controller: FakeHotkeyTapController
    private(set) var installCount = 0

    init(controller: FakeHotkeyTapController) {
        self.controller = controller
    }

    func install(for monitor: HotkeyMonitor) throws -> any HotkeyTapControlling {
        installCount += 1
        return controller
    }
}

private final class FakeTextEventPoster: TextEventPosting, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var unicodeTexts: [String] = []
    private(set) var pasteShortcutCount = 0

    func postUnicode(_ text: String) {
        lock.withLock {
            unicodeTexts.append(text)
        }
    }

    func postPasteShortcut() throws {
        lock.withLock {
            pasteShortcutCount += 1
        }
    }
}
