import Foundation

public enum DiagnosticSeverity: String, Codable, CaseIterable, Sendable {
    case info
    case warning
    case error
}

public struct OperationalDiagnosticEvent: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let occurredAt: Date
    public let severity: DiagnosticSeverity
    public let name: String
    public let sessionID: UUID
    public let dictationID: UUID?
    public let metrics: [String: Double]
    public let attributes: [String: String]

    public init(
        id: UUID = UUID(),
        occurredAt: Date = Date(),
        severity: DiagnosticSeverity,
        name: String,
        sessionID: UUID,
        dictationID: UUID? = nil,
        metrics: [String: Double] = [:],
        attributes: [String: String] = [:]
    ) {
        self.id = id
        self.occurredAt = occurredAt
        self.severity = severity
        self.name = name
        self.sessionID = sessionID
        self.dictationID = dictationID
        self.metrics = metrics
        self.attributes = attributes
    }
}

public struct OperationalDiagnosticsStorageReport: Equatable, Sendable {
    public let fileCount: Int
    public let totalBytes: Int64
    public let oldestEventAt: Date?
    public let newestEventAt: Date?
}

public struct OperationalDiagnosticsReport: Equatable, Sendable {
    public let generatedAt: Date
    public let eventCount: Int
    public let malformedLineCount: Int
    public let sessionCount: Int
    public let dictationCount: Int
    public let completedDictationCount: Int
    public let cancelledDictationCount: Int
    public let transcriptionCount: Int
    public let insertionCount: Int
    public let failureCount: Int
    public let warningCount: Int
    public let tailAuditCount: Int
    public let tailRecoveryCount: Int
    public let averageAudioSeconds: Double?
    public let averageCaptureRMS: Double?
    public let p95ClippedSampleFraction: Double?
    public let averageActiveWindowFraction: Double?
    public let averageTranscriptionSeconds: Double?
    public let medianTranscriptionSeconds: Double?
    public let p95TranscriptionSeconds: Double?
    public let averageProcessingSeconds: Double?
    public let averageInsertionSeconds: Double?
    public let p95TotalSeconds: Double?
    public let failuresByName: [String: Int]
    public let eventsByName: [String: Int]
    public let tailOutcomes: [String: Int]
    public let models: [String: Int]
    public let targetApplications: [String: Int]
}

public enum OperationalDiagnosticsError: Error, Equatable {
    case invalidConfiguration
    case fileWriteFailed
    case privatePayloadKey(String)
    case exportOverwritesStore
}

public final class OperationalDiagnosticsStore: @unchecked Sendable {
    public static let defaultRetentionDays = 90
    public static let defaultMaximumBytes: Int64 = 250_000_000

    public let directoryURL: URL
    public let retentionDays: Int
    public let maximumBytes: Int64

    private let fileManager: FileManager
    private let now: () -> Date
    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let dayFormatter: DateFormatter
    private let retentionCalendar: Calendar

    public init(
        directoryURL: URL = OperationalDiagnosticsStore.defaultDirectoryURL(),
        retentionDays: Int = OperationalDiagnosticsStore.defaultRetentionDays,
        maximumBytes: Int64 = OperationalDiagnosticsStore.defaultMaximumBytes,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = { Date() }
    ) throws {
        guard retentionDays >= 1, maximumBytes >= 1 else {
            throw OperationalDiagnosticsError.invalidConfiguration
        }
        self.directoryURL = directoryURL
        self.retentionDays = retentionDays
        self.maximumBytes = maximumBytes
        self.fileManager = fileManager
        self.now = now

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
        let dayFormatter = DateFormatter()
        dayFormatter.calendar = Calendar(identifier: .gregorian)
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        dayFormatter.dateFormat = "yyyy-MM-dd"
        self.dayFormatter = dayFormatter
        var retentionCalendar = Calendar(identifier: .gregorian)
        retentionCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        self.retentionCalendar = retentionCalendar

        try createDirectoryIfNeeded()
        try lock.withLock {
            try maintainStorage(referenceDate: now())
        }
    }

