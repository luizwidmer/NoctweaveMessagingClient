import SwiftUI
import NoctweaveCore
#if os(iOS)
import UIKit
#endif

enum GlassButtonSize {
    case regular
    case compact
}

private enum GlassBacking {
    static func color(theme: ThemeStyle, colorScheme: ColorScheme) -> Color {
        theme.isDark == (colorScheme == .dark) ? theme.surface : theme.elevatedSurface
    }
}

struct GlassButtonStyle: ButtonStyle {
    var prominent: Bool = false
    var size: GlassButtonSize = .regular

    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    private var verticalPadding: CGFloat {
        let base: CGFloat = size == .compact ? 6 : 8
        #if os(iOS)
        return IOSControlMetrics.isPad ? base * 1.15 : base
        #else
        return base
        #endif
    }

    private var horizontalPadding: CGFloat {
        let base: CGFloat = size == .compact ? 12 : 14
        #if os(iOS)
        return IOSControlMetrics.isPad ? base * 1.2 : base
        #else
        return base
        #endif
    }

    private var ipadLabelFontSize: CGFloat {
        size == .compact ? 18 : 20
    }

    func makeBody(configuration: Configuration) -> some View {
        let fillOpacity = prominent ? (configuration.isPressed ? 0.24 : 0.17) : (configuration.isPressed ? 0.08 : 0.03)
        return configuration.label
            #if os(iOS)
            .font(IOSControlMetrics.isPad ? .system(size: ipadLabelFontSize, weight: .semibold, design: .rounded) : nil)
            #endif
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .multilineTextAlignment(.center)
            .padding(.vertical, verticalPadding)
            .padding(.horizontal, horizontalPadding)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(GlassBacking.color(theme: theme, colorScheme: colorScheme))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        theme.accent.opacity(colorScheme == .dark ? 0.16 : 0.10),
                                        theme.glowSecondary.opacity(colorScheme == .dark ? 0.12 : 0.06),
                                        Color.clear
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.accentColor.opacity(fillOpacity))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        theme.surfaceHighlight,
                                        theme.surfaceBorder,
                                        theme.accent.opacity(prominent ? 0.28 : 0.12)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 0.9
                            )
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: theme.surfaceShadow, radius: configuration.isPressed ? 3 : 7, x: 0, y: configuration.isPressed ? 1 : 3)
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .opacity(isEnabled ? (configuration.isPressed ? 0.9 : 1.0) : 0.42)
            .saturation(isEnabled ? 1.0 : 0.35)
    }
}

struct GlassCircleButtonStyle: ButtonStyle {
    var prominent: Bool = false
    var diameter: CGFloat = 34

    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    private var resolvedDiameter: CGFloat {
        #if os(iOS)
        if IOSControlMetrics.isPad && diameter <= 44 {
            return diameter * IOSControlMetrics.padControlScale
        }
        #endif
        return diameter
    }

    private var labelScale: CGFloat {
        #if os(iOS)
        if IOSControlMetrics.isPad && diameter <= 44 {
            return IOSControlMetrics.padControlScale
        }
        #endif
        return 1.0
    }

    func makeBody(configuration: Configuration) -> some View {
        let fillOpacity = prominent ? (configuration.isPressed ? 0.25 : 0.17) : (configuration.isPressed ? 0.08 : 0.03)
        return configuration.label
            .scaleEffect(labelScale)
            .frame(width: resolvedDiameter, height: resolvedDiameter)
            .background(
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Circle()
                            .fill(GlassBacking.color(theme: theme, colorScheme: colorScheme))
                    )
                    .overlay(
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        theme.accent.opacity(colorScheme == .dark ? 0.18 : 0.10),
                                        theme.glowSecondary.opacity(colorScheme == .dark ? 0.12 : 0.06),
                                        Color.clear
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                    .overlay(
                        Circle()
                            .fill(Color.accentColor.opacity(fillOpacity))
                    )
                    .overlay(
                        Circle()
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        theme.surfaceHighlight,
                                        theme.surfaceBorder,
                                        theme.accent.opacity(prominent ? 0.28 : 0.12)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 0.9
                            )
                    )
            )
            .clipShape(Circle())
            .contentShape(Circle())
            .shadow(color: theme.surfaceShadow, radius: configuration.isPressed ? 3 : 7, x: 0, y: configuration.isPressed ? 1 : 3)
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .opacity(isEnabled ? (configuration.isPressed ? 0.9 : 1.0) : 0.42)
            .saturation(isEnabled ? 1.0 : 0.35)
    }
}

extension View {
    @ViewBuilder
    func applyIf<Content: View>(_ condition: Bool, @ViewBuilder _ transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }

