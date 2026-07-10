import CryptoKit
import Foundation
import NoctweaveCore

@MainActor
final class ThreadMessageStore {
    private static let maximumPlaintextBytes = 48 * 1024 * 1024
    private static let maximumStoredBytes = 64 * 1024 * 1024
    private static let maximumMessagesPerThread = 100_000
    private let directory: URL
    private let useEncryption: Bool

    init(directory: URL, useEncryption: Bool = true) {
        self.directory = directory
        self.useEncryption = useEncryption
    }

    func loadDirectMessages(profileId: UUID, contactId: UUID) throws -> [Message] {
        try loadMessages(from: directURL(profileId: profileId, contactId: contactId))
    }

    func saveDirectMessages(_ messages: [Message], profileId: UUID, contactId: UUID) throws {
        try saveMessages(messages, to: directURL(profileId: profileId, contactId: contactId))
    }

    func deleteDirectMessages(profileId: UUID, contactId: UUID) throws {
        try deleteFileIfPresent(directURL(profileId: profileId, contactId: contactId))
    }

    func loadGroupMessages(profileId: UUID, groupId: UUID) throws -> [Message] {
        try loadMessages(from: groupURL(profileId: profileId, groupId: groupId))
    }

    func saveGroupMessages(_ messages: [Message], profileId: UUID, groupId: UUID) throws {
        try saveMessages(messages, to: groupURL(profileId: profileId, groupId: groupId))
    }

    func deleteGroupMessages(profileId: UUID, groupId: UUID) throws {
        try deleteFileIfPresent(groupURL(profileId: profileId, groupId: groupId))
    }

    func deleteAllMessages(profileId: UUID) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return
        }
        let prefix = profileId.uuidString.lowercased()
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for file in files {
            let name = file.lastPathComponent.lowercased()
            if name.contains(prefix) {
                try? securelyRemoveFile(at: file)
            }
        }
    }

    func warmUpKeychain() throws {
        guard useEncryption else { return }
        _ = try storageKey()
    }

    private func loadMessages(from url: URL) throws -> [Message] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true,
              let fileSize = values.fileSize,
              fileSize >= 0,
              fileSize <= Self.maximumStoredBytes else {
            throw ThreadMessageStoreError.fileTooLarge
        }
        var data = try Data(contentsOf: url)
        defer { data.secureWipe() }
        guard data.count <= Self.maximumStoredBytes else {
            throw ThreadMessageStoreError.fileTooLarge
        }
        var payload = try decryptIfNeeded(data)
        defer { payload.secureWipe() }
        guard payload.count <= Self.maximumPlaintextBytes else {
            throw ThreadMessageStoreError.fileTooLarge
        }
        let decoded = try NoctweaveCoder.decode(ThreadMessagePayload.self, from: payload)
        guard decoded.messages.count <= Self.maximumMessagesPerThread else {
            throw ThreadMessageStoreError.tooManyMessages
        }
        return decoded.messages
    }

    private func saveMessages(_ messages: [Message], to url: URL) throws {
        guard messages.count <= Self.maximumMessagesPerThread else {
            throw ThreadMessageStoreError.tooManyMessages
        }
        let payload = ThreadMessagePayload(messages: messages)
        var encoded = try NoctweaveCoder.encode(payload)
        defer { encoded.secureWipe() }
        guard encoded.count <= Self.maximumPlaintextBytes else {
            throw ThreadMessageStoreError.fileTooLarge
        }
        var encrypted = try encryptIfNeeded(encoded)
        defer { encrypted.secureWipe() }
        guard encrypted.count <= Self.maximumStoredBytes else {
            throw ThreadMessageStoreError.fileTooLarge
        }
        try writeData(encrypted, to: url)
    }

    private func deleteFileIfPresent(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        try securelyRemoveFile(at: url)
    }

    private func directURL(profileId: UUID, contactId: UUID) -> URL {
        directory
            .appendingPathComponent("direct")
            .appendingPathComponent("\(profileId.uuidString)_\(contactId.uuidString).bin")
    }

    private func groupURL(profileId: UUID, groupId: UUID) -> URL {
        directory
            .appendingPathComponent("group")
            .appendingPathComponent("\(profileId.uuidString)_\(groupId.uuidString).bin")
    }

    private func writeData(_ data: Data, to url: URL) throws {
        let folder = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.createDirectory(
                at: folder,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: url, options: [.atomic])
        #endif
        do {
            try applyPrivacyAttributes(url: url)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    private func applyPrivacyAttributes(url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func encryptIfNeeded(_ payload: Data) throws -> Data {
        guard useEncryption else {
            return payload
        }
        let key = try storageKey()
        let sealed = try AES.GCM.seal(payload, using: key)
        guard var combined = sealed.combined else {
            throw ThreadMessageStoreError.encryptionFailed
        }
        defer { combined.secureWipe() }
        let envelope = ThreadMessageEnvelope(version: 1, sealed: combined)
        return try NoctweaveCoder.encode(envelope)
    }

    private func decryptIfNeeded(_ data: Data) throws -> Data {
        guard useEncryption else {
            return data
        }
        guard let envelope = try? NoctweaveCoder.decode(ThreadMessageEnvelope.self, from: data),
              envelope.version == 1 else {
            throw ThreadMessageStoreError.unexpectedPlaintextInEncryptedMode
        }
        let sealed = try AES.GCM.SealedBox(combined: envelope.sealed)
        let key = try storageKey()
        guard let opened = try? AES.GCM.open(sealed, using: key) else {
            throw ThreadMessageStoreError.encryptionFailed
        }
        return opened
    }

    private func securelyRemoveFile(at url: URL) throws {
        bestEffortOverwriteFile(at: url)
        try FileManager.default.removeItem(at: url)
    }

    private func storageKey() throws -> SymmetricKey {
        try SecureStorageKeyProvider.shared.loadOrCreateKey(
            service: "com.noctyra.securestorage",
            account: "vault-key-v1"
        )
    }

    private func bestEffortOverwriteFile(at url: URL) {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true,
              let byteCount = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value,
              byteCount > 0,
              let handle = try? FileHandle(forWritingTo: url) else {
            return
        }
        defer { try? handle.close() }
        let chunkSize = 64 * 1024
        let zeroChunk = Data(repeating: 0, count: chunkSize)
        var remaining = byteCount
        try? handle.seek(toOffset: 0)
        while remaining > 0 {
            let writeCount = min(UInt64(chunkSize), remaining)
            if writeCount == UInt64(chunkSize) {
                try? handle.write(contentsOf: zeroChunk)
            } else {
                try? handle.write(contentsOf: Data(repeating: 0, count: Int(writeCount)))
            }
            remaining -= writeCount
        }
        try? handle.synchronize()
    }
}

private struct ThreadMessageEnvelope: Codable {
    let version: Int
    let sealed: Data
}

private struct ThreadMessagePayload: Codable {
    let messages: [Message]
}

private extension Data {
    mutating func secureWipe() {
        guard !isEmpty else { return }
        let byteCount = count
        withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            _ = memset_s(baseAddress, byteCount, 0, byteCount)
        }
        removeAll(keepingCapacity: false)
    }
}

private enum ThreadMessageStoreError: Error {
    case encryptionFailed
    case fileTooLarge
    case tooManyMessages
    case unexpectedPlaintextInEncryptedMode
}
