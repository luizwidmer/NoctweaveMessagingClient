import CryptoKit
import Foundation
import NoctweaveCore

@MainActor
final class ClientAttachmentStore {
    private static let maximumStoredAttachmentBytes = 12 * 1024 * 1024
    // Scoped key identities are deliberately independent of the app-container URL.
    // Apple may relocate that URL during an update while preserving both the
    // relative attachment files and this Keychain item.
    private let keyService: String
    private static let legacyKeyAccount = "attachment-vault-v1"
    private let keyAccount: String
    private let directory: URL
    private var suppliedEncryptionKey: SymmetricKey?
    private let usesSuppliedEncryptionKey: Bool
    private var encryptionMaterialDestroyed = false

    init(directory: URL, storageScopeIdentifier: String, encryptionKey: SymmetricKey? = nil,
         keyService: String = "com.noctweave.securestorage") {
        self.keyService = keyService
        self.directory = directory
        self.keyAccount = "attachment-vault-v2-" + Data(SHA256.hash(data: Data(storageScopeIdentifier.utf8))).base64EncodedString()
        suppliedEncryptionKey = encryptionKey
        usesSuppliedEncryptionKey = encryptionKey != nil
    }

    func destroyEncryptionMaterial() throws {
        encryptionMaterialDestroyed = true
        suppliedEncryptionKey = nil
        if !usesSuppliedEncryptionKey {
            try SecureStorageKeyProvider.shared.destroyKey(service: keyService, account: keyAccount)
        }
    }

    func saveSanitizedAttachment(_ data: Data, attachmentId: UUID) throws -> String {
        guard !data.isEmpty,
              data.count <= AttachmentDescriptor.maximumTransportBytes else {
            throw ClientAttachmentStoreError.invalidPayload
        }
        let fileName = "\(attachmentId.uuidString).bin"
        let url = try attachmentURL(fileName: fileName)
        guard let sealed = try? AES.GCM.seal(
            data,
            using: storageKey(),
            authenticating: Self.authenticatedData(for: attachmentId)
        ),
              var combined = sealed.combined else {
            throw ClientAttachmentStoreError.invalidPayload
        }
        defer { combined.secureWipeClientAttachment() }
        let envelope = try NoctweaveCoder.encode(
            ClientAttachmentEnvelope(version: 3, sealed: combined)
        )
        guard envelope.count <= Self.maximumStoredAttachmentBytes else {
            throw ClientAttachmentStoreError.fileTooLarge
        }
        try SecureRegularFileIO.writePrivate(
            envelope,
            to: url,
            maximumBytes: Self.maximumStoredAttachmentBytes
        )
        return fileName
    }

    func warmUpKeychain() throws {
        _ = try storageKey()
    }

    func existingFileName(attachmentId: UUID) -> String? {
        let fileName = "\(attachmentId.uuidString).bin"
        guard let url = try? attachmentURL(fileName: fileName),
              SecureRegularFileIO.privateRegularFileExists(
                at: url,
                maximumBytes: Self.maximumStoredAttachmentBytes
              ) else {
            return nil
        }
        return fileName
    }

    func loadSanitizedAttachment(fileName: String) throws -> Data {
        let url = try attachmentURL(fileName: fileName)
        let attachmentId = try attachmentID(fileName: fileName)
        let encoded = try SecureRegularFileIO.read(
            from: url,
            maximumBytes: Self.maximumStoredAttachmentBytes,
            requirePrivateOwner: true
        )
        let envelope = try NoctweaveCoder.decode(ClientAttachmentEnvelope.self, from: encoded)
        guard (1...3).contains(envelope.version),
              let sealed = try? AES.GCM.SealedBox(combined: envelope.sealed) else {
            throw ClientAttachmentStoreError.invalidPayload
        }
        let key: SymmetricKey
        if envelope.version == 3 || usesSuppliedEncryptionKey { key = try storageKey() }
        else {
            guard !encryptionMaterialDestroyed else { throw ClientAttachmentStoreError.invalidPayload }
            key = try SecureStorageKeyProvider.shared.loadOrCreateKey(service: keyService, account: Self.legacyKeyAccount)
        }
        let opened: Data
        if envelope.version >= 2 {
            opened = try AES.GCM.open(
                sealed,
                using: key,
                authenticating: Self.authenticatedData(for: attachmentId)
            )
        } else {
            opened = try AES.GCM.open(sealed, using: key)
        }
        guard !opened.isEmpty,
              opened.count <= AttachmentDescriptor.maximumTransportBytes else {
            throw ClientAttachmentStoreError.invalidPayload
        }
        if envelope.version < 3 {
            _ = try saveSanitizedAttachment(opened, attachmentId: attachmentId)
        }
        return opened
    }

    /// Required before enabling cryptographic erasure: every managed attachment
    /// must use this store's key, not a key shared with a legacy installation.
    func prepareForKeyDestruction() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try SecureRegularFileIO.ensurePrivateDirectory(at: directory)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for file in files {
            // Authenticate every file, including v3. The unauthenticated envelope
            // version alone must never establish that a legacy key is no longer used.
            // Unknown files (including interrupted temporary writes) fail this check.
            var plaintext = try loadSanitizedAttachment(fileName: file.lastPathComponent)
            plaintext.secureWipeClientAttachment()
        }
    }

    func eraseAllLocalAttachments() throws {
        do {
            try SecureRegularFileIO.ensurePrivateDirectory(at: directory)
        } catch SecureRegularFileIOError.notFound {
            return
        }
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        for entry in entries {
            try FileManager.default.removeItem(at: entry)
        }
        try FileManager.default.removeItem(at: directory)
    }

    private func attachmentURL(fileName: String) throws -> URL {
        let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == (trimmed as NSString).lastPathComponent,
              trimmed.hasSuffix(".bin"),
              UUID(uuidString: String(trimmed.dropLast(4))) != nil else {
            throw ClientAttachmentStoreError.invalidFileName
        }
        return directory.appendingPathComponent(trimmed, isDirectory: false)
    }

    private func attachmentID(fileName: String) throws -> UUID {
        let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == (trimmed as NSString).lastPathComponent,
              trimmed.hasSuffix(".bin"),
              let identifier = UUID(uuidString: String(trimmed.dropLast(4))) else {
            throw ClientAttachmentStoreError.invalidFileName
        }
        return identifier
    }

    private static func authenticatedData(for attachmentId: UUID) -> Data {
        Data("org.noctweave.client-attachment/v2\0\(attachmentId.uuidString.lowercased())".utf8)
    }

    private func storageKey() throws -> SymmetricKey {
        guard !encryptionMaterialDestroyed else { throw ClientAttachmentStoreError.invalidPayload }
        if let suppliedEncryptionKey {
            return suppliedEncryptionKey
        }
        return try SecureStorageKeyProvider.shared.loadOrCreateKey(
            service: keyService,
            account: keyAccount
        )
    }

}

private struct ClientAttachmentEnvelope: Codable {
    let version: Int
    let sealed: Data
}

enum ClientAttachmentStoreError: Error {
    case invalidFileName
    case invalidPayload
    case fileTooLarge
}

private extension Data {
    mutating func secureWipeClientAttachment() {
        guard !isEmpty else { return }
        resetBytes(in: startIndex..<endIndex)
        removeAll(keepingCapacity: false)
    }
}
