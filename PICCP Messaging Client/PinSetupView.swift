#if os(iOS) || os(macOS)
import SwiftUI

enum PinSetupKind: String, Identifiable {
    case unlock
    case burnIdentity
    case clearChats

    var id: String { rawValue }

    var title: String {
        switch self {
        case .unlock:
            return "Set App PIN"
        case .burnIdentity:
            return "Set Burn Identity PIN"
        case .clearChats:
            return "Set Clear Chats PIN"
        }
    }

    var subtitle: String {
        switch self {
        case .unlock:
            return "Enter a 6-digit PIN to unlock the app."
        case .burnIdentity:
            return "This PIN burns your identity immediately from the lock screen."
        case .clearChats:
            return "This PIN clears all chats immediately from the lock screen."
        }
    }
}

struct PinSetupView: View {
    let title: String
    let subtitle: String
    let onComplete: (String) async -> Bool
    let onCancel: () -> Void
    @State private var step: Step = .enter
    @State private var entry = ""
    @State private var confirm = ""
    @State private var errorMessage: String?
    @FocusState private var isFocused: Bool

    private enum Step {
        case enter
        case confirm
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.black,
                    Color.black.opacity(0.92),
                    Color.black.opacity(0.85)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            VStack(spacing: 20) {
                HStack {
                    Button("Cancel") {
                        onCancel()
                    }
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        Capsule().fill(.ultraThinMaterial)
                    )
                    Spacer()
                }
                .padding(.horizontal, 16)

                Spacer()

                Image(systemName: "lock.shield")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.white)

                Text(title)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)

                VStack(spacing: 6) {
                    Text(stepText)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: 320)

                PinDots(count: 6, filled: currentInput.count)
                    .padding(.top, 4)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red.opacity(0.9))
                }

                hiddenField

                Spacer()
            }
            .padding(.vertical, 24)
            .onTapGesture {
                isFocused = true
            }
        }
        .ignoresSafeArea()
        .onAppear {
            isFocused = true
        }
        .onChange(of: step) { _, _ in
            isFocused = true
        }
    }

    private var stepText: String {
        step == .enter ? "Enter a 6-digit PIN." : "Repeat the PIN to confirm."
    }

    private var currentInput: String {
        step == .enter ? entry : confirm
    }

    private var hiddenField: some View {
        SecureField("", text: step == .enter ? $entry : $confirm)
            .pinKeyboard()
            .focused($isFocused)
            .opacity(0.01)
            .frame(width: 1, height: 1)
            .onChange(of: entry) { _, newValue in
                guard step == .enter else { return }
                entry = sanitize(newValue)
                errorMessage = nil
                if entry.count == 6 {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        step = .confirm
                    }
                }
            }
            .onChange(of: confirm) { _, newValue in
                guard step == .confirm else { return }
                confirm = sanitize(newValue)
                if confirm.count == 6 {
                    Task { @MainActor in
                        if confirm == entry {
                            let success = await onComplete(entry)
                            if !success {
                                errorMessage = "Unable to set PIN. Choose a different PIN."
                                confirm = ""
                                step = .enter
                                entry = ""
                            }
                        } else {
                            errorMessage = "PINs do not match."
                            confirm = ""
                        }
                    }
                }
            }
    }

    private func sanitize(_ value: String) -> String {
        String(value.filter { $0.isNumber }.prefix(6))
    }
}

private struct PinDots: View {
    let count: Int
    let filled: Int

    var body: some View {
        HStack(spacing: 12) {
            ForEach(0..<count, id: \.self) { index in
                Circle()
                    .fill(index < filled ? Color.white : Color.white.opacity(0.2))
                    .frame(width: 12, height: 12)
            }
        }
    }
}
#endif
