import Foundation
import PICCPCore
import CryptoKit
#if canImport(Security)
import Security
#endif

struct NoctyraPrefetchStatus: Codable, Equatable {
    var lastAttemptAt: Date?
    var lastSuccessAt: Date?
    var lastResult: String?
    var lastFetchedEnvelopeCount: Int
    var pendingEnvelopeCount: Int

    static let empty = NoctyraPrefetchStatus(
        lastAttemptAt: nil,
        lastSuccessAt: nil,
        lastResult: nil,
        lastFetchedEnvelopeCount: 0,
        pendingEnvelopeCount: 0
    )
}

struct NoctyraPrefetchConfig: Codable {
    var updatedAt: Date
    var profiles: [NoctyraPrefetchProfile]
}

struct NoctyraPrefetchProfile: Codable, Identifiable {
    var id: UUID
    var displayName: String
    var inboxId: String
    var inboxAccessKey: SigningKeyPair
    var relay: RelayEndpoint
    var relayAuthToken: String?
}

struct PrefetchedDirectEnvelopeRecord: Codable, Identifiable {
    var id: UUID { envelope.id }
    var profileId: UUID
    var inboxId: String
    var relay: RelayEndpoint
    var fetchedAt: Date
    var envelope: Envelope
}

@MainActor
final class CiphertextPrefetchStore {
    nonisolated static let appGroupIdentifier = "group.com.noctyra.client"
    private static let maxEncryptedFileBytes = 2_000_000

    private let directory: URL
    private let configURL: URL
    private let statusURL: URL
    private let directEnvelopeURL: URL

    init(directory: URL = CiphertextPrefetchStore.defaultDirectory()) {
        self.directory = directory
        self.configURL = directory.appendingPathComponent("prefetch-config.json")
        self.statusURL = directory.appendingPathComponent("prefetch-status.json")
        self.directEnvelopeURL = directory.appendingPathComponent("prefetched-direct-envelopes.json")
    }

    nonisolated static func defaultDirectory() -> URL {
        let fileManager = FileManager.default
        if let appGroupURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) {
            return appGroupURL.appendingPathComponent("CiphertextPrefetch", isDirectory: true)
        }
        return fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PICCPClient", isDirectory: true)
            .appendingPathComponent("CiphertextPrefetch", isDirectory: true)
    }

    func saveConfig(_ config: NoctyraPrefetchConfig) throws {
        try write(config, to: configURL, protection: .completeUntilFirstUserAuthentication)
    }

    func loadConfig() throws -> NoctyraPrefetchConfig? {
        try read(NoctyraPrefetchConfig.self, from: configURL)
    }

    func saveStatus(_ status: NoctyraPrefetchStatus) throws {
        try write(status, to: statusURL, protection: .completeUntilFirstUserAuthentication)
    }

    func loadStatus() throws -> NoctyraPrefetchStatus {
        try read(NoctyraPrefetchStatus.self, from: statusURL) ?? .empty
    }

    func appendDirectEnvelopes(_ records: [PrefetchedDirectEnvelopeRecord]) throws {
        guard !records.isEmpty else { return }
        var existing = try loadDirectEnvelopeRecords()
        var byId = Dictionary(uniqueKeysWithValues: existing.map { ($0.envelope.id, $0) })
        for record in records {
            byId[record.envelope.id] = record
        }
        existing = byId.values.sorted { $0.fetchedAt < $1.fetchedAt }
        try write(existing, to: directEnvelopeURL, protection: .completeUntilFirstUserAuthentication)
        var status = try loadStatus()
        status.pendingEnvelopeCount = existing.count
        try saveStatus(status)
    }

    func directEnvelopeRecords(profileId: UUID) throws -> [PrefetchedDirectEnvelopeRecord] {
        try loadDirectEnvelopeRecords().filter { $0.profileId == profileId }
    }

    func removeDirectEnvelopeIds(_ ids: Set<UUID>, profileId: UUID) throws {
        guard !ids.isEmpty else { return }
        let remaining = try loadDirectEnvelopeRecords().filter { record in
            record.profileId != profileId || !ids.contains(record.envelope.id)
        }
        try write(remaining, to: directEnvelopeURL, protection: .completeUntilFirstUserAuthentication)
        var status = try loadStatus()
        status.pendingEnvelopeCount = remaining.count
        try saveStatus(status)
    }

    private func loadDirectEnvelopeRecords() throws -> [PrefetchedDirectEnvelopeRecord] {
        try read([PrefetchedDirectEnvelopeRecord].self, from: directEnvelopeURL) ?? []
    }

    private func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attributes[.size] as? NSNumber,
           size.intValue > Self.maxEncryptedFileBytes {
            throw CiphertextPrefetchStoreError.fileTooLarge
        }
        let data = try Data(contentsOf: url)
        guard data.count <= Self.maxEncryptedFileBytes else {
            throw CiphertextPrefetchStoreError.fileTooLarge
        }
        let payload = try decrypt(data)
        return try PICCPCoder.decode(type, from: payload)
    }

    private func write<T: Encodable>(
        _ value: T,
        to url: URL,
        protection: FileProtectionType
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let payload = try PICCPCoder.encode(value, sortedKeys: true)
        let data = try encrypt(payload)
        try data.write(to: url, options: [.atomic])
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: protection], ofItemAtPath: url.path)
        #endif
        applyPrivacyAttributes(url: url)
    }

    private func encrypt(_ payload: Data) throws -> Data {
        let key = try CiphertextPrefetchKeychain.loadOrCreateKey()
        let sealed = try AES.GCM.seal(payload, using: key)
        guard let combined = sealed.combined else {
            throw CiphertextPrefetchStoreError.encryptionFailed
        }
        return try PICCPCoder.encode(CiphertextPrefetchFileEnvelope(version: 1, sealed: combined))
    }

    private func decrypt(_ data: Data) throws -> Data {
        let envelope = try PICCPCoder.decode(CiphertextPrefetchFileEnvelope.self, from: data)
        guard envelope.version == 1 else {
            throw CiphertextPrefetchStoreError.encryptionFailed
        }
        let sealed = try AES.GCM.SealedBox(combined: envelope.sealed)
        let key = try CiphertextPrefetchKeychain.loadOrCreateKey()
        guard let opened = try? AES.GCM.open(sealed, using: key) else {
            throw CiphertextPrefetchStoreError.encryptionFailed
        }
        return opened
    }

    private func applyPrivacyAttributes(url: URL) {
        do {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableURL = url
            try mutableURL.setResourceValues(values)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            print("[client] Failed to apply prefetch privacy attributes: \(error)")
        }
    }
}

private struct CiphertextPrefetchFileEnvelope: Codable {
    let version: Int
    let sealed: Data
}

private enum CiphertextPrefetchStoreError: Error {
    case encryptionFailed
    case fileTooLarge
}

#if canImport(Security)
private enum CiphertextPrefetchKeychain {
    private static let service = "com.noctyra.ciphertext-prefetch"
    private static let account = "prefetch-store-key-v1"

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
            throw CiphertextPrefetchKeychainError.unavailable(status: status)
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
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #endif
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            return
        }
        guard status == errSecSuccess else {
            throw CiphertextPrefetchKeychainError.unavailable(status: status)
        }
    }
}

private enum CiphertextPrefetchKeychainError: Error {
    case unavailable(status: OSStatus)
}
#endif
