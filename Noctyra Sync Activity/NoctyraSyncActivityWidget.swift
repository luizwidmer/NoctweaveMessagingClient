import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct NoctyraSyncActivityWidgetBundle: WidgetBundle {
    var body: some Widget {
        NoctyraSyncDashboardWidget()
        NoctyraSyncActivityWidget()
    }
}

struct NoctyraSyncDashboardWidget: Widget {
    let kind = "NoctyraSyncDashboardWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NoctyraSyncTimelineProvider()) { entry in
            NoctyraSyncWidgetView(snapshot: entry.snapshot)
                .containerBackground(Color(red: 0.07, green: 0.08, blue: 0.12), for: .widget)
        }
        .configurationDisplayName("Noctyra Sync")
        .description("Shows encrypted relay fetch status without message content.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct NoctyraSyncTimelineEntry: TimelineEntry {
    let date: Date
    let snapshot: NoctyraSyncWidgetSnapshot
}

private struct NoctyraSyncTimelineProvider: TimelineProvider {
    private let appGroupIdentifier = "group.com.noctyra.client"
    private let snapshotKey = "NoctyraSyncDashboardSnapshot"

    func placeholder(in context: Context) -> NoctyraSyncTimelineEntry {
        NoctyraSyncTimelineEntry(date: Date(), snapshot: .empty)
    }

    func getSnapshot(in context: Context, completion: @escaping (NoctyraSyncTimelineEntry) -> Void) {
        completion(NoctyraSyncTimelineEntry(date: Date(), snapshot: loadSnapshot()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NoctyraSyncTimelineEntry>) -> Void) {
        let entry = NoctyraSyncTimelineEntry(date: Date(), snapshot: loadSnapshot())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60))))
    }

    private func loadSnapshot() -> NoctyraSyncWidgetSnapshot {
        guard
            let payload = UserDefaults(suiteName: appGroupIdentifier)?.data(forKey: snapshotKey),
            let snapshot = try? JSONDecoder().decode(NoctyraSyncWidgetSnapshot.self, from: payload)
        else {
            return .empty
        }
        return snapshot
    }
}

struct NoctyraSyncActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NoctyraSyncActivityAttributes.self) { context in
            NoctyraSyncDashboardView(state: context.state)
                .activityBackgroundTint(Color(red: 0.07, green: 0.08, blue: 0.12))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.state.isFetching ? "Syncing" : "Noctyra", systemImage: context.state.isFetching ? "arrow.triangle.2.circlepath" : "shield.lefthalf.filled")
                        .font(.caption.weight(.semibold))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.stagedEnvelopeCount)")
                        .font(.title3.weight(.bold))
                        .monospacedDigit()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(syncHeadline(for: context.state))
                            .font(.caption.weight(.semibold))
                        Text(context.state.status)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.isFetching ? "arrow.triangle.2.circlepath" : "shield")
            } compactTrailing: {
                Text("\(context.state.stagedEnvelopeCount)")
                    .monospacedDigit()
            } minimal: {
                Image(systemName: "shield")
            }
        }
    }

    private func syncHeadline(for state: NoctyraSyncActivityAttributes.ContentState) -> String {
        if state.isFetching {
            return "Fetching encrypted relay envelopes"
        }
        if state.profileCount == 0 {
            return "No identities configured for sync"
        }
        if state.stagedEnvelopeCount == 1 {
            return "1 encrypted envelope staged"
        }
        return "\(state.stagedEnvelopeCount) encrypted envelopes staged"
    }
}

private struct NoctyraSyncWidgetView: View {
    let snapshot: NoctyraSyncWidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: snapshot.isFetching ? "arrow.triangle.2.circlepath" : "shield.lefthalf.filled")
                    .foregroundStyle(.indigo)
                Text("Noctyra Sync")
                    .font(.headline.weight(.semibold))
                Spacer()
            }

            HStack(spacing: 10) {
                metric("Profiles", snapshot.profileCount)
                metric("Fetched", snapshot.fetchedEnvelopeCount)
                metric("Staged", snapshot.stagedEnvelopeCount)
            }

            Text(snapshot.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if #available(iOSApplicationExtension 17.0, *) {
                Button(intent: NoctyraWidgetFetchIntent()) {
                    Label(snapshot.isFetching ? "Fetching" : "Fetch Now", systemImage: "arrow.down.circle")
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
            }

            if let lastSuccess = snapshot.lastSuccessAt {
                Text("Last success \(lastSuccess, style: .relative)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if let lastAttempt = snapshot.lastAttemptAt {
                Text("Last attempt \(lastAttempt, style: .relative)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.white)
    }

    private func metric(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(.headline.weight(.semibold))
                .monospacedDigit()
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct NoctyraSyncDashboardView: View {
    let state: NoctyraSyncActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: state.isFetching ? "arrow.triangle.2.circlepath" : "shield.lefthalf.filled")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.indigo)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Noctyra Sync")
                        .font(.headline.weight(.semibold))
                    Text(state.isFetching ? "Fetching ciphertext" : "Encrypted relay dashboard")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(state.stagedEnvelopeCount)")
                    .font(.title.weight(.bold))
                    .monospacedDigit()
            }

            HStack(spacing: 10) {
                metric(title: "Profiles", value: "\(state.profileCount)")
                metric(title: "Fetched", value: "\(state.fetchedEnvelopeCount)")
                metric(title: "Staged", value: "\(state.stagedEnvelopeCount)")
            }

            Text(state.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if #available(iOSApplicationExtension 17.0, *) {
                Button(intent: NoctyraWidgetFetchIntent()) {
                    Label(state.isFetching ? "Fetching" : "Fetch Now", systemImage: "arrow.down.circle")
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
            }
        }
        .padding()
    }

    private func metric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.headline.weight(.semibold))
                .monospacedDigit()
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
