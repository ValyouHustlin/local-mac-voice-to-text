import Foundation
import Testing
@testable import WordhandCore
@testable import wordhand

@Suite
struct ParakeetUnifiedTranscriberTests {
    @Test
    func warmupIsIdempotentAndTranscriptionUsesTheCompleteBuffer() async throws {
        let manager = FakeParakeetUnifiedManager(result: " complete text ")
        let model = try #require(
            ModelRegistry.find("parakeet-unified-en-0.6b")
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let transcriber = ParakeetUnifiedTranscriber(
            model: model,
            modelsDirectory: directory,
            manager: manager,
            validatesModelCache: false
        )
        let audio: [Float] = [0.1, -0.2, 0.3, -0.4]

        try await transcriber.warmUp()
        let result = try await transcriber.transcribe(audio)

        #expect(result == "complete text")
        #expect(await manager.loadDirectories == [directory])
        #expect(await manager.transcribedBuffers == [audio])
    }

    @Test
    func concurrentWarmupsShareOneModelLoad() async throws {
        let manager = FakeParakeetUnifiedManager(
            result: "ready",
            loadDelayNanoseconds: 20_000_000
        )
        let model = try #require(
            ModelRegistry.find("parakeet-unified-en-0.6b")
        )
        let transcriber = ParakeetUnifiedTranscriber(
            model: model,
            manager: manager,
            validatesModelCache: false
        )

        async let first: Void = transcriber.warmUp()
        async let second: Void = transcriber.warmUp()
        _ = try await (first, second)

        #expect(await manager.loadDirectories.count == 1)
    }

    @Test
    func readyCacheLoadFailureBecomesRepairableInvalidCache() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try makeStructurallyCompleteCache(at: root)
        let manager = FakeParakeetUnifiedManager(
            result: "unused",
            loadError: FakeParakeetError.loadFailed
        )
        let model = try #require(
            ModelRegistry.find("parakeet-unified-en-0.6b")
        )
        let transcriber = ParakeetUnifiedTranscriber(
            model: model,
            modelsDirectory: root,
            manager: manager
        )

        await #expect(throws: TranscriberError.cachedModelInvalid) {
            try await transcriber.warmUp()
        }
    }

    @Test
    func factoryKeepsWhisperFallbackAndSelectsParakeet() throws {
        let parakeet = try #require(
            ModelRegistry.find("parakeet-unified-en-0.6b")
        )
        let whisper = try #require(ModelRegistry.find("whisper-base.en"))

        #expect(
            TranscriberFactory.make(model: parakeet)
                is ParakeetUnifiedTranscriber
        )
        #expect(
            TranscriberFactory.make(model: whisper)
                is WhisperKitTranscriber
        )
    }

    @Test
    func cacheValidationRejectsPartialModelAndQuarantinesItWithoutDataLoss()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = root.appendingPathComponent(
            ParakeetModelStorage.repositoryFolderName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: model,
            withIntermediateDirectories: true
        )
        let marker = model.appendingPathComponent("partial-download")
        try Data("kept".utf8).write(to: marker)

        #expect(
            ParakeetModelStorage.cacheState(modelsBase: root)
                == .invalid(model)
        )
        let destination = try ParakeetModelStorage.quarantineInvalidModel(
            modelID: "parakeet-unified-en-0.6b",
            modelsBase: root,
            quarantineID: UUID(
                uuidString: "00000000-0000-0000-0000-000000000123"
            )!
        )

        #expect(try Data(contentsOf: destination.appendingPathComponent(
            "partial-download"
        )) == Data("kept".utf8))
        #expect(
            ParakeetModelStorage.cacheState(modelsBase: root) == .missing
        )
    }

    private func makeStructurallyCompleteCache(at root: URL) throws {
        let folder = root.appendingPathComponent(
            ParakeetModelStorage.repositoryFolderName,
            isDirectory: true
        )
        for relativePath in ParakeetModelStorage.requiredFiles {
            let file = folder.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = relativePath.hasSuffix(".json")
                ? Data("{}".utf8)
                : Data([1])
            try data.write(to: file)
        }
    }
}

private actor FakeParakeetUnifiedManager: ParakeetUnifiedManaging {
    let result: String
    let loadDelayNanoseconds: UInt64
    let loadError: Error?
    private(set) var loadDirectories: [URL] = []
    private(set) var transcribedBuffers: [[Float]] = []

    init(
        result: String,
        loadDelayNanoseconds: UInt64 = 0,
        loadError: Error? = nil
    ) {
        self.result = result
        self.loadDelayNanoseconds = loadDelayNanoseconds
        self.loadError = loadError
    }

    func loadModels(to directory: URL) async throws {
        loadDirectories.append(directory)
        if loadDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: loadDelayNanoseconds)
        }
        if let loadError {
            throw loadError
        }
    }

    func transcribe(_ samples: [Float]) -> String {
        transcribedBuffers.append(samples)
        return result
    }
}

private enum FakeParakeetError: Error {
    case loadFailed
}
