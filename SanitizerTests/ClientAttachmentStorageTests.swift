import CryptoKit
import Foundation
import NoctweaveCore
import Security

/// Runs against the same storage source as the app, with isolated Keychain items.
@main
struct ClientAttachmentStorageTests {
    struct Envelope: Codable { let version: Int; let sealed: Data }
    enum Failure: Error { case assertion(String) }

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure.assertion(message) }
    }

    @MainActor
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noctweave-attachment-erasure-\(UUID())")
        let service = "org.noctweave.tests.attachment-erasure.\(UUID())"
        defer {
            try? FileManager.default.removeItem(at: root)
            SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                           kSecAttrService as String: service] as CFDictionary)
        }
        let firstDirectory = root.appendingPathComponent("first")
        let secondDirectory = root.appendingPathComponent("second")
        let first = ClientAttachmentStore(directory: firstDirectory, storageScopeIdentifier: "first", keyService: service)
        let second = ClientAttachmentStore(directory: secondDirectory, storageScopeIdentifier: "second", keyService: service)
        let payload = Data("Disposable encrypted attachment".utf8)
        let firstID = UUID()
        let firstName = try first.saveSanitizedAttachment(payload, attachmentId: firstID)
        let secondName = try second.saveSanitizedAttachment(payload, attachmentId: UUID())
        let roundTrip = try first.loadSanitizedAttachment(fileName: firstName)
        try require(roundTrip == payload, "Scoped attachment round trip")

        // Reproduce both supported legacy envelopes using a key in our isolated service.
        let legacyKey = try SecureStorageKeyProvider.shared.loadOrCreateKey(service: service, account: "attachment-vault-v1")
        let forgedID = UUID()
        let forgedName = "\(forgedID.uuidString).bin"
        let forgedSealed = try AES.GCM.seal(payload, using: legacyKey,
            authenticating: Data("org.noctweave.client-attachment/v2\0\(forgedID.uuidString.lowercased())".utf8))
        let forgedURL = firstDirectory.appendingPathComponent(forgedName)
        try SecureRegularFileIO.writePrivate(NoctweaveCoder.encode(Envelope(version: 3, sealed: forgedSealed.combined!)),
            to: forgedURL, maximumBytes: 4096)
        do {
            try first.prepareForKeyDestruction()
            throw Failure.assertion("A forged v3 header bypassed the migration check")
        } catch is CryptoKitError { }
        try FileManager.default.removeItem(at: forgedURL)
        let orphan = firstDirectory.appendingPathComponent(".interrupted-write.tmp")
        try SecureRegularFileIO.writePrivate(Data("old encrypted temporary file".utf8), to: orphan, maximumBytes: 4096)
        do {
            try first.prepareForKeyDestruction()
            throw Failure.assertion("Migration ignored an unclassified file")
        } catch is ClientAttachmentStoreError { }
        try FileManager.default.removeItem(at: orphan)
        var legacyNames: [String] = []
        for version in [1, 2] {
            let id = UUID(), name = "\(id.uuidString).bin"
            let aad = version == 2 ? Data("org.noctweave.client-attachment/v2\0\(id.uuidString.lowercased())".utf8) : Data()
            let sealed = try AES.GCM.seal(payload, using: legacyKey, authenticating: aad)
            let encoded = try NoctweaveCoder.encode(Envelope(version: version, sealed: sealed.combined!))
            try SecureRegularFileIO.writePrivate(encoded, to: firstDirectory.appendingPathComponent(name), maximumBytes: 4096)
            legacyNames.append(name)
        }
        try first.prepareForKeyDestruction()
        for name in legacyNames {
            let migrated = try NoctweaveCoder.decode(Envelope.self, from: Data(contentsOf: firstDirectory.appendingPathComponent(name)))
            try require(migrated.version == 3, "Legacy attachment was not migrated")
            let contents = try first.loadSanitizedAttachment(fileName: name)
            try require(contents == payload, "Migration changed attachment content")
            let id = UUID(uuidString: String(name.dropLast(4)))!
            do {
                _ = try AES.GCM.open(AES.GCM.SealedBox(combined: migrated.sealed), using: legacyKey,
                    authenticating: Data("org.noctweave.client-attachment/v2\0\(id.uuidString.lowercased())".utf8))
                throw Failure.assertion("Legacy key can still decrypt migrated attachment")
            } catch is CryptoKitError { }
        }

        let retainedCiphertext = try Data(contentsOf: firstDirectory.appendingPathComponent(firstName))
        try first.destroyEncryptionMaterial()
        try require(FileManager.default.fileExists(atPath: firstDirectory.appendingPathComponent(firstName).path), "Key erasure removed ciphertext")
        let afterErasure = try Data(contentsOf: firstDirectory.appendingPathComponent(firstName))
        try require(afterErasure == retainedCiphertext, "Key erasure changed retained ciphertext")
        do {
            _ = try first.loadSanitizedAttachment(fileName: firstName)
            throw Failure.assertion("Retired attachment store decrypted")
        } catch is ClientAttachmentStoreError { }
        do {
            _ = try first.saveSanitizedAttachment(payload, attachmentId: UUID())
            throw Failure.assertion("Late attachment writer recreated a key")
        } catch is ClientAttachmentStoreError { }
        let otherContents = try second.loadSanitizedAttachment(fileName: secondName)
        try require(otherContents == payload, "Erasure affected another local store")
        SecureStorageKeyProvider.shared.clearProcessCache()
        let otherContentsAfterCacheClear = try second.loadSanitizedAttachment(fileName: secondName)
        try require(otherContentsAfterCacheClear == payload, "Erasure deleted another store's key")
        let legacyAfter = try SecureStorageKeyProvider.shared.loadOrCreateKey(service: service, account: "attachment-vault-v1")
        try require(legacyAfter.withUnsafeBytes { Data($0) } == legacyKey.withUnsafeBytes { Data($0) }, "Erasure deleted the shared legacy key")
        try first.eraseAllLocalAttachments()
        try require(!FileManager.default.fileExists(atPath: firstDirectory.path), "Wipe retained local attachments")
        try require(FileManager.default.fileExists(atPath: secondDirectory.appendingPathComponent(secondName).path), "Wipe affected another local store")
        print("Attachment storage checks passed: scoped round trip, v1/v2 migration, old-key rejection, key erasure, late-writer rejection, cross-store isolation, and file wipe.")
    }
}
