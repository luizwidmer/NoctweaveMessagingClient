import NoctweaveCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: ClientViewModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if model.isLocked {
                ClientLockView(model: model)
            } else {
                switch model.bootState {
                case .loading:
                    launchSurface {
                        ProgressView()
                            .controlSize(.large)
                        Text("Opening encrypted state")
                            .font(.headline)
                        Text("Verifying local storage before revealing conversations.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                case .failed(let message):
                    launchSurface {
                        Image(systemName: "lock.trianglebadge.exclamationmark")
                            .font(.system(size: 38, weight: .semibold))
                            .foregroundStyle(.orange)
                        Text("State unavailable")
                            .font(.title2.weight(.bold))
                        Text(readableStorageError(message))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Try Again") { Task { await model.open() } }
                            .glassButton(prominent: true)
                    }
                case .ready:
                    protectedClientShell
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.resumeFromBackground()
                model.syncAll()
            } else {
                model.lockForBackgroundIfConfigured()
            }
        }
        .onChange(of: model.isLocked) { _, locked in
            if !locked { model.syncAll() }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(5 * 60))
                } catch {
                    return
                }
                model.syncAll()
            }
        }
    }

    @ViewBuilder
    private var protectedClientShell: some View {
        #if os(iOS)
        if ProcessInfo.processInfo.arguments.contains("UI_TESTING")
            && !ProcessInfo.processInfo.arguments.contains("SECURE_RENDERING_TEST") {
            MatureClientShell(model: model)
        } else {
            ZStack {
                WarningBackground()
                MatureClientShell(model: model)
                    .secureContainerIfAvailable()
            }
        }
        #else
        MatureClientShell(model: model)
        #endif
    }

    private func launchSurface<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ZStack {
            GlassBackground()
            VStack(spacing: 14, content: content)
                .padding(28)
                .frame(maxWidth: 430)
                .uniformGlassCard(cornerRadius: 24, padding: 22)
                .padding(24)
        }
        .ignoresSafeArea()
    }

    private func readableStorageError(_ message: String) -> String {
        if message.contains("-34018") {
            return "Secure storage is unavailable in this build. Reinstall a normally signed app build and try again."
        }
        return message
    }
}

private struct ClientLockView: View {
    @ObservedObject var model: ClientViewModel
    @Environment(\.appTheme) private var theme
    @State private var pin = ""

    var body: some View {
        ZStack {
            GlassBackground()
            VStack(spacing: 18) {
                ZStack {
                    Circle().fill(theme.accent.opacity(0.14))
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(theme.accent)
                }
                .frame(width: 72, height: 72)
                Text("Noctweave is locked")
                    .font(.title2.weight(.bold))
                Text(lockMessage)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)

                switch model.appLockMode {
                case .off:
                    Button("Unlock") { model.unlockWithPIN("") }
                        .glassButton(prominent: true)
                        .onAppear { Task { await model.unlockWithBiometrics() } }
                case .biometrics:
                    Button("Unlock with Biometrics") {
                        Task { await model.unlockWithBiometrics() }
                    }
                    .glassButton(prominent: true)
                case .pinOnly:
                    pinEntry
                case .biometricsAndPin:
                    if model.biometricStepPassed {
                        pinEntry
                    } else {
                        Button("Verify Biometrics") {
                            Task { await model.unlockWithBiometrics() }
                        }
                        .glassButton(prominent: true)
                    }
                }

                if let error = model.lockError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(28)
            .frame(maxWidth: 460)
            .uniformGlassCard(cornerRadius: 26, padding: 22)
            .padding(24)
        }
        .ignoresSafeArea()
        .task {
            guard model.appLockMode == .biometrics
                    || (model.appLockMode == .biometricsAndPin && !model.biometricStepPassed) else {
                return
            }
            await model.unlockWithBiometrics()
        }
    }

    private var lockMessage: String {
        switch model.appLockMode {
        case .pinOnly, .biometricsAndPin:
            model.appLockMessage
        case .off, .biometrics:
            "Authenticate to reveal your encrypted conversations."
        }
    }

    private var pinEntry: some View {
        HStack {
            SecureField("Six-digit PIN", text: $pin)
                .noctweaveInputField()
                .frame(maxWidth: 220)
                .onSubmit { submitPIN() }
            Button("Unlock") { submitPIN() }
                .glassButton(prominent: true)
        }
    }

    private func submitPIN() {
        model.unlockWithPIN(pin)
        pin = ""
    }
}
