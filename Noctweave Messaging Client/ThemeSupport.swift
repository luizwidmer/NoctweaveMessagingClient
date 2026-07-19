import SwiftUI
import NoctweaveCore

struct ThemeStyle: Equatable {
    let palette: ThemePalette
    let family: ThemePaletteFamily
    let basePalette: ThemePalette
    let preferredColorScheme: ColorScheme
    let backgroundTint: Color
    let glowPrimary: Color
    let glowSecondary: Color
    let glowTertiary: Color
    let bubbleReceived: Color
    let bubbleSent: Color
    let accent: Color

    init(palette: ThemePalette) {
        self.palette = palette
        self.family = palette.family
        self.basePalette = palette.basePalette
        self.preferredColorScheme = palette.isDarkVariant ? .dark : .light
        switch palette.family {
        case .glacier:
            backgroundTint = Color.blue.opacity(0.12)
            glowPrimary = Color.cyan
            glowSecondary = Color.blue
            glowTertiary = Color.indigo
            bubbleReceived = Color.blue
            bubbleSent = Color.teal
            accent = Color.cyan
        case .sunset:
            backgroundTint = Color.orange.opacity(0.14)
            glowPrimary = Color.orange
            glowSecondary = Color.red
            glowTertiary = Color.pink
            bubbleReceived = Color.orange
            bubbleSent = Color.red
            accent = Color.orange
        case .forest:
            backgroundTint = Color.green.opacity(0.12)
            glowPrimary = Color.green
            glowSecondary = Color.mint
            glowTertiary = Color.teal
            bubbleReceived = Color.green
            bubbleSent = Color.mint
            accent = Color.green
        case .citrus:
            backgroundTint = Color.yellow.opacity(0.16)
            glowPrimary = Color.yellow
            glowSecondary = Color.green
            glowTertiary = Color.orange
            bubbleReceived = Color.yellow
            bubbleSent = Color.green
            accent = Color.yellow
        case .slate:
            backgroundTint = Color.gray.opacity(0.12)
            glowPrimary = Color.gray
            glowSecondary = Color.blue
            glowTertiary = Color.indigo
            bubbleReceived = Color.gray
            bubbleSent = Color.blue
            accent = Color.gray
        case .aurora:
            backgroundTint = Color.teal.opacity(0.16)
            glowPrimary = Color.mint
            glowSecondary = Color.blue
            glowTertiary = Color.cyan
            bubbleReceived = Color.teal
            bubbleSent = Color.cyan
            accent = Color.mint
        case .ember:
            backgroundTint = Color.red.opacity(0.12)
            glowPrimary = Color.red
            glowSecondary = Color.orange
            glowTertiary = Color.yellow
            bubbleReceived = Color.red
            bubbleSent = Color.orange
            accent = Color.orange
        case .cobalt:
            backgroundTint = Color.blue.opacity(0.2)
            glowPrimary = Color.blue
            glowSecondary = Color.indigo
            glowTertiary = Color.cyan
            bubbleReceived = Color.blue
            bubbleSent = Color.indigo
            accent = Color.blue
        case .orchid:
            backgroundTint = Color.pink.opacity(0.12)
            glowPrimary = Color.pink
            glowSecondary = Color.purple
            glowTertiary = Color.indigo
            bubbleReceived = Color.pink
            bubbleSent = Color.purple
            accent = Color.pink
        case .dune:
            backgroundTint = Color.brown.opacity(0.14)
            glowPrimary = Color.orange
            glowSecondary = Color.yellow
            glowTertiary = Color.red
            bubbleReceived = Color.brown
            bubbleSent = Color.orange
            accent = Color.orange
        case .noir:
            backgroundTint = Color.noctweavePlumBlack.opacity(0.28)
            glowPrimary = Color.noctweaveWine
            glowSecondary = Color.noctweaveCoral
            glowTertiary = Color.noctweaveSand
            bubbleReceived = Color.noctweaveWine
            bubbleSent = Color.noctweaveCoral
            accent = Color.noctweaveCoral
        case .prism:
            backgroundTint = Color.cyan.opacity(0.16)
            glowPrimary = Color.cyan
            glowSecondary = Color.pink
            glowTertiary = Color.yellow
            bubbleReceived = Color.cyan
            bubbleSent = Color.pink
            accent = Color.cyan
        case .weave:
            backgroundTint = Color.noctweaveSand.opacity(0.2)
            glowPrimary = Color.noctweaveCoral
            glowSecondary = Color.noctweaveWine
            glowTertiary = Color.noctweaveIvory
            bubbleReceived = Color.noctweaveWine
            bubbleSent = Color.noctweaveCoral
            accent = Color.noctweaveCoral
        case .abyss:
            backgroundTint = Color.blue.opacity(0.22)
            glowPrimary = Color.indigo
            glowSecondary = Color.cyan
            glowTertiary = Color.blue
            bubbleReceived = Color.indigo
            bubbleSent = Color.cyan
            accent = Color.cyan
        case .pearl:
            backgroundTint = Color.gray.opacity(0.10)
            glowPrimary = Color.white
            glowSecondary = Color.blue
            glowTertiary = Color.mint
            bubbleReceived = Color.gray
            bubbleSent = Color.blue
            accent = Color.blue
        }
    }
}

