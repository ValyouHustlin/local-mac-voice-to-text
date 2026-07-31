import Darwin
import Foundation
import WordhandCore

private enum ReleaseAuthTool {
    static func run(_ arguments: [String]) throws {
        guard let command = arguments.first else {
            throw ToolError.usage
        }
        let operands = Array(arguments.dropFirst())
        switch command {
        case "production-key-status":
            guard operands.isEmpty else { throw ToolError.usage }
            try ProductionReleaseManifestAuthenticator
                .requireConfiguredTrustAnchor()
        case "preflight-private-key":
            guard operands.count == 1 else { throw ToolError.usage }
            try ProductionReleaseManifestAuthenticator.preflight(
                privateKey: readPrivateKey(at: operands[0])
            )
        case "sign":
            guard operands.count == 3 else { throw ToolError.usage }
            let manifest = try Data(contentsOf: URL(fileURLWithPath: operands[0]))
            let signature = try ProductionReleaseManifestAuthenticator.sign(
                manifest: manifest,
                privateKey: readPrivateKey(at: operands[1])
            )
            try signature.write(
                to: URL(fileURLWithPath: operands[2]),
                options: [.atomic]
            )
        case "verify":
            guard operands.count == 2 else { throw ToolError.usage }
            try ProductionReleaseManifestAuthenticator.verify(
                manifest: try Data(
                    contentsOf: URL(fileURLWithPath: operands[0])
                ),
                signatureEnvelope: try Data(
                    contentsOf: URL(fileURLWithPath: operands[1])
                )
            )
        default:
            throw ToolError.usage
        }
    }

    private static func readPrivateKey(at path: String) throws -> Data {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw ToolError.insecurePrivateKeyFile
        }
        let handle = FileHandle(
            fileDescriptor: descriptor,
            closeOnDealloc: true
        )
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == getuid(),
              (metadata.st_mode & 0o777) == 0o600,
              metadata.st_size == 32,
              try !hasExtendedACL(descriptor)
        else {
            try? handle.close()
            throw ToolError.insecurePrivateKeyFile
        }
        let data = try handle.readToEnd() ?? Data()
        try handle.close()
        guard data.count == 32 else {
            throw ReleaseManifestAuthenticationError.invalidPrivateKey
        }
        return data
    }

    private static func hasExtendedACL(_ descriptor: Int32) throws -> Bool {
        errno = 0
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT {
                return false
            }
            throw ToolError.insecurePrivateKeyFile
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        errno = 0
        let status = acl_get_entry(
            acl,
            Int32(ACL_FIRST_ENTRY.rawValue),
            &entry
        )
        guard status == 0 else {
            throw ToolError.insecurePrivateKeyFile
        }
        return true
    }

    enum ToolError: Error {
        case usage
        case insecurePrivateKeyFile
    }
}

do {
    try ReleaseAuthTool.run(Array(CommandLine.arguments.dropFirst()))
} catch {
    if case ReleaseAuthTool.ToolError.usage = error {
        FileHandle.standardError.write(
            Data(
                """
                usage: wordhand-release-auth production-key-status
                       wordhand-release-auth preflight-private-key <private-key-path>
                       wordhand-release-auth sign <manifest> <private-key-path> <signature>
                       wordhand-release-auth verify <manifest> <signature>

                """.utf8
            )
        )
        exit(64)
    }
    FileHandle.standardError.write(
        Data("release authentication rejected: \(error)\n".utf8)
    )
    exit(78)
}
