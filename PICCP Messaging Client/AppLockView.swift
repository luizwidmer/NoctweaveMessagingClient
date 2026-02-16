import SwiftUI
import PICCPCore

struct AppLockView: View {
    @ObservedObject var model: ClientViewModel
    @State private var biometricPassed = false
    @State private var pin = ""
    @State private var errorMessage: String?

    private var mode: AppLockMode {
        model.state.appLock.mode
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.black,
                    Color.black.opacity(0.9),
                    Color.black.opacity(0.85)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            VStack(spacing: 16) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.white)
                Text("App Locked")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text(lockSubtitle)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)

                switch mode {
                case .biometricsAndPin:
                    if model.state.appLock.isPinConfigured {
                        if biometricPassed {
                            pinUnlockView
                        } else {
                            unlockButton
                        }
                    } else {
                        missingPinNote
                    }
                case .pinOnly:
                    if model.state.appLock.isPinConfigured {
                        pinUnlockView
                    } else {
                        missingPinNote
                    }
                case .biometrics:
                    unlockButton
                case .off:
                    EmptyView()
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red.opacity(0.9))
                }
            }
            .padding(32)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .opacity(0.9)
            )
            .padding()
        }
        .ignoresSafeArea()
        .transition(.opacity)
        .onAppear {
            biometricPassed = false
            pin = ""
            errorMessage = nil
        }
    }

    private var unlockButton: some View {
        Button("Unlock with Biometrics") {
            Task { await attemptBiometricUnlock() }
        }
        .glassButton(prominent: true)
        .disabled(mode == .off)
    }

    private var lockSubtitle: String {
        switch mode {
        case .off:
            return "Unlocking is disabled."
        case .biometrics:
            return "Use biometrics to access your conversations."
        case .pinOnly:
            return "Enter your PIN to access your conversations."
        case .biometricsAndPin:
            return "Use biometrics, then enter your PIN to continue."
        }
    }

    private var pinUnlockView: some View {
        VStack(spacing: 10) {
            SecureField("PIN", text: $pin)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 180)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
                .onChange(of: pin) { _, newValue in
                    pin = sanitizePin(newValue)
                }
            Button("Unlock") {
                attemptPinUnlock()
            }
            .glassButton(prominent: true)
        }
    }

    private var missingPinNote: some View {
        Text("PIN not configured. Set one in Settings.")
            .font(.caption)
            .foregroundStyle(.white.opacity(0.7))
    }

    private func attemptBiometricUnlock() async {
        let success = await model.performBiometricUnlock()
        await MainActor.run {
            if success {
                errorMessage = nil
                if mode == .biometrics {
                    model.completeUnlock()
                } else {
                    biometricPassed = true
                }
            } else {
                errorMessage = "Biometric check failed."
            }
        }
    }

    private func attemptPinUnlock() {
        let trimmed = sanitizePin(pin)
        guard trimmed.count == 6 else {
            errorMessage = "Enter a 6-digit PIN."
            return
        }
        Task {
            if await model.performActionPinIfNeeded(trimmed) != nil {
                await MainActor.run {
                    errorMessage = nil
                    pin = ""
                    biometricPassed = false
                    model.completeUnlock()
                }
                return
            }
            await MainActor.run {
                if model.verifyAppLockPin(trimmed) {
                    model.completeUnlock()
                    pin = ""
                    errorMessage = nil
                } else {
                    errorMessage = "Invalid PIN."
                }
            }
        }
    }

    private func sanitizePin(_ value: String) -> String {
        String(value.filter { $0.isNumber }.prefix(6))
    }

}
