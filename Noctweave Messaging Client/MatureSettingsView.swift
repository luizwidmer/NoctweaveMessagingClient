import NoctweaveCore
import SwiftUI

private enum MatureSettingsDestination {
    case appearance
    case privacy
    case appSecurity
    case storage
    case legal
}

struct MatureSettingsView: View {
    @ObservedObject var model: ClientViewModel
    @Binding var selectedPalette: String
    let onLock: () -> Void

    @State private var destination: MatureSettingsDestination?

    var body: some View {
        Group {
            switch destination {
            case .appearance:
                MatureAppearanceSettings(
                    model: model,
                    selectedPalette: $selectedPalette,
                    onBack: { destination = nil }
                )
            case .privacy:
                MaturePrivacySettings(model: model, onBack: { destination = nil })
            case .appSecurity:
                MatureAppSecuritySettings(
                    model: model,
                    onBack: { destination = nil },
                    onLock: onLock
                )
            case .storage:
                MatureStorageSettings(onBack: { destination = nil })
            case .legal:
                MatureLegalSettings(onBack: { destination = nil })
            case nil:
                settingsRoot
            }
        }
        .animation(.easeInOut(duration: 0.18), value: destination)
    }

    private var settingsRoot: some View {
        VStack(spacing: 0) {
            MatureTopBar(
                title: "Settings",
                subtitle: "Appearance, privacy, and app security",
                backAction: nil
            ) { EmptyView() }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("PERSONALIZE")
                        .settingsSectionLabel()
                    settingsRow(
                        destination: .appearance,
                        identifier: "settings.appearance",
                        icon: "paintpalette.fill",
                        title: "Appearance",
                        subtitle: ThemePalette(rawValue: selectedPalette)?.displayName ?? "Noir",
                        color: .purple
                    )

                    Text("PROTECTION")
                        .settingsSectionLabel()
                        .padding(.top, 8)
                    settingsRow(
                        destination: .privacy,
                        identifier: "settings.privacy",
                        icon: "hand.raised.fill",
                        title: "Privacy",
                        subtitle: "Screen, focus, and typing protections",
                        color: .cyan
                    )
                    settingsRow(
                        destination: .appSecurity,
                        identifier: "settings.appSecurity",
                        icon: "lock.shield.fill",
                        title: "App Security",
                        subtitle: model.appLockMode == .off
                            ? "App lock is off"
                            : "Protected with \(model.appLockMode.displayName)",
                        color: .green
                    )
                    settingsRow(
                        destination: .storage,
                        identifier: "settings.storage",
                        icon: "externaldrive.fill.badge.checkmark",
                        title: "Storage Protection",
                        subtitle: "Encrypted local state and memory boundaries",
                        color: .orange
                    )

                    Text("NOCTWEAVE")
                        .settingsSectionLabel()
                        .padding(.top, 8)
                    settingsRow(
                        destination: .legal,
                        identifier: "settings.legal",
                        icon: "doc.text.fill",
                        title: "Legal & About",
                        subtitle: "Privacy policy, terms, licenses, and version",
                        color: .indigo
                    )
                }
                .padding(16)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func settingsRow(
        destination: MatureSettingsDestination,
        identifier: String,
        icon: String,
        title: String,
        subtitle: String,
        color: Color
    ) -> some View {
        Button { self.destination = destination } label: {
            HStack(spacing: 14) {
                SettingsIcon(symbol: icon, color: color)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 10)
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .uniformGlassCard(cornerRadius: 21, padding: 0, minHeight: 82)
        .accessibilityIdentifier(identifier)
    }
}

private struct MatureAppearanceSettings: View {
    @ObservedObject var model: ClientViewModel
    @Binding var selectedPalette: String
    let onBack: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 145), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            MatureTopBar(
                title: "Appearance",
                subtitle: "Choose a palette",
                backAction: onBack
            ) { EmptyView() }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SettingsIntroCard(
                        icon: "paintpalette.fill",
                        title: "Make it yours",
                        message: "Every palette includes a coordinated background, glass tint, accent, and message color. Changes apply immediately."
                    )
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(ThemePalette.allCases) { palette in
                            paletteButton(palette)
                        }
                    }
                    SettingsFeedback(model: model)
                }
                .padding(16)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
        }
        .accessibilityIdentifier("settings.appearance.detail")
    }

    private func paletteButton(_ palette: ThemePalette) -> some View {
        let style = ThemeStyle(palette: palette)
        let selected = selectedPalette == palette.rawValue
        return Button {
            selectedPalette = palette.rawValue
            Task { _ = await model.saveAppearance(palette) }
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 7) {
                    Circle().fill(style.glowPrimary).frame(width: 18, height: 18)
                    Circle().fill(style.glowSecondary).frame(width: 18, height: 18)
                    Circle().fill(style.glowTertiary).frame(width: 18, height: 18)
                    Spacer()
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(style.accent)
                    }
                }
                Text(palette.displayName)
                    .font(.subheadline.weight(.semibold))
                Text(palette.isDarkVariant ? "Dark" : "Bright")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            style.backgroundTint.opacity(selected ? 0.6 : 0.24),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(selected ? style.accent.opacity(0.8) : Color.white.opacity(0.09), lineWidth: selected ? 1.5 : 1)
        }
        .accessibilityIdentifier("settings.palette.\(palette.rawValue)")
    }
}

