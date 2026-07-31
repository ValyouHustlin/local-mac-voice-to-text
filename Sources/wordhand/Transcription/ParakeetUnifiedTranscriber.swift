import FluidAudio
import Foundation
import WordhandCore

protocol ParakeetUnifiedManaging: Sendable {
    func loadModels(to directory: URL) async throws
    func transcribe(_ samples: [Float]) async throws -> String
}

actor FluidParakeetUnifiedManager: ParakeetUnifiedManaging {
    private let manager = UnifiedAsrManager(encoderPrecision: .int8)

    func loadModels(to directory: URL) async throws {
        try await manager.loadModels(
            to: directory,
            configuration: nil,
            progressHandler: nil
        )
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        try await manager.transcribe(samples)
    }
}

actor ParakeetUnifiedTranscriber: Transcribing {
    let modelID: String

    private let manager: any ParakeetUnifiedManaging
    private let modelsDirectory: URL
    private let validatesModelCache: Bool
    private var isReady = false
    private var warmupTask: Task<Void, Error>?

    init(
        model: TranscriptionModel,
        modelsDirectory: URL = ParakeetModelStorage.defaultModelsBase(),
        manager: any ParakeetUnifiedManaging = FluidParakeetUnifiedManager(),
        validatesModelCache: Bool = true
    ) {
        precondition(model.engine == .parakeet)
        self.modelID = model.id
        self.modelsDirectory = modelsDirectory
        self.manager = manager
        self.validatesModelCache = validatesModelCache
    }

    func warmUp() async throws {
        guard !isReady else { return }
        if let warmupTask {
            try await warmupTask.value
            isReady = true
            try Task.checkCancellation()
            return
        }
        try Task.checkCancellation()
        let initialCacheState = ParakeetModelStorage.cacheState(
            modelsBase: modelsDirectory
        )
        if validatesModelCache, case .invalid = initialCacheState {
            throw TranscriberError.cachedModelInvalid
        }
        let manager = self.manager
        let modelsDirectory = self.modelsDirectory
        let validatesModelCache = self.validatesModelCache
        let task = Task {
            do {
                try await manager.loadModels(to: modelsDirectory)
            } catch {
                if validatesModelCache, case .ready = initialCacheState {
                    throw TranscriberError.cachedModelInvalid
                }
                throw error
            }
            if validatesModelCache,
               case .ready = ParakeetModelStorage.cacheState(
                   modelsBase: modelsDirectory
               )
            {
                return
            }
            if validatesModelCache {
                throw TranscriberError.cachedModelInvalid
            }
        }
        warmupTask = task
        do {
            try await task.value
            warmupTask = nil
            isReady = true
            try Task.checkCancellation()
        } catch {
            warmupTask = nil
            throw error
        }
    }

    func transcribe(_ audio: [Float]) async throws -> String {
        guard !audio.isEmpty else { return "" }
        try await warmUp()
        try Task.checkCancellation()
        return try await manager.transcribe(audio)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() async {
        // FluidAudio 0.15.5 exposes no inference-cancellation API. The
        // coordinator invalidates the operation so a late result can never
        // reach History or insertion; the complete captured buffer remains
        // available for recovery.
    }
}