private struct AppThemeKey: EnvironmentKey {
    // Keep the default consistent with the core default so first render matches.
    static let defaultValue = ThemeStyle(palette: .noir)
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

    private struct GlowSpec: Hashable {
        let color: Color
        let size: CGFloat
        let blur: CGFloat
        let x: CGFloat
        let y: CGFloat
        let opacity: Double
    }

    private struct BackgroundRecipe {
        let stops: [Color]
        let glows: [GlowSpec]
        let grainOpacity: Double
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

    private var recipe: BackgroundRecipe {
        // Tune per palette so backgrounds feel genuinely distinct (not just hue-shifted).
        let baseStops: [Color] = [
            baseColor.opacity(isDarkMode ? 0.92 : 1.0),
            theme.backgroundTint.opacity(isDarkMode ? 0.7 : 0.35),
            theme.glowPrimary.opacity(isDarkMode ? 0.28 : 0.18),
            theme.glowSecondary.opacity(isDarkMode ? 0.18 : 0.12)
        ]

        let grain: Double = {
            #if os(iOS)
            return isDarkMode ? 0.10 : 0.06
            #else
            return 0.05
            #endif
        }()

        func glow(
            _ color: Color,
            size: CGFloat,
            blur: CGFloat,
            x: CGFloat,
            y: CGFloat,
            opacity: Double
        ) -> GlowSpec {
            GlowSpec(color: color, size: size, blur: blur, x: x, y: y, opacity: opacity)
        }

        switch theme.family {
        case .glacier:
            return BackgroundRecipe(
                stops: baseStops + [Color.white.opacity(isDarkMode ? 0.04 : 0.02)],
                glows: [
                    glow(theme.glowPrimary, size: 420, blur: 90, x: -180, y: -240, opacity: primaryGlowOpacity),
                    glow(theme.glowSecondary, size: 340, blur: 80, x: 220, y: 160, opacity: secondaryGlowOpacity),
                    glow(theme.glowTertiary, size: 520, blur: 110, x: 60, y: -40, opacity: isDarkMode ? 0.16 : 0.10)
                ],
                grainOpacity: grain
            )
        case .sunset:
            return BackgroundRecipe(
                stops: [
                    baseColor.opacity(isDarkMode ? 0.90 : 1.0),
                    theme.backgroundTint.opacity(isDarkMode ? 0.75 : 0.40),
                    theme.glowSecondary.opacity(isDarkMode ? 0.22 : 0.16),
                    theme.glowPrimary.opacity(isDarkMode ? 0.18 : 0.10)
                ],
                glows: [
                    glow(theme.glowSecondary, size: 520, blur: 120, x: -220, y: -120, opacity: isDarkMode ? 0.22 : 0.14),
                    glow(theme.glowPrimary, size: 320, blur: 80, x: 220, y: -180, opacity: isDarkMode ? 0.22 : 0.14),
                    glow(theme.glowTertiary, size: 420, blur: 100, x: 200, y: 180, opacity: isDarkMode ? 0.18 : 0.10)
                ],
                grainOpacity: grain
            )
        case .forest:
            return BackgroundRecipe(
                stops: baseStops,
                glows: [
                    glow(theme.glowPrimary, size: 520, blur: 115, x: -220, y: -240, opacity: isDarkMode ? 0.20 : 0.12),
                    glow(theme.glowSecondary, size: 300, blur: 70, x: 230, y: 140, opacity: secondaryGlowOpacity),
                    glow(theme.glowTertiary, size: 420, blur: 95, x: -40, y: 220, opacity: isDarkMode ? 0.14 : 0.08)
                ],
                grainOpacity: grain
            )
        case .citrus:
            return BackgroundRecipe(
                stops: [
                    baseColor.opacity(isDarkMode ? 0.90 : 1.0),
                    theme.backgroundTint.opacity(isDarkMode ? 0.75 : 0.42),
                    theme.glowPrimary.opacity(isDarkMode ? 0.18 : 0.12),
                    theme.glowTertiary.opacity(isDarkMode ? 0.14 : 0.08)
                ],
                glows: [
                    glow(theme.glowPrimary, size: 420, blur: 95, x: -220, y: -220, opacity: isDarkMode ? 0.18 : 0.12),
                    glow(theme.glowSecondary, size: 360, blur: 85, x: 240, y: 120, opacity: isDarkMode ? 0.16 : 0.10),
                    glow(theme.glowTertiary, size: 520, blur: 120, x: 40, y: 220, opacity: isDarkMode ? 0.16 : 0.09)
                ],
                grainOpacity: grain
            )
        case .slate:
            return BackgroundRecipe(
                stops: [
                    baseColor.opacity(isDarkMode ? 0.92 : 1.0),
                    baseColor.opacity(isDarkMode ? 0.86 : 0.94),
                    theme.backgroundTint.opacity(isDarkMode ? 0.55 : 0.22)
                ],
                glows: [
                    glow(theme.glowSecondary, size: 420, blur: 95, x: -220, y: -220, opacity: isDarkMode ? 0.12 : 0.08),
                    glow(theme.glowTertiary, size: 420, blur: 105, x: 220, y: 200, opacity: isDarkMode ? 0.12 : 0.06)
                ],
                grainOpacity: grain * 0.8
            )
        case .aurora:
            return BackgroundRecipe(
                stops: [
                    baseColor.opacity(isDarkMode ? 0.90 : 1.0),
                    theme.backgroundTint.opacity(isDarkMode ? 0.8 : 0.42),
                    theme.glowTertiary.opacity(isDarkMode ? 0.18 : 0.12),
                    theme.glowPrimary.opacity(isDarkMode ? 0.16 : 0.10)
                ],
                glows: [
                    glow(theme.glowTertiary, size: 580, blur: 130, x: -220, y: -120, opacity: isDarkMode ? 0.20 : 0.12),
                    glow(theme.glowPrimary, size: 380, blur: 90, x: 220, y: -200, opacity: isDarkMode ? 0.18 : 0.12),
                    glow(theme.glowSecondary, size: 520, blur: 120, x: 140, y: 220, opacity: isDarkMode ? 0.16 : 0.10)
                ],
                grainOpacity: grain
            )
        case .ember:
            return BackgroundRecipe(
                stops: [
                    baseColor.opacity(isDarkMode ? 0.90 : 1.0),
                    theme.backgroundTint.opacity(isDarkMode ? 0.75 : 0.40),
                    theme.glowSecondary.opacity(isDarkMode ? 0.20 : 0.12),
                    theme.glowTertiary.opacity(isDarkMode ? 0.16 : 0.08)
                ],
                glows: [
                    glow(theme.glowPrimary, size: 520, blur: 120, x: -240, y: -180, opacity: isDarkMode ? 0.20 : 0.12),
                    glow(theme.glowSecondary, size: 420, blur: 100, x: 240, y: 40, opacity: isDarkMode ? 0.18 : 0.10),
                    glow(theme.glowTertiary, size: 520, blur: 120, x: 120, y: 240, opacity: isDarkMode ? 0.14 : 0.08)
                ],
                grainOpacity: grain
            )
        case .cobalt:
            return BackgroundRecipe(
                stops: [
                    baseColor.opacity(isDarkMode ? 0.90 : 1.0),
                    theme.backgroundTint.opacity(isDarkMode ? 0.75 : 0.34),
                    theme.glowSecondary.opacity(isDarkMode ? 0.18 : 0.10),
                    theme.glowTertiary.opacity(isDarkMode ? 0.14 : 0.08)
                ],
                glows: [
                    glow(theme.glowPrimary, size: 520, blur: 120, x: -220, y: -240, opacity: isDarkMode ? 0.20 : 0.12),
                    glow(theme.glowSecondary, size: 420, blur: 100, x: 240, y: 120, opacity: isDarkMode ? 0.18 : 0.10),
                    glow(theme.glowTertiary, size: 560, blur: 130, x: 40, y: 220, opacity: isDarkMode ? 0.16 : 0.09)
                ],
                grainOpacity: grain
            )
        case .orchid:
            return BackgroundRecipe(
                stops: [
                    baseColor.opacity(isDarkMode ? 0.90 : 1.0),
                    theme.backgroundTint.opacity(isDarkMode ? 0.78 : 0.42),
                    theme.glowSecondary.opacity(isDarkMode ? 0.18 : 0.10),
                    theme.glowTertiary.opacity(isDarkMode ? 0.14 : 0.08)
                ],
                glows: [
                    glow(theme.glowPrimary, size: 420, blur: 95, x: -240, y: -240, opacity: isDarkMode ? 0.18 : 0.11),
                    glow(theme.glowSecondary, size: 520, blur: 120, x: 240, y: -40, opacity: isDarkMode ? 0.18 : 0.11),
                    glow(theme.glowTertiary, size: 520, blur: 120, x: 80, y: 240, opacity: isDarkMode ? 0.14 : 0.08)
                ],
                grainOpacity: grain
            )
        case .dune:
            return BackgroundRecipe(
                stops: [
                    baseColor.opacity(isDarkMode ? 0.90 : 1.0),
                    theme.backgroundTint.opacity(isDarkMode ? 0.78 : 0.45),
                    theme.glowSecondary.opacity(isDarkMode ? 0.16 : 0.10),
                    theme.glowPrimary.opacity(isDarkMode ? 0.14 : 0.08)
                ],
                glows: [
                    glow(theme.glowSecondary, size: 560, blur: 130, x: -240, y: -120, opacity: isDarkMode ? 0.16 : 0.10),
                    glow(theme.glowPrimary, size: 420, blur: 95, x: 260, y: 120, opacity: isDarkMode ? 0.16 : 0.10),
                    glow(theme.glowTertiary, size: 520, blur: 120, x: 60, y: 240, opacity: isDarkMode ? 0.12 : 0.07)
                ],
                grainOpacity: grain * 0.9
            )
        case .noir:
            return BackgroundRecipe(
                stops: [
                    // Noir should stay dark even in system light mode (privacy-forward by default).
                    Color.black.opacity(isDarkMode ? 0.94 : 0.92),
                    Color.black.opacity(isDarkMode ? 0.86 : 0.88),
                    theme.backgroundTint.opacity(isDarkMode ? 0.55 : 0.24)
                ],
                glows: [
                    glow(theme.glowPrimary, size: 520, blur: 130, x: -200, y: -240, opacity: isDarkMode ? 0.12 : 0.06),
                    glow(theme.glowTertiary, size: 520, blur: 130, x: 220, y: 200, opacity: isDarkMode ? 0.10 : 0.05)
                ],
                grainOpacity: grain * 0.8
            )
        case .prism:
            return BackgroundRecipe(
                stops: [
                    baseColor.opacity(isDarkMode ? 0.90 : 1.0),
                    theme.backgroundTint.opacity(isDarkMode ? 0.78 : 0.42),
                    theme.glowPrimary.opacity(isDarkMode ? 0.24 : 0.14),
                    theme.glowSecondary.opacity(isDarkMode ? 0.20 : 0.12)
                ],
                glows: [
                    glow(theme.glowPrimary, size: 520, blur: 120, x: -220, y: -180, opacity: isDarkMode ? 0.22 : 0.12),
                    glow(theme.glowSecondary, size: 420, blur: 110, x: 240, y: -120, opacity: isDarkMode ? 0.18 : 0.10),
                    glow(theme.glowTertiary, size: 560, blur: 150, x: 80, y: 200, opacity: isDarkMode ? 0.14 : 0.08)
                ],
                grainOpacity: grain
            )
        case .weave:
            return BackgroundRecipe(
                stops: [
                    baseColor.opacity(isDarkMode ? 0.90 : 1.0),
                    theme.backgroundTint.opacity(isDarkMode ? 0.70 : 0.34),
                    theme.glowPrimary.opacity(isDarkMode ? 0.20 : 0.12),
                    theme.glowSecondary.opacity(isDarkMode ? 0.18 : 0.10)
                ],
                glows: [
                    glow(theme.glowPrimary, size: 560, blur: 140, x: -220, y: -120, opacity: isDarkMode ? 0.20 : 0.12),
                    glow(theme.glowSecondary, size: 420, blur: 110, x: 240, y: 180, opacity: isDarkMode ? 0.18 : 0.10),
                    glow(theme.glowTertiary, size: 420, blur: 120, x: 160, y: -220, opacity: isDarkMode ? 0.14 : 0.08)
                ],
                grainOpacity: grain
            )
        case .abyss:
            return BackgroundRecipe(
                stops: [
                    baseColor.opacity(isDarkMode ? 0.86 : 1.0),
                    theme.backgroundTint.opacity(isDarkMode ? 0.80 : 0.46),
                    theme.glowPrimary.opacity(isDarkMode ? 0.22 : 0.12),
                    theme.glowSecondary.opacity(isDarkMode ? 0.18 : 0.10)
                ],
                glows: [
                    glow(theme.glowPrimary, size: 620, blur: 170, x: -160, y: -220, opacity: isDarkMode ? 0.20 : 0.12),
                    glow(theme.glowSecondary, size: 460, blur: 130, x: 240, y: 160, opacity: isDarkMode ? 0.18 : 0.10),
                    glow(theme.glowTertiary, size: 520, blur: 150, x: 60, y: 220, opacity: isDarkMode ? 0.14 : 0.08)
                ],
                grainOpacity: grain
            )
        case .pearl:
            return BackgroundRecipe(
                stops: [
                    baseColor.opacity(isDarkMode ? 0.92 : 1.0),
                    Color.white.opacity(isDarkMode ? 0.05 : 0.08),
                    theme.backgroundTint.opacity(isDarkMode ? 0.60 : 0.26),
                    theme.glowSecondary.opacity(isDarkMode ? 0.14 : 0.08)
                ],
                glows: [
                    glow(theme.glowSecondary, size: 480, blur: 140, x: -220, y: -160, opacity: isDarkMode ? 0.12 : 0.08),
                    glow(theme.glowTertiary, size: 540, blur: 160, x: 200, y: 180, opacity: isDarkMode ? 0.10 : 0.07),
                    glow(theme.glowPrimary, size: 620, blur: 190, x: 80, y: -40, opacity: isDarkMode ? 0.10 : 0.06)
                ],
                grainOpacity: grain * 0.75
            )
        }
    }