private struct MaturePrivacySettings: View {
    @ObservedObject var model: ClientViewModel
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            MatureTopBar(
                title: "Privacy",
                subtitle: "Local protections with clear limits",
                backAction: onBack
            ) { EmptyView() }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsIntroCard(
                        icon: "hand.raised.fill",
                        title: "Privacy stays local",
                        message: "These controls change how this device reveals content. They do not make a compromised operating system trustworthy or hide network metadata from a relay."
                    )

                    Text("ON-SCREEN CONTENT")
                        .settingsSectionLabel()
                        .padding(.top, 6)
                    SettingsToggleCard(
                        title: "Hide when unfocused",
                        message: "Cover conversations, contacts, identities, and relay details whenever Noctweave loses focus.",
                        symbol: "eye.slash.fill",
                        isOn: privacyBinding(\.hideSensitiveWhenUnfocused)
                    )

                    #if os(macOS)
                    SettingsToggleCard(
                        title: "Block window capture",
                        message: "Ask WindowServer to exclude the Noctweave window from standard capture APIs. Physical cameras and privileged software remain outside this boundary.",
                        symbol: "rectangle.slash.fill",
                        isOn: privacyBinding(\.macBlockWindowCapture)
                    )
                    #else
                    SettingsStatusCard(
                        title: "Protected rendering",
                        message: "Sensitive screens use the strongest protected rendering path available on iOS. This remains enabled by design.",
                        symbol: "checkmark.shield.fill",
                        status: "Always on"
                    )
                    #endif

                    Text("COMPOSER")
                        .settingsSectionLabel()
                        .padding(.top, 6)
                    SettingsToggleCard(
                        title: "Private typing assistance",
                        message: "Disable autocorrection and predictive suggestions in message composers. This does not protect against a compromised keyboard or operating system.",
                        symbol: "keyboard.badge.ellipsis",
                        isOn: privacyBinding(\.secureTypingEnabled)
                    )
                    SettingsFeedback(model: model)
                }
                .padding(16)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
        }
        .accessibilityIdentifier("settings.privacy.detail")
    }

    private func privacyBinding(_ keyPath: WritableKeyPath<PrivacySettings, Bool>) -> Binding<Bool> {
        Binding {
            model.privacySettings[keyPath: keyPath]
        } set: { value in
            var settings = model.privacySettings
            settings[keyPath: keyPath] = value
            Task { _ = await model.savePrivacy(settings) }
        }
    }
}

private struct MatureAppSecuritySettings: View {
    @ObservedObject var model: ClientViewModel
    let onBack: () -> Void
    let onLock: () -> Void
    @State private var showingSetup = false

