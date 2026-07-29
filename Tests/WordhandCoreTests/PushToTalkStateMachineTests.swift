import Testing
@testable import WordhandCore

@Suite
struct PushToTalkStateMachineTests {
    @Test
    func controlSpaceEmitsOnePressAndOneRelease() {
        var state = PushToTalkStateMachine()

        #expect(state.handle(keyDown(49, [.control])) == .pressed)
        #expect(state.handle(keyDown(49, [.control])) == nil)
        #expect(state.handle(keyUp(49, [.control])) == .released)
        #expect(state.handle(keyUp(49)) == nil)
    }

    @Test
    func rejectsSpaceWithoutExactControlModifier() {
        var state = PushToTalkStateMachine()

        #expect(state.handle(keyDown(49)) == nil)
        #expect(state.handle(keyDown(49, [.control, .shift])) == nil)
        #expect(state.handle(keyDown(36, [.control])) == nil)
        #expect(state.isPressed == false)
    }

    @Test
    func releasingControlFirstRecoversFromMissedSpaceRelease() {
        var state = PushToTalkStateMachine()

        #expect(state.handle(keyDown(49, [.control])) == .pressed)
        #expect(state.handle(HotkeyInput(kind: .flagsChanged)) == .released)
        #expect(state.isPressed == false)
        #expect(state.handle(keyUp(49)) == nil)
    }

    @Test
    func unrelatedModifierChangesDoNotReleaseActiveShortcut() {
        var state = PushToTalkStateMachine()

        #expect(state.handle(keyDown(49, [.control])) == .pressed)
        #expect(
            state.handle(HotkeyInput(kind: .flagsChanged, modifiers: [.control, .shift]))
                == nil
        )
        #expect(state.handle(keyUp(49, [.control])) == .released)
    }

    private func keyDown(
        _ keyCode: UInt16,
        _ modifiers: Set<HotkeyModifier> = []
    ) -> HotkeyInput {
        HotkeyInput(kind: .keyDown, keyCode: keyCode, modifiers: modifiers)
    }

    private func keyUp(
        _ keyCode: UInt16,
        _ modifiers: Set<HotkeyModifier> = []
    ) -> HotkeyInput {
        HotkeyInput(kind: .keyUp, keyCode: keyCode, modifiers: modifiers)
    }
}
