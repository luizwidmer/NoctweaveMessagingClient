import SwiftUI
import NoctweaveCore

struct FirstRunSetupView: View {
    @ObservedObject var model: ClientViewModel

    @State private var step: Step = .identity
    @State private var displayName: String = ""
    @State private var selectedRelayId: UUID?
    @State private var privacySettings = PrivacySettings()
    @State private var appLockSettings = AppLockSettings()
    @State private var storageMode: StorageProtectionMode = .keychain
    @State private var acceptedPrivacyPolicy = false
    @State private var acceptedTermsOfUse = false
    @State private var showingRelayEditor = false
    @State private var pinSetupKind: PinSetupKind?
    @State private var isUpdatingStorageMode = false
    @State private var isFinishing = false
    @State private var onboardingBiometricVerified = false
    @State private var onboardingBiometricError: String?
    @State private var isVerifyingOnboardingBiometrics = false

    private enum Step: Int, CaseIterable {
        case identity
        case relay
        case privacy
        case legal
        case review

        var title: String {
            switch self {
            case .identity: return "Create Identity"
            case .relay: return "Choose Relay"
            case .privacy: return "Privacy & Unlock"
            case .legal: return "Legal Consent"
            case .review: return "Finish Setup"
            }
        }

        var subtitle: String {
            switch self {
            case .identity: return "Set your display identity for this device."
            case .relay: return "Pick the relay that will route your encrypted envelopes."
            case .privacy: return "Configure baseline protections before entering chats."
            case .legal: return "Review and accept required legal documents."
            case .review: return "Confirm your choices and create your profile."
            }
        }

        var symbol: String {
            switch self {
            case .identity: return "person.crop.circle"
            case .relay: return "antenna.radiowaves.left.and.right"
            case .privacy: return "lock.shield"
            case .legal: return "doc.text"
            case .review: return "checkmark.seal"
            }
        }
    }

