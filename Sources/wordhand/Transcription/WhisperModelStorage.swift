import Foundation

enum WhisperModelCacheState: Equatable {
    case missing
    case invalid(URL)
    case ready(URL)
}

enum WhisperModelStorageError: Error, Equatable {
    case cacheIsNotInvalid
    case unsafeModelID
    case quarantineAlreadyExists
}

enum WhisperModelStorage {
    private static let requiredCompiledModels = [
        "MelSpectrogram.mlmodelc",
        "AudioEncoder.mlmodelc",
        "TextDecoder.mlmodelc",
    ]
    private static let requiredCompiledFiles = [
        "metadata.json",
        "model.mil",
        "coremldata.bin",
        "weights/weight.bin",
    ]

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
        guard case .ready(let folder) = cacheState(
            modelID: modelID,
            downloadBase: downloadBase,
            fileManager: fileManager
        ) else {
            return nil
        }
        return folder
    }

    static func cacheState(
        modelID: String,
        downloadBase: URL,
        fileManager: FileManager = .default
    ) -> WhisperModelCacheState {
        let folder = modelFolder(modelID: modelID, downloadBase: downloadBase)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: folder.path,
            isDirectory: &isDirectory
        ) else {
            return .missing
        }
        guard isDirectory.boolValue,
              isNonemptyJSONFile(
                  folder.appendingPathComponent("config.json"),
                  fileManager: fileManager
              ),
              requiredCompiledModels.allSatisfy({
                  isCompleteCompiledModel(
                      folder.appendingPathComponent($0, isDirectory: true),
                      fileManager: fileManager
                  )
              })
        else {
            return .invalid(folder)
        }
        return .ready(folder)
    }

    static func quarantineInvalidModel(
        modelID: String,
        downloadBase: URL,
        quarantineID: UUID = UUID(),
        fileManager: FileManager = .default
    ) throws -> URL {
        guard isSafeModelID(modelID) else {
            throw WhisperModelStorageError.unsafeModelID
        }
        guard case .invalid(let folder) = cacheState(
            modelID: modelID,
            downloadBase: downloadBase,
            fileManager: fileManager
        ) else {
            throw WhisperModelStorageError.cacheIsNotInvalid
        }
        let quarantineFolder = quarantineRoot(downloadBase: downloadBase)
            .appendingPathComponent(modelID, isDirectory: true)
        try fileManager.createDirectory(
            at: quarantineFolder,
            withIntermediateDirectories: true
        )
        let destination = quarantineFolder.appendingPathComponent(
            quarantineID.uuidString,
            isDirectory: true
        )
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw WhisperModelStorageError.quarantineAlreadyExists
        }
        try fileManager.moveItem(at: folder, to: destination)
        return destination
    }

    static func removeQuarantinedModels(
        modelID: String,
        downloadBase: URL,
        fileManager: FileManager = .default
    ) throws {
        guard isSafeModelID(modelID) else {
            throw WhisperModelStorageError.unsafeModelID
        }
        let folder = quarantineRoot(downloadBase: downloadBase)
            .appendingPathComponent(modelID, isDirectory: true)
        guard fileManager.fileExists(atPath: folder.path) else { return }
        try fileManager.removeItem(at: folder)
    }

    private static func modelFolder(
        modelID: String,
        downloadBase: URL
    ) -> URL {
        downloadBase
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent("whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(modelID, isDirectory: true)
    }

    private static func quarantineRoot(downloadBase: URL) -> URL {
        downloadBase
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent("whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(".wordhand-quarantine", isDirectory: true)
    }

    private static func isSafeModelID(_ modelID: String) -> Bool {
        !modelID.isEmpty
            && modelID != "."
            && modelID != ".."
            && !modelID.contains("/")
            && !modelID.contains("\\")
    }

    private static func isCompleteCompiledModel(
        _ folder: URL,
        fileManager: FileManager
    ) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: folder.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            return false
        }
        return requiredCompiledFiles.allSatisfy { path in
            let file = folder.appendingPathComponent(path)
            if path == "metadata.json" {
                return isNonemptyJSONFile(file, fileManager: fileManager)
            }
            return isNonemptyRegularFile(file, fileManager: fileManager)
        }
    }

    private static func isNonemptyJSONFile(
        _ file: URL,
        fileManager: FileManager
    ) -> Bool {
        guard isNonemptyRegularFile(file, fileManager: fileManager),
              let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data),
              object is [String: Any] || object is [Any]
        else {
            return false
        }
        return true
    }

    private static func isNonemptyRegularFile(
        _ file: URL,
        fileManager: FileManager
    ) -> Bool {
        guard let values = try? file.resourceValues(
            forKeys: [.isRegularFileKey, .fileSizeKey]
        ) else {
            return false
        }
        return values.isRegularFile == true && (values.fileSize ?? 0) > 0
    }
}
