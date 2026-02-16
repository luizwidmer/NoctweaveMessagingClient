import SwiftUI

#if os(iOS)

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