    var body: some View {
        ZStack {
            onboardingBackground

            VStack(spacing: 16) {
                header
                progressStrip

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 12) {
                            Image(systemName: step.symbol)
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 38, height: 38)
                                .background(Color.accentColor.opacity(0.14), in: Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                Text(step.title)
                                    .font(.title3.weight(.semibold))
                                Text(step.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Group {
                            switch step {
                            case .identity:
                                identityStep
                            case .relay:
                                relayStep
                            case .privacy:
                                privacyStep
                            case .legal:
                                legalStep
                            case .review:
                                reviewStep
                            }
                        }

                        if let error = model.lastError {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .accessibilityIdentifier("onboarding-error")
                        } else if let status = model.storageProtectionStatus {
                            Label(status, systemImage: "lock.shield")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityIdentifier("onboarding-storage-status")
                        }
                    }
                    .padding(20)
                    .background(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(.ultraThinMaterial)
                            .overlay(
                                RoundedRectangle(cornerRadius: 22, style: .continuous)
                                    .fill(
                                        LinearGradient(
                                            colors: [
                                                Color.indigo.opacity(0.12),
                                                Color.cyan.opacity(0.05),
                                                Color.clear
                                            ],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(Color.white.opacity(0.16), lineWidth: 1)
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                footer
            }
            .frame(maxWidth: 760, maxHeight: .infinity)
            .padding(.horizontal, 18)
            .padding(.vertical, 18)
        }
        .onAppear {
            if selectedRelayId == nil {
                selectedRelayId = model.state.selectedRelayId ?? model.state.relayServers.first?.id
            }
            acceptedPrivacyPolicy = model.state.hasAcceptedPrivacyPolicy
            acceptedTermsOfUse = model.state.hasAcceptedTermsOfUse
            privacySettings = model.state.privacy
            appLockSettings = model.state.appLock
            if appLockSettings.mode == .off {
                appLockSettings.mode = model.biometricsAvailable ? .biometrics : .pinOnly
            }
            if !model.biometricsAvailable, appLockSettings.mode == .biometrics {
                appLockSettings.mode = appLockSettings.isPinConfigured ? .pinOnly : .off
            }
            if !model.biometricsAvailable, appLockSettings.mode == .biometricsAndPin {
                appLockSettings.mode = appLockSettings.isPinConfigured ? .pinOnly : .off
            }
            onboardingBiometricVerified = !requiresBiometricsForOnboardingLock(appLockSettings.mode)
            storageMode = model.storageProtectionMode
        }
        .sheet(isPresented: $showingRelayEditor) {
            RelayEditorView(
                title: "Add Relay",
                initial: nil,
                requiresReachableRelay: true
            ) { name, endpoint, note, relayPassword, pinOrigin in
                Task {
                    await model.addRelayServer(
                        name: name,
                        endpoint: endpoint,
                        note: note,
                        relayPassword: relayPassword,
                        certificatePinOrigin: pinOrigin
                    )
                    selectedRelayId = model.state.relayServers.first(where: {
                        $0.endpoint == endpoint
                    })?.id
                }
            }
            .noctyraSheetPresentation()
        }
        .platformPinPresentation(item: $pinSetupKind) { kind in
            PinSetupView(
                title: kind.title,
                subtitle: kind.subtitle,
                onComplete: { pin in
                    let success: Bool
                    switch kind {
                    case .unlock:
                        success = await model.setAppLockPin(pin)
                    case .burnIdentity:
                        success = await model.setActionPin(pin, action: .burnIdentity)
                    case .clearChats:
                        success = await model.setActionPin(pin, action: .clearChats)
                    case .actionPlan:
                        success = false
                    }
                    if success {
                        await MainActor.run {
                            syncAppLockPinsFromModel()
                            pinSetupKind = nil
                        }
                    }
                    return success
                },
                onCancel: {
                    pinSetupKind = nil
                }
            )
        }
        .onChange(of: storageMode) { _, newValue in
            guard newValue != model.storageProtectionMode else { return }
            isUpdatingStorageMode = true
            Task {
                await model.updateStorageProtectionMode(newValue)
                await MainActor.run {
                    storageMode = model.storageProtectionMode
                    isUpdatingStorageMode = false
                }
            }
        }
        .onChange(of: model.state.appLock) { _, newValue in
            appLockSettings.lockScreenMessage = newValue.lockScreenMessage
            appLockSettings.pinSalt = newValue.pinSalt
            appLockSettings.pinHash = newValue.pinHash
        }
        .onChange(of: appLockSettings.mode) { _, newValue in
            if requiresBiometricsForOnboardingLock(newValue) {
                onboardingBiometricVerified = false
                triggerOnboardingBiometricVerification()
            } else {
                onboardingBiometricVerified = true
                onboardingBiometricError = nil
            }
        }
        .interactiveDismissDisabled(true)
    }

    private var onboardingBackground: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.black,
                    Color(red: 0.06, green: 0.08, blue: 0.15),
                    Color(red: 0.03, green: 0.06, blue: 0.10)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Circle()
                .fill(Color.cyan.opacity(0.18))
                .frame(width: 340, height: 340)
                .blur(radius: 48)
                .offset(x: 170, y: -250)
            Circle()
                .fill(Color.indigo.opacity(0.20))
                .frame(width: 320, height: 320)
                .blur(radius: 46)
                .offset(x: -180, y: 220)
        }
        .ignoresSafeArea()
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image("Rhombus")
                .resizable()
                .scaledToFit()
                .frame(width: 54, height: 54)
                .shadow(color: Color.cyan.opacity(0.30), radius: 14)
            VStack(alignment: .leading, spacing: 3) {
                Text("Noctyra")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                Text("Private by design. Yours to operate.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private var progressStrip: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.rawValue) { item in
                HStack(spacing: 5) {
                    Image(systemName: item.rawValue < step.rawValue ? "checkmark" : item.symbol)
                        .font(.system(size: 9, weight: .bold))
                    if item == step {
                        Text("\(item.rawValue + 1) of \(Step.allCases.count)")
                            .font(.caption2.weight(.semibold))
                    }
                }
                .foregroundStyle(item.rawValue <= step.rawValue ? Color.white : Color.secondary)
                .frame(maxWidth: item == step ? 92 : 32, minHeight: 30)
                .background(
                    Capsule()
                        .fill(item == step ? Color.accentColor.opacity(0.30) : Color.white.opacity(item.rawValue < step.rawValue ? 0.14 : 0.06))
                )
                .animation(.easeInOut(duration: 0.20), value: step)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack {
            Button("Back") { back() }
                .glassButton()
                .disabled(step == .identity || isFinishing)
                .opacity(step == .identity ? 0 : 1)
                .allowsHitTesting(step != .identity && !isFinishing)
            Spacer()
            Button(step == .review ? "Create" : "Continue") {
                advance()
            }
            .glassButton(prominent: true)
            .disabled(!canContinue || isFinishing)
            .accessibilityIdentifier("onboarding-continue")
        }
        .padding(.bottom, 2)
    }

    private var canContinue: Bool {
        switch step {
        case .identity:
            return !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .relay:
            return selectedRelayId != nil || !model.state.relayServers.isEmpty
        case .privacy:
            return canContinuePrivacyStep
        case .legal:
            return acceptedPrivacyPolicy && acceptedTermsOfUse
        case .review:
            return !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && (selectedRelayId != nil || !model.state.relayServers.isEmpty)
                && canContinuePrivacyStep
                && acceptedPrivacyPolicy
                && acceptedTermsOfUse
        }
    }

    private var identityStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Your first identity", systemImage: "person.badge.key.fill")
                .font(.headline)
            Text("Choose the name contacts will see. Cryptographic keys and your mailbox address are generated locally after setup.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("Display name", text: $displayName)
                .onboardingField()
            Label("You can create more independent identities later.", systemImage: "plus.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .uniformGlassCard(cornerRadius: 18, padding: 16)
    }

    private var relayStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Relays transport encrypted envelopes only. Choose your preferred home relay now.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if model.state.relayServers.isEmpty {
                Text("No relays are configured.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.state.relayServers) { server in
                        Button {
                            selectedRelayId = server.id
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: selectedRelayId == server.id ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedRelayId == server.id ? Color.accentColor : Color.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(server.displayName)
                                        .font(.headline)
                                        .lineLimit(1)
                                    Text(relayAddressLabel(server.endpoint))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if let note = server.note, !note.isEmpty {
                                        Text(note)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                                Spacer()
                            }
                            .uniformGlassCard(cornerRadius: 14, padding: 12, minHeight: 60)
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(selectedRelayId == server.id ? Color.accentColor.opacity(0.55) : Color.clear, lineWidth: 1.2)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Button("Add Relay") {
                showingRelayEditor = true
            }
            .glassButton()
        }
    }

    private var privacyStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set your privacy baseline now. You can fine-tune everything later in Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Group {
                Text("Storage Protection")
                    .font(.headline)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(StorageProtectionMode.allCases) { mode in
                        Button {
                            storageMode = mode
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: storageMode == mode ? "checkmark.circle.fill" : "circle")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(mode.displayName)
                                        .font(.subheadline.weight(.semibold))
                                    Text(mode.descriptionText)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .uniformGlassCard(cornerRadius: 14, padding: 12, minHeight: 64)
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(storageMode == mode ? Color.accentColor.opacity(0.55) : Color.clear, lineWidth: 1.2)
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("onboarding-storage-\(mode.rawValue)")
                    }
                }
                if isUpdatingStorageMode {
                    Text("Updating storage protection...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider().opacity(0.22)

            Group {
                Text("Privacy")
                    .font(.headline)
                Toggle("Secure typing", isOn: $privacySettings.secureTypingEnabled)
                Text("Enables secure input where available to reduce keyboard capture exposure.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #if os(iOS)
                Picker("Secure typing keyboard", selection: $privacySettings.secureTypingKeyboard) {
                    ForEach(SecureTypingKeyboard.allCases) { keyboard in
                        Text(keyboard.displayName).tag(keyboard)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!privacySettings.secureTypingEnabled)
                Text(privacySettings.secureTypingKeyboard == .noctyra
                     ? "Noctyra's keyboard is preferred because input stays inside the app instead of using the OS keyboard path."
                     : "Apple's secure keyboard uses native secure text entry. iOS may show the Passwords shortcut.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #endif
                Toggle("Use in-app camera capture", isOn: $privacySettings.useSecureCameraCapture)
                Text("On by default. Captures inside Noctyra and avoids automatic Photos persistence.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #if os(macOS)
                Toggle("Hide sensitive content when unfocused", isOn: $privacySettings.hideSensitiveWhenUnfocused)
                Toggle("Block window capture (best effort)", isOn: $privacySettings.macBlockWindowCapture)
                #endif
            }

            Divider().opacity(0.22)

            Group {
                Text("App Lock")
                    .font(.headline)
                if !model.biometricsAvailable {
                    Text("Biometrics are unavailable on this device. PIN-based unlock is available.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(onboardingLockModes, id: \.self) { mode in
                        Button {
                            appLockSettings.mode = mode
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: appLockSettings.mode == mode ? "checkmark.circle.fill" : "circle")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(mode.displayName)
                                        .font(.subheadline.weight(.semibold))
                                    Text(lockModeDescription(mode))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .uniformGlassCard(cornerRadius: 14, padding: 12, minHeight: 64)
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(appLockSettings.mode == mode ? Color.accentColor.opacity(0.55) : Color.clear, lineWidth: 1.2)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                Picker("Session timeout", selection: $appLockSettings.sessionTimeoutMinutes) {
                    Text("Immediate").tag(0)
                    Text("1 minute").tag(1)
                    Text("5 minutes").tag(5)
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                    Text("60 minutes").tag(60)
                }
                .pickerStyle(.menu)

                if requiresPinForOnboardingLock {
                    Text(appLockSettings.isPinConfigured ? "PIN configured." : "PIN is required for the selected unlock method.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(appLockSettings.isPinConfigured ? "Update PIN" : "Set PIN") {
                        pinSetupKind = .unlock
                    }
                    .glassButton(prominent: true)
                }

                if requiresBiometricsForOnboardingLock(appLockSettings.mode) {
                    Text(onboardingBiometricVerified ? "Biometrics verified for this setup." : "Biometric permission must be granted during setup.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(isVerifyingOnboardingBiometrics ? "Verifying..." : (onboardingBiometricVerified ? "Re-verify Biometrics" : "Verify Biometrics")) {
                        triggerOnboardingBiometricVerification()
                    }
                    .glassButton(prominent: !onboardingBiometricVerified)
                    .disabled(isVerifyingOnboardingBiometrics)
                    if let onboardingBiometricError {
                        Text(onboardingBiometricError)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }

                TextField("Optional lock screen message", text: $appLockSettings.lockScreenMessage, axis: .vertical)
                    .lineLimit(2...3)
                    .onboardingField()
                    .onChange(of: appLockSettings.lockScreenMessage) { _, newValue in
                        let capped = String(newValue.prefix(140))
                        if capped != newValue {
                            appLockSettings.lockScreenMessage = capped
                        }
                    }
                Text("Optional. This message is shown on the app lock screen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var reviewStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            reviewRow(label: "Name", value: displayName.isEmpty ? "Not set" : displayName)
            reviewRow(label: "Relay", value: selectedRelayDisplay)
            reviewRow(label: "Storage", value: storageMode.displayName)
            reviewRow(
                label: "Secure Typing",
                value: privacySettings.secureTypingEnabled
                    ? "On (\(privacySettings.secureTypingKeyboard.shortName))"
                    : "Off"
            )
            reviewRow(label: "In-App Camera", value: privacySettings.useSecureCameraCapture ? "On" : "Off")
            reviewRow(label: "App Lock", value: appLockSettings.mode.displayName)
            reviewRow(
                label: "Lock Message",
                value: appLockSettings.lockScreenMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Not set"
                    : "Configured"
            )
            reviewRow(label: "Privacy Policy", value: acceptedPrivacyPolicy ? "Accepted" : "Not accepted")
            reviewRow(label: "Terms of Use", value: acceptedTermsOfUse ? "Accepted" : "Not accepted")
            Text("Noctyra will now create your profile, generate keys, publish prekeys, and begin relay sync.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func reviewRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var legalStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Privacy Policy")
                        .font(.headline)
                    Text(privacyPolicyText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Divider().opacity(0.2)
                    Text("Terms of Use")
                        .font(.headline)
                    Text(termsOfUseText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 170, maxHeight: 290)

            Toggle("I accept the Privacy Policy", isOn: $acceptedPrivacyPolicy)
            Toggle("I accept the Terms of Use", isOn: $acceptedTermsOfUse)
        }
    }

    private var selectedRelayDisplay: String {
        if let selectedRelayId, let server = model.state.relayServers.first(where: { $0.id == selectedRelayId }) {
            return server.displayName
        }
        return model.state.relayServers.first?.displayName ?? "Not set"
    }

    private func relayAddressLabel(_ endpoint: RelayEndpoint) -> String {
        let scheme: String
        let defaultPort: UInt16
        switch endpoint.transport {
        case .http:
            scheme = endpoint.useTLS ? "https" : "http"
            defaultPort = endpoint.useTLS ? 443 : 80
        case .websocket:
            scheme = endpoint.useTLS ? "wss" : "ws"
            defaultPort = endpoint.useTLS ? 443 : 80
        case .tcp:
            scheme = endpoint.useTLS ? "tls" : "tcp"
            defaultPort = 9339
        }
        if endpoint.port == defaultPort {
            return "\(scheme)://\(endpoint.host)"
        }
        return "\(scheme)://\(endpoint.host):\(endpoint.port)"
    }

    private func back() {
        guard let current = Step(rawValue: step.rawValue), current != .identity else { return }
        step = Step(rawValue: max(0, current.rawValue - 1)) ?? .identity
    }

    private func advance() {
        if step == .review {
            finish()
            return
        }
        step = Step(rawValue: min(Step.allCases.count - 1, step.rawValue + 1)) ?? .review
    }

    private func finish() {
        guard !isFinishing else { return }
        isFinishing = true
        let relayId = selectedRelayId ?? model.state.relayServers.first?.id
        let finalPrivacy = privacySettings
        let finalAppLock = appLockSettings
        let finalStorageMode = storageMode
        Task {
            let storageReady = await model.updateStorageProtectionMode(finalStorageMode)
            guard storageReady else {
                await MainActor.run {
                    isFinishing = false
                }
                return
            }
            await model.completeOnboarding(
                displayName: displayName,
                relayId: relayId,
                privacy: finalPrivacy,
                appLock: finalAppLock,
                acceptedPrivacyPolicy: acceptedPrivacyPolicy,
                acceptedTermsOfUse: acceptedTermsOfUse
            )
            isFinishing = false
        }
    }

    private var onboardingLockModes: [AppLockMode] {
        if model.biometricsAvailable {
            return [.biometrics, .pinOnly, .biometricsAndPin]
        }
        return [.pinOnly]
    }

    private func lockModeDescription(_ mode: AppLockMode) -> String {
        switch mode {
        case .off:
            return "Disabled"
        case .biometrics:
            return "Unlock with biometrics only."
        case .pinOnly:
            return "Unlock with a 6-digit PIN only."
        case .biometricsAndPin:
            return "Require biometrics first, then PIN."
        }
    }

    private var privacyPolicyText: String {
        """
        Noctyra stores selected profile data locally on your device and transmits encrypted envelopes through relays you configure. Even with end-to-end encryption, relay operators and network observers may infer metadata such as timing, source IP, destination relay, online status, and traffic volume patterns. You are solely responsible for selecting trustworthy relays, hardening your devices, controlling backups, and evaluating metadata exposure in your threat model.
        """
    }

    private var termsOfUseText: String {
        """
        By continuing, you agree this software is provided \"as is\" and \"as available\" without warranties or guarantees of any kind, express or implied, including merchantability, fitness for a particular purpose, availability, non-infringement, or security outcomes. Any relay bundled with a prerelease build is an optional temporary test endpoint, not a managed or production service; it may change or disappear without notice and has no promised uptime, retention, moderation, recovery, or security outcome. There are no developer-hosted production relays, managed infrastructure, moderation services, abuse handling services, recovery guarantees, legal compliance guarantees, or promised uptime. You are solely responsible for lawful use, key management, relay operation choices, compliance obligations, and operational security. To the maximum extent permitted by law, the software provider is not liable for any use or misuse of the software, including unlawful activity, data loss, compromise, metadata exposure, service interruption, account or identity loss, or any direct, indirect, incidental, consequential, special, exemplary, or punitive damages. You agree to indemnify and hold harmless the software provider from claims, liabilities, losses, and expenses arising from your use, deployment, or operation of the software.
        """
    }

    private var requiresPinForOnboardingLock: Bool {
        appLockSettings.mode == .biometricsAndPin || appLockSettings.mode == .pinOnly
    }

    private var canContinuePrivacyStep: Bool {
        if isUpdatingStorageMode {
            return false
        }
        if requiresPinForOnboardingLock && !appLockSettings.isPinConfigured {
            return false
        }
        if requiresBiometricsForOnboardingLock(appLockSettings.mode) && !onboardingBiometricVerified {
            return false
        }
        return true
    }

    private func requiresBiometricsForOnboardingLock(_ mode: AppLockMode) -> Bool {
        mode == .biometrics || mode == .biometricsAndPin
    }

    private func triggerOnboardingBiometricVerification() {
        guard model.biometricsAvailable else { return }
        guard !isVerifyingOnboardingBiometrics else { return }
        isVerifyingOnboardingBiometrics = true
        onboardingBiometricError = nil
        Task {
            let success = await model.performBiometricUnlock(reason: "Authorize app biometrics setup")
            await MainActor.run {
                isVerifyingOnboardingBiometrics = false
                onboardingBiometricVerified = success
                if !success {
                    onboardingBiometricError = "Biometric verification failed. Enroll Face ID/Touch ID and allow Noctyra in system settings."
                }
            }
        }
    }

    private func syncAppLockPinsFromModel() {
        let source = model.state.appLock
        appLockSettings.pinSalt = source.pinSalt
        appLockSettings.pinHash = source.pinHash
        appLockSettings.lockScreenMessage = source.lockScreenMessage
    }
}

private extension View {
    func onboardingField() -> some View {
        textFieldStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.white.opacity(0.16), lineWidth: 0.8)
                    )
            )
    }
}
