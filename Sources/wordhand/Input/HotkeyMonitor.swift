import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import WordhandCore

protocol HotkeyTapControlling: AnyObject {
    func setEnabled(_ enabled: Bool)
    func stop()
}

protocol HotkeyTapInstalling {
    func install(for monitor: HotkeyMonitor) throws -> any HotkeyTapControlling
}

/// Watches configured global shortcuts and emits recording press/release edges.
/// Requires Accessibility permission. Bindings can be replaced while running.
final class HotkeyMonitor: HotkeyMonitoring {
    enum HotkeyError: Error { case tapCreateFailed }

    private let debug: Bool
    private let tapInstaller: any HotkeyTapInstalling
    private var onEvent: ((HotkeyEvent) -> Void)?
    private var tapController: (any HotkeyTapControlling)?
    private var bindings: [HotkeyBinding]
    private var stateMachine: HotkeyRoutingStateMachine
    private var isSuspended = false

    init(
        bindings: [HotkeyBinding],
        debug: Bool = false,
        tapInstaller: any HotkeyTapInstalling = CGHotkeyTapInstaller()
    ) {
        self.bindings = bindings
        self.stateMachine = HotkeyRoutingStateMachine(bindings: bindings)
        self.debug = debug
        self.tapInstaller = tapInstaller
    }

    func updateBindings(_ bindings: [HotkeyBinding]) {
        guard bindings != self.bindings else { return }
        self.bindings = bindings
        if let edge = stateMachine.updateBindings(bindings) {
            onEvent?(edge)
        }
    }

    func setSuspended(_ suspended: Bool) {
        guard isSuspended != suspended else { return }
        isSuspended = suspended
        if suspended, let edge = stateMachine.updateBindings(bindings) {
            onEvent?(edge)
        }
    }

    func cancelActiveRecording() {
        stateMachine.cancelActive()
    }

    fileprivate func reenableEventTap() {
        tapController?.setEnabled(true)
    }

    func start(onEvent: @escaping (HotkeyEvent) -> Void) throws {
        self.onEvent = onEvent
        do {
            tapController = try tapInstaller.install(for: self)
        } catch {
            self.onEvent = nil
            throw error
        }
    }

    func stop() {
        tapController?.stop()
        tapController = nil
        onEvent = nil
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Bool {
        guard !isSuspended else { return false }
        if debug {
            let flags = event.flags
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            FileHandle.standardError.write(
                Data(
                    "  [debug] type=\(type.rawValue) keycode=\(keycode) flags=\(String(flags.rawValue, radix: 16))\n"
                        .utf8
                ))
        }
        guard let kind = Self.inputKind(for: type) else { return false }
        let input = HotkeyInput(
            kind: kind,
            keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)),
            modifiers: Self.modifiers(from: event.flags),
            isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        )
        let shouldConsume = stateMachine.shouldConsume(input)
        if let edge = stateMachine.handle(input) {
            onEvent?(edge)
        }
        return shouldConsume
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

private struct CGHotkeyTapInstaller: HotkeyTapInstalling {
    func install(for monitor: HotkeyMonitor) throws -> any HotkeyTapControlling {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let trusted = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        if !trusted {
            FileHandle.standardError.write(Data(
                "accessibility not granted — system prompt opened. Grant access, then quit and relaunch wordhand.\n".utf8
            ))
            throw HotkeyMonitor.HotkeyError.tapCreateFailed
        }

        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
        let userInfo = Unmanaged.passUnretained(monitor).toOpaque()

        // .cgSessionEventTap is the right level for an accessibility-granted
        // user process (.cghidEventTap requires root).
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: hotkeyCallback,
                userInfo: userInfo
            )
        else {
            throw HotkeyMonitor.HotkeyError.tapCreateFailed
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CGEvent.tapEnable(tap: tap, enable: false)
            throw HotkeyMonitor.HotkeyError.tapCreateFailed
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return CGHotkeyTapController(tap: tap, runLoopSource: source)
    }
}

private final class CGHotkeyTapController: HotkeyTapControlling {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    init(tap: CFMachPort, runLoopSource: CFRunLoopSource) {
        self.tap = tap
        self.runLoopSource = runLoopSource
    }

    func setEnabled(_ enabled: Bool) {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: enabled)
        }
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
    }

    deinit {
        stop()
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
        monitor.reenableEventTap()
        return Unmanaged.passUnretained(event)
    }

    return monitor.handle(type: type, event: event)
        ? nil
        : Unmanaged.passUnretained(event)
}
