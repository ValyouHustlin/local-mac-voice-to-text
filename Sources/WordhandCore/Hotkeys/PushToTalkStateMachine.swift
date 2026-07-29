import Foundation

public enum HotkeyInputKind: Sendable {
    case keyDown
    case keyUp
    case flagsChanged
}

public enum HotkeyModifier: String, Codable, Hashable, Sendable {
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
    public var isRepeat: Bool

    public init(
        kind: HotkeyInputKind,
        keyCode: UInt16 = 0,
        modifiers: Set<HotkeyModifier> = [],
        isRepeat: Bool = false
    ) {
        self.kind = kind
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.isRepeat = isRepeat
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
                !input.isRepeat,
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

/// Routes multiple configurable shortcuts into the coordinator's recording
/// edges. Push-to-talk bindings release with the physical key. Toggle bindings
/// release only when the same shortcut is tapped again.
public struct HotkeyRoutingStateMachine: Sendable {
    private var bindings: [HotkeyBinding]
    private var activeBindingIndex: Int?
    private var heldKeyCodes = Set<UInt16>()

    public init(bindings: [HotkeyBinding]) {
        self.bindings = bindings
    }

    public var isActive: Bool {
        activeBindingIndex != nil
    }

    @discardableResult
    public mutating func updateBindings(_ bindings: [HotkeyBinding]) -> HotkeyEvent? {
        let event: HotkeyEvent? = activeBindingIndex == nil ? nil : .released
        self.bindings = bindings
        activeBindingIndex = nil
        heldKeyCodes.removeAll()
        return event
    }

    public mutating func handle(_ input: HotkeyInput) -> HotkeyEvent? {
        switch input.kind {
        case .keyDown:
            guard !input.isRepeat, !heldKeyCodes.contains(input.keyCode) else {
                return nil
            }
            heldKeyCodes.insert(input.keyCode)

            if let activeBindingIndex {
                let active = bindings[activeBindingIndex]
                guard
                    active.action == .toggleRecording,
                    matches(active, input: input)
                else {
                    return nil
                }
                self.activeBindingIndex = nil
                return .released
            }

            guard let index = bindings.firstIndex(where: {
                Self.isRecordingAction($0.action) && matches($0, input: input)
            }) else {
                return nil
            }
            activeBindingIndex = index
            return .pressed

        case .keyUp:
            heldKeyCodes.remove(input.keyCode)
            guard let activeBindingIndex else { return nil }
            let active = bindings[activeBindingIndex]
            guard
                active.action == .pushToTalk,
                input.keyCode == active.keyCode
            else {
                return nil
            }
            self.activeBindingIndex = nil
            return .released

        case .flagsChanged:
            guard let activeBindingIndex else { return nil }
            let active = bindings[activeBindingIndex]
            guard
                active.action == .pushToTalk,
                !input.modifiers.isSuperset(of: active.resolvedModifiers)
            else {
                return nil
            }
            heldKeyCodes.remove(active.keyCode)
            self.activeBindingIndex = nil
            return .released
        }
    }

    private func matches(_ binding: HotkeyBinding, input: HotkeyInput) -> Bool {
        input.keyCode == binding.keyCode
            && input.modifiers == binding.resolvedModifiers
    }

    private static func isRecordingAction(_ action: HotkeyBinding.Action) -> Bool {
        action == .pushToTalk || action == .toggleRecording
    }
}
