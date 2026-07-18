import AppIntents
import CryptoKit
import Foundation
import NoctweaveCore
import Security
import WidgetKit

@available(iOS 17.0, *)
struct NoctyraWidgetFetchIntent: AppIntent {
    static var title: LocalizedStringResource = "Fetch Sealed Packets"
    static var description = IntentDescription(
        "Stages opaque relay packets without decrypting payloads or committing receive cursors."
    )
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        await OpaqueRouteWidgetRunner.markFetching()
        let result = await OpaqueRouteWidgetRunner().run()
        await OpaqueRouteWidgetRunner.publish(result: result)
        return .result()
    }
}

private struct OpaqueRouteWidgetResult {
    let fetchedPacketCount: Int
    let routeCount: Int
    let status: String
    let lastAttemptAt: Date
    let lastSuccessAt: Date?
}

private struct OpaqueRoutePrefetchRouteV1: Codable {
    let routeID: OpaqueReceiveRouteIDV2
    let readCredential: RouteReadCredentialV2
    let relay: RelayEndpoint
    let committedCursor: OpaqueRouteCursorV2?
}

private struct OpaqueRoutePrefetchConfigV1: Codable {
    let version: Int
    let updatedAt: Date
    let routes: [OpaqueRoutePrefetchRouteV1]
}

private struct OpaqueRoutePrefetchSealedFileV1: Codable {
    let version: Int
    let ciphertext: Data
}

private enum OpaqueRouteWidgetError: Error {
    case appGroupUnavailable
    case invalidConfig
    case configTooLarge
    case keyUnavailable
    case decryptionFailed
    case relayRejected
}

private struct OpaqueRouteWidgetStore {
    static let appGroupIdentifier = "group.com.noctyra.client"
    static let snapshotKey = "NoctyraSyncDashboardSnapshot"
    static let maximumRoutes = 256
    static let maximumConfigBytes = 2 * 1_024 * 1_024
    static let authenticatedData = Data("NOCTYRA/OPAQUE-ROUTE-PREFETCH-CONFIG/V1".utf8)

    private static let keychainService = "com.noctyra.opaque-route-prefetch"
    private static let keychainAccount = "route-prefetch-key-v1"
    private static let keychainAccessGroup = "9MY7SXN56X.com.noctyra.prefetch"

    let directory: URL
    let configURL: URL
    let batchesDirectory: URL

    init() throws {
        guard let root = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier
        ) else {
            throw OpaqueRouteWidgetError.appGroupUnavailable
        }
        directory = root.appendingPathComponent("OpaqueRoutePrefetch", isDirectory: true)
        configURL = directory.appendingPathComponent("route-config-v1.bin")
        batchesDirectory = directory.appendingPathComponent("batches", isDirectory: true)
    }

    func loadConfig() throws -> OpaqueRoutePrefetchConfigV1? {
        guard FileManager.default.fileExists(atPath: configURL.path) else { return nil }
        let values = try configURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true,
              let size = values.fileSize,
              size >= 0,
              size <= Self.maximumConfigBytes else {
            throw OpaqueRouteWidgetError.configTooLarge
        }
        var stored = try Data(contentsOf: configURL)
        defer { stored.wipeWidgetBytes() }
        guard stored.count <= Self.maximumConfigBytes else {
            throw OpaqueRouteWidgetError.configTooLarge
        }
        let envelope = try NoctweaveCoder.decode(
            OpaqueRoutePrefetchSealedFileV1.self,
            from: stored
        )
        guard envelope.version == 1 else { throw OpaqueRouteWidgetError.invalidConfig }
        let keyData = try loadKeyData()
        let box = try AES.GCM.SealedBox(combined: envelope.ciphertext)
        guard var plaintext = try? AES.GCM.open(
            box,
            using: SymmetricKey(data: keyData),
            authenticating: Self.authenticatedData
        ) else {
            throw OpaqueRouteWidgetError.decryptionFailed
        }
        defer { plaintext.wipeWidgetBytes() }
        let config = try NoctweaveCoder.decode(OpaqueRoutePrefetchConfigV1.self, from: plaintext)
        guard config.version == 1,
              config.updatedAt.timeIntervalSince1970.isFinite,
              config.routes.count <= Self.maximumRoutes,
              Set(config.routes.map(\.routeID)).count == config.routes.count,
              config.routes.allSatisfy({ route in
                  route.routeID.isStructurallyValid
                      && route.readCredential.isStructurallyValid
                      && route.relay.isStructurallyValid
                      && route.committedCursor?.isStructurallyValid != false
              }) else {
            throw OpaqueRouteWidgetError.invalidConfig
        }
        return config
    }

    func save(_ batch: DecentralizedPrefetchBatch) async throws {
        try FileManager.default.createDirectory(
            at: batchesDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let store = try DecentralizedPrefetchBatchStore(
            fileURL: batchesDirectory.appendingPathComponent(
                try batchFilename(routeID: batch.routeID)
            ),
            protectionKey: loadKeyData()
        )
        try await store.save(batch)
    }

    func stagedPacketCount() async -> Int {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: batchesDirectory.path),
              let keyData = try? loadKeyData() else {
            return 0
        }
        var count = 0
        for name in names where name.hasSuffix(".nwbatch") {
            guard let store = try? DecentralizedPrefetchBatchStore(
                fileURL: batchesDirectory.appendingPathComponent(name),
                protectionKey: keyData
            ), let batch = try? await store.load() else {
                continue
            }
            count += batch.records.count
        }
        return count
    }

    private func batchFilename(routeID: OpaqueReceiveRouteIDV2) throws -> String {
        let encoded = try NoctweaveCoder.encode(routeID, sortedKeys: true)
        return SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
            + ".nwbatch"
    }

    private func loadKeyData() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecAttrAccessGroup as String: Self.keychainAccessGroup
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              data.count == 32 else {
            throw OpaqueRouteWidgetError.keyUnavailable
        }
        return data
    }

    static func readSnapshot() -> NoctyraSyncWidgetSnapshot {
        guard let data = UserDefaults(suiteName: appGroupIdentifier)?.data(forKey: snapshotKey),
              let snapshot = try? JSONDecoder().decode(NoctyraSyncWidgetSnapshot.self, from: data) else {
            return .empty
        }
        return snapshot
    }

    static func writeSnapshot(_ snapshot: NoctyraSyncWidgetSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults(suiteName: appGroupIdentifier)?.set(data, forKey: snapshotKey)
        WidgetCenter.shared.reloadTimelines(ofKind: "NoctyraSyncDashboardWidget")
    }
}

