import CryptoKit
import Foundation
import NoctweaveCore
#if canImport(Security)
import Security
#endif

@MainActor
final class AttachmentStore {
    private let directory: URL
    private let useEncryption: Bool

    init(directory: URL, useEncryption: Bool = true) {
        self.directory = directory
        self.useEncryption = useEncryption
    }

    func saveAttachment(_ data: Data, descriptor: AttachmentDescriptor) throws -> String {
        let fileName = "\(descriptor.id.uuidString).bin"
        let url = try attachmentURL(fileName: fileName)
        var payload = try encryptIfNeeded(data)
        defer { payload.secureWipe() }
        try writeData(payload, to: url)
        return fileName
    }

    func loadAttachment(fileName: String) throws -> Data {
        var encrypted = try loadEncryptedAttachment(fileName: fileName)
        defer { encrypted.secureWipe() }
        return try decryptAttachmentPayload(encrypted)
    }

    func loadEncryptedAttachment(fileName: String) throws -> Data {
        let url = try attachmentURL(fileName: fileName)
        return try Data(contentsOf: url)
    }

    func decryptAttachmentPayload(_ data: Data) throws -> Data {
        try decryptIfNeeded(data)
    }

    func deleteAttachment(fileName: String) throws {
        let url = try attachmentURL(fileName: fileName)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    func warmUpKeychain() throws {
        guard useEncryption else { return }
        _ = try AttachmentKeychain.loadOrCreateKey()
    }

    private func encryptIfNeeded(_ payload: Data) throws -> Data {
        guard useEncryption else {
            return payload
        }
        let key = try AttachmentKeychain.loadOrCreateKey()
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
        let key = try AttachmentKeychain.loadOrCreateKey()
        guard let opened = try? AES.GCM.open(sealed, using: key) else {
            throw AttachmentStoreError.encryptionFailed
        }
        return opened
    }

    private func writeData(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: url, options: [.atomic])
        #endif
        applyPrivacyAttributes(url: url)
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

    private func applyPrivacyAttributes(url: URL) {
        do {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableURL = url
            try mutableURL.setResourceValues(values)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            print("[client] Failed to apply attachment privacy attributes")
        }
    }
}

private struct AttachmentEnvelope: Codable {
    let version: Int
    let sealed: Data
}

private enum AttachmentStoreError: Error {
    case encryptionFailed
    case invalidFileName
    case unexpectedPlaintextInEncryptedMode
}

#if canImport(Security)
private enum AttachmentKeychain {
    private static let service = "com.noctyra.securestorage"
    private static let account = "vault-key-v1"

    static func loadOrCreateKey() throws -> SymmetricKey {
        if let existing = try loadKey(service: service, account: account) {
            return existing
        }
        let key = SymmetricKey(size: .bits256)
        try saveKey(key, service: service, account: account)
        return key
    }

    private static func loadKey(service: String, account: String) throws -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, var data = item as? Data else {
            throw AttachmentKeychainError.unavailable(status: status)
        }
        defer { data.secureWipe() }
        return SymmetricKey(data: data)
    }

    private static func saveKey(_ key: SymmetricKey, service: String, account: String) throws {
        var data = key.withUnsafeBytes { Data($0) }
        defer { data.secureWipe() }
        var attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
        #if os(iOS)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        #endif
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecAttrSynchronizable as String: kCFBooleanFalse as Any
            ]
            let update: [String: Any] = [
                kSecValueData as String: data
            ]
            let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw AttachmentKeychainError.unavailable(status: updateStatus)
            }
            return
        }
        guard status == errSecSuccess else {
            throw AttachmentKeychainError.unavailable(status: status)
        }
    }
}

private enum AttachmentKeychainError: Error {
    case unavailable(status: OSStatus)
}
#else
private enum AttachmentKeychain {
    static func loadOrCreateKey() throws -> SymmetricKey {
        throw AttachmentStoreError.encryptionFailed
    }
}
#endif

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