    var body: some View {
        VStack(spacing: 0) {
            MatureTopBar(
                title: "App Security",
                subtitle: "Control access to local conversations",
                backAction: onBack
            ) { EmptyView() }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsStatusCard(
                        title: model.appLockMode == .off ? "App lock is off" : model.appLockMode.displayName,
                        message: securitySummary,
                        symbol: model.appLockMode == .off ? "lock.open.fill" : "lock.shield.fill",
                        status: model.appLockMode == .off ? "Off" : "Active"
                    )

                    Button { showingSetup = true } label: {
                        SettingsActionLabel(
                            icon: "key.fill",
                            title: "Choose App Unlock Method",
                            message: "Configure biometrics, a six-digit PIN, or both. Existing protection must be authenticated before any change."
                        )
                    }
                    .buttonStyle(.plain)
                    .uniformGlassCard(cornerRadius: 21, padding: 0, minHeight: 92)
                    .accessibilityIdentifier("settings.appSecurity.configure")

                    if model.appLockMode != .off {
                        Button(action: onLock) {
                            SettingsActionLabel(
                                icon: "lock.fill",
                                title: "Lock Now",
                                message: "Immediately cover the app and require the configured unlock method."
                            )
                        }
                        .buttonStyle(.plain)
                        .uniformGlassCard(cornerRadius: 21, padding: 0, minHeight: 92)
                    }
                    SettingsFeedback(model: model)
                }
                .padding(16)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
        }
        .sheet(isPresented: $showingSetup) {
            MatureAppLockSetupFlow(model: model)
        }
        .accessibilityIdentifier("settings.appSecurity.detail")
    }

    private var securitySummary: String {
        guard model.appLockMode != .off else {
            return "Anyone with access to this unlocked device can open Noctweave."
        }
        let timeout = model.appLockSettings.sessionTimeoutMinutes
        let timeoutText = timeout == 0 ? "immediately" : "after \(timeout) minute\(timeout == 1 ? "" : "s")"
        return "Noctweave locks \(timeoutText) away from the app. Biometrics never fall back to the device password."
    }
}

private struct MatureStorageSettings: View {
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            MatureTopBar(
                title: "Storage Protection",
                subtitle: "How local data is handled",
                backAction: onBack
            ) { EmptyView() }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsStatusCard(
                        title: "Encrypted at rest",
                        message: "Identity material, relationship state, conversations, and local preferences are stored in an authenticated encrypted state file.",
                        symbol: "externaldrive.fill.badge.checkmark",
                        status: "Active"
                    )
                    SettingsInfoCard(
                        icon: "memorychip.fill",
                        title: "While in use",
                        message: "The app decrypts only the state needed for active work. Swift and the operating system do not provide a universal guarantee that every temporary copy can be physically overwritten, so a compromised OS remains outside the protection boundary."
                    )
                    SettingsInfoCard(
                        icon: "arrow.trianglehead.2.clockwise.rotate.90.icloud.fill",
                        title: "Backups and exports",
                        message: "Device backups and files you explicitly export may have different retention rules. Protect those destinations separately and remove exports when they are no longer needed."
                    )
                }
                .padding(16)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
        }
        .accessibilityIdentifier("settings.storage.detail")
    }
}

private struct MatureLegalSettings: View {
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            MatureTopBar(
                title: "Legal & About",
                subtitle: "Policies and build information",
                backAction: onBack
            ) { EmptyView() }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsInfoCard(
                        icon: "hand.raised.fill",
                        title: "Privacy Policy",
                        message: "Noctweave stores profile data locally and transmits encrypted envelopes through relays you configure. Relay operators and network observers may still infer timing, source IP, destination relay, availability, and traffic volume. You are responsible for relay selection, backups, device hardening, and evaluating metadata exposure in your threat model."
                    )
                    SettingsInfoCard(
                        icon: "checkmark.seal.fill",
                        title: "Terms of Use",
                        message: "This software is supplied as is and as available, without warranties or guaranteed security outcomes. Test relays are temporary and provide no promised uptime, retention, moderation, recovery, or availability. You are responsible for lawful use, key management, relay choices, compliance, and operational security."
                    )
                    SettingsInfoCard(
                        icon: "shippingbox.fill",
                        title: "About Noctweave",
                        message: "Version \(appVersion) (\(buildNumber)) · Post-quantum messaging infrastructure using relationship-scoped identities and ciphertext-only relay delivery."
                    )
                }
                .padding(16)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
        }
        .accessibilityIdentifier("settings.legal.detail")
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }
}

private enum AppLockSetupStage {
    case authorize
    case configure
    case newPIN
    case confirmPIN
}

