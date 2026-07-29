import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import WordhandCore

/// Watches Control-Space globally and emits push-to-talk press/release edges.
/// Requires Accessibility permission. If the tap fails to register, callers
/// will see an error from `start()`.
final class HotkeyMonitor: HotkeyMonitoring {
    enum HotkeyError: Error { case tapCreateFailed }

    private let debug: Bool
    private var onEvent: ((HotkeyEvent) -> Void)?
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var stateMachine = PushToTalkStateMachine()

    init(debug: Bool = false) {
        self.debug = debug
    }

    func start(onEvent: @escaping (HotkeyEvent) -> Void) throws {
        self.onEvent = onEvent

        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let trusted = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        if !trusted {
            FileHandle.standardError.write(Data(
                "accessibility not granted — system prompt opened. Grant access, then quit and relaunch wordhand.\n".utf8
            ))
            throw HotkeyError.tapCreateFailed
        }

        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        // .cgSessionEventTap is the right level for an accessibility-granted
        // user process (.cghidEventTap requires root).
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: mask,
                callback: hotkeyCallback,
                userInfo: userInfo
            )
        else {
            throw HotkeyError.tapCreateFailed
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.runLoopSource = source
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        onEvent = nil
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        if debug {
            let flags = event.flags
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            FileHandle.standardError.write(
                Data(
                    "  [debug] type=\(type.rawValue) keycode=\(keycode) flags=\(String(flags.rawValue, radix: 16))\n"
                        .utf8
                ))
        }
        guard let kind = Self.inputKind(for: type) else { return }
        let input = HotkeyInput(
            kind: kind,
            keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)),
            modifiers: Self.modifiers(from: event.flags)
        )
        if let edge = stateMachine.handle(input) {
            onEvent?(edge)
        }
    }

    private static func inputKind(for type: CGEventType) -> HotkeyInputKind? {
        switch type {
        case .keyDown: return .keyDown
        case .keyUp: return .keyUp
        case .flagsChanged: return .flagsChanged
        default: return nil
        }
    }

    private static func modifiers(from flags: CGEventFlags) -> Set<HotkeyModifier> {
        var modifiers = Set<HotkeyModifier>()
        if flags.contains(.maskControl) { modifiers.insert(.control) }
        if flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        if flags.contains(.maskCommand) { modifiers.insert(.command) }
        if flags.contains(.maskSecondaryFn) { modifiers.insert(.function) }
        return modifiers
    }
}

private func hotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        // System disabled our tap; we'll need to re-enable. For now just no-op
        // and let the user restart wordhand.
        return Unmanaged.passUnretained(event)
    }

    let copy = event.copy()
    DispatchQueue.main.async {
        if let copy {
            monitor.handle(type: type, event: copy)
        }
    }
    return Unmanaged.passUnretained(event)
}
