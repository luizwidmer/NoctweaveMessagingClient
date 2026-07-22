import NoctweaveCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: ClientViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingLocalResetConfirmation = false
    #if os(macOS)
    @StateObject private var windowController = AppWindowController()
    #endif

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
                        Button("Reset Local App Data…", role: .destructive) {
                            showingLocalResetConfirmation = true
                        }
                        .glassButton()
                        .accessibilityIdentifier("boot.resetLocalData")
                        Text("Reset is the recovery path for an incompatible pre-release database or a rollback alert you have independently verified. It permanently removes local identities, contacts, messages, groups, and attachments from this device.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                case .ready:
                    if model.isOnboardingComplete {
                        protectedClientShell
                    } else {
                        ClientOnboardingView(model: model)
                    }
                }
            }
        }
        #if os(macOS)
        .environmentObject(windowController)
        .background(NoctweaveWindowConfigurator())
        .overlay {
            WindowCaptureView(controller: windowController)
                .frame(width: 0, height: 0)
        }
        .overlay(alignment: .topLeading) {
            NoctweaveTrafficLights()
                .environmentObject(windowController)
                .padding(.leading, 14)
                .padding(.top, 12)
                .zIndex(1_000)
        }
        .ignoresSafeArea(.container, edges: .top)
        #endif
        .confirmationDialog(
            "Reset all local Noctweave data?",
            isPresented: $showingLocalResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset Local App Data", role: .destructive) {
                Task { await model.resetLocalApplication() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently erases local identities, contacts, messages, groups, attachments, and app settings. It cannot be undone and starts onboarding again.")
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.resumeFromBackground()
                model.foregroundResumeSync()
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
                .uniformGlassCard(cornerRadius: 24, padding: 22)
                .frame(maxWidth: 430)
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
            .uniformGlassCard(cornerRadius: 26, padding: 22)
            .frame(maxWidth: 460)
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

private struct ClientOnboardingView: View {
    @ObservedObject var model: ClientViewModel
    @Environment(\.appTheme) private var theme
    @State private var displayName = ""
    @State private var relay = ""
    @State private var relayPassword = ""
    @State private var privacy = PrivacySettings()
    @State private var appLockMode: AppLockMode = .off
    @State private var pin = ""
    @State private var pinConfirmation = ""
    @State private var acceptedPrivacyPolicy = false
    @State private var acceptedTerms = false
    @State private var showingLegalDocuments = false
    @State private var showingAdvancedRelayOptions = false

    private let bundledTestRelay = "https://noctyratest.luizwidmer.com"

    var body: some View {
        ZStack {
            GlassBackground().ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    onboardingHeader
                    stepContent
                }
                .padding(24)
                .uniformGlassCard(cornerRadius: 30, padding: 0)
                .frame(maxWidth: 680)
                .background {
                    Color.clear
                        .accessibilityElement()
                        .accessibilityIdentifier("onboarding.container")
                        .allowsHitTesting(false)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 18)
                .padding(.vertical, 28)
            }
        }
        .task {
            if displayName.isEmpty {
                displayName = model.activePersona?.displayName == "Unnamed Persona"
                    ? ""
                    : (model.activePersona?.displayName ?? "")
            }
            privacy = model.privacySettings
        }
        .sheet(isPresented: $showingLegalDocuments) {
            OnboardingLegalDocumentsView()
        }
    }

    private var onboardingHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image("NoctweaveIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 62, height: 62)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Welcome to Noctweave")
                        .font(.largeTitle.weight(.bold))
                        .minimumScaleFactor(0.75)
                    Text("Private by design. Future by default.")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            ProgressView(value: Double(stepNumber), total: 6)
                .tint(theme.accent)
                .accessibilityLabel("Setup progress")
                .accessibilityValue("Step \(stepNumber) of 6")
            HStack {
                Text("STEP \(stepNumber) OF 6")
                    .font(.caption2.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(theme.accent)
                Spacer()
                Text(stepTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch model.onboardingStep {
        case .legal:
            onboardingSection(
                icon: "checkmark.shield.fill",
                title: "Start with informed consent",
                message: "Noctweave has no accounts or developer-operated production relay. Encryption protects content, but your device, relay choice, and network metadata still matter."
            ) {
                Button {
                    showingLegalDocuments = true
                } label: {
                    Label("Read Privacy Policy and Terms", systemImage: "doc.text.magnifyingglass")
                }
                .glassButton()

                Toggle("I have read and accept the Privacy Policy", isOn: $acceptedPrivacyPolicy)
                    .accessibilityIdentifier("onboarding.acceptPrivacy")
                Toggle("I have read and accept the Terms of Use", isOn: $acceptedTerms)
                    .accessibilityIdentifier("onboarding.acceptTerms")

                Button("Accept and Continue") {
                    model.acceptOnboardingLegalDocuments()
                }
                .glassButton(prominent: true)
                .disabled(!acceptedPrivacyPolicy || !acceptedTerms)
                .accessibilityIdentifier("onboarding.legal.continue")
            }
        case .persona:
            onboardingSection(
                icon: "person.crop.square.filled.and.at.rectangle",
                title: "Create your first persona",
                message: "A persona organizes relationships on this device. It is not a public account, reusable network identifier, or recovery authority. Each contact receives fresh relationship-scoped keys."
            ) {
                TextField("Display name", text: $displayName)
                    .noctweaveInputField()
                    .accessibilityIdentifier("onboarding.persona.name")
                Text("You can create additional isolated personas later and assign each one a different relay.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Create Persona") {
                    model.saveOnboardingPersonaName(displayName)
                }
                .glassButton(prominent: true)
                .disabled(displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("onboarding.persona.continue")
            }
        case .relay:
            onboardingSection(
                icon: "antenna.radiowaves.left.and.right",
                title: "Choose a relay",
                message: "A relay stores and forwards encrypted envelopes. Noctweave verifies reachability and required protocol capabilities before saving it."
            ) {
                TextField("Relay URL or host", text: $relay)
                    .noctweaveInputField()
                    .accessibilityIdentifier("onboarding.relay.address")

                Button {
                    relay = bundledTestRelay
                } label: {
                    Label("Use bundled test relay", systemImage: "testtube.2")
                }
                .glassButton(compact: true)

                DisclosureGroup("Advanced access options", isExpanded: $showingAdvancedRelayOptions) {
                    VStack(alignment: .leading, spacing: 8) {
                        SecureField("Relay access password", text: $relayPassword)
                            .noctweaveInputField()
                        Text("Only enter a password if the relay operator requires one. Certificate pins are configured later in Advanced Relay Tools.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)
                }

                Button("Check and Save Relay") {
                    model.validateOnboardingRelay(relayText: relay, password: relayPassword)
                }
                .glassButton(prominent: true)
                .disabled(relay.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || model.onboardingRelayCheckState == .checking)
                .accessibilityIdentifier("onboarding.relay.validate")
                onboardingStatus
            }
        case .storageProtection:
            onboardingSection(
                icon: "externaldrive.badge.shield.half.filled",
                title: "Protect local storage",
                message: "Conversation state and attachments remain encrypted on disk. Noctweave asks the system Keychain to protect an independent rollback anchor and attachment-vault key."
            ) {
                Label("macOS may ask for your login password once to authorize Keychain access.", systemImage: "key.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("The Keychain is not a Noctweave account and does not sync message content. If secure key storage is unavailable, setup fails closed instead of silently writing plaintext.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Enable Encrypted Storage") {
                    model.acknowledgeOnboardingStorageProtection()
                }
                .glassButton(prominent: true)
                .accessibilityIdentifier("onboarding.storage.enable")
                onboardingStatus
            }
        case .privacy:
            onboardingSection(
                icon: "hand.raised.fill",
                title: "Choose local privacy controls",
                message: "These controls reduce exposure on the device. They cannot protect against a fully compromised operating system or hardware."
            ) {
                privacyChoice(
                    "Noctweave keyboard",
                    detail: "Use the in-app keyboard so message text does not pass through the operating system keyboard or its suggestions.",
                    isOn: $privacy.secureTypingEnabled
                )
                privacyChoice(
                    "In-app camera",
                    detail: "Capture directly into the encrypted attachment pipeline without first writing to the Photos library.",
                    isOn: $privacy.useSecureCameraCapture
                )
                privacyChoice(
                    "Auto-download attachments",
                    detail: "Fetch encrypted files automatically. Turn this off to approve each download in chat or the file gallery.",
                    isOn: $privacy.autoDownloadAttachments
                )
                privacyChoice(
                    "Hide when unfocused",
                    detail: "Cover contact, identity, relay, and conversation details whenever the app loses focus.",
                    isOn: $privacy.hideSensitiveWhenUnfocused
                )
                Button("Save Privacy Choices") {
                    Task { _ = await model.completeOnboardingPrivacy(privacy) }
                }
                .glassButton(prominent: true)
                .accessibilityIdentifier("onboarding.privacy.continue")
            }
        case .appLock:
            onboardingSection(
                icon: "lock.shield.fill",
                title: "Choose app access protection",
                message: "App lock covers the interface after launch or inactivity. Biometrics use biometric-only policy with no device-passcode fallback."
            ) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 10)], spacing: 10) {
                    ForEach(availableLockModes) { mode in
                        Button {
                            appLockMode = mode
                            pin = ""
                            pinConfirmation = ""
                        } label: {
                            HStack(spacing: 11) {
                                Image(systemName: lockIcon(for: mode))
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(lockTitle(for: mode)).font(.subheadline.weight(.semibold))
                                    Text(lockDetail(for: mode))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: appLockMode == mode ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(appLockMode == mode ? theme.accent : Color.secondary)
                            }
                            .padding(13)
                            .frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
                            .background(
                                appLockMode == mode ? theme.accent.opacity(0.12) : Color.white.opacity(0.035),
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                if requiresPIN {
                    SecureField("Six-digit PIN", text: $pin)
                        .pinKeyboard()
                        .noctweaveInputField()
                    SecureField("Repeat PIN", text: $pinConfirmation)
                        .pinKeyboard()
                        .noctweaveInputField()
                    if !pin.isEmpty && (pin.count != 6 || pin != pinConfirmation) {
                        Text(pin.count == 6 && pinConfirmation.count == 6
                            ? "PIN entries do not match."
                            : "PINs must contain exactly six digits.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Button(appLockMode == .off ? "Finish Without App Lock" : "Enable and Finish") {
                    Task {
                        if appLockMode == .off {
                            _ = await model.skipOnboardingAppLock()
                        } else {
                            _ = await model.completeOnboardingAppLock(
                                mode: appLockMode,
                                newPIN: requiresPIN ? pin : nil
                            )
                        }
                    }
                }
                .glassButton(prominent: true)
                .disabled(requiresPIN && !validPIN)
                .accessibilityIdentifier("onboarding.finish")

                if let error = model.settingsError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        case .complete:
            ProgressView("Opening encrypted conversations…")
        }
    }

    private func onboardingSection<Content: View>(
        icon: String,
        title: String,
        message: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 13) {
                Image(systemName: icon)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(theme.accent)
                    .frame(width: 44, height: 44)
                    .background(theme.accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.title2.weight(.bold))
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider().opacity(0.3)
            content()
        }
        .uniformGlassCard(cornerRadius: 24, padding: 18)
    }

    private func privacyChoice(
        _ title: String,
        detail: String,
        isOn: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(title, isOn: isOn)
                .font(.subheadline.weight(.semibold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.trailing, 8)
        }
        .padding(12)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
    }

    private var availableLockModes: [AppLockMode] {
        AppLockMode.allCases.filter { mode in
            model.biometricsAvailable || (mode != .biometrics && mode != .biometricsAndPin)
        }
    }

    private var requiresPIN: Bool {
        appLockMode == .pinOnly || appLockMode == .biometricsAndPin
    }

    private var validPIN: Bool {
        pin.count == 6 && pin == pinConfirmation && pin.allSatisfy(\.isNumber)
    }

    private var stepNumber: Int {
        switch model.onboardingStep {
        case .legal: 1
        case .persona: 2
        case .relay: 3
        case .storageProtection: 4
        case .privacy: 5
        case .appLock, .complete: 6
        }
    }

    private var stepTitle: String {
        switch model.onboardingStep {
        case .legal: "Privacy and Terms"
        case .persona: "Local Persona"
        case .relay: "Relay Connection"
        case .storageProtection: "Encrypted Storage"
        case .privacy: "Privacy Controls"
        case .appLock: "App Access"
        case .complete: "Ready"
        }
    }

    private func lockIcon(for mode: AppLockMode) -> String {
        switch mode {
        case .off: "lock.open"
        case .biometrics: "faceid"
        case .pinOnly: "number.square.fill"
        case .biometricsAndPin: "person.badge.key.fill"
        }
    }

    private func lockTitle(for mode: AppLockMode) -> String {
        switch mode {
        case .off: "No app lock"
        case .biometrics: model.biometricDisplayName
        case .pinOnly: "Six-digit PIN"
        case .biometricsAndPin: "\(model.biometricDisplayName) + PIN"
        }
    }

    private func lockDetail(for mode: AppLockMode) -> String {
        switch mode {
        case .off: "Open after local storage unlock"
        case .biometrics: "Biometric-only, no passcode fallback"
        case .pinOnly: "Works without biometric hardware"
        case .biometricsAndPin: "Require both independent checks"
        }
    }

    private var onboardingStatus: some View {
        Group {
            switch model.onboardingRelayCheckState {
            case .ready(let readiness):
                Text("Validated \(readiness.endpoint.host):\(readiness.endpoint.port)")
                    .foregroundStyle(.green)
            case .checking:
                ProgressView("Validating…")
            case .failed(let message):
                Text(message).foregroundStyle(.red)
            case .idle:
                EmptyView()
            }
            if let error = model.lastError { Text(error).foregroundStyle(.red) }
        }
        .font(.caption)
    }
}

private struct OnboardingLegalDocumentsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SheetHero(
                        icon: "doc.text.fill",
                        title: "Privacy and Terms",
                        subtitle: "Read these documents before creating local state."
                    )
                    legalSection(
                        title: "Privacy Policy",
                        icon: "hand.raised.fill",
                        text: "Noctweave stores selected profile data locally and transmits encrypted envelopes through relays you configure. Even with end-to-end encryption, relay operators and network observers may infer metadata including timing, source IP, destination relay, online status, and traffic volume. You are responsible for relay selection, device hardening, backups, and evaluating metadata exposure in your threat model."
                    )
                    legalSection(
                        title: "Terms of Use",
                        icon: "checkmark.seal.fill",
                        text: "This software is supplied as is and as available, without warranties or guarantees of availability, fitness, security outcomes, recovery, moderation, legal compliance, or uninterrupted relay service. No developer-operated production relay is provided. You are responsible for lawful use, key management, relay operation choices, and operational security. To the maximum extent permitted by law, the software provider is not liable for misuse, compromise, metadata exposure, identity loss, data loss, service interruption, or resulting damages."
                    )
                }
                .padding(18)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Policies")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 640, minHeight: 560)
        #endif
        .noctweaveSheetBackground()
        .noctweaveSheetPresentation()
    }

    private func legalSection(title: String, icon: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.headline)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .uniformGlassCard(cornerRadius: 20, padding: 16)
    }
}

struct SheetHero: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.tint)
                .frame(width: 46, height: 46)
                .background(Color.accentColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title2.weight(.bold))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .uniformGlassCard(cornerRadius: 22, padding: 16)
    }
}

struct SheetActionBar<Trailing: View>: View {
    let closeLabel: String
    let onClose: () -> Void
    @ViewBuilder let trailing: () -> Trailing

    init(
        closeLabel: String = "Close",
        onClose: @escaping () -> Void,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.closeLabel = closeLabel
        self.onClose = onClose
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(closeLabel, action: onClose)
                .glassButton(compact: true)
            Spacer()
            trailing()
        }
        .frame(maxWidth: .infinity)
    }
}

struct SheetSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: () -> Content

    init(
        title: String,
        icon: String,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.icon = icon
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(.primary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .uniformGlassCard(cornerRadius: 18, padding: 15)
    }
}
