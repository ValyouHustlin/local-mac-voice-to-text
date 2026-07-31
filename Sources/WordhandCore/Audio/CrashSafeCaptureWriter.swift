import Foundation

/// Moves capture-journal writes off the real-time audio callback while exposing
/// the exact contiguous prefix that has reached the journal.
public final class CrashSafeCaptureWriter: @unchecked Sendable {
    private let journal: CrashSafeCaptureJournal
    private let queue: DispatchQueue
    private let pendingWrites = DispatchGroup()
    private let condition = NSCondition()
    private let beforeAppend: @Sendable (UInt64) -> Void

    private var accepting = false
    private var nextSequence: UInt64 = 0
    private var acknowledgedSequence: UInt64?
    private var failure: Error?

    public init(journal: CrashSafeCaptureJournal) {
        self.journal = journal
        self.queue = DispatchQueue(
            label: "com.valyou.wordhand.capture-recovery",
            qos: .userInitiated
        )
        self.beforeAppend = { _ in }
    }

    init(
        journal: CrashSafeCaptureJournal,
        queue: DispatchQueue = DispatchQueue(
            label: "com.valyou.wordhand.capture-recovery.test",
            qos: .userInitiated
        ),
        beforeAppend: @escaping @Sendable (UInt64) -> Void
    ) {
        self.journal = journal
        self.queue = queue
        self.beforeAppend = beforeAppend
    }

    public var lastAcknowledgedSequence: UInt64? {
        condition.withLock { acknowledgedSequence }
    }

    public func beginCapture(
        id: UUID,
        createdAt: Date,
        sampleRate: Int
    ) throws {
        try journal.beginCapture(
            id: id,
            createdAt: createdAt,
            sampleRate: sampleRate
        )
        condition.withLock {
            accepting = true
            nextSequence = 0
            acknowledgedSequence = nil
            failure = nil
            condition.broadcast()
        }
    }

    /// Enqueues one immutable audio chunk and returns its ordered sequence.
    /// The sequence is not crash-safe until `lastAcknowledgedSequence` reaches it.
    @discardableResult
    public func enqueue(_ samples: [Float]) -> UInt64? {
        guard !samples.isEmpty else { return nil }
        let sequence: UInt64? = condition.withLock {
            guard accepting, failure == nil else { return nil }
            let sequence = nextSequence
            nextSequence += 1
            pendingWrites.enter()
            return sequence
        }
        guard let sequence else { return nil }

        queue.async { [self] in
            defer { pendingWrites.leave() }
            guard condition.withLock({ failure == nil }) else { return }
            beforeAppend(sequence)
            guard condition.withLock({ failure == nil }) else { return }
            do {
                try journal.append(samples)
                condition.withLock {
                    acknowledgedSequence = sequence
                    condition.broadcast()
                }
            } catch {
                condition.withLock {
                    accepting = false
                    if failure == nil {
                        failure = error
                    }
                    condition.broadcast()
                }
            }
        }
        return sequence
    }

    /// Stops admission, drains every queued append, and synchronizes the
    /// journal. The journal remains recoverable until History commits.
    public func seal() async throws {
        condition.withLock {
            accepting = false
            condition.broadcast()
        }
        await waitForPendingWrites()
        if let failure = condition.withLock({ failure }) {
            throw failure
        }
        try journal.finishCapture()
    }

    /// A deterministic test/fixture seam for the process-death boundary.
    public func waitUntilAcknowledged(
        _ sequence: UInt64,
        timeout: TimeInterval
    ) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while acknowledgedSequence.map({ $0 < sequence }) ?? true {
            if failure != nil || !condition.wait(until: deadline) {
                return false
            }
        }
        return true
    }

    private func waitForPendingWrites() async {
        await withCheckedContinuation { continuation in
            pendingWrites.notify(queue: queue) {
                continuation.resume()
            }
        }
    }
}
