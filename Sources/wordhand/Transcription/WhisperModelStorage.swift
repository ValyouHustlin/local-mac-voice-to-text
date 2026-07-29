import Foundation

enum WhisperModelStorage {
    static func defaultDownloadBase(
        fileManager: FileManager = .default
    ) -> URL {
        let documents = fileManager.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
        return documents.appendingPathComponent("huggingface", isDirectory: true)
    }

    static func localModelFolder(
        modelID: String,
        downloadBase: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        let folder = downloadBase
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent("whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(modelID, isDirectory: true)
        let requiredEntries = [
            "config.json",
            "MelSpectrogram.mlmodelc",
            "AudioEncoder.mlmodelc",
            "TextDecoder.mlmodelc",
        ]
        guard requiredEntries.allSatisfy({
            fileManager.fileExists(atPath: folder.appendingPathComponent($0).path)
        }) else {
            return nil
        }
        return folder
    }
}
