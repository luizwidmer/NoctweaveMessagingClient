import CryptoKit
import Foundation
import Security

enum ClientGroupNameStoreError: LocalizedError {
    case legacyNamesPresent
    case unavailable
    case sessionUnavailable
    case invalidRecord
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .legacyNamesPresent:
            "Older local group names are present in plaintext settings. Record their labels, then explicitly reset local app data before saving new labels."
        case .unavailable: "Protected group-name storage is unavailable. Unlock Keychain access and try again."
        case .sessionUnavailable: "Unlock the app before changing group names."
        case .invalidRecord: "Protected group names could not be read. Existing data was not replaced."
        case .tooLarge: "Group names exceed the protected storage limit."
        }
    }
}

/// A device-local Keychain record replaces the old plaintext group-name plist.
/// The account binds names to one local state container, including test fixtures.
@MainActor
struct ClientGroupNameStore {
    private static let legacyKey = "noctweave.groupNames"
    private static let maximumBytes = 128 * 1_024
    let service: String
    let account: String
    let defaults: UserDefaults

    init(stateURL: URL, scope: String,
         service: String = (Bundle.main.bundleIdentifier ?? "NoctweaveClient") + ".group-names.v1",
         defaults: UserDefaults = .standard) {
        self.service = service
        self.account = Data(SHA256.hash(data: Data((scope + ":" + stateURL.standardizedFileURL.path).utf8)))
            .base64EncodedString()
        self.defaults = defaults
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    func load() throws -> [String: String] {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        switch SecItemCopyMatching(request as CFDictionary, &result) {
        case errSecSuccess:
            guard var data = result as? Data else { throw ClientGroupNameStoreError.invalidRecord }
            defer { data.resetBytes(in: data.startIndex..<data.endIndex) }
            guard defaults.object(forKey: Self.legacyKey) == nil else { throw ClientGroupNameStoreError.legacyNamesPresent }
            guard data.count <= Self.maximumBytes,
                  let names = try? JSONDecoder().decode([String: String].self, from: data) else {
                throw ClientGroupNameStoreError.invalidRecord
            }
            return names
        case errSecItemNotFound:
            guard defaults.object(forKey: Self.legacyKey) == nil else { throw ClientGroupNameStoreError.legacyNamesPresent }
            return [:]
        default:
            throw ClientGroupNameStoreError.unavailable
        }
    }

    func save(_ names: [String: String]) throws {
        guard defaults.object(forKey: Self.legacyKey) == nil else { throw ClientGroupNameStoreError.legacyNamesPresent }
        var data = try JSONEncoder().encode(names)
        defer { data.resetBytes(in: data.startIndex..<data.endIndex) }
        guard data.count <= Self.maximumBytes else { throw ClientGroupNameStoreError.tooLarge }
        let update = [kSecValueData as String: data] as CFDictionary
        var status = SecItemUpdate(query as CFDictionary, update)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
            if status == errSecDuplicateItem { status = SecItemUpdate(query as CFDictionary, update) }
        }
        guard status == errSecSuccess else { throw ClientGroupNameStoreError.unavailable }
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ClientGroupNameStoreError.unavailable
        }
        defaults.removeObject(forKey: Self.legacyKey)
    }
}
