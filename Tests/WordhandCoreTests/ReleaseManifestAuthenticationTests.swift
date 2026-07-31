import CryptoKit
import Foundation
import Testing
@testable import WordhandCore

@Suite
struct ReleaseManifestAuthenticationTests {
    private let manifest = Data(
        #"{"schemaVersion":1,"version":"1.2.3"}"#.utf8
    )

    @Test
    func exactCanonicalEnvelopeVerifiesWithDerivedKeyFingerprint() throws {
        let privateKey = Data(repeating: 7, count: 32)
        let publicKey = try ReleaseManifestAuthenticator.publicKey(
            forPrivateKey: privateKey
        )
        let anchor = try ReleaseManifestTrustAnchor(publicKey: publicKey)
        let envelopeData = try ReleaseManifestAuthenticator.sign(
            manifest: manifest,
            privateKey: privateKey
        )
        let envelope = try JSONDecoder().decode(
            ReleaseManifestSignatureEnvelope.self,
            from: envelopeData
        )

        #expect(envelope.schemaVersion == 1)
        #expect(envelope.algorithm == "Ed25519")
        #expect(envelope.keyID == anchor.keyID)
        #expect(envelope.keyID.hasPrefix("ed25519:"))
        #expect(envelope.keyID.count == 72)
        #expect(envelopeData == (try envelope.canonicalData()))
        try ReleaseManifestAuthenticator.verify(
            manifest: manifest,
            signatureEnvelope: envelopeData,
            trustAnchor: anchor
        )
    }

    @Test
    func manifestSignatureAndPinnedKeyTamperingFailClosed() throws {
        let privateKey = Data(repeating: 9, count: 32)
        let anchor = try ReleaseManifestTrustAnchor(
            publicKey: ReleaseManifestAuthenticator.publicKey(
                forPrivateKey: privateKey
            )
        )
        let envelopeData = try ReleaseManifestAuthenticator.sign(
            manifest: manifest,
            privateKey: privateKey
        )

        expectError(.manifestDigestMismatch) {
            try ReleaseManifestAuthenticator.verify(
                manifest: manifest + Data(" ".utf8),
                signatureEnvelope: envelopeData,
                trustAnchor: anchor
            )
        }

        var envelope = try JSONDecoder().decode(
            ReleaseManifestSignatureEnvelope.self,
            from: envelopeData
        )
        envelope = envelope.with(
            signature: String(envelope.signature.dropLast()) + "A"
        )
        expectError(.invalidSignatureEncoding) {
            try ReleaseManifestAuthenticator.verify(
                manifest: manifest,
                signatureEnvelope: try envelope.canonicalData(),
                trustAnchor: anchor
            )
        }

        let wrongAnchor = try ReleaseManifestTrustAnchor(
            publicKey: ReleaseManifestAuthenticator.publicKey(
                forPrivateKey: Data(repeating: 10, count: 32)
            )
        )
        expectError(.unexpectedKeyID) {
            try ReleaseManifestAuthenticator.verify(
                manifest: manifest,
                signatureEnvelope: envelopeData,
                trustAnchor: wrongAnchor
            )
        }
    }

