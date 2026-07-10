import Foundation
import Combine

#if os(iOS)
import WidgetKit
#endif

@MainActor
final class NoctyraSyncDashboardController: ObservableObject {
    private static let appGroupIdentifier = "group.com.noctyra.client"
    private static let widgetSnapshotKey = "NoctyraSyncDashboardSnapshot"
    private static let widgetKind = "NoctyraSyncDashboardWidget"

    @Published private(set) var isFetching = false
    @Published private(set) var lastAttemptAt: Date?
    @Published private(set) var lastSuccessAt: Date?
    @Published private(set) var fetchedEnvelopeCount = 0
    @Published private(set) var stagedEnvelopeCount = 0
    @Published private(set) var profileCount = 0
    @Published private(set) var statusText = "No sync yet"
    @Published private(set) var syncError: String?

    private let store = CiphertextPrefetchStore()

    func refreshFromStore() {
        do {
            let status = try store.loadStatus()
            let profileCount = try store.loadConfig()?.profiles.count ?? 0
            let stagedCount = try store.prefetchedRecordCount()
            apply(
                status: status,
                fetchedCount: fetchedEnvelopeCount,
                stagedCount: stagedCount,
                profileCount: profileCount,
                isFetching: isFetching
            )
            writeWidgetSnapshot()
        } catch {
            syncError = "Unable to read encrypted prefetch status."
        }
    }

    func prefetchNow() async {
        isFetching = true
        syncError = nil
        lastAttemptAt = Date()
        writeWidgetSnapshot()

        let result = await CiphertextPrefetchRunner(store: store).run()
        isFetching = false
        fetchedEnvelopeCount = result.fetchedEnvelopeCount
        do {
            let status = try store.loadStatus()
            let stagedCount = try store.prefetchedRecordCount()
            apply(
                status: status,
                fetchedCount: result.fetchedEnvelopeCount,
                stagedCount: stagedCount,
                profileCount: result.profileCount,
                isFetching: false
            )
            if !result.failures.isEmpty {
                syncError = result.failures.joined(separator: "\n")
            }
            writeWidgetSnapshot()
        } catch {
            syncError = "Sync completed, but status could not be read."
        }
    }

    func reloadWidgetTimeline() {
        #if os(iOS)
        WidgetCenter.shared.reloadTimelines(ofKind: Self.widgetKind)
        #endif
    }

    static func clearWidgetSnapshot() {
        #if os(iOS)
        UserDefaults(suiteName: appGroupIdentifier)?.removeObject(forKey: widgetSnapshotKey)
        WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
        #endif
    }

    static func refreshWidgetFromStore(fetchedEnvelopeCount: Int? = nil) async {
        #if os(iOS)
        let store = CiphertextPrefetchStore()
        let status = (try? store.loadStatus()) ?? .empty
        let stagedCount = (try? store.prefetchedRecordCount()) ?? 0
        let profileCount = (try? store.loadConfig()?.profiles.count) ?? 0
        writeWidgetSnapshot(
            isFetching: false,
            lastAttemptAt: status.lastAttemptAt,
            lastSuccessAt: status.lastSuccessAt,
            fetchedEnvelopeCount: fetchedEnvelopeCount ?? 0,
            stagedEnvelopeCount: stagedCount,
            profileCount: profileCount,
            status: status.lastResult ?? "No sync yet"
        )
        #endif
    }

    private func apply(
        status: NoctyraPrefetchStatus,
        fetchedCount: Int,
        stagedCount: Int,
        profileCount: Int,
        isFetching: Bool
    ) {
        self.lastAttemptAt = status.lastAttemptAt
        self.lastSuccessAt = status.lastSuccessAt
        self.fetchedEnvelopeCount = fetchedCount
        self.stagedEnvelopeCount = stagedCount
        self.profileCount = profileCount
        self.statusText = status.lastResult ?? "No sync yet"
        self.isFetching = isFetching
    }

    private func writeWidgetSnapshot() {
        Self.writeWidgetSnapshot(
            isFetching: isFetching,
            lastAttemptAt: lastAttemptAt,
            lastSuccessAt: lastSuccessAt,
            fetchedEnvelopeCount: fetchedEnvelopeCount,
            stagedEnvelopeCount: stagedEnvelopeCount,
            profileCount: profileCount,
            status: statusText
        )
    }

    private static func writeWidgetSnapshot(
        isFetching: Bool,
        lastAttemptAt: Date?,
        lastSuccessAt: Date?,
        fetchedEnvelopeCount: Int,
        stagedEnvelopeCount: Int,
        profileCount: Int,
        status: String
    ) {
        #if os(iOS)
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
        guard let payload = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults(suiteName: appGroupIdentifier)?.set(payload, forKey: widgetSnapshotKey)
        WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
        #endif
    }
}
