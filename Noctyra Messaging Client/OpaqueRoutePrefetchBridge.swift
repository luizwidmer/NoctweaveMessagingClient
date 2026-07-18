import CryptoKit
import Foundation
import NoctweaveCore
import Security

struct OpaqueRoutePrefetchRouteV1: Codable {
    let routeID: OpaqueReceiveRouteIDV2
    let readCredential: RouteReadCredentialV2
    let relay: RelayEndpoint
    let committedCursor: OpaqueRouteCursorV2?
}

struct OpaqueRoutePrefetchConfigV1: Codable {
    let version: Int
    let updatedAt: Date
    let routes: [OpaqueRoutePrefetchRouteV1]
}

private struct OpaqueRoutePrefetchSealedFileV1: Codable {
    let version: Int
    let ciphertext: Data
}

enum OpaqueRoutePrefetchBridge {
    static let appGroupIdentifier = "group.com.noctyra.client"
    static let snapshotKey = "NoctyraSyncDashboardSnapshot"
    static let maximumRoutes = 256
    static let maximumConfigBytes = 2 * 1_024 * 1_024
    static let authenticatedData = Data("NOCTYRA/OPAQUE-ROUTE-PREFETCH-CONFIG/V1".utf8)

    private static let keychainService = "com.noctyra.opaque-route-prefetch"
    private static let keychainAccount = "route-prefetch-key-v1"
    private static let keychainAccessGroup = "9MY7SXN56X.com.noctyra.prefetch"

    static func update(from state: ClientState) throws {
        guard let persona = state.personas.first(where: { $0.id == state.activePersonaID }) else {
            throw PrefetchBridgeError.invalidState
        }
        let routes = Array(
            persona.relationships
                .flatMap(\.localReceiveRoutes)
                .filter { $0.route.lease.expiresAt > Date() }
                .prefix(maximumRoutes)
                .map {
                    OpaqueRoutePrefetchRouteV1(
                        routeID: $0.route.routeID,
                        readCredential: $0.clientCapabilities.readCredential,
                        relay: $0.relay,
                        committedCursor: $0.committedCursor
                    )
                }
        )
        let config = OpaqueRoutePrefetchConfigV1(
            version: 1,
            updatedAt: Date(),
            routes: routes
        )
        let directory = try sharedDirectory()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let keyData = try loadOrCreateKeyData()
        let key = SymmetricKey(data: keyData)
        var plaintext = try NoctweaveCoder.encode(config, sortedKeys: true)
        defer { plaintext.wipePrefetchBytes() }
        guard plaintext.count <= maximumConfigBytes else {
            throw PrefetchBridgeError.configTooLarge
        }
        let sealed = try AES.GCM.seal(
            plaintext,
            using: key,
            authenticating: authenticatedData
        )
        guard var combined = sealed.combined else {
            throw PrefetchBridgeError.encryptionFailed
        }
        defer { combined.wipePrefetchBytes() }
        var encoded = try NoctweaveCoder.encode(
            OpaqueRoutePrefetchSealedFileV1(version: 1, ciphertext: combined),
            sortedKeys: true
        )
        defer { encoded.wipePrefetchBytes() }
        guard encoded.count <= maximumConfigBytes else {
            throw PrefetchBridgeError.configTooLarge
        }
        let configURL = directory.appendingPathComponent("route-config-v1.bin")
        #if os(iOS)
        try encoded.write(to: configURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try encoded.write(to: configURL, options: .atomic)
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)

        // The foreground client remains authoritative. Widget pulls never
        // commit relay cursors, so clearing its cache cannot lose a message.
        let batches = directory.appendingPathComponent("batches", isDirectory: true)
        if FileManager.default.fileExists(atPath: batches.path) {
            try? FileManager.default.removeItem(at: batches)
        }
    }

    private static func sharedDirectory() throws -> URL {
        guard let root = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            throw PrefetchBridgeError.appGroupUnavailable
        }
        return root.appendingPathComponent("OpaqueRoutePrefetch", isDirectory: true)
    }

    private static func loadOrCreateKeyData() throws -> Data {
        if let existing = try loadKeyData() { return existing }
        var bytes = Data(count: 32)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, 32, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw PrefetchBridgeError.keychainFailure(status) }
        defer { bytes.wipePrefetchBytes() }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: bytes,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrAccessGroup as String: keychainAccessGroup
        ]
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        if addStatus == errSecDuplicateItem, let existing = try loadKeyData() {
            return existing
        }
        guard addStatus == errSecSuccess else {
            throw PrefetchBridgeError.keychainFailure(addStatus)
        }
        return bytes
    }

    private static func loadKeyData() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecAttrAccessGroup as String: keychainAccessGroup
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = item as? Data,
              data.count == 32 else {
            throw PrefetchBridgeError.keychainFailure(status)
        }
        return data
    }
}

private enum PrefetchBridgeError: Error {
    case invalidState
    case appGroupUnavailable
    case configTooLarge
    case encryptionFailed
    case keychainFailure(OSStatus)
}

private extension Data {
    mutating func wipePrefetchBytes() {
        guard !isEmpty else { return }
        resetBytes(in: startIndex..<endIndex)
        removeAll(keepingCapacity: false)
    }
}