    @Test
    func envelopeSchemaAlgorithmKeyFieldsAndCanonicalBytesAreBound() throws {
        let privateKey = Data(repeating: 11, count: 32)
        let anchor = try ReleaseManifestTrustAnchor(
            publicKey: ReleaseManifestAuthenticator.publicKey(
                forPrivateKey: privateKey
            )
        )
        let envelopeData = try ReleaseManifestAuthenticator.sign(
            manifest: manifest,
            privateKey: privateKey
        )
        let envelope = try JSONDecoder().decode(
            ReleaseManifestSignatureEnvelope.self,
            from: envelopeData
        )

        expectError(.unsupportedSchema) {
            try verify(envelope.with(schemaVersion: 2), anchor: anchor)
        }
        expectError(.unsupportedAlgorithm) {
            try verify(envelope.with(algorithm: "ECDSA"), anchor: anchor)
        }
        expectError(.unexpectedKeyID) {
            try verify(
                envelope.with(
                    keyID: "ed25519:\(String(repeating: "0", count: 64))"
                ),
                anchor: anchor
            )
        }

        let object = try #require(
            JSONSerialization.jsonObject(with: envelopeData)
                as? [String: Any]
        )
        var extra = object
        extra["publicKey"] = "attacker-controlled"
        expectError(.unexpectedEnvelopeFields) {
            try ReleaseManifestAuthenticator.verify(
                manifest: manifest,
                signatureEnvelope: try JSONSerialization.data(
                    withJSONObject: extra,
                    options: [.sortedKeys]
                ) + Data("\n".utf8),
                trustAnchor: anchor
            )
        }
        expectError(.noncanonicalEnvelope) {
            try ReleaseManifestAuthenticator.verify(
                manifest: manifest,
                signatureEnvelope: Data(" ".utf8) + envelopeData,
                trustAnchor: anchor
            )
        }
        let duplicate = Data(
            """
            {"algorithm":"Ed25519","algorithm":"ECDSA",\
            "keyID":"\(envelope.keyID)",\
            "manifestSHA256":"\(envelope.manifestSHA256)",\
            "schemaVersion":1,"signature":"\(envelope.signature)"}

            """.utf8
        )
        expectError(.noncanonicalEnvelope) {
            try ReleaseManifestAuthenticator.verify(
                manifest: manifest,
                signatureEnvelope: duplicate,
                trustAnchor: anchor
            )
        }
    }

    @Test
    func boundsAndKeyMaterialAreValidated() throws {
        let privateKey = Data(repeating: 13, count: 32)
        let anchor = try ReleaseManifestTrustAnchor(
            publicKey: ReleaseManifestAuthenticator.publicKey(
                forPrivateKey: privateKey
            )
        )
        expectError(.manifestTooLarge) {
            _ = try ReleaseManifestAuthenticator.sign(
                manifest: Data(
                    repeating: 0,
                    count: ReleaseManifestAuthenticator.maximumManifestBytes + 1
                ),
                privateKey: privateKey
            )
        }
        expectError(.invalidPrivateKey) {
            _ = try ReleaseManifestAuthenticator.sign(
                manifest: manifest,
                privateKey: Data(repeating: 0, count: 31)
            )
        }
        expectError(.invalidPublicKey) {
            _ = try ReleaseManifestTrustAnchor(
                publicKey: Data(repeating: 0, count: 31)
            )
        }
        expectError(.signatureEnvelopeTooLarge) {
            try ReleaseManifestAuthenticator.verify(
                manifest: manifest,
                signatureEnvelope: Data(
                    repeating: 0,
                    count:
                        ReleaseManifestAuthenticator.maximumSignatureEnvelopeBytes
                        + 1
                ),
                trustAnchor: anchor
            )
        }
    }

    @Test
    func productionTrustIsUnavailableAndCannotUseFixtureKey() throws {
        let unavailable = Data(
            """
            {
              "schemaVersion": 1,
              "keyID": null,
              "publicKeyBase64": null
            }
            """.utf8
        )
        #expect(try ReleaseManifestTrustAnchorLoader.parse(unavailable) == nil)
        #expect(try ReleaseManifestTrustAnchorLoader.loadProduction() == nil)

        let fixtureKey = Data(repeating: 15, count: 32)
        expectError(.productionTrustAnchorUnavailable) {
            try ProductionReleaseManifestAuthenticator.preflight(
                privateKey: fixtureKey
            )
        }
        expectError(.productionTrustAnchorUnavailable) {
            _ = try ProductionReleaseManifestAuthenticator.sign(
                manifest: manifest,
                privateKey: fixtureKey
            )
        }
        expectError(.productionTrustAnchorUnavailable) {
            try ProductionReleaseManifestAuthenticator.verify(
                manifest: manifest,
                signatureEnvelope: try ReleaseManifestAuthenticator.sign(
                    manifest: manifest,
                    privateKey: fixtureKey
                )
            )
        }
    }

    @Test
    func trustAnchorRequiresExactFingerprintAndSchema() throws {
        let privateKey = Data(repeating: 17, count: 32)
        let publicKey = try ReleaseManifestAuthenticator.publicKey(
            forPrivateKey: privateKey
        )
        let keyID = ReleaseManifestAuthenticator.keyID(for: publicKey)
        let configured = Data(
            """
            {
              "schemaVersion": 1,
              "keyID": "\(keyID)",
              "publicKeyBase64": "\(publicKey.base64EncodedString())"
            }
            """.utf8
        )
        #expect(
            try ReleaseManifestTrustAnchorLoader.parse(configured)?.keyID
                == keyID
        )

        for invalid in [
            configured.replacing(keyID, with: "ed25519:\(String(repeating: "0", count: 64))"),
            Data(
                """
                {"schemaVersion":1,"keyID":"\(keyID)",\
                "publicKeyBase64":null}
                """.utf8
            ),
            Data(
                """
                {"schemaVersion":2,"keyID":null,"publicKeyBase64":null}
                """.utf8
            ),
            Data(
                """
                {"schemaVersion":1,"keyID":null,"publicKeyBase64":null,\
                "fallbackKey":"forbidden"}
                """.utf8
            ),
        ] {
            expectError(.invalidTrustAnchor) {
                _ = try ReleaseManifestTrustAnchorLoader.parse(invalid)
            }
        }
    }

    private func verify(
        _ envelope: ReleaseManifestSignatureEnvelope,
        anchor: ReleaseManifestTrustAnchor
    ) throws {
        try ReleaseManifestAuthenticator.verify(
            manifest: manifest,
            signatureEnvelope: envelope.canonicalData(),
            trustAnchor: anchor
        )
    }

    private func expectError(
        _ expected: ReleaseManifestAuthenticationError,
        operation: () throws -> Void
    ) {
        do {
            try operation()
            Issue.record("expected \(expected)")
        } catch let error as ReleaseManifestAuthenticationError {
            #expect(error == expected)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}

private extension ReleaseManifestSignatureEnvelope {
    func with(
        schemaVersion: Int? = nil,
        algorithm: String? = nil,
        keyID: String? = nil,
        signature: String? = nil
    ) -> Self {
        Self(
            schemaVersion: schemaVersion ?? self.schemaVersion,
            algorithm: algorithm ?? self.algorithm,
            keyID: keyID ?? self.keyID,
            manifestSHA256: manifestSHA256,
            signature: signature ?? self.signature
        )
    }
}

private extension Data {
    func replacing(_ oldValue: String, with newValue: String) -> Data {
        Data(
            String(decoding: self, as: UTF8.self)
                .replacingOccurrences(of: oldValue, with: newValue)
                .utf8
        )
    }
}
