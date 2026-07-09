import AppIntents
import CryptoKit
import Foundation
import NoctweaveCore
import Security
import WidgetKit

@available(iOS 17.0, *)
struct NoctyraWidgetFetchIntent: AppIntent {
    static var title: LocalizedStringResource = "Fetch Ciphertext"
    static var description = IntentDescription("Fetches encrypted relay envelopes without decrypting or acknowledging messages.")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        await NoctyraWidgetPrefetchRunner.markFetching()
        let result = await NoctyraWidgetPrefetchRunner().run()
        await NoctyraWidgetPrefetchRunner.publish(result: result)
        return .result()
    }
}

private struct NoctyraWidgetPrefetchResult {
    var fetchedEnvelopeCount: Int
    var profileCount: Int
    var status: String
    var lastAttemptAt: Date
    var lastSuccessAt: Date?
}

private struct WidgetPrefetchStatus: Codable, Equatable {
    var lastAttemptAt: Date?
    var lastSuccessAt: Date?
    var lastResult: String?

    static let empty = WidgetPrefetchStatus(lastAttemptAt: nil, lastSuccessAt: nil, lastResult: nil)
}

private struct WidgetPrefetchConfig: Codable {
    var updatedAt: Date
    var profiles: [WidgetPrefetchProfile]
}

private struct WidgetPrefetchProfile: Codable, Identifiable {
    var id: UUID
    var inboxId: String
    var inboxAccessKey: SigningKeyPair
    var relay: RelayEndpoint
    var relayAuthToken: String?
}

private enum WidgetPrefetchStoreError: Error {
    case encryptedFileTooLarge
    case encryptionFailed
    case invalidBatch
}

private struct WidgetPrefetchEnvelopeFile: Codable {
    let version: Int
    let sealed: Data
}

private struct NoctyraWidgetPrefetchStore {
    static let appGroupIdentifier = "group.com.noctyra.client"
    static let snapshotKey = "NoctyraSyncDashboardSnapshot"
    private static let maxEncryptedFileBytes = 2_000_000
    private static let maxPrefetchProfiles = 64
    private static let maxPrefetchedRecords = 512

    private let directory: URL
    private let configURL: URL
    private let statusURL: URL
    private let batchURL: URL

