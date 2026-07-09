import Foundation
import Combine

#if os(iOS)
import ActivityKit
import WidgetKit
#endif

@MainActor
final class NoctyraSyncDashboardController: ObservableObject {
    private static let appGroupIdentifier = "group.com.noctyra.client"
    private static let widgetSnapshotKey = "NoctyraSyncDashboardSnapshot"
    private static let widgetKind = "NoctyraSyncDashboardWidget"

    @Published private(set) var isLiveActivityRunning = false
    @Published private(set) var isFetching = false
    @Published private(set) var lastAttemptAt: Date?
    @Published private(set) var lastSuccessAt: Date?
    @Published private(set) var fetchedEnvelopeCount = 0
    @Published private(set) var stagedEnvelopeCount = 0
    @Published private(set) var profileCount = 0
    @Published private(set) var statusText = "No sync yet"
    @Published private(set) var liveActivityError: String?

    private let store = CiphertextPrefetchStore()

    var liveActivitiesAvailable: Bool {
        #if os(iOS)
        if #available(iOS 16.2, *) {
            return ActivityAuthorizationInfo().areActivitiesEnabled
        }
        #endif
        return false
    }

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
            refreshLiveActivityState()
        } catch {
            liveActivityError = "Unable to read encrypted prefetch status."
        }
    }

    func startLiveActivity() {
        #if os(iOS)
        guard #available(iOS 16.2, *) else {
            liveActivityError = "Live Activities require iOS 16.2 or later."
            return
        }
        guard liveActivitiesAvailable else {
            liveActivityError = "Live Activities are disabled in iOS Settings."
            return
        }
        do {
            refreshFromStore()
            let state = currentActivityState()
            if let activity = Activity<NoctyraSyncActivityAttributes>.activities.first {
                Task {
                    await activity.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(15 * 60)))
                }
            } else {
                _ = try Activity<NoctyraSyncActivityAttributes>.request(
                    attributes: NoctyraSyncActivityAttributes(dashboardName: "Noctyra Sync"),
                    content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(15 * 60)),
                    pushType: nil
                )
            }
            refreshLiveActivityState()
            liveActivityError = nil
        } catch {
            liveActivityError = "Unable to start Live Activity."
        }
        #else
        liveActivityError = "Live Activities are available on iPhone only."
        #endif
    }

    func stopLiveActivity() {
        #if os(iOS)
        guard #available(iOS 16.2, *) else { return }
        Task {
            for activity in Activity<NoctyraSyncActivityAttributes>.activities {
                await activity.end(
                    ActivityContent(state: currentActivityState(), staleDate: nil),
                    dismissalPolicy: .immediate
                )
            }
            await MainActor.run {
                refreshLiveActivityState()
            }
        }
        #endif
    }

    func prefetchNow() async {
        isFetching = true
        liveActivityError = nil
        lastAttemptAt = Date()
        writeWidgetSnapshot()
        await updateLiveActivityIfRunning()

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
                liveActivityError = result.failures.joined(separator: "\n")
            }
            writeWidgetSnapshot()
        } catch {
            liveActivityError = "Sync completed, but status could not be read."
        }
        await updateLiveActivityIfRunning()
    }

    func updateLiveActivityIfRunning() async {
        #if os(iOS)
        guard #available(iOS 16.2, *) else { return }
        let state = currentActivityState()
        for activity in Activity<NoctyraSyncActivityAttributes>.activities {
            await activity.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(15 * 60)))
        }
        WidgetCenter.shared.reloadTimelines(ofKind: Self.widgetKind)
        refreshLiveActivityState()
        #endif
    }

    static func refreshLiveActivitiesFromStore(fetchedEnvelopeCount: Int? = nil) async {
        #if os(iOS)
        guard #available(iOS 16.2, *) else { return }
        let store = CiphertextPrefetchStore()
        let status = (try? store.loadStatus()) ?? .empty
        let stagedCount = (try? store.prefetchedRecordCount()) ?? 0
        let profileCount = (try? store.loadConfig()?.profiles.count) ?? 0
        let state = NoctyraSyncActivityAttributes.ContentState(
            isFetching: false,
            lastAttemptAt: status.lastAttemptAt,
            lastSuccessAt: status.lastSuccessAt,
            fetchedEnvelopeCount: fetchedEnvelopeCount ?? 0,
            stagedEnvelopeCount: stagedCount,
            profileCount: profileCount,
            status: status.lastResult ?? "No sync yet"
        )
        for activity in Activity<NoctyraSyncActivityAttributes>.activities {
            await activity.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(15 * 60)))
        }
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

    private func refreshLiveActivityState() {
        #if os(iOS)
        if #available(iOS 16.2, *) {
            isLiveActivityRunning = !Activity<NoctyraSyncActivityAttributes>.activities.isEmpty
        } else {
            isLiveActivityRunning = false
        }
        #else
        isLiveActivityRunning = false
        #endif
    }

    #if os(iOS)
    @available(iOS 16.2, *)
    private func currentActivityState() -> NoctyraSyncActivityAttributes.ContentState {
        NoctyraSyncActivityAttributes.ContentState(
            isFetching: isFetching,
            lastAttemptAt: lastAttemptAt,
            lastSuccessAt: lastSuccessAt,
            fetchedEnvelopeCount: fetchedEnvelopeCount,
            stagedEnvelopeCount: stagedEnvelopeCount,
            profileCount: profileCount,
            status: statusText
        )
    }
    #endif
}
