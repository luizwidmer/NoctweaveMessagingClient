import AppIntents
import NoctweaveCore
import SwiftUI
import WidgetKit

@main
struct NoctweaveSyncActivityWidgetBundle: WidgetBundle {
    var body: some Widget {
        NoctweaveSyncDashboardWidget()
    }
}

struct NoctweaveSyncDashboardWidget: Widget {
    let kind = "NoctweaveSyncDashboardWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NoctweaveSyncTimelineProvider()) { entry in
            let theme = NoctweaveWidgetTheme(paletteRawValue: entry.snapshot.paletteRawValue)
            NoctweaveSyncWidgetView(snapshot: entry.snapshot, theme: theme)
                .containerBackground(for: .widget) {
                    NoctweaveWidgetBackground(theme: theme)
                }
                .environment(\.colorScheme, theme.isDark ? .dark : .light)
        }
        .configurationDisplayName("Noctweave Sync")
        .description("Shows sealed opaque-route packet status without message content.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct NoctweaveSyncTimelineEntry: TimelineEntry {
    let date: Date
    let snapshot: NoctweaveSyncWidgetSnapshot
}

private struct NoctweaveSyncTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> NoctweaveSyncTimelineEntry {
        NoctweaveSyncTimelineEntry(date: Date(), snapshot: .empty)
    }

    func getSnapshot(in context: Context, completion: @escaping (NoctweaveSyncTimelineEntry) -> Void) {
        completion(NoctweaveSyncTimelineEntry(date: Date(), snapshot: loadSnapshot()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NoctweaveSyncTimelineEntry>) -> Void) {
        let entry = NoctweaveSyncTimelineEntry(date: Date(), snapshot: loadSnapshot())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60))))
    }

    private func loadSnapshot() -> NoctweaveSyncWidgetSnapshot {
        OpaqueRouteWidgetStore.readSnapshot()
    }
}

