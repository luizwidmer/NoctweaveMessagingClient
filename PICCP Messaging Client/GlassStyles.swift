import SwiftUI
import PICCPCore

enum GlassButtonSize {
    case regular
    case compact
}

private enum GlassBacking {
    static func color(theme: ThemeStyle, colorScheme: ColorScheme) -> Color {
        let isDark = (colorScheme == .dark)
        // Keep glass "ultra thin" but avoid the overly see-through look on macOS borderless windows.
        // Noir gets a bit more backing to feel intentionally privacy-forward.
        let baseOpacity: Double = {
            if isDark {
                return theme.palette == .noir ? 0.34 : 0.22
            }
            return theme.palette == .noir ? 0.14 : 0.08
        }()
        return Color.black.opacity(baseOpacity)
    }
}

struct GlassButtonStyle: ButtonStyle {
    var prominent: Bool = false
    var size: GlassButtonSize = .regular

    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    private var verticalPadding: CGFloat {
        size == .compact ? 6 : 8
    }

    private var horizontalPadding: CGFloat {
        size == .compact ? 12 : 14
    }

    func makeBody(configuration: Configuration) -> some View {
        let fillOpacity = prominent ? (configuration.isPressed ? 0.22 : 0.16) : 0.0
        return configuration.label
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
                            .fill(Color.accentColor.opacity(fillOpacity))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.white.opacity(prominent ? 0.35 : 0.2), lineWidth: 0.8)
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .opacity(configuration.isPressed ? 0.9 : 1.0)
    }
}

struct GlassCircleButtonStyle: ButtonStyle {
    var prominent: Bool = false
    var diameter: CGFloat = 34

    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        let fillOpacity = prominent ? (configuration.isPressed ? 0.22 : 0.16) : 0.0
        return configuration.label
            .frame(width: diameter, height: diameter)
            .background(
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Circle()
                            .fill(GlassBacking.color(theme: theme, colorScheme: colorScheme))
                    )
                    .overlay(
                        Circle()
                            .fill(Color.accentColor.opacity(fillOpacity))
                    )
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(prominent ? 0.35 : 0.2), lineWidth: 0.8)
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .opacity(configuration.isPressed ? 0.9 : 1.0)
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
}