private struct MatureAppLockSetupFlow: View {
    @ObservedObject var model: ClientViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var stage: AppLockSetupStage
    @State private var mode: AppLockMode
    @State private var timeout: Int
    @State private var message: String
    @State private var enteredPIN = ""
    @State private var firstPIN = ""
    @State private var localError: String?
    @State private var automaticAuthorizationStarted = false

    private let timeoutOptions = [0, 1, 5, 15, 30, 60]

    init(model: ClientViewModel) {
        self.model = model
        _stage = State(initialValue: model.appLockMode == .off ? .configure : .authorize)
        _mode = State(initialValue: model.appLockMode)
        _timeout = State(initialValue: model.appLockSettings.sessionTimeoutMinutes)
        _message = State(initialValue: model.appLockSettings.lockScreenMessage)
    }

    var body: some View {
        ZStack {
            GlassBackground()
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(stageTitle)
                            .font(.title2.weight(.bold))
                        Text(stageSubtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(action: close) { Image(systemName: "xmark") }
                        .glassCircleButton(diameter: 38)
                        .accessibilityLabel("Close")
                }
                .padding(18)
                .background(.ultraThinMaterial)

                ScrollView {
                    Group {
                        switch stage {
                        case .authorize: authorizationStep
                        case .configure: configurationStep
                        case .newPIN: pinStep(confirming: false)
                        case .confirmPIN: pinStep(confirming: true)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 620)
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.hidden)
            }
        }
        .frame(minWidth: 360, idealWidth: 540, minHeight: 560, idealHeight: 700)
        .interactiveDismissDisabled(model.isSavingSettings)
        .task(id: stage) {
            guard stage == .authorize,
                  model.appLockMode == .biometrics,
                  !automaticAuthorizationStarted else { return }
            automaticAuthorizationStarted = true
            await authorizeCurrentMethod()
        }
    }

    private var authorizationStep: some View {
        VStack(spacing: 18) {
            SettingsIntroCard(
                icon: "person.badge.key.fill",
                title: "Confirm it is you",
                message: "Changing the unlock method can expose encrypted local state. Authenticate with the protection already configured on this device."
            )
            if model.appLockMode == .biometrics {
                ProgressView("Waiting for \(model.biometricDisplayName)…")
                    .padding(24)
                if model.settingsError != nil {
                    Button("Try Again") {
                        Task { await authorizeCurrentMethod() }
                    }
                    .glassButton(prominent: true)
                }
            } else {
                SettingsPINPad(pin: $enteredPIN)
                Button(model.appLockMode == .biometricsAndPin ? "Continue to Biometrics" : "Continue") {
                    Task { await authorizeCurrentMethod() }
                }
                .glassButton(prominent: true)
                .disabled(enteredPIN.count != 6)
            }
            errorText
        }
    }

    private var configurationStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsIntroCard(
                icon: "lock.shield.fill",
                title: "Choose how Noctweave unlocks",
                message: "A method is not enabled until every required step succeeds. Biometric modes use biometrics only and never offer the device password as fallback."
            )

