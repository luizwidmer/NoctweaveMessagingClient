import SwiftUI

struct NoctyraTopBar: View {
    let title: String
    var subtitle: String? = nil
    var leading: AnyView? = nil
    var trailing: AnyView? = nil

    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        HStack(spacing: 12) {
            if let leading { leading }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    #if os(iOS)
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    #else
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    #endif
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        #if os(iOS)
                        .font(.caption)
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
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        // In iPhone landscape, the safe area can introduce large left/right insets that make
        // the top bar look "underfit". Keep content in the safe area, but let the glass
        // background bleed edge-to-edge for a professional look.
        .background {
            ZStack {
                Rectangle()
                    .fill(.ultraThinMaterial)
                LinearGradient(
                    colors: [
                        theme.accent.opacity(isDark ? 0.14 : 0.10),
                        Color.white.opacity(isDark ? 0.03 : 0.05),
                        theme.glowSecondary.opacity(isDark ? 0.10 : 0.06)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .opacity(isDark ? 0.7 : 0.5)
                // No blend modes here; iOS secure-container pipelines can flatten them.
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(isDark ? 0.18 : 0.30),
                                Color.white.opacity(0.0)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(height: 1)
                    .frame(maxHeight: .infinity, alignment: .top)
                Rectangle()
                    .fill(Color.white.opacity(isDark ? 0.12 : 0.18))
                    .frame(height: 0.5)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .allowsHitTesting(false)
            #if os(iOS)
            .ignoresSafeArea(.container, edges: [.top, .leading, .trailing])
            #endif
        }
    }
}
