import Foundation

/// A local, single-draft handoff between the containing iOS app and its keyboard.
///
/// The app writes an atomically replaced file inside their App Group container.
/// The keyboard removes only the exact draft it inserted, so an older keyboard
/// process cannot erase a newer recording that arrived during insertion.
public struct SharedTranscriptStore: Sendable {
    public static let fileName = "pending-transcript.json"
    public static let defaultMaximumAge: TimeInterval = 60 * 60

    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func save(_ draft: MobileTranscriptDraft) throws {
        let validated = try draft.validated()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(validated)
        try coordinateWrite(options: .forReplacing) { coordinatedURL in
            try data.write(
                to: coordinatedURL,
                options: [.atomic, .completeFileProtection]
            )
        }
    }

    public func pending(
        now: Date = Date(),
        maximumAge: TimeInterval = Self.defaultMaximumAge
    ) throws -> MobileTranscriptDraft? {
        guard let draft = try coordinatedDraft() else { return nil }

        guard now.timeIntervalSince(draft.createdAt) <= maximumAge else {
            _ = try? consume(id: draft.id)
            return nil
        }
        return draft
    }

    /// Removes a draft only if it is still the exact draft the caller inserted.
    @discardableResult
    public func consume(id: UUID) throws -> Bool {
        var consumed = false
        try coordinateWrite(options: .forDeleting) { coordinatedURL in
            guard FileManager.default.fileExists(atPath: coordinatedURL.path) else {
                return
            }
            let current = try decode(Data(contentsOf: coordinatedURL))
            guard current.id == id else { return }
            try FileManager.default.removeItem(at: coordinatedURL)
            consumed = true
        }
        return consumed
    }

    public func clear() throws {
        try coordinateWrite(options: .forDeleting) { coordinatedURL in
            guard FileManager.default.fileExists(atPath: coordinatedURL.path) else {
                return
            }
            try FileManager.default.removeItem(at: coordinatedURL)
        }
    }

    private func coordinatedDraft() throws -> MobileTranscriptDraft? {
        var result: MobileTranscriptDraft?
        try coordinateRead { coordinatedURL in
            guard FileManager.default.fileExists(atPath: coordinatedURL.path) else {
                return
            }
            result = try decode(Data(contentsOf: coordinatedURL))
        }
        return result
    }

    private func decode(_ data: Data) throws -> MobileTranscriptDraft {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(MobileTranscriptDraft.self, from: data).validated()
    }

    private func coordinateRead(
        _ operation: (URL) throws -> Void
    ) throws {
        var coordinationError: NSError?
        var operationError: Error?
        NSFileCoordinator().coordinate(
            readingItemAt: fileURL,
            options: [],
            error: &coordinationError
        ) { coordinatedURL in
            do {
                try operation(coordinatedURL)
            } catch {
                operationError = error
            }
        }
        if let operationError { throw operationError }
        if let coordinationError { throw coordinationError }
    }

    private func coordinateWrite(
        options: NSFileCoordinator.WritingOptions,
        _ operation: (URL) throws -> Void
    ) throws {
        var coordinationError: NSError?
        var operationError: Error?
        NSFileCoordinator().coordinate(
            writingItemAt: fileURL,
            options: options,
            error: &coordinationError
        ) { coordinatedURL in
            do {
                try operation(coordinatedURL)
            } catch {
                operationError = error
            }
        }
        if let operationError { throw operationError }
        if let coordinationError { throw coordinationError }
    }
}