    init() {
        let base = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier)?
            .appendingPathComponent("CiphertextPrefetch", isDirectory: true)
        ?? FileManager.default.temporaryDirectory.appendingPathComponent("NoctyraCiphertextPrefetch", isDirectory: true)
        self.directory = base
        self.configURL = base.appendingPathComponent("prefetch-config.json")
        self.statusURL = base.appendingPathComponent("prefetch-status.json")
        self.batchURL = base.appendingPathComponent("prefetched-ciphertext-batch.bin")
    }

    func loadConfig() throws -> WidgetPrefetchConfig? {
        guard var payload = try readPayload(from: configURL) else { return nil }
        defer { payload.secureWipe() }
        let decoded = try NoctweaveCoder.decode(WidgetPrefetchConfig.self, from: payload)
        return WidgetPrefetchConfig(updatedAt: decoded.updatedAt, profiles: Array(decoded.profiles.prefix(Self.maxPrefetchProfiles)))
    }

    func loadStatus() throws -> WidgetPrefetchStatus {
        guard var payload = try readPayload(from: statusURL) else { return .empty }
        defer { payload.secureWipe() }
        return try NoctweaveCoder.decode(WidgetPrefetchStatus.self, from: payload)
    }

    func saveStatus(_ status: WidgetPrefetchStatus) throws {
        try write(status, to: statusURL)
    }

    func prefetchedRecordCount() throws -> Int {
        try loadPrefetchRecords().count
    }

    func appendDirectEnvelopes(_ records: [(profile: WidgetPrefetchProfile, fetchedAt: Date, envelope: Envelope)]) throws {
        guard !records.isEmpty else { return }
        var existing = try loadPrefetchRecords()
        var byId = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        for record in records {
            byId[record.envelope.id] = try DecentralizedPrefetchRecord(
                id: record.envelope.id,
                kind: .directMessage,
                relayIdentifier: relayIdentifier(for: record.profile.relay),
                inboxId: record.profile.inboxId,
                groupId: nil,
                stagedAt: record.fetchedAt,
                sealedEnvelope: NoctweaveCoder.encode(record.envelope),
                acknowledgementDeferred: true
            )
        }
        existing = cappedPrefetchRecords(Array(byId.values))
        try writePrefetchRecords(existing)
    }

    private func loadPrefetchRecords() throws -> [DecentralizedPrefetchRecord] {
        try read(DecentralizedPrefetchBatch.self, from: batchURL)?.records ?? []
    }

    private func writePrefetchRecords(_ records: [DecentralizedPrefetchRecord]) throws {
        if records.isEmpty {
            try? FileManager.default.removeItem(at: batchURL)
            return
        }
        let capped = cappedPrefetchRecords(records)
        let batch = DecentralizedPrefetchBatch(records: capped, stagedAt: capped.map(\.stagedAt).max() ?? Date())
        guard batch.isCiphertextOnly else { throw WidgetPrefetchStoreError.invalidBatch }
        try write(batch, to: batchURL)
    }

    private func cappedPrefetchRecords(_ records: [DecentralizedPrefetchRecord]) -> [DecentralizedPrefetchRecord] {
        Array(records.sorted { lhs, rhs in
            if lhs.stagedAt == rhs.stagedAt {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.stagedAt < rhs.stagedAt
        }.suffix(Self.maxPrefetchedRecords))
    }

    private func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard var payload = try readPayload(from: url) else { return nil }
        defer { payload.secureWipe() }
        return try NoctweaveCoder.decode(type, from: payload)
    }

    private func readPayload(from url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attributes[.size] as? NSNumber, size.intValue > Self.maxEncryptedFileBytes {
            throw WidgetPrefetchStoreError.encryptedFileTooLarge
        }
        var data = try Data(contentsOf: url)
        defer { data.secureWipe() }
        guard data.count <= Self.maxEncryptedFileBytes else {
            throw WidgetPrefetchStoreError.encryptedFileTooLarge
        }
        return try decrypt(data)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var payload = try NoctweaveCoder.encode(value, sortedKeys: true)
        defer { payload.secureWipe() }
        var data = try encrypt(payload)
        defer { data.secureWipe() }
        guard data.count <= Self.maxEncryptedFileBytes else {
            throw WidgetPrefetchStoreError.encryptedFileTooLarge
        }
        try data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func encrypt(_ payload: Data) throws -> Data {
        let key = try NoctyraWidgetPrefetchKeychain.loadOrCreateKey()
        let sealed = try AES.GCM.seal(payload, using: key)
        guard var combined = sealed.combined else {
            throw WidgetPrefetchStoreError.encryptionFailed
        }
        defer { combined.secureWipe() }
        return try NoctweaveCoder.encode(WidgetPrefetchEnvelopeFile(version: 1, sealed: combined))
    }

    private func decrypt(_ data: Data) throws -> Data {
        let envelope = try NoctweaveCoder.decode(WidgetPrefetchEnvelopeFile.self, from: data)
        guard envelope.version == 1 else { throw WidgetPrefetchStoreError.encryptionFailed }
        let sealed = try AES.GCM.SealedBox(combined: envelope.sealed)
        let key = try NoctyraWidgetPrefetchKeychain.loadOrCreateKey()
        guard let opened = try? AES.GCM.open(sealed, using: key) else {
            throw WidgetPrefetchStoreError.encryptionFailed
        }
        return opened
    }

    private func relayIdentifier(for relay: RelayEndpoint) -> String {
        "\(relay.transport.rawValue):\(relay.useTLS ? "tls" : "plain"):\(relay.host):\(relay.port)"
    }

    static func writeSnapshot(_ snapshot: NoctyraSyncWidgetSnapshot) {
        guard let payload = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults(suiteName: appGroupIdentifier)?.set(payload, forKey: snapshotKey)
        WidgetCenter.shared.reloadTimelines(ofKind: "NoctyraSyncDashboardWidget")
    }
}

private enum NoctyraWidgetPrefetchKeychain {
    private static let service = "com.noctyra.ciphertext-prefetch"
    private static let account = "prefetch-store-key-v1"
    private static let accessGroup = "9MY7SXN56X.com.noctyra.prefetch"

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
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecAttrAccessGroup as String: accessGroup
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, var data = item as? Data else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        defer { data.secureWipe() }
        return SymmetricKey(data: data)
    }

    private static func saveKey(_ key: SymmetricKey) throws {
        var data = key.withUnsafeBytes { Data($0) }
        defer { data.secureWipe() }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrAccessGroup as String: accessGroup
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem { return }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}

private struct NoctyraWidgetPrefetchRunner {
    private let store = NoctyraWidgetPrefetchStore()
    private let maxEnvelopeCountPerProfile = 100

    func run() async -> NoctyraWidgetPrefetchResult {
        let startedAt = Date()
        do {
            guard let config = try store.loadConfig(), !config.profiles.isEmpty else {
                let status = WidgetPrefetchStatus(
                    lastAttemptAt: startedAt,
                    lastSuccessAt: nil,
                    lastResult: "No prefetch profiles are configured."
                )
                try? store.saveStatus(status)
                return NoctyraWidgetPrefetchResult(
                    fetchedEnvelopeCount: 0,
                    profileCount: 0,
                    status: status.lastResult ?? "No profiles.",
                    lastAttemptAt: startedAt,
                    lastSuccessAt: nil
                )
            }

            var fetchedCount = 0
            var failures = 0
            for profile in config.profiles {
                do {
                    let envelopes = try await fetchDirectEnvelopes(for: profile)
                    try store.appendDirectEnvelopes(envelopes.map {
                        (profile: profile, fetchedAt: Date(), envelope: $0)
                    })
                    fetchedCount += envelopes.count
                } catch {
                    failures += 1
                }
            }

            let statusText = failures == 0
                ? "Encrypted ciphertext prefetch completed."
                : "Encrypted ciphertext prefetch completed with limited profile failures."
            let status = WidgetPrefetchStatus(
                lastAttemptAt: startedAt,
                lastSuccessAt: failures == 0 ? Date() : nil,
                lastResult: statusText
            )
            try? store.saveStatus(status)
            return NoctyraWidgetPrefetchResult(
                fetchedEnvelopeCount: fetchedCount,
                profileCount: config.profiles.count,
                status: statusText,
                lastAttemptAt: startedAt,
                lastSuccessAt: status.lastSuccessAt
            )
        } catch {
            let statusText = "Encrypted ciphertext prefetch failed."
            try? store.saveStatus(WidgetPrefetchStatus(lastAttemptAt: startedAt, lastSuccessAt: nil, lastResult: statusText))
            return NoctyraWidgetPrefetchResult(
                fetchedEnvelopeCount: 0,
                profileCount: 0,
                status: statusText,
                lastAttemptAt: startedAt,
                lastSuccessAt: nil
            )
        }
    }

