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
                            Color(red: 0.11, green: 0.10, blue: 0.17),
                            Color(red: 0.05, green: 0.14, blue: 0.16)
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
        if family == .systemMedium {
            mediumLayout
        } else {
            smallLayout
        }
    }

    private var smallLayout: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                icon(size: 26, symbolSize: 13)
                Text("Inbox")
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                statusDot
            }

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 0) {
                Text("\(snapshot.stagedEnvelopeCount)")
                    .font(.system(size: 36, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.70)
                    .contentTransition(.numericText())
                Text(snapshot.stagedEnvelopeCount == 1 ? "note waiting" : "waiting for you")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Text(compactFooterText)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.56))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 4)
                fetchButton(compact: true)
            }
        }
        .foregroundStyle(.white)
    }

    private var mediumLayout: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 9) {
                    icon(size: 28, symbolSize: 14)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Noctyra Sync")
                            .font(.headline.weight(.semibold))
                            .lineLimit(1)
                        Text(snapshot.isFetching ? "Checking for notes" : "Quiet mailbox")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.white.opacity(0.56))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: 0) {
                    Text("\(snapshot.stagedEnvelopeCount)")
                        .font(.system(size: 40, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.70)
                    Text(snapshot.stagedEnvelopeCount == 1 ? "private note waiting" : "waiting for you")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 8) {
                statusPill
                statChip(title: "Boxes", value: snapshot.profileCount)
                statChip(title: "Found", value: snapshot.fetchedEnvelopeCount)
                Spacer(minLength: 0)
                Text(statusText)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.56))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                fetchButton(compact: false)
            }
            .frame(width: 118, alignment: .trailing)
        }
        .foregroundStyle(.white)
    }

    private func icon(size: CGFloat, symbolSize: CGFloat) -> some View {
        Image(systemName: snapshot.isFetching ? "sparkles" : "moon.stars.fill")
            .font(.system(size: symbolSize, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                Circle()
                    .fill(Color.purple.opacity(0.34))
                    .overlay(Circle().stroke(Color.white.opacity(0.14), lineWidth: 0.8))
            )
    }

    private var statusDot: some View {
        Circle()
            .fill(snapshot.isFetching ? Color.cyan : Color.green)
            .frame(width: 8, height: 8)
            .accessibilityLabel(snapshot.isFetching ? "Fetching" : "Ready")
    }

    private var statusPill: some View {
        Text(snapshot.isFetching ? "Checking" : "Settled")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(snapshot.isFetching ? Color.cyan : Color.mint)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.white.opacity(0.08), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.10), lineWidth: 0.7))
    }

    private func statChip(title: String, value: Int) -> some View {
        HStack(spacing: 5) {
            Text("\(value)")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white.opacity(0.56))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.white.opacity(0.07), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.10), lineWidth: 0.7))
    }

    private func fetchButton(compact: Bool) -> some View {
        Group {
            if #available(iOSApplicationExtension 17.0, *) {
                Button(intent: NoctyraWidgetFetchIntent()) {
                    if compact {
                        Image(systemName: snapshot.isFetching ? "sparkles" : "tray.and.arrow.down.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 30, height: 30)
                    } else {
                        Label(snapshot.isFetching ? "Checking" : "Check", systemImage: "tray.and.arrow.down.fill")
                            .lineLimit(1)
                    }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .buttonStyle(.plain)
                .padding(.horizontal, compact ? 0 : 12)
                .padding(.vertical, compact ? 0 : 7)
                .background(Color.purple.opacity(0.88), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.14), lineWidth: 0.8))
            }
        }
    }

    private var compactFooterText: String {
        if snapshot.profileCount == 0 {
            return "Nothing set up yet"
        }
        return shortStatusText
    }

    private var statusText: String {
        if let lastSuccess = snapshot.lastSuccessAt {
            return "Last check \(Self.relativeFormatter.localizedString(for: lastSuccess, relativeTo: Date()))"
        }
        if let lastAttempt = snapshot.lastAttemptAt {
            return "Last check \(Self.relativeFormatter.localizedString(for: lastAttempt, relativeTo: Date()))"
        }
        return snapshot.status
    }

    private var shortStatusText: String {
        if let lastSuccess = snapshot.lastSuccessAt {
            return Self.relativeFormatter.localizedString(for: lastSuccess, relativeTo: Date())
        }
        if let lastAttempt = snapshot.lastAttemptAt {
            return Self.relativeFormatter.localizedString(for: lastAttempt, relativeTo: Date())
        }
        return snapshot.status
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}
