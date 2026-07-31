import Foundation
import WordhandCore

enum ParakeetModelCacheState: Equatable, Sendable {
    case missing
    case invalid(URL)
    case ready(URL)
}

enum ParakeetModelStorageError: Error, Equatable {
    case cacheIsNotInvalid
    case unsafeModelID
    case quarantineAlreadyExists
}

enum ParakeetModelStorage {
    static let repositoryFolderName = "parakeet-unified-en-0.6b"

    static let requiredFiles = [
        "config.json",
        "metadata.json",
        "vocab.json",
        "parakeet_unified_encoder_int8.mlmodelc/model.mil",
        "parakeet_unified_encoder_int8.mlmodelc/coremldata.bin",
        "parakeet_unified_encoder_int8.mlmodelc/weights/weight.bin",
        "parakeet_unified_decoder.mlmodelc/model.mil",
        "parakeet_unified_decoder.mlmodelc/coremldata.bin",
        "parakeet_unified_decoder.mlmodelc/weights/weight.bin",
        "parakeet_unified_joint_decision_single_step.mlmodelc/model.mil",
        "parakeet_unified_joint_decision_single_step.mlmodelc/coremldata.bin",
        "parakeet_unified_joint_decision_single_step.mlmodelc/weights/weight.bin",
    ]

    static func defaultModelsBase() -> URL {
        ApplicationData.defaultDirectory()
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("FluidAudio", isDirectory: true)
    }

    static func cacheState(
        modelsBase: URL = defaultModelsBase(),
        fileManager: FileManager = .default
    ) -> ParakeetModelCacheState {
        let folder = modelsBase.appendingPathComponent(
            repositoryFolderName,
            isDirectory: true
        )
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: folder.path,
            isDirectory: &isDirectory
        ) else {
            return .missing
        }
        guard isDirectory.boolValue,
              requiredFiles.allSatisfy({
                  isNonemptyRegularFile(
                      folder.appendingPathComponent($0),
                      fileManager: fileManager
                  )
              }),
              ["config.json", "metadata.json", "vocab.json"].allSatisfy({
                  isNonemptyJSONFile(
                      folder.appendingPathComponent($0),
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
        modelsBase: URL = defaultModelsBase(),
        quarantineID: UUID = UUID(),
        fileManager: FileManager = .default
    ) throws -> URL {
        guard isSafeModelID(modelID) else {
            throw ParakeetModelStorageError.unsafeModelID
        }
        guard case .invalid(let folder) = cacheState(
            modelsBase: modelsBase,
            fileManager: fileManager
        ) else {
            throw ParakeetModelStorageError.cacheIsNotInvalid
        }
        let root = quarantineRoot(modelsBase: modelsBase)
            .appendingPathComponent(modelID, isDirectory: true)
        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let destination = root.appendingPathComponent(
            quarantineID.uuidString,
            isDirectory: true
        )
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw ParakeetModelStorageError.quarantineAlreadyExists
        }
        try fileManager.moveItem(at: folder, to: destination)
        return destination
    }

    static func removeQuarantinedModels(
        modelID: String,
        modelsBase: URL = defaultModelsBase(),
        fileManager: FileManager = .default
    ) throws {
        guard isSafeModelID(modelID) else {
            throw ParakeetModelStorageError.unsafeModelID
        }
        let folder = quarantineRoot(modelsBase: modelsBase)
            .appendingPathComponent(modelID, isDirectory: true)
        guard fileManager.fileExists(atPath: folder.path) else { return }
        try fileManager.removeItem(at: folder)
    }

    private static func quarantineRoot(modelsBase: URL) -> URL {
        modelsBase.appendingPathComponent(
            ".wordhand-quarantine",
            isDirectory: true
        )
    }

    private static func isSafeModelID(_ modelID: String) -> Bool {
        !modelID.isEmpty
            && modelID != "."
            && modelID != ".."
            && !modelID.contains("/")
            && !modelID.contains("\\")
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
}