private struct OpaqueRouteWidgetRunner {
    private let maximumPacketsPerRoute: UInt16 = 64

    func run() async -> OpaqueRouteWidgetResult {
        let startedAt = Date()
        do {
            let store = try OpaqueRouteWidgetStore()
            guard let config = try store.loadConfig(), !config.routes.isEmpty else {
                return OpaqueRouteWidgetResult(
                    fetchedPacketCount: 0,
                    routeCount: 0,
                    status: "Open Noctyra to configure opaque routes.",
                    lastAttemptAt: startedAt,
                    lastSuccessAt: nil
                )
            }

            var fetched = 0
            var failures = 0
            for route in config.routes {
                do {
                    guard let batch = try await fetch(route: route) else { continue }
                    try await store.save(batch)
                    fetched += batch.records.count
                } catch {
                    failures += 1
                }
            }
            let status = failures == 0
                ? "Sealed opaque-route packets staged."
                : "Packet staging completed with limited route availability."
            return OpaqueRouteWidgetResult(
                fetchedPacketCount: fetched,
                routeCount: config.routes.count,
                status: status,
                lastAttemptAt: startedAt,
                lastSuccessAt: failures == 0 ? Date() : nil
            )
        } catch {
            return OpaqueRouteWidgetResult(
                fetchedPacketCount: 0,
                routeCount: 0,
                status: "Opaque-route packet staging is unavailable.",
                lastAttemptAt: startedAt,
                lastSuccessAt: nil
            )
        }
    }

    static func markFetching() async {
        let previous = OpaqueRouteWidgetStore.readSnapshot()
        OpaqueRouteWidgetStore.writeSnapshot(
            NoctyraSyncWidgetSnapshot(
                updatedAt: Date(),
                isFetching: true,
                lastAttemptAt: Date(),
                lastSuccessAt: previous.lastSuccessAt,
                fetchedPacketCount: 0,
                stagedPacketCount: previous.stagedPacketCount,
                routeCount: previous.routeCount,
                status: "Fetching sealed opaque-route packets."
            )
        )
    }

    static func publish(result: OpaqueRouteWidgetResult) async {
        let staged = (try? OpaqueRouteWidgetStore()).map { store in
            Task { await store.stagedPacketCount() }
        }
        let stagedCount = await staged?.value ?? 0
        OpaqueRouteWidgetStore.writeSnapshot(
            NoctyraSyncWidgetSnapshot(
                updatedAt: Date(),
                isFetching: false,
                lastAttemptAt: result.lastAttemptAt,
                lastSuccessAt: result.lastSuccessAt,
                fetchedPacketCount: result.fetchedPacketCount,
                stagedPacketCount: stagedCount,
                routeCount: result.routeCount,
                status: result.status
            )
        )
    }

    private func fetch(
        route: OpaqueRoutePrefetchRouteV1
    ) async throws -> DecentralizedPrefetchBatch? {
        let request = try route.readCredential.makeSyncRequest(
            routeID: route.routeID,
            after: route.committedCursor,
            limit: maximumPacketsPerRoute
        )
        let response = try await RelayClient(endpoint: route.relay).send(
            .syncOpaqueRouteV2(
                SyncOpaqueRouteRelayRequestV2(
                    request: request,
                    readCredential: route.readCredential
                )
            ),
            timeout: 8
        )
        guard response.status == .success,
              case .opaqueRouteSync(let sync)? = response.successBody else {
            throw OpaqueRouteWidgetError.relayRejected
        }
        guard !sync.packets.isEmpty else { return nil }
        return try DecentralizedPrefetchStager.stageOpaqueRouteBatch(
            sync,
            routeID: route.routeID,
            relayIdentifier: relayIdentifier(route.relay),
            fetchedAfter: route.committedCursor,
            stagedAt: Date()
        )
    }

    private func relayIdentifier(_ relay: RelayEndpoint) -> String {
        "\(relay.transport.rawValue):\(relay.useTLS ? "tls" : "plain"):\(relay.host):\(relay.port)"
    }
}

private extension Data {
    mutating func wipeWidgetBytes() {
        guard !isEmpty else { return }
        resetBytes(in: startIndex..<endIndex)
        removeAll(keepingCapacity: false)
    }
}
