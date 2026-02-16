import SwiftUI
import PICCPCore

struct FirstRunSetupView: View {
    @ObservedObject var model: ClientViewModel

    @State private var step: Step = .identity
    @State private var displayName: String = ""
    @State private var selectedRelayId: UUID?
    @State private var acceptedPrivacyPolicy = false
    @State private var acceptedTermsOfUse = false
    @State private var showingRelayEditor = false
    @State private var isFinishing = false

    private enum Step: Int, CaseIterable {
        case identity
        case relay
        case legal
        case review

        var title: String {
            switch self {
            case .identity: return "Create Identity"
            case .relay: return "Choose Relay"
            case .legal: return "Legal Consent"
            case .review: return "Finish Setup"
            }
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                NoctyraTopBar(title: "Welcome", subtitle: "Set up identity and relay")

                VStack(alignment: .leading, spacing: 12) {
                    Text(step.title)
                        .font(.title3.weight(.semibold))

                    switch step {
                    case .identity:
                        identityStep
                    case .relay:
                        relayStep
                    case .legal:
                        legalStep
                    case .review:
                        reviewStep
                    }

                    Divider().opacity(0.25)

                    HStack {
                        Button("Back") { back() }
                            .glassButton()
                            .disabled(step == .identity || isFinishing)
                        Spacer()
                        Button(step == .review ? "Create" : "Continue") {
                            advance()
                        }
                        .glassButton(prominent: true)
                        .disabled(!canContinue || isFinishing)
                    }
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .frame(maxWidth: 560)
        }
        .onAppear {
            // Defaults for first boot.
            if displayName.isEmpty {
                displayName = ""
            }
            if selectedRelayId == nil {
                selectedRelayId = model.state.selectedRelayId ?? model.state.relayServers.first?.id
            }
            acceptedPrivacyPolicy = model.state.hasAcceptedPrivacyPolicy
            acceptedTermsOfUse = model.state.hasAcceptedTermsOfUse
        }
        .sheet(isPresented: $showingRelayEditor) {
            RelayEditorView(title: "Add Relay Server", initial: nil) { name, host, port, useTLS, note, relayPassword in
                Task {
                    await model.addRelayServer(
                        name: name,
                        host: host,
                        port: port,
                        useTLS: useTLS,
                        note: note,
                        relayPassword: relayPassword
                    )
                    selectedRelayId = model.state.relayServers.first(where: {
                        $0.endpoint.host == host && $0.endpoint.port == port && $0.endpoint.useTLS == useTLS
                    })?.id
                }
            }
        }
        .interactiveDismissDisabled(true)
    }

    private var canContinue: Bool {
        switch step {
        case .identity:
            return !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .relay:
            return selectedRelayId != nil || !model.state.relayServers.isEmpty
        case .legal:
            return acceptedPrivacyPolicy && acceptedTermsOfUse
        case .review:
            return !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && (selectedRelayId != nil || !model.state.relayServers.isEmpty)
                && acceptedPrivacyPolicy
                && acceptedTermsOfUse
        }
    }

    private var identityStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("This name is shown to your contacts. Your cryptographic identity is generated on-device.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Display name", text: $displayName)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var relayStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Relays route your encrypted envelopes. Pick a home relay now; you can add more later.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if model.state.relayServers.isEmpty {
                Text("No relays yet.")
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
                                    Text("\(server.endpoint.host):\(server.endpoint.port)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Color.white.opacity(0.06))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Button("Add Relay Server") {
                showingRelayEditor = true
            }
            .glassButton()
        }
    }

    private var reviewStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Review")
                .font(.headline)
            HStack {
                Text("Name")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(displayName.isEmpty ? "Not set" : displayName)
            }
            HStack {
                Text("Relay")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(selectedRelayDisplay)
                    .lineLimit(1)
            }
            HStack {
                Text("Privacy Policy")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(acceptedPrivacyPolicy ? "Accepted" : "Not accepted")
            }
            HStack {
                Text("Terms of Use")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(acceptedTermsOfUse ? "Accepted" : "Not accepted")
            }
            Text("Noctyra will generate your identity keys, publish prekeys to the relay, and start syncing messages.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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
            .frame(minHeight: 180, maxHeight: 260)

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
        Task {
            await model.completeOnboarding(
                displayName: displayName,
                relayId: relayId,
                acceptedPrivacyPolicy: acceptedPrivacyPolicy,
                acceptedTermsOfUse: acceptedTermsOfUse
            )
            isFinishing = false
        }
    }

    private var privacyPolicyText: String {
        """
        Noctyra stores selected profile data locally on your device and transmits encrypted envelopes through relays you configure. Even with end-to-end encryption, relay operators and network observers may infer metadata such as timing, source IP, destination relay, online status, and traffic volume patterns. You are solely responsible for selecting trustworthy relays, hardening your devices, controlling backups, and evaluating metadata exposure in your threat model.
        """
    }

    private var termsOfUseText: String {
        """
        By continuing, you agree this software is provided \"as is\" and \"as available\" without warranties or guarantees of any kind, express or implied, including merchantability, fitness for a particular purpose, availability, non-infringement, or security outcomes. There are no developer-hosted relays, managed infrastructure, moderation services, abuse handling services, recovery guarantees, legal compliance guarantees, or promised uptime. You are solely responsible for lawful use, key management, relay operation choices, compliance obligations, and operational security. To the maximum extent permitted by law, the software provider is not liable for any use or misuse of the software, including unlawful activity, data loss, compromise, metadata exposure, service interruption, account or identity loss, or any direct, indirect, incidental, consequential, special, exemplary, or punitive damages. You agree to indemnify and hold harmless the software provider from claims, liabilities, losses, and expenses arising from your use, deployment, or operation of the software.
        """
    }
}