    @ViewBuilder
    private var baseLayer: some View {
        LinearGradient(
            colors: recipe.stops,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var body: some View {
        // Layout-neutral background: tie rendering to the actual available size so the large glow
        // circles never influence parent sizing (which can otherwise cause iOS width overflow).
        GeometryReader { proxy in
            ZStack {
                baseLayer
                ForEach(recipe.glows, id: \.self) { glow in
                    Circle()
                        .fill(glow.color.opacity(glow.opacity))
                        .frame(width: glow.size, height: glow.size)
                        .blur(radius: glow.blur)
                        .offset(x: glow.x, y: glow.y)
                        .blendMode(.screen)
                }
                BackgroundGrain()
                    .opacity(recipe.grainOpacity)
                    .blendMode(.overlay)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .compositingGroup()
        }
        .ignoresSafeArea()
    }
}

private struct BackgroundGrain: View {
    // Cheap-looking gradients kill "pro" vibes. A tiny bit of grain makes glass feel physical.
    private struct Point: Hashable {
        let x: CGFloat
        let y: CGFloat
        let alpha: CGFloat
        let radius: CGFloat
    }

    @State private var points: [Point] = []

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                if points.isEmpty {
                    return
                }
                for p in points {
                    let rect = CGRect(x: p.x * size.width, y: p.y * size.height, width: p.radius, height: p.radius)
                    context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(p.alpha)))
                }
            }
            .onAppear {
                if points.isEmpty {
                    points = makePoints(count: max(600, Int((proxy.size.width * proxy.size.height) / 5000)))
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func makePoints(count: Int) -> [Point] {
        var rng = SeededGenerator(seed: 0xBADC0FFEE)
        return (0..<count).map { _ in
            Point(
                x: CGFloat.random(in: 0...1, using: &rng),
                y: CGFloat.random(in: 0...1, using: &rng),
                alpha: CGFloat.random(in: 0.02...0.08, using: &rng),
                radius: CGFloat.random(in: 0.6...1.6, using: &rng)
            )
        }
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        // Xorshift64*
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
