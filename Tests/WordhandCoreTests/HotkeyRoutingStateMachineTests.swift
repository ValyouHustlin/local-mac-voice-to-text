import Testing
@testable import WordhandCore

@Suite
struct HotkeyRoutingStateMachineTests {
    @Test
    func toggleBindingStartsAndStopsOnSeparateTaps() {
        var state = HotkeyRoutingStateMachine(bindings: [
            HotkeyBinding(
                key: "space",
                keyCode: 49,
                modifiers: ["control"],
                action: .toggleRecording
            ),
        ])

        #expect(state.handle(keyDown(49, [.control])) == .pressed)
        #expect(state.handle(keyDown(49, [.control], isRepeat: true)) == nil)
        #expect(state.handle(keyUp(49, [.control])) == nil)
        #expect(state.handle(keyDown(49, [.control])) == .released)
        #expect(state.handle(keyUp(49, [.control])) == nil)
    }

    @Test
    func routesMultipleBindingsWithoutCrossReleasing() {
        var state = HotkeyRoutingStateMachine(bindings: [
            HotkeyBinding(
                key: "space",
                keyCode: 49,
                modifiers: ["control"],
                action: .toggleRecording
            ),
            HotkeyBinding(
                key: "k",
                keyCode: 40,
                modifiers: ["command", "shift"],
                action: .pushToTalk
            ),
        ])

        #expect(state.handle(keyDown(49, [.control])) == .pressed)
        #expect(state.handle(keyDown(40, [.command, .shift])) == nil)
        #expect(state.handle(keyUp(40, [.command, .shift])) == nil)
        #expect(state.handle(keyUp(49, [.control])) == nil)
        #expect(state.handle(keyDown(49, [.control])) == .released)

        #expect(state.handle(keyDown(40, [.command, .shift])) == .pressed)
        #expect(state.handle(keyUp(49, [.control])) == nil)
        #expect(state.handle(keyUp(40, [.command, .shift])) == .released)
    }

    @Test
    func replacingBindingsReleasesAnActiveRecording() {
        var state = HotkeyRoutingStateMachine(bindings: [
            HotkeyBinding(
                key: "space",
                keyCode: 49,
                modifiers: ["control"],
                action: .pushToTalk
            ),
        ])

        #expect(state.handle(keyDown(49, [.control])) == .pressed)
        #expect(state.updateBindings([
            HotkeyBinding(
                key: "d",
                keyCode: 2,
                modifiers: ["command", "shift"],
                action: .toggleRecording
            ),
        ]) == .released)
        #expect(state.handle(keyUp(49, [.control])) == nil)
        #expect(state.handle(keyDown(2, [.command, .shift])) == .pressed)
    }

    @Test
    func pushToTalkRecoversWhenARequiredModifierIsReleasedFirst() {
        var state = HotkeyRoutingStateMachine(bindings: [
            HotkeyBinding(
                key: "k",
                keyCode: 40,
                modifiers: ["command", "shift"],
                action: .pushToTalk
            ),
        ])

        #expect(state.handle(keyDown(40, [.command, .shift])) == .pressed)
        #expect(
            state.handle(
                HotkeyInput(
                    kind: .flagsChanged,
                    modifiers: [.command]
                )
            ) == .released
        )
    }

    private func keyDown(
        _ keyCode: UInt16,
        _ modifiers: Set<HotkeyModifier>,
        isRepeat: Bool = false
    ) -> HotkeyInput {
        HotkeyInput(
            kind: .keyDown,
            keyCode: keyCode,
            modifiers: modifiers,
            isRepeat: isRepeat
        )
    }

    private func keyUp(
        _ keyCode: UInt16,
        _ modifiers: Set<HotkeyModifier>
    ) -> HotkeyInput {
        HotkeyInput(kind: .keyUp, keyCode: keyCode, modifiers: modifiers)
    }
}
