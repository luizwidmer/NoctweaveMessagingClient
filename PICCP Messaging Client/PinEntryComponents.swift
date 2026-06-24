import SwiftUI

struct PinDotsRow: View {
    let total: Int
    let filled: Int

    var body: some View {
        HStack(spacing: 12) {
            ForEach(0..<total, id: \.self) { index in
                Circle()
                    .fill(index < filled ? Color.white : Color.white.opacity(0.22))
                    .frame(width: 12, height: 12)
            }
        }
    }
}

struct NumericPinPad: View {
    @Binding var pin: String
    var maxLength: Int = 6
    var isEnabled: Bool = true
    var onComplete: (String) -> Void

    private let rows: [[String]] = [
        ["1", "2", "3"],
        ["4", "5", "6"],
        ["7", "8", "9"],
        ["", "0", "⌫"]
    ]

    var body: some View {
        VStack(spacing: 10) {
            ForEach(rows.indices, id: \.self) { row in
                HStack(spacing: 10) {
                    ForEach(rows[row], id: \.self) { label in
                        if label.isEmpty {
                            Color.clear
                                .frame(width: 66, height: 54)
                        } else {
                            Button {
                                handleTap(label)
                            } label: {
                                Text(label)
                                    .font(.system(size: 21, weight: .semibold, design: .rounded))
                                    .frame(width: 66, height: 54)
                            }
                            .buttonStyle(PinPadKeyStyle())
                            .disabled(!isEnabled)
                        }
                    }
                }
            }
        }
    }

    private func handleTap(_ label: String) {
        guard isEnabled else { return }
        if label == "⌫" {
            guard !pin.isEmpty else { return }
            pin.removeLast()
            return
        }
        guard pin.count < maxLength else { return }
        pin.append(contentsOf: label)
        if pin.count == maxLength {
            onComplete(pin)
        }
    }
}

private struct PinPadKeyStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.24 : 0.13))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(configuration.isPressed ? 0.35 : 0.18), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
