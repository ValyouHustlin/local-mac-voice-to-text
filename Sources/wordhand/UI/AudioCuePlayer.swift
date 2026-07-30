import AppKit
import AVFoundation
import Foundation

protocol AudioCueSound: AnyObject {
    var currentTime: TimeInterval { get set }
    var volume: Float { get set }

    @discardableResult
    func prepareToPlay() -> Bool

    @discardableResult
    func play() -> Bool

    func pause()
}

extension AVAudioPlayer: AudioCueSound {}

@MainActor
final class AudioCuePlayer {
    enum Cue: CaseIterable {
        case start
        case stop
        case cancel
    }

    var isEnabled: Bool
    private var sounds: [Cue: any AudioCueSound] = [:]

    init(
        isEnabled: Bool,
        playerFactory: (Data) -> (any AudioCueSound)? = {
            try? AVAudioPlayer(data: $0)
        }
    ) {
        self.isEnabled = isEnabled
        for cue in Cue.allCases {
            if let sound = playerFactory(Self.waveData(for: cue)) {
                sound.volume = cue == .cancel ? 0.16 : 0.19
                sound.prepareToPlay()
                sounds[cue] = sound
            }
        }
    }

    @discardableResult
    func play(_ cue: Cue) -> Bool {
        guard isEnabled, let sound = sounds[cue] else { return false }
        for (otherCue, otherSound) in sounds where otherCue != cue {
            otherSound.pause()
            otherSound.currentTime = 0
        }
        sound.currentTime = 0
        let didPlay = sound.play()
        if didPlay {
            FileHandle.standardError.write(Data("sound cue: \(cue)\n".utf8))
        }
        return didPlay
    }

    private static func waveData(for cue: Cue) -> Data {
        let sampleRate = 44_100
        let notes: [(frequency: Double, duration: Double)]
        switch cue {
        case .start:
            notes = [(520, 0.045), (700, 0.065)]
        case .stop:
            notes = [(660, 0.05), (470, 0.075)]
        case .cancel:
            notes = [(390, 0.045), (290, 0.06)]
        }

        var samples: [Int16] = []
        for (frequency, duration) in notes {
            let count = Int(Double(sampleRate) * duration)
            for index in 0..<count {
                let progress = Double(index) / Double(max(1, count - 1))
                let envelope = sin(.pi * progress)
                let fundamental = sin(2 * .pi * frequency * Double(index) / Double(sampleRate))
                let overtone = sin(2 * .pi * frequency * 2 * Double(index) / Double(sampleRate))
                let value = (fundamental * 0.86 + overtone * 0.14) * envelope * 0.46
                samples.append(Int16(clamping: Int(value * Double(Int16.max))))
            }
        }
        return makeWAV(samples: samples, sampleRate: sampleRate)
    }

    private static func makeWAV(samples: [Int16], sampleRate: Int) -> Data {
        var data = Data()
        let byteCount = UInt32(samples.count * MemoryLayout<Int16>.size)
        data.appendASCII("RIFF")
        data.appendLittleEndian(UInt32(36) + byteCount)
        data.appendASCII("WAVEfmt ")
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt32(sampleRate))
        data.appendLittleEndian(UInt32(sampleRate * 2))
        data.appendLittleEndian(UInt16(2))
        data.appendLittleEndian(UInt16(16))
        data.appendASCII("data")
        data.appendLittleEndian(byteCount)
        for sample in samples {
            data.appendLittleEndian(UInt16(bitPattern: sample))
        }
        return data
    }
}

private extension Data {
    mutating func appendASCII(_ string: String) {
        append(contentsOf: string.utf8)
    }

    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
