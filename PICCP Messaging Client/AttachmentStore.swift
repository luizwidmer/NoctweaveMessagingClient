import CryptoKit
import Foundation
import PICCPCore
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
        let url = directory.appendingPathComponent(fileName)
        let payload = try encryptIfNeeded(data)
        try writeData(payload, to: url)
        return fileName
    }

    func loadAttachment(fileName: String) throws -> Data {
        let url = directory.appendingPathComponent(fileName)
        let data = try Data(contentsOf: url)
        return try decryptIfNeeded(data)
    }

    func deleteAttachment(fileName: String) throws {
        let url = directory.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func encryptIfNeeded(_ payload: Data) throws -> Data {
        guard useEncryption else {
            return payload
        }
        let key = try AttachmentKeychain.loadOrCreateKey()
        let sealed = try AES.GCM.seal(payload, using: key)
        guard let combined = sealed.combined else {
            throw AttachmentStoreError.encryptionFailed
        }
        let envelope = AttachmentEnvelope(version: 1, sealed: combined)
        return try PICCPCoder.encode(envelope)
    }

    private func decryptIfNeeded(_ data: Data) throws -> Data {
        guard useEncryption else {
            return data
        }
        if let envelope = try? PICCPCoder.decode(AttachmentEnvelope.self, from: data),
           envelope.version == 1 {
            let key = try AttachmentKeychain.loadOrCreateKey()
            let sealed = try AES.GCM.SealedBox(combined: envelope.sealed)
            return try AES.GCM.open(sealed, using: key)
        }
        return data
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

    private func applyPrivacyAttributes(url: URL) {
        do {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableURL = url
            try mutableURL.setResourceValues(values)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            print("[client] Failed to apply attachment privacy attributes: \(error)")
        }
    }
}

private struct AttachmentEnvelope: Codable {
    let version: Int
    let sealed: Data
}

private enum AttachmentStoreError: Error {
    case encryptionFailed
}

#if canImport(Security)
private enum AttachmentKeychain {
    private static let service = "com.lattice.attachments"
    private static let account = "attachment-key"

    static func loadOrCreateKey() throws -> SymmetricKey {
        if let existing = try loadKey() {
            return existing
        }
        let key = SymmetricKey(size: .bits256)
        try saveKey(key)
        return key
    }

    private static func loadKey() throws -> SymmetricKey? {
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
        guard status == errSecSuccess, let data = item as? Data else {
            throw AttachmentKeychainError.unavailable(status: status)
        }
        return SymmetricKey(data: data)
    }

    private static func saveKey(_ key: SymmetricKey) throws {
        let data = key.withUnsafeBytes { Data($0) }
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
