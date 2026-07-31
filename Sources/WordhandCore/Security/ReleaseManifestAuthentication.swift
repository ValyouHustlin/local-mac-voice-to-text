import CryptoKit
import Foundation

public enum ReleaseManifestAuthenticationError: Error, Equatable, Sendable {
    case invalidManifest
    case manifestTooLarge
    case signatureEnvelopeTooLarge
    case invalidPrivateKey
    case invalidPublicKey
    case invalidKeyID
    case invalidSignatureEncoding
    case invalidSignature
    case unsupportedSchema
    case unsupportedAlgorithm
    case unexpectedKeyID
    case unexpectedEnvelopeFields
    case noncanonicalEnvelope
    case manifestDigestMismatch
    case invalidTrustAnchor
    case productionTrustAnchorUnavailable
    case privateKeyDoesNotMatchTrustAnchor
}

struct ReleaseManifestTrustAnchor: Equatable, Sendable {
    let keyID: String
    let publicKey: Data

    init(publicKey: Data) throws {
        guard publicKey.count == 32,
              (try? Curve25519.Signing.PublicKey(
                  rawRepresentation: publicKey
              )) != nil
        else {
            throw ReleaseManifestAuthenticationError.invalidPublicKey
        }
        self.publicKey = publicKey
        self.keyID = ReleaseManifestAuthenticator.keyID(for: publicKey)
    }
}

struct ReleaseManifestSignatureEnvelope: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let algorithm: String
    let keyID: String
    let manifestSHA256: String
    let signature: String

    func canonicalData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(0x0A)
        return data
    }
}

enum ReleaseManifestAuthenticator {
    static let maximumManifestBytes = 64 * 1024
    static let maximumSignatureEnvelopeBytes = 8 * 1024

    private static let schemaVersion = 1
    private static let algorithm = "Ed25519"
    private static let domain = Data(
        "com.valyou.wordhand/release-manifest/v1\u{0}".utf8
    )
    private static let envelopeKeys: Set<String> = [
        "schemaVersion",
        "algorithm",
        "keyID",
        "manifestSHA256",
        "signature",
    ]

    static func publicKey(forPrivateKey privateKey: Data) throws -> Data {
        guard privateKey.count == 32,
              let signingKey = try? Curve25519.Signing.PrivateKey(
                  rawRepresentation: privateKey
              )
        else {
            throw ReleaseManifestAuthenticationError.invalidPrivateKey
        }
        return signingKey.publicKey.rawRepresentation
    }

    static func keyID(for publicKey: Data) -> String {
        "ed25519:\(SHA256.hash(data: publicKey).hexString)"
    }

    static func sign(manifest: Data, privateKey: Data) throws -> Data {
        try validateManifest(manifest)
        guard privateKey.count == 32,
              let signingKey = try? Curve25519.Signing.PrivateKey(
                  rawRepresentation: privateKey
              )
        else {
            throw ReleaseManifestAuthenticationError.invalidPrivateKey
        }
        let keyID = self.keyID(for: signingKey.publicKey.rawRepresentation)
        let signature = try signingKey.signature(
            for: signedMessage(manifest: manifest, keyID: keyID)
        )
        return try ReleaseManifestSignatureEnvelope(
            schemaVersion: schemaVersion,
            algorithm: algorithm,
            keyID: keyID,
            manifestSHA256: SHA256.hash(data: manifest).hexString,
            signature: signature.base64EncodedString()
        ).canonicalData()
    }

