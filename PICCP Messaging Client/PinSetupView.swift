#if os(iOS) || os(macOS)
import SwiftUI

enum PinSetupKind: String, Identifiable {
    case unlock
    case burnIdentity
    case clearChats
    case actionPlan

    var id: String { rawValue }

    var title: String {
        switch self {
        case .unlock:
            return "Set App PIN"
        case .burnIdentity:
            return "Set Burn Identity PIN"
        case .clearChats:
            return "Set Clear Chats PIN"
        case .actionPlan:
            return "Set Action Plan PIN"
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
        case .actionPlan:
            return "This PIN runs your selected action bundle, then becomes your unlock PIN."
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
    @State private var isSubmitting = false

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

                PinDotsRow(total: 6, filled: currentInput.count)
                    .padding(.top, 4)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red.opacity(0.9))
                }

                NumericPinPad(
                    pin: step == .enter ? $entry : $confirm,
                    maxLength: 6,
                    isEnabled: !isSubmitting
                ) { _ in
                    submitCurrentStep()
                }
                .padding(.top, 6)

                Spacer()
            }
            .padding(.vertical, 24)
        }
        .ignoresSafeArea()
    }

    private var stepText: String {
        step == .enter ? "Enter a 6-digit PIN." : "Repeat the PIN to confirm."
    }

    private var currentInput: String {
        step == .enter ? entry : confirm
    }

    private func submitCurrentStep() {
        errorMessage = nil
        switch step {
        case .enter:
            guard entry.count == 6 else { return }
            withAnimation(.easeInOut(duration: 0.15)) {
                step = .confirm
            }
        case .confirm:
            guard confirm.count == 6 else { return }
            guard confirm == entry else {
                errorMessage = "PINs do not match."
                confirm = ""
                return
            }
            isSubmitting = true
            Task { @MainActor in
                let success = await onComplete(entry)
                isSubmitting = false
                if !success {
                    errorMessage = "Unable to set PIN. Choose a different PIN."
                    confirm = ""
                    entry = ""
                    step = .enter
                }
            }
        }
    }

}
#endif
