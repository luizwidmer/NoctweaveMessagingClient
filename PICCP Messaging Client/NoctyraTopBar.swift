import SwiftUI

struct NoctyraTopBar: View {
    let title: String
    var subtitle: String? = nil
    var leading: AnyView? = nil
    var trailing: AnyView? = nil

    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    private var isDark: Bool { colorScheme == .dark }
    #if os(iOS)
    private var titleSize: CGFloat { IOSControlMetrics.isPad ? 31 : 19 }
    private var subtitleSize: CGFloat { IOSControlMetrics.isPad ? 18 : 12 }
    private var horizontalPadding: CGFloat { IOSControlMetrics.isPad ? 28 : 14 }
    private var verticalPadding: CGFloat { IOSControlMetrics.isPad ? 16 : 9 }
    #endif

    var body: some View {
        HStack(spacing: 12) {
            if let leading { leading }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    #if os(iOS)
                    .font(.system(size: titleSize, weight: .semibold, design: .rounded))
                    #else
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    #endif
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        #if os(iOS)
                        .font(.system(size: subtitleSize, weight: .medium, design: .rounded))
                        #else
                        .font(.caption2)
                        #endif
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            if let trailing { trailing }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        #if os(iOS)
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        #else
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        #endif
        .background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    theme.accent.opacity(isDark ? 0.075 : 0.045),
                                    theme.glowSecondary.opacity(isDark ? 0.045 : 0.025),
                                    Color.clear
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Color.white.opacity(isDark ? 0.055 : 0.10))
                        .frame(height: 0.5)
                }
            .allowsHitTesting(false)
            #if os(iOS)
            .ignoresSafeArea(.container, edges: [.top, .leading, .trailing])
            #endif
        }
        .shadow(color: theme.accent.opacity(isDark ? 0.055 : 0.035), radius: 8, x: 0, y: 3)
    }
}
