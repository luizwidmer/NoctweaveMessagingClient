import ActivityKit
import SwiftUI
import WidgetKit

@main
struct NoctyraSyncActivityWidgetBundle: WidgetBundle {
    var body: some Widget {
        NoctyraSyncActivityWidget()
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
