import AppIntents
import SwiftUI
import WidgetKit

@main
struct NoctyraSyncActivityWidgetBundle: WidgetBundle {
    var body: some Widget {
        NoctyraSyncDashboardWidget()
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
