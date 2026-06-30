import SwiftUI
import NoctweaveCore

struct AppLockView: View {
    @ObservedObject var model: ClientViewModel
    @State private var biometricPassed = false
    @State private var pin = ""
    @State private var errorMessage: String?
    @State private var isUnlocking = false
    @State private var isBiometricUnlocking = false

    private var mode: AppLockMode {
        model.state.appLock.mode
    }

    private var effectiveMode: AppLockMode {
        guard !model.biometricsAvailable else {
            return mode
        }
        switch mode {
        case .biometricsAndPin:
            return model.state.appLock.isPinConfigured ? .pinOnly : .off
        case .biometrics:
            return model.state.appLock.isPinConfigured ? .pinOnly : .off
        case .pinOnly, .off:
            return mode
        }
    }

    private var customLockMessage: String? {
        let message = model.state.appLock.lockScreenMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? nil : message
    }

    private var shouldShowCustomMessage: Bool {
        switch effectiveMode {
        case .pinOnly:
            return true
        case .biometricsAndPin:
            return biometricPassed
        case .biometrics, .off:
            return false
        }
    }

    private var shouldShowLockSubtitle: Bool {
        !(shouldShowCustomMessage && customLockMessage != nil)
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
                if shouldShowCustomMessage, let customLockMessage {
                    Text(customLockMessage)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.white.opacity(0.92))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                }
                if shouldShowLockSubtitle {
                    Text(lockSubtitle)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                }

                switch effectiveMode {
                case .biometricsAndPin:
                    if model.state.appLock.isPinConfigured {
                        if biometricPassed {
                            pinUnlockView
                        } else {
                            biometricProgressView
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
                    biometricProgressView
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
            Task { await attemptAutoBiometricUnlockIfNeeded() }
        }
        .onChange(of: effectiveMode) { _, _ in
            Task { await attemptAutoBiometricUnlockIfNeeded() }
        }
    }

    private var retryBiometricButton: some View {
        Button("Retry Biometrics") {
            Task { await attemptBiometricUnlock() }
        }
        .glassButton(prominent: true)
        .disabled(effectiveMode == .off)
    }

    @ViewBuilder
    private var biometricProgressView: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                if isBiometricUnlocking {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white.opacity(0.85))
                }
                Text(isBiometricUnlocking ? "Verifying biometrics..." : "Waiting for biometric verification...")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
            }
            if !isBiometricUnlocking, errorMessage != nil {
                retryBiometricButton
            }
        }
    }

    private var lockSubtitle: String {
        switch effectiveMode {
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
            PinDotsRow(total: 6, filled: pin.count)
                .padding(.top, 4)
            NumericPinPad(pin: $pin, maxLength: 6, isEnabled: !isUnlocking) { _ in
                attemptPinUnlock()
            }
            .padding(.top, 4)
        }
    }

    private var missingPinNote: some View {
        Text("PIN not configured. Set one in Settings.")
            .font(.caption)
            .foregroundStyle(.white.opacity(0.7))
    }

    private func attemptBiometricUnlock() async {
        await MainActor.run {
            guard !isBiometricUnlocking else { return }
            isBiometricUnlocking = true
        }
        let success = await model.performBiometricUnlock()
        await MainActor.run {
            isBiometricUnlocking = false
            if success {
                errorMessage = nil
                if effectiveMode == .biometrics {
                    model.completeUnlock()
                } else {
                    biometricPassed = true
                }
            } else {
                errorMessage = "Biometric check failed."
            }
        }
    }

    private func attemptAutoBiometricUnlockIfNeeded() async {
        guard effectiveMode == .biometrics || (effectiveMode == .biometricsAndPin && !biometricPassed) else {
            return
        }
        await attemptBiometricUnlock()
    }

    private func attemptPinUnlock() {
        let lockout = model.appLockPinLockoutRemainingSeconds()
        if lockout > 0 {
            errorMessage = "Too many attempts. Try again in \(lockout)s."
            pin = ""
            return
        }
        let trimmed = sanitizePin(pin)
        guard trimmed.count == 6 else {
            errorMessage = "Enter a 6-digit PIN."
            return
        }
        isUnlocking = true
        Task {
            if await model.performActionPinIfNeeded(trimmed) != nil {
                await MainActor.run {
                    errorMessage = nil
                    pin = ""
                    biometricPassed = false
                    isUnlocking = false
                    model.completeUnlock()
                }
                return
            }
            await MainActor.run {
                if model.verifyAppLockPin(trimmed) {
                    model.completeUnlock()
                    pin = ""
                    errorMessage = nil
                    isUnlocking = false
                } else {
                    let lockout = model.appLockPinLockoutRemainingSeconds()
                    if lockout > 0 {
                        errorMessage = "Too many attempts. Try again in \(lockout)s."
                    } else {
                        errorMessage = "Invalid PIN."
                    }
                    pin = ""
                    isUnlocking = false
                }
            }
        }
    }

    private func sanitizePin(_ value: String) -> String {
        String(value.filter { $0.isNumber }.prefix(6))
    }

}
