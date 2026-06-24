import SwiftUI

#if os(iOS)
import UIKit

enum IOSControlMetrics {
    static let padControlScale: CGFloat = 2.0
    static let padTextScale: CGFloat = 1.72
    static let padInsetScale: CGFloat = 1.6

    static var isPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    static var circleButtonDiameter: CGFloat {
        isPad ? 34 * padControlScale : 34
    }

    static var circleIconSize: CGFloat {
        isPad ? 14 * padControlScale : 14
    }

    static var prominentCircleIconSize: CGFloat {
        isPad ? 15 * padControlScale : 15
    }

    static var composerHeight: CGFloat {
        isPad ? 68 : 42
    }

    static var tabIconSize: CGFloat {
        isPad ? 15 * padControlScale : 15
    }

    static var tabTextSize: CGFloat {
        isPad ? 9.5 * padTextScale : 9.5
    }

    static var tabItemVerticalPadding: CGFloat {
        isPad ? 6 * padInsetScale : 6
    }

    static var tabBarHorizontalPadding: CGFloat {
        isPad ? 10 * padInsetScale : 10
    }

    static var tabBarBottomPadding: CGFloat {
        isPad ? 6 * padInsetScale : 6
    }
}

/// iOS-friendly segmented control that always fits by wrapping into multiple rows.
/// Use instead of `.pickerStyle(.segmented)` which can overflow in portrait on iPhones.
struct ChipSegmentedControl<Option: Hashable & Identifiable>: View {
    @Binding var selection: Option
    let options: [Option]
    let title: (Option) -> String

    var minItemWidth: CGFloat = 110

    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        let columns = [GridItem(.adaptive(minimum: minItemWidth), spacing: 8)]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(options) { opt in
                Button {
                    selection = opt
                } label: {
                    Text(title(opt))
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .allowsTightening(true)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(.ultraThinMaterial)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(Color.black.opacity(isDark ? 0.16 : 0.06))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(theme.accent.opacity(selection == opt ? (isDark ? 0.20 : 0.16) : 0.0))
                                )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.white.opacity(selection == opt ? (isDark ? 0.22 : 0.18) : 0.10), lineWidth: 0.8)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title(opt))
            }
        }
    }
}

#endif