            Text("UNLOCK METHOD").settingsSectionLabel()
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 10)], spacing: 10) {
                ForEach(AppLockMode.allCases) { candidate in
                    unlockMethodButton(candidate)
                }
            }

            Text("LOCK TIMING").settingsSectionLabel().padding(.top, 4)
            HStack(spacing: 12) {
                SettingsIcon(symbol: "timer", color: .orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Away from app").font(.headline)
                    Text("Lock after Noctweave leaves the foreground.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Timeout", selection: $timeout) {
                    ForEach(timeoutOptions, id: \.self) { value in
                        Text(timeoutLabel(value)).tag(value)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            .padding(16)
            .uniformGlassCard(cornerRadius: 20, padding: 0, minHeight: 84)

            if mode == .pinOnly || mode == .biometricsAndPin {
                Text("PIN SCREEN").settingsSectionLabel().padding(.top, 4)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Custom message").font(.headline)
                    Text("Shown only on the PIN entry screen. Leave blank for the standard message.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Optional lock-screen message", text: $message, axis: .vertical)
                        .lineLimit(1...3)
                        .noctweaveInputField()
                        .onChange(of: message) { _, value in
                            if value.count > 240 { message = String(value.prefix(240)) }
                        }
                }
                .padding(16)
                .uniformGlassCard(cornerRadius: 20, padding: 0, minHeight: 112)
            }

            errorText
            Button(mode == .pinOnly || mode == .biometricsAndPin ? "Continue to PIN" : "Save Protection") {
                if mode == .pinOnly || mode == .biometricsAndPin {
                    enteredPIN = ""
                    localError = nil
                    stage = .newPIN
                } else {
                    Task { await save(pin: nil) }
                }
            }
            .glassButton(prominent: true)
            .disabled(model.isSavingSettings || ((mode == .biometrics || mode == .biometricsAndPin) && !model.biometricsAvailable))
        }
    }

    private func pinStep(confirming: Bool) -> some View {
        VStack(spacing: 18) {
            SettingsIntroCard(
                icon: confirming ? "checkmark.shield.fill" : "number.square.fill",
                title: confirming ? "Repeat your PIN" : "Create a six-digit PIN",
                message: confirming
                    ? "Enter the same PIN once more."
                    : "Use six numbers you can remember. Noctweave stores only a salted, stretched verifier."
            )
            SettingsPINPad(pin: $enteredPIN)
            errorText
            Button(confirming ? "Save Protection" : "Continue") {
                if confirming {
                    guard enteredPIN == firstPIN else {
                        localError = "The PINs do not match. Start again."
                        firstPIN = ""
                        enteredPIN = ""
                        stage = .newPIN
                        return
                    }
                    Task { await save(pin: enteredPIN) }
                } else {
                    firstPIN = enteredPIN
                    enteredPIN = ""
                    localError = nil
                    stage = .confirmPIN
                }
            }
            .glassButton(prominent: true)
            .disabled(enteredPIN.count != 6 || model.isSavingSettings)
            Button("Back") {
                enteredPIN = ""
                localError = nil
                stage = confirming ? .newPIN : .configure
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    private func unlockMethodButton(_ candidate: AppLockMode) -> some View {
        let needsBiometrics = candidate == .biometrics || candidate == .biometricsAndPin
        let unavailable = needsBiometrics && !model.biometricsAvailable
        return Button {
            mode = candidate
        } label: {
            HStack(spacing: 12) {
                SettingsIcon(symbol: methodIcon(candidate), color: candidate == .off ? .gray : .green)
                VStack(alignment: .leading, spacing: 3) {
                    Text(methodName(candidate)).font(.headline)
                    Text(methodDescription(candidate))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                Image(systemName: mode == candidate ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(mode == candidate ? Color.accentColor : Color.secondary)
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(unavailable)
        .opacity(unavailable ? 0.5 : 1)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(mode == candidate ? Color.accentColor.opacity(0.75) : Color.white.opacity(0.08), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var errorText: some View {
        if let value = localError ?? model.settingsError {
            Text(value)
                .font(.caption)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }

    private var stageTitle: String {
        switch stage {
        case .authorize: "Authenticate"
        case .configure: "App Security"
        case .newPIN: "Create PIN"
        case .confirmPIN: "Confirm PIN"
        }
    }

    private var stageSubtitle: String {
        switch stage {
        case .authorize: "Current protection"
        case .configure: "Changes apply only after setup completes"
        case .newPIN, .confirmPIN: "Six digits · numbers only"
        }
    }

    private func authorizeCurrentMethod() async {
        localError = nil
        if await model.authorizeAppLockChanges(pin: enteredPIN.isEmpty ? nil : enteredPIN) {
            enteredPIN = ""
            stage = .configure
        }
    }

    private func save(pin: String?) async {
        localError = nil
        if await model.saveAppLockConfiguration(
            mode: mode,
            sessionTimeoutMinutes: timeout,
            lockScreenMessage: message,
            newPIN: pin
        ) {
            dismiss()
        }
    }

    private func close() {
        model.cancelAppLockChanges()
        dismiss()
    }

    private func timeoutLabel(_ value: Int) -> String {
        if value == 0 { return "Immediately" }
        return "\(value) min"
    }

    private func methodIcon(_ value: AppLockMode) -> String {
        switch value {
        case .off: "lock.open.fill"
        case .biometrics: "faceid"
        case .pinOnly: "number.square.fill"
        case .biometricsAndPin: "person.badge.key.fill"
        }
    }

    private func methodName(_ value: AppLockMode) -> String {
        switch value {
        case .biometrics: model.biometricDisplayName
        case .biometricsAndPin: "\(model.biometricDisplayName) + PIN"
        default: value.displayName
        }
    }

    private func methodDescription(_ value: AppLockMode) -> String {
        switch value {
        case .off: "No additional app lock"
        case .biometrics: "Fast, with no password fallback"
        case .pinOnly: "Six digits, entered in app"
        case .biometricsAndPin: "Require both checks"
        }
    }
}

private struct SettingsPINPad: View {
    @Binding var pin: String
    private let keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "", "0", "delete.left.fill"]
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 13) {
                ForEach(0..<6, id: \.self) { index in
                    Circle()
                        .fill(index < pin.count ? Color.accentColor : Color.secondary.opacity(0.22))
                        .frame(width: 14, height: 14)
                        .overlay {
                            Circle().stroke(Color.white.opacity(0.12), lineWidth: 1)
                        }
                }
            }
            .accessibilityLabel("PIN entry")
            .accessibilityValue("\(pin.count) of 6 digits entered")

            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                    if key.isEmpty {
                        Color.clear.frame(height: 52)
                    } else {
                        Button {
                            if key == "delete.left.fill" {
                                if !pin.isEmpty { pin.removeLast() }
                            } else if pin.count < 6 {
                                pin.append(key)
                            }
                        } label: {
                            Group {
                                if key == "delete.left.fill" {
                                    Image(systemName: key)
                                } else {
                                    Text(key).font(.title3.weight(.semibold))
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color.white.opacity(0.09), lineWidth: 1)
                        }
                    }
                }
            }
            .frame(maxWidth: 330)
        }
    }
}

private struct SettingsIcon: View {
    let symbol: String
    let color: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 44, height: 44)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}

private struct SettingsIntroCard: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            SettingsIcon(symbol: icon, color: .accentColor)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .uniformGlassCard(cornerRadius: 21, padding: 0, minHeight: 92)
    }
}

private struct SettingsActionLabel: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        HStack(spacing: 14) {
            SettingsIcon(symbol: icon, color: .accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .contentShape(Rectangle())
    }
}

private struct SettingsToggleCard: View {
    let title: String
    let message: String
    let symbol: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(alignment: .top, spacing: 14) {
                SettingsIcon(symbol: symbol, color: .accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .toggleStyle(.switch)
        .padding(16)
        .uniformGlassCard(cornerRadius: 21, padding: 0, minHeight: 92)
    }
}

private struct SettingsStatusCard: View {
    let title: String
    let message: String
    let symbol: String
    let status: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            SettingsIcon(symbol: symbol, color: .green)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    Text(status)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Color.green.opacity(0.12), in: Capsule())
                }
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .uniformGlassCard(cornerRadius: 21, padding: 0, minHeight: 100)
    }
}

private struct SettingsInfoCard: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundStyle(.tint)
                Text(title).font(.headline)
            }
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .uniformGlassCard(cornerRadius: 21, padding: 0, minHeight: 104)
    }
}

private struct SettingsFeedback: View {
    @ObservedObject var model: ClientViewModel

    @ViewBuilder
    var body: some View {
        if model.isSavingSettings {
            HStack(spacing: 9) {
                ProgressView().controlSize(.small)
                Text("Saving securely…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
        } else if let error = model.settingsError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .padding(.horizontal, 4)
        } else if let message = model.settingsMessage {
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .padding(.horizontal, 4)
        }
    }
}

private extension View {
    func settingsSectionLabel() -> some View {
        self
            .font(.caption2.weight(.bold))
            .foregroundStyle(.secondary)
            .tracking(1.1)
            .padding(.horizontal, 4)
    }
}

struct MaturePrivacyShield: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(Color.black.opacity(0.72))
                .ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "eye.slash.fill")
                    .font(.system(size: 34, weight: .semibold))
                Text("Sensitive content hidden")
                    .font(.title3.weight(.bold))
                Text("Return to Noctweave to reveal this screen.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .padding(28)
        }
        .allowsHitTesting(true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Sensitive content hidden")
    }
}
