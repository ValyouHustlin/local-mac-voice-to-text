import Foundation

public enum HotkeyInputKind: Sendable {
    case keyDown
    case keyUp
    case flagsChanged
}

public enum HotkeyModifier: Hashable, Sendable {
    case control
    case option
    case shift
    case command
    case function
}

public struct HotkeyInput: Sendable {
    public var kind: HotkeyInputKind
    public var keyCode: UInt16
    public var modifiers: Set<HotkeyModifier>

    public init(
        kind: HotkeyInputKind,
        keyCode: UInt16 = 0,
        modifiers: Set<HotkeyModifier> = []
    ) {
        self.kind = kind
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

public struct HotkeyShortcut: Equatable, Sendable {
    public static let controlSpace = HotkeyShortcut(
        keyCode: 49,
        modifiers: [.control]
    )

    public var keyCode: UInt16
    public var modifiers: Set<HotkeyModifier>

    public init(keyCode: UInt16, modifiers: Set<HotkeyModifier>) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

/// Converts global keyboard input into one press and one release edge for a
/// push-to-talk shortcut. It also releases if a required modifier is lifted
/// before the primary key, preventing a stuck recording state.
public struct PushToTalkStateMachine: Sendable {
    public let shortcut: HotkeyShortcut
    public private(set) var isPressed = false

    public init(shortcut: HotkeyShortcut = .controlSpace) {
        self.shortcut = shortcut
    }

    public mutating func handle(_ input: HotkeyInput) -> HotkeyEvent? {
        switch input.kind {
        case .keyDown:
            guard
                input.keyCode == shortcut.keyCode,
                input.modifiers == shortcut.modifiers,
                !isPressed
            else { return nil }
            isPressed = true
            return .pressed

        case .keyUp:
            guard input.keyCode == shortcut.keyCode, isPressed else { return nil }
            isPressed = false
            return .released

        case .flagsChanged:
            guard isPressed, input.modifiers.isSuperset(of: shortcut.modifiers) == false else {
                return nil
            }
            isPressed = false
            return .released
        }
    }
}
