import AppIntents
import CryptoKit
import Darwin
import Foundation
import NoctweaveCore
import Security
import WidgetKit

@available(iOS 17.0, *)
struct NoctweaveWidgetFetchIntent: AppIntent {
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
    static let appGroupIdentifier = "group.com.noctweave.client"
    static let snapshotKey = "NoctweaveSyncDashboardSnapshot"
    static let maximumRoutes = 256
    static let maximumConfigBytes = 2 * 1_024 * 1_024
    static let authenticatedData = Data("NOCTWEAVE/OPAQUE-ROUTE-PREFETCH-CONFIG/V1".utf8)

    private static let keychainService = "com.noctweave.opaque-route-prefetch"
    private static let keychainAccount = "route-prefetch-key-v1"
    private static let keychainAccessGroup = "9MY7SXN56X.com.noctweave.prefetch"

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
        guard var stored = try readBoundedPrivateConfig(
            from: configURL,
            maximumBytes: Self.maximumConfigBytes
        ) else { return nil }
        defer { stored.wipeWidgetBytes() }
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

    static func readSnapshot() -> NoctweaveSyncWidgetSnapshot {
        guard let data = UserDefaults(suiteName: appGroupIdentifier)?.data(forKey: snapshotKey),
              let snapshot = try? JSONDecoder().decode(NoctweaveSyncWidgetSnapshot.self, from: data) else {
            return .empty
        }
        return snapshot
    }

    static func writeSnapshot(_ snapshot: NoctweaveSyncWidgetSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults(suiteName: appGroupIdentifier)?.set(data, forKey: snapshotKey)
        WidgetCenter.shared.reloadTimelines(ofKind: "NoctweaveSyncDashboardWidget")
    }

    private func readBoundedPrivateConfig(
        from url: URL,
        maximumBytes: Int
    ) throws -> Data? {
        guard maximumBytes >= 0, maximumBytes < Int.max else {
            throw OpaqueRouteWidgetError.configTooLarge
        }
        let directory: Int32 = url.deletingLastPathComponent()
            .withUnsafeFileSystemRepresentation { path in
                guard let path else { return -1 }
                return Darwin.open(
                    path,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
            }
        if directory < 0, errno == ENOENT { return nil }
        guard directory >= 0 else {
            throw OpaqueRouteWidgetError.invalidConfig
        }
        defer { _ = Darwin.close(directory) }
        let name = url.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw OpaqueRouteWidgetError.invalidConfig
        }
        let descriptor: Int32 = name.withCString { filename in
            Darwin.openat(
                directory,
                filename,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
            )
        }
        if descriptor < 0, errno == ENOENT { return nil }
        guard descriptor >= 0 else {
            throw OpaqueRouteWidgetError.invalidConfig
        }
        defer { _ = Darwin.close(descriptor) }

        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              (before.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              before.st_uid == geteuid(),
              (before.st_mode & mode_t(0o077)) == 0,
              before.st_size > 0 else {
            throw OpaqueRouteWidgetError.invalidConfig
        }
        guard UInt64(before.st_size) <= UInt64(maximumBytes) else {
            throw OpaqueRouteWidgetError.configTooLarge
        }

        var data = Data()
        data.reserveCapacity(Int(before.st_size))
        var buffer = [UInt8](
            repeating: 0,
            count: min(64 * 1_024, maximumBytes + 1)
        )
        while true {
            let remaining = maximumBytes + 1 - data.count
            guard remaining > 0 else {
                throw OpaqueRouteWidgetError.configTooLarge
            }
            let requested = min(buffer.count, remaining)
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return Darwin.read(descriptor, base, requested)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw OpaqueRouteWidgetError.invalidConfig
            }
            if count == 0 { break }
            data.append(contentsOf: buffer[0..<count])
            guard data.count <= maximumBytes else {
                throw OpaqueRouteWidgetError.configTooLarge
            }
        }

        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              data.count == Int(after.st_size) else {
            throw OpaqueRouteWidgetError.invalidConfig
        }
        return data
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
                    status: "Open Noctweave to configure opaque routes.",
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
            NoctweaveSyncWidgetSnapshot(
                updatedAt: Date(),
                isFetching: true,
                lastAttemptAt: Date(),
                lastSuccessAt: previous.lastSuccessAt,
                fetchedPacketCount: 0,
                stagedPacketCount: previous.stagedPacketCount,
                routeCount: previous.routeCount,
                status: "Fetching sealed opaque-route packets.",
                paletteRawValue: previous.paletteRawValue
            )
        )
    }

    static func publish(result: OpaqueRouteWidgetResult) async {
        let staged = (try? OpaqueRouteWidgetStore()).map { store in
            Task { await store.stagedPacketCount() }
        }
        let stagedCount = await staged?.value ?? 0
        OpaqueRouteWidgetStore.writeSnapshot(
            NoctweaveSyncWidgetSnapshot(
                updatedAt: Date(),
                isFetching: false,
                lastAttemptAt: result.lastAttemptAt,
                lastSuccessAt: result.lastSuccessAt,
                fetchedPacketCount: result.fetchedPacketCount,
                stagedPacketCount: stagedCount,
                routeCount: result.routeCount,
                status: result.status,
                paletteRawValue: OpaqueRouteWidgetStore.readSnapshot().paletteRawValue
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
