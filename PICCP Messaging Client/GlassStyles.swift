import SwiftUI

enum GlassButtonSize {
    case regular
    case compact
}

struct GlassButtonStyle: ButtonStyle {
    var prominent: Bool = false
    var size: GlassButtonSize = .regular

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

    func makeBody(configuration: Configuration) -> some View {
        let fillOpacity = prominent ? (configuration.isPressed ? 0.22 : 0.16) : 0.0
        return configuration.label
            .frame(width: diameter, height: diameter)
            .background(
                Circle()
                    .fill(.ultraThinMaterial)
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