    static func verify(
        manifest: Data,
        signatureEnvelope: Data,
        trustAnchor: ReleaseManifestTrustAnchor
    ) throws {
        try validateManifest(manifest)
        guard signatureEnvelope.count <= maximumSignatureEnvelopeBytes else {
            throw ReleaseManifestAuthenticationError.signatureEnvelopeTooLarge
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: signatureEnvelope)
        } catch {
            throw ReleaseManifestAuthenticationError.noncanonicalEnvelope
        }
        guard let dictionary = object as? [String: Any],
              Set(dictionary.keys) == envelopeKeys
        else {
            throw ReleaseManifestAuthenticationError.unexpectedEnvelopeFields
        }
        let envelope: ReleaseManifestSignatureEnvelope
        do {
            envelope = try JSONDecoder().decode(
                ReleaseManifestSignatureEnvelope.self,
                from: signatureEnvelope
            )
        } catch {
            throw ReleaseManifestAuthenticationError.noncanonicalEnvelope
        }
        guard signatureEnvelope == (try envelope.canonicalData()) else {
            throw ReleaseManifestAuthenticationError.noncanonicalEnvelope
        }
        guard envelope.schemaVersion == schemaVersion else {
            throw ReleaseManifestAuthenticationError.unsupportedSchema
        }
        guard envelope.algorithm == algorithm else {
            throw ReleaseManifestAuthenticationError.unsupportedAlgorithm
        }
        guard envelope.keyID == trustAnchor.keyID else {
            throw ReleaseManifestAuthenticationError.unexpectedKeyID
        }
        guard envelope.manifestSHA256 == SHA256.hash(data: manifest).hexString else {
            throw ReleaseManifestAuthenticationError.manifestDigestMismatch
        }
        guard let signature = Data(base64Encoded: envelope.signature),
              signature.count == 64,
              signature.base64EncodedString() == envelope.signature
        else {
            throw ReleaseManifestAuthenticationError.invalidSignatureEncoding
        }
        let publicKey = try Curve25519.Signing.PublicKey(
            rawRepresentation: trustAnchor.publicKey
        )
        guard publicKey.isValidSignature(
            signature,
            for: signedMessage(manifest: manifest, keyID: envelope.keyID)
        ) else {
            throw ReleaseManifestAuthenticationError.invalidSignature
        }
    }

    private static func validateManifest(_ manifest: Data) throws {
        guard !manifest.isEmpty else {
            throw ReleaseManifestAuthenticationError.invalidManifest
        }
        guard manifest.count <= maximumManifestBytes else {
            throw ReleaseManifestAuthenticationError.manifestTooLarge
        }
    }

    private static func signedMessage(manifest: Data, keyID: String) -> Data {
        var message = domain
        message.append(contentsOf: keyID.utf8)
        message.append(0)
        message.append(manifest)
        return message
    }
}

enum ReleaseManifestTrustAnchorLoader {
    private struct Document: Decodable {
        let schemaVersion: Int
        let keyID: String?
        let publicKeyBase64: String?
    }

    private static let documentKeys: Set<String> = [
        "schemaVersion",
        "keyID",
        "publicKeyBase64",
    ]

    static func parse(_ data: Data) throws -> ReleaseManifestTrustAnchor? {
        guard data.count <= 8 * 1024,
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              Set(dictionary.keys) == documentKeys,
              let document = try? JSONDecoder().decode(Document.self, from: data),
              document.schemaVersion == 1
        else {
            throw ReleaseManifestAuthenticationError.invalidTrustAnchor
        }
        switch (document.keyID, document.publicKeyBase64) {
        case (nil, nil):
            return nil
        case let (keyID?, encodedPublicKey?):
            guard let publicKey = Data(base64Encoded: encodedPublicKey),
                  publicKey.base64EncodedString() == encodedPublicKey,
                  let anchor = try? ReleaseManifestTrustAnchor(publicKey: publicKey),
                  anchor.keyID == keyID
            else {
                throw ReleaseManifestAuthenticationError.invalidTrustAnchor
            }
            return anchor
        default:
            throw ReleaseManifestAuthenticationError.invalidTrustAnchor
        }
    }

    static func loadProduction() throws -> ReleaseManifestTrustAnchor? {
        // Compile the anchor into every verifier so manually assembled app
        // bundles cannot lose a separate SwiftPM resource bundle.
        try parse(
            Data(
                """
                {"keyID":null,"publicKeyBase64":null,"schemaVersion":1}
                """.utf8
            )
        )
    }
}

public enum ProductionReleaseManifestAuthenticator {
    public static func requireConfiguredTrustAnchor() throws {
        _ = try productionAnchor()
    }

    public static func preflight(privateKey: Data) throws {
        let anchor = try productionAnchor()
        let publicKey = try ReleaseManifestAuthenticator.publicKey(
            forPrivateKey: privateKey
        )
        guard publicKey == anchor.publicKey else {
            throw ReleaseManifestAuthenticationError
                .privateKeyDoesNotMatchTrustAnchor
        }
    }

    public static func sign(manifest: Data, privateKey: Data) throws -> Data {
        try preflight(privateKey: privateKey)
        return try ReleaseManifestAuthenticator.sign(
            manifest: manifest,
            privateKey: privateKey
        )
    }

    public static func verify(
        manifest: Data,
        signatureEnvelope: Data
    ) throws {
        try ReleaseManifestAuthenticator.verify(
            manifest: manifest,
            signatureEnvelope: signatureEnvelope,
            trustAnchor: try productionAnchor()
        )
    }

    private static func productionAnchor() throws -> ReleaseManifestTrustAnchor {
        guard let anchor = try ReleaseManifestTrustAnchorLoader.loadProduction()
        else {
            throw ReleaseManifestAuthenticationError
                .productionTrustAnchorUnavailable
        }
        return anchor
    }
}

private extension Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