    public static func defaultDirectoryURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        ApplicationData.defaultDirectory(homeDirectory: homeDirectory)
            .appendingPathComponent("Diagnostics", isDirectory: true)
    }

    public func append(_ event: OperationalDiagnosticEvent) throws {
        try lock.withLock {
            if let forbiddenKey = event.attributes.keys.first(where: {
                Self.forbiddenPayloadAttributeKeys.contains($0.lowercased())
            }) {
                throw OperationalDiagnosticsError.privatePayloadKey(forbiddenKey)
            }
            try createDirectoryIfNeeded()
            let fileURL = dailyFileURL(for: event.occurredAt)
            let data = try encoder.encode(event) + Data([0x0A])
            if !fileManager.fileExists(atPath: fileURL.path) {
                guard fileManager.createFile(
                    atPath: fileURL.path,
                    contents: nil,
                    attributes: [.posixPermissions: 0o600]
                ) else {
                    throw OperationalDiagnosticsError.fileWriteFailed
                }
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
            try maintainStorage(referenceDate: now())
        }
    }

    public func events() throws -> [OperationalDiagnosticEvent] {
        try lock.withLock {
            try readAll().events.sorted {
                if $0.occurredAt != $1.occurredAt {
                    return $0.occurredAt < $1.occurredAt
                }
                return $0.id.uuidString < $1.id.uuidString
            }
        }
    }

    public func report() throws -> OperationalDiagnosticsReport {
        try lock.withLock {
            let read = try readAll()
            let events = read.events
            let sessions = Set(events.map(\.sessionID))
            let dictations = Set(events.compactMap(\.dictationID))
            let failures = events.filter { $0.severity == .error }
            let warnings = events.filter { $0.severity == .warning }
            let completedDictations = events.filter {
                $0.name == "dictation.completed"
            }
            let cancelledDictations = events.filter {
                $0.name == "dictation.cancelled"
            }
            let transcriptions = events.filter {
                $0.name == "transcription.completed"
            }
            let captures = events.filter { $0.name == "capture.completed" }
            let insertions = events.filter { $0.name == "insertion.completed" }
            let tailAudits = transcriptions.filter {
                $0.attributes["tail_outcome"] != nil
                    && $0.attributes["tail_outcome"] != "not_audited"
            }
            let tailRecoveries = tailAudits.filter {
                ["merged", "full_retry_recovered"].contains(
                    $0.attributes["tail_outcome"]
                )
            }
            let transcriptionDurations = transcriptions.compactMap {
                $0.metrics["transcription_seconds"]
            }
            let totalDurations = completedDictations.compactMap {
                $0.metrics["total_seconds"]
            }

            return OperationalDiagnosticsReport(
                generatedAt: now(),
                eventCount: events.count,
                malformedLineCount: read.malformedLineCount,
                sessionCount: sessions.count,
                dictationCount: dictations.count,
                completedDictationCount: completedDictations.count,
                cancelledDictationCount: cancelledDictations.count,
                transcriptionCount: transcriptions.count,
                insertionCount: insertions.count,
                failureCount: failures.count,
                warningCount: warnings.count,
                tailAuditCount: tailAudits.count,
                tailRecoveryCount: tailRecoveries.count,
                averageAudioSeconds: Self.average(
                    captures.compactMap { $0.metrics["audio_seconds"] }
                ),
                averageCaptureRMS: Self.average(
                    captures.compactMap { $0.metrics["rms"] }
                ),
                p95ClippedSampleFraction: Self.percentile(
                    captures.compactMap {
                        $0.metrics["clipped_sample_fraction"]
                    },
                    percentile: 0.95
                ),
                averageActiveWindowFraction: Self.average(
                    captures.compactMap {
                        $0.metrics["active_window_fraction"]
                    }
                ),
                averageTranscriptionSeconds: Self.average(
                    transcriptionDurations
                ),
                medianTranscriptionSeconds: Self.percentile(
                    transcriptionDurations,
                    percentile: 0.5
                ),
                p95TranscriptionSeconds: Self.percentile(
                    transcriptionDurations,
                    percentile: 0.95
                ),
                averageProcessingSeconds: Self.average(
                    events.compactMap { $0.metrics["processing_seconds"] }
                ),
                averageInsertionSeconds: Self.average(
                    insertions.compactMap { $0.metrics["insertion_seconds"] }
                ),
                p95TotalSeconds: Self.percentile(
                    totalDurations,
                    percentile: 0.95
                ),
                failuresByName: Self.counts(failures.map(\.name)),
                eventsByName: Self.counts(events.map(\.name)),
                tailOutcomes: Self.counts(
                    transcriptions.compactMap {
                        $0.attributes["tail_outcome"]
                    }
                ),
                models: Self.counts(
                    transcriptions.compactMap { $0.attributes["model_id"] }
                ),
                targetApplications: Self.counts(
                    events
                        .filter { $0.name == "dictation.started" }
                        .compactMap { $0.attributes["target_app"] }
                        .filter { $0 != "unknown" }
                )
            )
        }
    }

    public func storageReport() throws -> OperationalDiagnosticsStorageReport {
        try lock.withLock {
            let files = try logFiles()
            let bytes = try files.reduce(into: Int64(0)) { total, file in
                let values = try file.resourceValues(forKeys: [.fileSizeKey])
                total += Int64(values.fileSize ?? 0)
            }
            let read = try read(files: files)
            return OperationalDiagnosticsStorageReport(
                fileCount: files.count,
                totalBytes: bytes,
                oldestEventAt: read.events.map(\.occurredAt).min(),
                newestEventAt: read.events.map(\.occurredAt).max()
            )
        }
    }

    @discardableResult
    public func clear() throws -> Int {
        try lock.withLock {
            let files = try logFiles()
            for file in files {
                try fileManager.removeItem(at: file)
            }
            return files.count
        }
    }

    public func export(to outputURL: URL) throws {
        try lock.withLock {
            let files = try logFiles()
            let standardizedOutput = outputURL.standardizedFileURL
            guard !files.contains(where: {
                $0.standardizedFileURL == standardizedOutput
            }) else {
                throw OperationalDiagnosticsError.exportOverwritesStore
            }
            let parent = outputURL.deletingLastPathComponent()
            try fileManager.createDirectory(
                at: parent,
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: outputURL.path) {
                try fileManager.removeItem(at: outputURL)
            }
            guard fileManager.createFile(
                atPath: outputURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw OperationalDiagnosticsError.fileWriteFailed
            }
            let output = try FileHandle(forWritingTo: outputURL)
            defer { try? output.close() }
            for file in files {
                try output.write(contentsOf: Data(contentsOf: file))
            }
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: outputURL.path
            )
        }
    }

    private func createDirectoryIfNeeded() throws {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )
    }

    private func maintainStorage(referenceDate: Date) throws {
        let cutoff = retentionCalendar.date(
            byAdding: .day,
            value: -retentionDays,
            to: referenceDate
        ) ?? referenceDate
        var files = try logFiles()
        for file in files {
            guard let fileDate = dateFromFileName(file),
                  fileDate < retentionCalendar.startOfDay(for: cutoff)
            else {
                continue
            }
            try fileManager.removeItem(at: file)
        }

        files = try logFiles()
        var sizes: [(url: URL, bytes: Int64)] = try files.map { file in
            let values = try file.resourceValues(forKeys: [.fileSizeKey])
            return (file, Int64(values.fileSize ?? 0))
        }
        var total = sizes.reduce(into: Int64(0)) { $0 += $1.bytes }
        while total > maximumBytes, sizes.count > 1 {
            guard let oldest = sizes.first else { break }
            try fileManager.removeItem(at: oldest.url)
            total -= oldest.bytes
            sizes.removeFirst()
        }
        if total > maximumBytes, let remaining = sizes.first {
            try trimToNewestCompleteLines(
                file: remaining.url,
                maximumBytes: maximumBytes
            )
        }
    }

    private func readAll() throws
        -> (events: [OperationalDiagnosticEvent], malformedLineCount: Int)
    {
        try read(files: logFiles())
    }

    private func read(files: [URL]) throws
        -> (events: [OperationalDiagnosticEvent], malformedLineCount: Int)
    {
        var events: [OperationalDiagnosticEvent] = []
        var malformedLineCount = 0
        for file in files {
            let data = try Data(contentsOf: file)
            for line in data.split(separator: 0x0A) where !line.isEmpty {
                do {
                    events.append(
                        try decoder.decode(
                            OperationalDiagnosticEvent.self,
                            from: Data(line)
                        )
                    )
                } catch {
                    malformedLineCount += 1
                }
            }
        }
        return (events, malformedLineCount)
    }

    private func logFiles() throws -> [URL] {
        guard fileManager.fileExists(atPath: directoryURL.path) else {
            return []
        }
        return try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        .filter {
            $0.pathExtension == "jsonl"
                && dateFromFileName($0) != nil
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func dailyFileURL(for date: Date) -> URL {
        directoryURL.appendingPathComponent(
            "wordhand-\(dayFormatter.string(from: date)).jsonl"
        )
    }

    private func dateFromFileName(_ file: URL) -> Date? {
        let name = file.deletingPathExtension().lastPathComponent
        guard name.hasPrefix("wordhand-") else { return nil }
        return dayFormatter.date(
            from: String(name.dropFirst("wordhand-".count))
        )
    }

    private static func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func counts(_ values: [String]) -> [String: Int] {
        Dictionary(values.map { ($0, 1) }, uniquingKeysWith: +)
    }

    private static func percentile(
        _ values: [Double],
        percentile: Double
    ) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = max(
            0,
            min(
                sorted.count - 1,
                Int(ceil(percentile * Double(sorted.count))) - 1
            )
        )
        return sorted[rank]
    }

    private func trimToNewestCompleteLines(
        file: URL,
        maximumBytes: Int64
    ) throws {
        let data = try Data(contentsOf: file)
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        var kept: [Data.SubSequence] = []
        var keptBytes: Int64 = 0
        for line in lines.reversed() {
            let lineBytes = Int64(line.count + 1)
            guard keptBytes + lineBytes <= maximumBytes else { break }
            kept.append(line)
            keptBytes += lineBytes
        }

        var trimmed = Data()
        for line in kept.reversed() {
            trimmed.append(contentsOf: line)
            trimmed.append(0x0A)
        }
        try trimmed.write(to: file, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: file.path
        )
    }

    private static let forbiddenPayloadAttributeKeys: Set<String> = [
        "audio",
        "audio_data",
        "audio_samples",
        "dictionary",
        "prompt",
        "processed_text",
        "raw_text",
        "samples",
        "system_prompt",
        "text",
        "transcript",
        "transcript_text",
        "vocabulary",
    ]
}