    static func markFetching() async {
        let store = NoctyraWidgetPrefetchStore()
        let status = (try? store.loadStatus()) ?? .empty
        let profileCount = (try? store.loadConfig()?.profiles.count) ?? 0
        let stagedCount = (try? store.prefetchedRecordCount()) ?? 0
        await updateSurfaces(
            isFetching: true,
            lastAttemptAt: Date(),
            lastSuccessAt: status.lastSuccessAt,
            fetchedEnvelopeCount: 0,
            stagedEnvelopeCount: stagedCount,
            profileCount: profileCount,
            status: "Fetching encrypted relay envelopes."
        )
    }

    static func publish(result: NoctyraWidgetPrefetchResult) async {
        let store = NoctyraWidgetPrefetchStore()
        let stagedCount = (try? store.prefetchedRecordCount()) ?? 0
        await updateSurfaces(
            isFetching: false,
            lastAttemptAt: result.lastAttemptAt,
            lastSuccessAt: result.lastSuccessAt,
            fetchedEnvelopeCount: result.fetchedEnvelopeCount,
            stagedEnvelopeCount: stagedCount,
            profileCount: result.profileCount,
            status: result.status
        )
    }

    private func fetchDirectEnvelopes(for profile: WidgetPrefetchProfile) async throws -> [Envelope] {
        var request = FetchRequest(
            inboxId: profile.inboxId,
            routingToken: profile.inboxId,
            maxCount: maxEnvelopeCountPerProfile,
            longPollTimeoutSeconds: nil
        )
        let publicKey = profile.inboxAccessKey.publicKeyData
        let proof = try makeActorProof(signingKey: profile.inboxAccessKey, publicSigningKey: publicKey) { actorProof in
            try request.signableData(for: actorProof)
        }
        request = FetchRequest(
            inboxId: profile.inboxId,
            routingToken: profile.inboxId,
            maxCount: maxEnvelopeCountPerProfile,
            longPollTimeoutSeconds: nil,
            accessProof: proof
        )
        let response = try await RelayClient(endpoint: profile.relay, authToken: profile.relayAuthToken)
            .send(.fetch(request), timeout: 8)
        guard response.type == .messages else {
            throw NSError(domain: "Noctyra.WidgetPrefetch", code: 1)
        }
        return Array((response.messages ?? []).prefix(maxEnvelopeCountPerProfile))
    }

    private func makeActorProof(
        signingKey: SigningKeyPair,
        publicSigningKey: Data,
        signableDataBuilder: (RelayActorProof) throws -> Data
    ) throws -> RelayActorProof {
        let signedAt = Date()
        let nonce = UUID()
        let placeholder = RelayActorProof(
            fingerprint: CryptoBox.fingerprint(for: publicSigningKey),
            publicSigningKey: publicSigningKey,
            signedAt: signedAt,
            nonce: nonce,
            signature: Data()
        )
        let signature = try signingKey.sign(try signableDataBuilder(placeholder))
        return RelayActorProof(
            fingerprint: CryptoBox.fingerprint(for: publicSigningKey),
            publicSigningKey: publicSigningKey,
            signedAt: signedAt,
            nonce: nonce,
            signature: signature
        )
    }

    private static func updateSurfaces(
        isFetching: Bool,
        lastAttemptAt: Date?,
        lastSuccessAt: Date?,
        fetchedEnvelopeCount: Int,
        stagedEnvelopeCount: Int,
        profileCount: Int,
        status: String
    ) async {
        let snapshot = NoctyraSyncWidgetSnapshot(
            updatedAt: Date(),
            isFetching: isFetching,
            lastAttemptAt: lastAttemptAt,
            lastSuccessAt: lastSuccessAt,
            fetchedEnvelopeCount: fetchedEnvelopeCount,
            stagedEnvelopeCount: stagedEnvelopeCount,
            profileCount: profileCount,
            status: status
        )
        NoctyraWidgetPrefetchStore.writeSnapshot(snapshot)
    }
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