    func glassButton(prominent: Bool = false, compact: Bool = false) -> some View {
        let size: GlassButtonSize = compact ? .compact : .regular
        return buttonStyle(GlassButtonStyle(prominent: prominent, size: size))
    }

    func glassCircleButton(prominent: Bool = false, diameter: CGFloat = 34) -> some View {
        buttonStyle(GlassCircleButtonStyle(prominent: prominent, diameter: diameter))
    }

    func pinKeyboard() -> some View {
        #if os(iOS)
        return keyboardType(.numberPad)
        #else
        return self
        #endif
    }

    @ViewBuilder
    func noctweaveSheetPresentation() -> some View {
        #if os(iOS)
        if #available(iOS 16.4, *) {
            presentationBackground(.clear)
                .presentationCornerRadius(24)
        } else {
            self
        }
        #elseif os(macOS)
        if #available(macOS 13.0, *) {
            presentationBackground(.clear)
        } else {
            self
        }
        #else
        self
        #endif
    }

    func noctweaveSheetBackground() -> some View {
        background {
            NoctweaveSheetBackground()
        }
    }

    func uniformGlassCard(cornerRadius: CGFloat = 14, padding: CGFloat = 12, minHeight: CGFloat? = nil) -> some View {
        modifier(UniformGlassCardModifier(cornerRadius: cornerRadius, padding: padding, minHeight: minHeight))
    }

    func adaptiveReadableContent(maxWidth: CGFloat = 820, alignment: Alignment = .center) -> some View {
        modifier(AdaptiveReadableContentModifier(maxWidth: maxWidth, alignment: alignment))
    }

    func noctweaveInputField(cornerRadius: CGFloat = 12) -> some View {
        modifier(NoctweaveInputFieldModifier(cornerRadius: cornerRadius))
    }

    @ViewBuilder
    func hideSheetNavigationBar() -> some View {
        #if os(iOS)
        toolbar(.hidden, for: .navigationBar)
        #else
        self
        #endif
    }
}

private struct AdaptiveReadableContentModifier: ViewModifier {
    let maxWidth: CGFloat
    let alignment: Alignment
    @State private var availableWidth: CGFloat = 0

    func body(content: Content) -> some View {
        #if os(iOS)
        ZStack {
            if IOSControlMetrics.isPad && availableWidth > 700 {
                content
                    .frame(width: min(maxWidth, availableWidth), alignment: alignment)
            } else {
                content
                    .frame(maxWidth: .infinity, alignment: alignment)
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .preference(key: AvailableWidthPreferenceKey.self, value: proxy.size.width)
                }
            }
        .onPreferenceChange(AvailableWidthPreferenceKey.self) { width in
            availableWidth = width
        }
        #else
        content
            .frame(maxWidth: .infinity, alignment: alignment)
        #endif
    }
}

#if os(iOS)
private struct AvailableWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
#endif

private struct NoctweaveInputFieldModifier: ViewModifier {
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(theme.inputSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(theme.accent.opacity(colorScheme == .dark ? 0.07 : 0.04))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        theme.surfaceHighlight,
                                        theme.surfaceBorder,
                                        theme.accent.opacity(0.10)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 0.8
                            )
                    )
            )
    }
}

private struct UniformGlassCardModifier: ViewModifier {
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    let cornerRadius: CGFloat
    let padding: CGFloat
    let minHeight: CGFloat?

    func body(content: Content) -> some View {
        let isDark = colorScheme == .dark
        if let minHeight {
            contentCard(content: content, isDark: isDark)
                .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
        } else {
            contentCard(content: content, isDark: isDark)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func contentCard(content: Content, isDark: Bool) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(theme.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        theme.accent.opacity(isDark ? 0.16 : 0.09),
                                        theme.glowSecondary.opacity(isDark ? 0.10 : 0.05),
                                        Color.clear
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        theme.surfaceHighlight,
                                        theme.surfaceBorder,
                                        theme.accent.opacity(isDark ? 0.18 : 0.10)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 0.9
                            )
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: theme.surfaceShadow, radius: isDark ? 12 : 8, x: 0, y: isDark ? 5 : 3)
    }
}

private struct NoctweaveSheetBackground: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let isDark = colorScheme == .dark
        ZStack {
            #if os(iOS)
            SecureGlassBackground()
            #else
            GlassBackground()
            #endif
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(Rectangle().fill(theme.elevatedSurface))
                .opacity(isDark ? 0.70 : 0.92)
            LinearGradient(
                colors: [
                    theme.accent.opacity(isDark ? 0.18 : 0.10),
                    theme.glowSecondary.opacity(isDark ? 0.14 : 0.07),
                    Color.clear
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .blendMode(.plusLighter)
            .opacity(isDark ? 0.85 : 0.60)
        }
        .ignoresSafeArea()
    }
}
