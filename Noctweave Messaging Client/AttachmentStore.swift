import CryptoKit
import Foundation
import NoctweaveCore

@MainActor
final class AttachmentStore {
    private static let maximumStoredAttachmentBytes = 12 * 1024 * 1024
    private let directory: URL
    private let useEncryption: Bool

    init(directory: URL, useEncryption: Bool = true) {
        self.directory = directory
        self.useEncryption = useEncryption
    }

    func saveAttachment(_ data: Data, descriptor: AttachmentDescriptor) throws -> String {
        guard descriptor.isStructurallyValid(),
              data.count == descriptor.byteCount,
              data.count <= AttachmentDescriptor.maximumTransportBytes,
              AttachmentCrypto.sha256(data) == descriptor.sha256 else {
            throw AttachmentStoreError.invalidPayload
        }
        let fileName = "\(descriptor.id.uuidString).bin"
        let url = try attachmentURL(fileName: fileName)
        var payload = try encryptIfNeeded(data)
        defer { payload.secureWipe() }
        guard payload.count <= Self.maximumStoredAttachmentBytes else {
            throw AttachmentStoreError.fileTooLarge
        }
        try writeData(payload, to: url)
        return fileName
    }

    /// Stores bytes that have already passed transport integrity checks and
    /// local sanitization. Sanitization can legitimately change the byte count
    /// and digest, so the original wire descriptor must not be re-applied.
    func saveSanitizedAttachment(_ data: Data, attachmentId: UUID) throws -> String {
        guard !data.isEmpty,
              data.count <= AttachmentDescriptor.maximumTransportBytes else {
            throw AttachmentStoreError.invalidPayload
        }
        let fileName = "\(attachmentId.uuidString).bin"
        let url = try attachmentURL(fileName: fileName)
        var payload = try encryptIfNeeded(data)
        defer { payload.secureWipe() }
        guard payload.count <= Self.maximumStoredAttachmentBytes else {
            throw AttachmentStoreError.fileTooLarge
        }
        try writeData(payload, to: url)
        return fileName
    }

    func loadAttachment(fileName: String) throws -> Data {
        var encrypted = try loadEncryptedAttachment(fileName: fileName)
        defer { encrypted.secureWipe() }
        let decrypted = try decryptAttachmentPayload(encrypted)
        guard decrypted.count <= AttachmentDescriptor.maximumTransportBytes else {
            throw AttachmentStoreError.fileTooLarge
        }
        return decrypted
    }

    func loadEncryptedAttachment(fileName: String) throws -> Data {
        let url = try attachmentURL(fileName: fileName)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true,
              let fileSize = values.fileSize,
              fileSize >= 0,
              fileSize <= Self.maximumStoredAttachmentBytes else {
            throw AttachmentStoreError.fileTooLarge
        }
        let data = try Data(contentsOf: url)
        guard data.count <= Self.maximumStoredAttachmentBytes else {
            throw AttachmentStoreError.fileTooLarge
        }
        return data
    }

    func decryptAttachmentPayload(_ data: Data) throws -> Data {
        guard data.count <= Self.maximumStoredAttachmentBytes else {
            throw AttachmentStoreError.fileTooLarge
        }
        return try decryptIfNeeded(data)
    }

    func deleteAttachment(fileName: String) throws {
        let url = try attachmentURL(fileName: fileName)
        if FileManager.default.fileExists(atPath: url.path) {
            try securelyRemoveFile(at: url)
        }
    }

    func warmUpKeychain() throws {
        guard useEncryption else { return }
        _ = try storageKey()
    }

    private func encryptIfNeeded(_ payload: Data) throws -> Data {
        guard useEncryption else {
            return payload
        }
        let key = try storageKey()
        let sealed = try AES.GCM.seal(payload, using: key)
        guard var combined = sealed.combined else {
            throw AttachmentStoreError.encryptionFailed
        }
        defer { combined.secureWipe() }
        let envelope = AttachmentEnvelope(version: 1, sealed: combined)
        return try NoctweaveCoder.encode(envelope)
    }

    private func decryptIfNeeded(_ data: Data) throws -> Data {
        guard useEncryption else {
            return data
        }
        guard let envelope = try? NoctweaveCoder.decode(AttachmentEnvelope.self, from: data),
              envelope.version == 1 else {
            throw AttachmentStoreError.unexpectedPlaintextInEncryptedMode
        }
        let sealed = try AES.GCM.SealedBox(combined: envelope.sealed)
        let key = try storageKey()
        guard let opened = try? AES.GCM.open(sealed, using: key) else {
            throw AttachmentStoreError.encryptionFailed
        }
        return opened
    }

    private func writeData(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
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

    private func attachmentURL(fileName: String) throws -> URL {
        let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed == (trimmed as NSString).lastPathComponent,
              trimmed.hasSuffix(".bin"),
              UUID(uuidString: String(trimmed.dropLast(4))) != nil else {
            throw AttachmentStoreError.invalidFileName
        }
        return directory.appendingPathComponent(trimmed, isDirectory: false)
    }

    private func applyPrivacyAttributes(url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func storageKey() throws -> SymmetricKey {
        try SecureStorageKeyProvider.shared.loadOrCreateKey(
            service: "com.noctweave.securestorage",
            account: "vault-key-v1"
        )
    }

    private func securelyRemoveFile(at url: URL) throws {
        bestEffortOverwriteFile(at: url)
        try FileManager.default.removeItem(at: url)
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

private struct AttachmentEnvelope: Codable {
    let version: Int
    let sealed: Data
}

private enum AttachmentStoreError: Error {
    case encryptionFailed
    case invalidFileName
    case invalidPayload
    case fileTooLarge
    case unexpectedPlaintextInEncryptedMode
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
