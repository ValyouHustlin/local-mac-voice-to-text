import AVFoundation
import Foundation
import WordhandCore

/// Captures microphone audio while recording is active and returns a 16 kHz
/// mono Float32 buffer when stopped. Format-converts on the fly so callers
/// don't have to worry about the input device's native rate.
final class AudioCapture: StreamingAudioCapturing, RecoveryManagedAudioCapturing {
    enum CaptureError: Error {
        case engineStartFailed(Error)
        case converterCreationFailed
    }

    static let targetSampleRate: Double = 16_000
    private static let tailCaptureNanoseconds: UInt64 = 80_000_000

    private let engine = AVAudioEngine()
    private let recoveryJournal: CrashSafeCaptureJournal
    private let recoveryWriter: CrashSafeCaptureWriter
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private var streamingChunkHandler: (@Sendable ([Float]) -> Void)?
    private var isRecording = false
    private let lock = NSLock()
    private var acceptsRecoveryChunks = false

    /// Called for every audio buffer with the buffer's RMS level (0…~1).
    /// Invoked on an arbitrary thread; hop to main if you touch UI.
    var onLevel: ((Float) -> Void)?
    /// Reports that this recording continued in RAM without crash protection.
    var onRecoveryFailure: (@MainActor @Sendable (String) -> Void)?
    /// Called after the input tap is stopped, before recovery writes drain.
    /// This keeps finish feedback independent from journal I/O latency.
    var onInputStopped: (@MainActor () -> Void)?

    init(
        recoveryJournal: CrashSafeCaptureJournal = CrashSafeCaptureJournal()
    ) {
        self.recoveryJournal = recoveryJournal
        self.recoveryWriter = CrashSafeCaptureWriter(journal: recoveryJournal)
    }

    func prepareRecovery(id: UUID, createdAt: Date, sampleRate: Int) throws {
        try recoveryWriter.beginCapture(
            id: id,
            createdAt: createdAt,
            sampleRate: sampleRate
        )
    }

    func markRecoveryCommitted(id: UUID) throws {
        try recoveryJournal.discard(id: id)
    }

    func discardRecovery(id: UUID) throws {
        try recoveryJournal.discard(id: id)
    }

    func setStreamingChunkHandler(
        _ handler: (@Sendable ([Float]) -> Void)?
    ) {
        lock.withLock {
            streamingChunkHandler = handler
        }
    }

    /// Begin recording. Idempotent — calling while already recording is a no-op.
    func start() throws {
        guard !isRecording else { return }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioCapture.targetSampleRate,
            channels: 1,
            interleaved: false
        )!

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw CaptureError.converterCreationFailed
        }
        self.converter = converter

        lock.withLock {
            samples.removeAll(keepingCapacity: true)
            acceptsRecoveryChunks = true
        }

        // Tap with input format; convert inside the callback.
        // Smaller buffers surface speech about four times more frequently than
        // the previous 4096-frame tap on a 48 kHz USB microphone. That lowers
        // level/preview latency and reduces the unflushed tail at key release.
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer: buffer, converter: converter, targetFormat: targetFormat)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw CaptureError.engineStartFailed(error)
        }

        isRecording = true
    }

    /// Stop recording and return all captured samples (16 kHz mono Float32).
    ///
    /// AVAudioEngine taps deliver fixed-size buffers. Keep the tap alive for
    /// one short grace interval after the hotkey release so the buffer holding
    /// the final phoneme is delivered instead of being discarded by stop().
    @discardableResult
    func stop() async -> [Float] {
        guard isRecording else { return [] }
        try? await Task.sleep(nanoseconds: Self.tailCaptureNanoseconds)
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        isRecording = false
        await onInputStopped?()

        let captured = lock.withLock {
            acceptsRecoveryChunks = false
            let captured = samples
            samples.removeAll(keepingCapacity: true)
            return captured
        }
        do {
            try await recoveryWriter.seal()
        } catch {
            await onRecoveryFailure?(String(describing: error))
        }
        return captured
    }

    private func process(
        buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat
    ) {
        // Output buffer capacity scales with sample-rate ratio.
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64

        guard let outBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outCapacity
        ) else { return }

        var consumed = false
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }

        var error: NSError?
        let status = converter.convert(to: outBuffer, error: &error, withInputFrom: inputBlock)
        guard status != .error, let channelData = outBuffer.floatChannelData else { return }

        let count = Int(outBuffer.frameLength)
        let ptr = channelData[0]
        let chunk = Array(UnsafeBufferPointer(start: ptr, count: count))

        let chunkHandler = lock.withLock {
            samples.append(contentsOf: chunk)
            if acceptsRecoveryChunks {
                if recoveryWriter.enqueue(chunk) == nil {
                    FileHandle.standardError.write(Data(
                        "capture recovery is unavailable for this recording\n".utf8
                    ))
                }
            }
            return streamingChunkHandler
        }
        chunkHandler?(chunk)

        if let onLevel {
            onLevel(computeRMS(chunk))
        }
    }

}

// MARK: - WAV writer (for debugging M3 captures)

enum WAVWriter {
    /// Write Float32 mono samples as 16-bit PCM WAV to `path`.
    static func write(samples: [Float], sampleRate: Int, to path: String) throws {
        let bytesPerSample = 2
        let dataSize = samples.count * bytesPerSample

        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        data.append(uint32LE(36 + UInt32(dataSize)))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.append(uint32LE(16))                       // fmt chunk size
        data.append(uint16LE(1))                        // PCM
        data.append(uint16LE(1))                        // mono
        data.append(uint32LE(UInt32(sampleRate)))
        data.append(uint32LE(UInt32(sampleRate * bytesPerSample)))
        data.append(uint16LE(UInt16(bytesPerSample)))   // block align
        data.append(uint16LE(16))                       // bits per sample
        data.append(contentsOf: Array("data".utf8))
        data.append(uint32LE(UInt32(dataSize)))

        for s in samples {
            let clamped = max(-1.0, min(1.0, s))
            let i = Int16(clamped * 32767.0)
            data.append(uint16LE(UInt16(bitPattern: i)))
        }

        try data.write(to: URL(fileURLWithPath: path))
    }

    private static func uint32LE(_ v: UInt32) -> Data {
        var x = v.littleEndian
        return Data(bytes: &x, count: 4)
    }
    private static func uint16LE(_ v: UInt16) -> Data {
        var x = v.littleEndian
        return Data(bytes: &x, count: 2)
    }
}

func computeRMS(_ samples: [Float]) -> Float {
    guard !samples.isEmpty else { return 0 }
    var sum: Double = 0
    for s in samples { sum += Double(s * s) }
    return Float((sum / Double(samples.count)).squareRoot())
}
