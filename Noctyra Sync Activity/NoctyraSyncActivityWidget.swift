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
                .containerBackground(
                    LinearGradient(
                        colors: [
                            Color(red: 0.08, green: 0.09, blue: 0.14),
                            Color(red: 0.05, green: 0.10, blue: 0.13)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    for: .widget
                )
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
    @Environment(\.widgetFamily) private var family

    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 9 : 12) {
            header

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 3) {
                Text("\(snapshot.stagedEnvelopeCount)")
                    .font(.system(size: family == .systemSmall ? 38 : 44, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(snapshot.stagedEnvelopeCount == 1 ? "encrypted envelope staged" : "encrypted envelopes staged")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.70))
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
            }

            if family == .systemMedium {
                mediumDetails
            } else {
                Text(compactFooterText)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.58))
                    .lineLimit(1)
            }

            fetchButton
        }
        .foregroundStyle(.white)
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: snapshot.isFetching ? "arrow.triangle.2.circlepath" : "shield.lefthalf.filled")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(Color.indigo.opacity(0.38))
                        .overlay(Circle().stroke(Color.white.opacity(0.14), lineWidth: 0.8))
                )

            VStack(alignment: .leading, spacing: 1) {
                Text("Noctyra")
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)
                Text(snapshot.isFetching ? "Fetching ciphertext" : "Sync dashboard")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.58))
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Text(snapshot.isFetching ? "Syncing" : "Ready")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(snapshot.isFetching ? Color.cyan : Color.green)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.white.opacity(0.08), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.10), lineWidth: 0.7))
        }
    }

    private var mediumDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                statChip(title: "Profiles", value: snapshot.profileCount)
                statChip(title: "Fetched", value: snapshot.fetchedEnvelopeCount)
            }

            Text(statusText)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.58))
                .lineLimit(1)
        }
    }

    private func statChip(title: String, value: Int) -> some View {
        HStack(spacing: 5) {
            Text("\(value)")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white.opacity(0.56))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.white.opacity(0.07), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.10), lineWidth: 0.7))
    }

    private var fetchButton: some View {
        Group {
            if #available(iOSApplicationExtension 17.0, *) {
                Button(intent: NoctyraWidgetFetchIntent()) {
                    Label(snapshot.isFetching ? "Fetching" : "Fetch", systemImage: "arrow.down.circle.fill")
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
            }
        }
    }

    private var compactFooterText: String {
        if snapshot.profileCount == 0 {
            return "No identities configured"
        }
        return statusText
    }

    private var statusText: String {
        if let lastSuccess = snapshot.lastSuccessAt {
            return "Last success \(Self.relativeFormatter.localizedString(for: lastSuccess, relativeTo: Date()))"
        }
        if let lastAttempt = snapshot.lastAttemptAt {
            return "Last attempt \(Self.relativeFormatter.localizedString(for: lastAttempt, relativeTo: Date()))"
        }
        return snapshot.status
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}
