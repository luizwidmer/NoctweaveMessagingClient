import SwiftUI
import PICCPCore

struct ThemeStyle: Equatable {
    let palette: ThemePalette
    let backgroundTint: Color
    let glowPrimary: Color
    let glowSecondary: Color
    let bubbleReceived: Color
    let bubbleSent: Color
    let accent: Color

    init(palette: ThemePalette) {
        self.palette = palette
        switch palette {
        case .glacier:
            backgroundTint = Color.blue.opacity(0.12)
            glowPrimary = Color.cyan
            glowSecondary = Color.blue
            bubbleReceived = Color.blue
            bubbleSent = Color.teal
            accent = Color.cyan
        case .sunset:
            backgroundTint = Color.orange.opacity(0.14)
            glowPrimary = Color.orange
            glowSecondary = Color.red
            bubbleReceived = Color.orange
            bubbleSent = Color.red
            accent = Color.orange
        case .forest:
            backgroundTint = Color.green.opacity(0.12)
            glowPrimary = Color.green
            glowSecondary = Color.mint
            bubbleReceived = Color.green
            bubbleSent = Color.mint
            accent = Color.green
        case .citrus:
            backgroundTint = Color.yellow.opacity(0.16)
            glowPrimary = Color.yellow
            glowSecondary = Color.green
            bubbleReceived = Color.yellow
            bubbleSent = Color.green
            accent = Color.yellow
        case .slate:
            backgroundTint = Color.gray.opacity(0.12)
            glowPrimary = Color.gray
            glowSecondary = Color.blue
            bubbleReceived = Color.gray
            bubbleSent = Color.blue
            accent = Color.gray
        }
    }
}

private struct AppThemeKey: EnvironmentKey {
    static let defaultValue = ThemeStyle(palette: .glacier)
}

extension EnvironmentValues {
    var appTheme: ThemeStyle {
        get { self[AppThemeKey.self] }
        set { self[AppThemeKey.self] = newValue }
    }
}

struct GlassBackground: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    private var isDarkMode: Bool {
        colorScheme == .dark
    }

    private var baseColor: Color {
        #if os(iOS)
        return Color(UIColor.tertiarySystemBackground)
        #elseif os(macOS)
        return Color(NSColor.windowBackgroundColor)
        #else
        return Color.white
        #endif
    }

    private var primaryGlowOpacity: Double {
        #if os(iOS)
        return isDarkMode ? 0.5 : 0.32
        #else
        return 0.25
        #endif
    }

    private var secondaryGlowOpacity: Double {
        #if os(iOS)
        return isDarkMode ? 0.36 : 0.22
        #else
        return 0.18
        #endif
    }

    @ViewBuilder
    private var baseLayer: some View {
        #if os(iOS)
        LinearGradient(
            colors: [
                baseColor.opacity(isDarkMode ? 0.9 : 1.0),
                theme.backgroundTint.opacity(isDarkMode ? 0.6 : 0.35),
                theme.glowPrimary.opacity(isDarkMode ? 0.45 : 0.25),
                theme.glowSecondary.opacity(isDarkMode ? 0.32 : 0.18),
                Color.white.opacity(isDarkMode ? 0.06 : 0.02)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        #else
        LinearGradient(
            colors: [
                baseColor,
                baseColor.opacity(0.94),
                theme.backgroundTint
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        #endif
    }

    var body: some View {
        ZStack {
            baseLayer
            Circle()
                .fill(theme.glowPrimary.opacity(primaryGlowOpacity))
                .frame(width: 360, height: 360)
                .blur(radius: 80)
                .offset(x: -160, y: -200)
            Circle()
                .fill(theme.glowSecondary.opacity(secondaryGlowOpacity))
                .frame(width: 300, height: 300)
                .blur(radius: 70)
                .offset(x: 180, y: 140)
        }
        .ignoresSafeArea()
    }
}
