import ArgumentParser
import Foundation
import WordhandCore

struct DiagnosticsCommands: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diagnostics",
        abstract: "Inspect Wordhand's private 90-day operational diagnostics.",
        subcommands: [Status.self, Report.self, Export.self, Clear.self]
    )

    struct Status: ParsableCommand {
        func run() throws {
            let store = try OperationalDiagnosticsStore()
            let storage = try store.storageReport()
            print("retention: \(store.retentionDays) days")
            print(
                "storage: \(Self.bytes(storage.totalBytes)) / "
                    + "\(Self.bytes(store.maximumBytes))"
            )
            print("files: \(storage.fileCount)")
            if let oldest = storage.oldestEventAt {
                print("oldest event: \(oldest.formatted())")
            }
            if let newest = storage.newestEventAt {
                print("newest event: \(newest.formatted())")
            }
            print("location: \(store.directoryURL.path)")
            print("privacy: metadata only; no transcript text or audio")
        }

        private static func bytes(_ value: Int64) -> String {
            ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
        }
    }

    struct Report: ParsableCommand {
        func run() throws {
            let store = try OperationalDiagnosticsStore()
            print(Self.format(try store.report(), retentionDays: store.retentionDays))
        }

        static func format(
            _ report: OperationalDiagnosticsReport,
            retentionDays: Int
        ) -> String {
            var lines = [
                "Wordhand health report · \(retentionDays) days",
                "events: \(report.eventCount)",
                "app sessions: \(report.sessionCount)",
                "dictations: \(report.dictationCount)",
                "completed dictations: \(report.completedDictationCount)",
                "cancelled dictations: \(report.cancelledDictationCount)",
                "transcriptions: \(report.transcriptionCount)",
                "successful insertions: \(report.insertionCount)",
                "warnings: \(report.warningCount)",
                "failures: \(report.failureCount)",
                "tail audits: \(report.tailAuditCount)",
                "tail recoveries: \(report.tailRecoveryCount)",
                "full-buffer retries: \(report.fullRetryCount)",
            ]
            if let value = report.averageAudioSeconds {
                lines.append(String(format: "average audio: %.2fs", value))
            }
            if let value = report.averageCaptureRMS {
                lines.append(String(format: "average capture RMS: %.4f", value))
            }
            if let value = report.p95ClippedSampleFraction {
                lines.append(
                    String(format: "p95 clipped samples: %.3f%%", value * 100)
                )
            }
            if let value = report.averageActiveWindowFraction {
                lines.append(
                    String(
                        format: "average active-audio windows: %.1f%%",
                        value * 100
                    )
                )
            }
            if let value = report.averageTranscriptionSeconds {
                lines.append(String(format: "average transcription: %.2fs", value))
            }
            if let value = report.medianTranscriptionSeconds {
                lines.append(String(format: "median transcription: %.2fs", value))
            }
            if let value = report.p95TranscriptionSeconds {
                lines.append(String(format: "p95 transcription: %.2fs", value))
            }
            if let value = report.averagePrimaryDecodeSeconds {
                lines.append(String(format: "average primary decode: %.2fs", value))
            }
            if let value = report.averageTailAuditDecodeSeconds {
                lines.append(String(
                    format: "average tail-audit decode: %.2fs",
                    value
                ))
            }
            if let value = report.averageFullRetryDecodeSeconds {
                lines.append(String(
                    format: "average full-buffer retry decode: %.2fs",
                    value
                ))
            }
            if let value = report.averageCaptureDrainSeconds {
                lines.append(String(format: "average capture drain: %.3fs", value))
            }
            if let value = report.averageReleaseToRawTextSeconds {
                lines.append(String(
                    format: "average release to raw text: %.2fs",
                    value
                ))
            }
            if let value = report.averageReleaseToFormattedTextSeconds {
                lines.append(String(
                    format: "average release to formatted text: %.2fs",
                    value
                ))
            }
            if let value = report.medianReleaseToInsertionSeconds {
                lines.append(String(
                    format: "median release to insertion: %.2fs",
                    value
                ))
            }
            if let value = report.p95ReleaseToInsertionSeconds {
                lines.append(String(
                    format: "p95 release to insertion: %.2fs",
                    value
                ))
            }
            if let value = report.averageProcessingSeconds {
                lines.append(String(format: "average formatting: %.2fs", value))
            }
            if let value = report.averageInsertionSeconds {
                lines.append(String(format: "average insertion: %.3fs", value))
            }
            if let value = report.p95TotalSeconds {
                lines.append(String(
                    format: "p95 recording through completion: %.2fs",
                    value
                ))
            }
            if report.malformedLineCount > 0 {
                lines.append(
                    "malformed diagnostic lines: \(report.malformedLineCount)"
                )
            }
            if !report.failuresByName.isEmpty {
                lines.append("failure breakdown:")
                for item in report.failuresByName.sorted(by: {
                    if $0.value != $1.value { return $0.value > $1.value }
                    return $0.key < $1.key
                }) {
                    lines.append("  \(item.key): \(item.value)")
                }
            }
            appendBreakdown(
                title: "event breakdown",
                values: report.eventsByName,
                to: &lines
            )
            appendBreakdown(
                title: "tail outcomes",
                values: report.tailOutcomes,
                to: &lines
            )
            appendBreakdown(
                title: "models",
                values: report.models,
                to: &lines
            )
            appendBreakdown(
                title: "target applications",
                values: report.targetApplications,
                to: &lines
            )
            lines.append("privacy: metadata only; no transcript text or audio")
            return lines.joined(separator: "\n")
        }

        private static func appendBreakdown(
            title: String,
            values: [String: Int],
            to lines: inout [String]
        ) {
            guard !values.isEmpty else { return }
            lines.append("\(title):")
            for item in values.sorted(by: {
                if $0.value != $1.value { return $0.value > $1.value }
                return $0.key < $1.key
            }).prefix(10) {
                lines.append("  \(item.key): \(item.value)")
            }
        }
    }

    struct Export: ParsableCommand {
        @Argument(help: "Destination .jsonl file.")
        var path: String

        func run() throws {
            let output = URL(
                fileURLWithPath: NSString(string: path).expandingTildeInPath
            )
            let store = try OperationalDiagnosticsStore()
            try store.export(to: output)
            print("Exported private diagnostics to \(output.path)")
            print("The export contains metadata only; no transcript text or audio.")
        }
    }

    struct Clear: ParsableCommand {
        @Flag(name: .long, help: "Confirm permanent deletion of diagnostics.")
        var confirm = false

        func run() throws {
            guard confirm else {
                throw ValidationError(
                    "Pass --confirm to permanently delete local diagnostics."
                )
            }
            let removed = try OperationalDiagnosticsStore().clear()
            print("Deleted \(removed) local diagnostic file(s).")
        }
    }
}