private struct NoctweaveSyncWidgetView: View {
    let snapshot: NoctweaveSyncWidgetSnapshot
    let theme: NoctweaveWidgetTheme
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
                Text("Routes")
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                statusDot
            }

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 0) {
                Text("\(snapshot.stagedPacketCount)")
                    .font(.system(size: 36, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.70)
                    .contentTransition(.numericText())
                Text(snapshot.stagedPacketCount == 1 ? "sealed packet" : "sealed packets")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(theme.muted)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Text(compactFooterText)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(theme.muted.opacity(0.88))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 4)
                fetchButton(compact: true)
            }
        }
        .foregroundStyle(theme.text)
    }

    private var mediumLayout: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                icon(size: 30, symbolSize: 15)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Routes")
                        .font(.headline.weight(.semibold))
                        .lineLimit(1)
                    Text(snapshot.isFetching ? "Checking" : "Last sync")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(theme.muted.opacity(0.88))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if snapshot.isFetching {
                    statusPill
                }
            }

            Spacer(minLength: 0)

            HStack(alignment: .bottom, spacing: 18) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(snapshot.stagedPacketCount)")
                        .font(.system(size: 42, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.70)
                    Text(snapshot.stagedPacketCount == 1 ? "sealed packet" : "sealed packets")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.muted)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 8) {
                    Text(shortStatusText)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(theme.muted.opacity(0.88))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    fetchButton(compact: false)
                }
            }
        }
        .foregroundStyle(theme.text)
    }

    private func icon(size: CGFloat, symbolSize: CGFloat) -> some View {
        NoctweaveWidgetMark(theme: theme)
            .frame(width: size, height: size)
            .overlay {
                if snapshot.isFetching {
                    Circle()
                        .fill(theme.primary.opacity(0.92))
                        .overlay {
                            Image(systemName: "sparkles")
                                .font(.system(size: symbolSize, weight: .semibold))
                                .foregroundStyle(theme.buttonText)
                        }
                }
            }
    }

    private var statusDot: some View {
        Circle()
            .fill(snapshot.isFetching ? theme.secondary : theme.tertiary)
            .frame(width: 8, height: 8)
            .accessibilityLabel(snapshot.isFetching ? "Fetching" : "Ready")
    }

    private var statusPill: some View {
        Text("Checking")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(theme.buttonText)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(theme.primary.opacity(0.76), in: Capsule())
            .overlay(Capsule().stroke(theme.secondary.opacity(0.48), lineWidth: 0.7))
    }

    private func fetchButton(compact: Bool) -> some View {
        Group {
            if #available(iOSApplicationExtension 17.0, *) {
                Button(intent: NoctweaveWidgetFetchIntent()) {
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
                .foregroundStyle(theme.buttonText)
                .buttonStyle(.plain)
                .padding(.horizontal, compact ? 0 : 12)
                .padding(.vertical, compact ? 0 : 7)
                .background(
                    LinearGradient(
                        colors: [theme.primary, theme.secondary, theme.tertiary],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    in: Capsule()
                )
                .overlay(Capsule().stroke(theme.secondary.opacity(0.46), lineWidth: 0.8))
            }
        }
    }

    private var compactFooterText: String {
        if snapshot.routeCount == 0 {
            return "Nothing set up yet"
        }
        return shortStatusText
    }

    private var shortStatusText: String {
        if let lastSuccess = snapshot.lastSuccessAt {
            return Self.relativeStatus(for: lastSuccess)
        }
        if let lastAttempt = snapshot.lastAttemptAt {
            return Self.relativeStatus(for: lastAttempt)
        }
        return snapshot.status
    }

    private static func relativeStatus(for date: Date) -> String {
        let now = Date()
        if abs(date.timeIntervalSince(now)) < 60 {
            return "Just now"
        }
        return relativeFormatter.localizedString(for: date, relativeTo: now)
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

private struct NoctweaveWidgetMark: View {
    let theme: NoctweaveWidgetTheme

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let scale = size / 256
            let xOffset = (proxy.size.width - size) / 2
            let yOffset = (proxy.size.height - size) / 2

            ZStack {
                RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [theme.surface, theme.canvas],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                            .stroke(theme.primary.opacity(0.48), lineWidth: max(0.7, size * 0.012))
                    }

                Path { path in
                    path.move(to: point(104, 56, scale: scale, xOffset: xOffset, yOffset: yOffset))
                    path.addLine(to: point(200, 56, scale: scale, xOffset: xOffset, yOffset: yOffset))
                    path.addLine(to: point(200, 164, scale: scale, xOffset: xOffset, yOffset: yOffset))
                    path.addLine(to: point(137, 132.5, scale: scale, xOffset: xOffset, yOffset: yOffset))
                    path.addLine(to: point(137, 114.5, scale: scale, xOffset: xOffset, yOffset: yOffset))
                    path.addLine(to: point(104, 98, scale: scale, xOffset: xOffset, yOffset: yOffset))
                    path.closeSubpath()
                }
                .fill(
                    LinearGradient(
                        colors: [theme.primary, theme.secondary],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

                Path { path in
                    path.move(to: point(56, 92, scale: scale, xOffset: xOffset, yOffset: yOffset))
                    path.addLine(to: point(119, 123.5, scale: scale, xOffset: xOffset, yOffset: yOffset))
                    path.addLine(to: point(119, 141.5, scale: scale, xOffset: xOffset, yOffset: yOffset))
                    path.addLine(to: point(152, 158, scale: scale, xOffset: xOffset, yOffset: yOffset))
                    path.addLine(to: point(152, 200, scale: scale, xOffset: xOffset, yOffset: yOffset))
                    path.addLine(to: point(56, 200, scale: scale, xOffset: xOffset, yOffset: yOffset))
                    path.closeSubpath()
                }
                .fill(
                    LinearGradient(
                        colors: [theme.secondary, theme.tertiary],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private func point(
        _ x: CGFloat,
        _ y: CGFloat,
        scale: CGFloat,
        xOffset: CGFloat,
        yOffset: CGFloat
    ) -> CGPoint {
        CGPoint(x: xOffset + x * scale, y: yOffset + y * scale)
    }
}

private struct NoctweaveWidgetBackground: View {
    let theme: NoctweaveWidgetTheme

    var body: some View {
        ZStack {
            theme.canvas
            LinearGradient(
                colors: [theme.surface, theme.canvas],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [theme.primary.opacity(theme.isDark ? 0.30 : 0.18), .clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 180
            )
            RadialGradient(
                colors: [theme.tertiary.opacity(theme.isDark ? 0.18 : 0.12), .clear],
                center: .bottomTrailing,
                startRadius: 0,
                endRadius: 150
            )
        }
    }
}

private struct NoctweaveWidgetTheme {
    let isDark: Bool
    let canvas: Color
    let surface: Color
    let primary: Color
    let secondary: Color
    let tertiary: Color
    let text: Color
    let muted: Color
    let buttonText: Color

    init(paletteRawValue: String?) {
        let palette = paletteRawValue.flatMap(ThemePalette.init(rawValue:)) ?? .noir
        isDark = palette.isDarkVariant

        let colors: (Color, Color, Color)
        switch palette.family {
        case .glacier: colors = (.cyan, .blue, .indigo)
        case .sunset: colors = (.orange, .red, .pink)
        case .forest: colors = (.green, .mint, .teal)
        case .citrus: colors = (.yellow, .green, .orange)
        case .slate: colors = (.gray, .blue, .indigo)
        case .aurora: colors = (.mint, .blue, .cyan)
        case .ember: colors = (.red, .orange, .yellow)
        case .cobalt: colors = (.blue, .indigo, .cyan)
        case .orchid: colors = (.pink, .purple, .indigo)
        case .dune: colors = (.orange, .yellow, .red)
        case .noir:
            colors = (
                Color(red: 146 / 255, green: 45 / 255, blue: 53 / 255),
                Color(red: 201 / 255, green: 106 / 255, blue: 97 / 255),
                Color(red: 235 / 255, green: 199 / 255, blue: 175 / 255)
            )
        case .prism: colors = (.cyan, .pink, .yellow)
        case .weave:
            colors = (
                Color(red: 201 / 255, green: 106 / 255, blue: 97 / 255),
                Color(red: 146 / 255, green: 45 / 255, blue: 53 / 255),
                Color(red: 250 / 255, green: 243 / 255, blue: 234 / 255)
            )
        case .abyss: colors = (.indigo, .cyan, .blue)
        case .pearl: colors = (.white, .blue, .mint)
        }
        primary = colors.0
        secondary = colors.1
        tertiary = colors.2

        if isDark {
            canvas = palette.family == .noir
                ? Color(red: 27 / 255, green: 18 / 255, blue: 23 / 255)
                : Color(red: 6 / 255, green: 8 / 255, blue: 15 / 255)
            surface = palette.family == .noir
                ? Color(red: 45 / 255, green: 28 / 255, blue: 35 / 255)
                : Color(red: 20 / 255, green: 24 / 255, blue: 37 / 255)
            text = Color.white.opacity(0.96)
            muted = Color.white.opacity(0.62)
            buttonText = Color.white
        } else {
            canvas = palette == .noirBright
                ? Color(red: 250 / 255, green: 243 / 255, blue: 234 / 255)
                : Color(white: 0.96)
            surface = Color.white.opacity(0.92)
            text = Color.black.opacity(0.86)
            muted = Color.black.opacity(0.54)
            buttonText = palette.family == .citrus || palette.family == .pearl
                ? Color.black.opacity(0.86)
                : Color.white
        }
    }
}
