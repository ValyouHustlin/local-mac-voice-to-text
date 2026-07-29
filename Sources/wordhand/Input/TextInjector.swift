import AppKit
import Carbon
import CoreGraphics
import Foundation
import WordhandCore

protocol TextEventPosting: Sendable {
    func postUnicode(_ text: String)
    func postPasteShortcut() throws
}

struct CGTextEventPoster: TextEventPosting {
    func postUnicode(_ text: String) {
        TextInjector.inject(text)
    }

    func postPasteShortcut() throws {
        try TextInjector.postPasteShortcut()
    }
}

/// Posts a string of text at the current cursor location by synthesizing
/// keyboard events with `CGEventKeyboardSetUnicodeString`. Works in nearly
/// every text field on macOS; some Electron apps and secure password fields
/// can drop characters (platform constraint).
enum TextInjector {
    /// Inject the given text at the current cursor location.
    /// Splits long strings into chunks because the underlying API has a
    /// per-event character limit (~20 chars).
    static func inject(_ text: String) {
        guard !text.isEmpty else { return }

        let utf16 = Array(text.utf16)
        let chunkSize = 20
        var index = 0

        while index < utf16.count {
            let end = min(index + chunkSize, utf16.count)
            var chunk = Array(utf16[index..<end])
            postChunk(&chunk)
            index = end
        }
    }

    private static func postChunk(_ chunk: inout [UniChar]) {
        let length = chunk.count
        guard length > 0 else { return }

        let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
        down?.keyboardSetUnicodeString(stringLength: length, unicodeString: &chunk)
        down?.post(tap: .cgSessionEventTap)

        let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        up?.keyboardSetUnicodeString(stringLength: length, unicodeString: &chunk)
        up?.post(tap: .cgSessionEventTap)
    }
}

struct MacTextInserter: TextInserting, @unchecked Sendable {
    private let eventPoster: any TextEventPosting
    private let secureInputEnabled: @Sendable () -> Bool

    init(
        eventPoster: any TextEventPosting = CGTextEventPoster(),
        secureInputEnabled: @escaping @Sendable () -> Bool = {
            IsSecureEventInputEnabled()
        }
    ) {
        self.eventPoster = eventPoster
        self.secureInputEnabled = secureInputEnabled
    }

    func insert(_ text: String, mode: InsertionMode) async throws {
        guard !text.isEmpty else { return }

        switch mode {
        case .unicode:
            guard !secureInputEnabled() else {
                throw TextInsertionError.secureInputEnabled
            }
            eventPoster.postUnicode(text)

        case .copyOnly:
            try await MainActor.run {
                let pasteboard = NSPasteboard.general
                let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
                pasteboard.clearContents()
                guard pasteboard.setString(text, forType: .string) else {
                    snapshot.restore(to: pasteboard)
                    throw TextInsertionError.clipboardWriteFailed
                }
            }

        case .paste:
            guard !secureInputEnabled() else {
                throw TextInsertionError.secureInputEnabled
            }

            let transaction = try await MainActor.run {
                let pasteboard = NSPasteboard.general
                let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
                pasteboard.clearContents()
                guard pasteboard.setString(text, forType: .string) else {
                    snapshot.restore(to: pasteboard)
                    throw TextInsertionError.clipboardWriteFailed
                }
                let ownedChangeCount = pasteboard.changeCount
                do {
                    try eventPoster.postPasteShortcut()
                } catch {
                    snapshot.restore(to: pasteboard)
                    throw error
                }
                return PasteboardTransaction(
                    snapshot: snapshot,
                    ownedChangeCount: ownedChangeCount
                )
            }

            // Give browser/Electron targets time to consume the paste before
            // returning the user's rich clipboard contents.
            try? await Task.sleep(nanoseconds: 180_000_000)
            await MainActor.run {
                let pasteboard = NSPasteboard.general
                guard PasteboardRestorationPolicy.shouldRestore(
                    ownedChangeCount: transaction.ownedChangeCount,
                    currentChangeCount: pasteboard.changeCount
                ) else {
                    return
                }
                transaction.snapshot.restore(to: pasteboard)
            }
        }
    }
}

enum TextInsertionError: LocalizedError {
    case secureInputEnabled
    case clipboardWriteFailed
    case pasteEventCreationFailed

    var errorDescription: String? {
        switch self {
        case .secureInputEnabled:
            return "Secure Input is active. The transcript is safe in History, but macOS blocked insertion."
        case .clipboardWriteFailed:
            return "Wordhand couldn’t place the transcript on the clipboard."
        case .pasteEventCreationFailed:
            return "Wordhand couldn’t create the Command-V event."
        }
    }
}

private struct PasteboardTransaction: @unchecked Sendable {
    let snapshot: PasteboardSnapshot
    let ownedChangeCount: Int
}

private struct PasteboardSnapshot: @unchecked Sendable {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    init(pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }

        let restoredItems = items.map { contents in
            let item = NSPasteboardItem()
            for (type, data) in contents {
                item.setData(data, forType: type)
            }
            return item
        }
        _ = pasteboard.writeObjects(restoredItems)
    }
}

private extension TextInjector {
    static func postPasteShortcut() throws {
        guard
            let down = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true),
            let up = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false)
        else {
            throw TextInsertionError.pasteEventCreationFailed
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }
}
