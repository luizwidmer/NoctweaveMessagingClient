import SwiftUI

struct ClientLegalDocumentsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SheetActionBar(onClose: { dismiss() })

                    SheetHero(
                        icon: "doc.text.fill",
                        title: "Policies",
                        subtitle: "Privacy, operation, and terms of use."
                    )

                    SheetSection(title: "Privacy Policy", icon: "hand.raised.fill") {
                    Text(
                        "Noctyra stores selected profile data locally on your device and transmits encrypted envelopes through relays you configure. Even with end-to-end encryption, relay operators and network observers may infer metadata such as timing, source IP, destination relay, online status, and traffic volume patterns. You are solely responsible for selecting trustworthy relays, hardening your devices, controlling backups, and evaluating metadata exposure in your threat model."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    }

                    SheetSection(title: "Terms of Use", icon: "checkmark.seal.fill") {
                    Text(
                        "By continuing, you agree this software is provided \"as is\" and \"as available\" without warranties or guarantees of any kind, express or implied, including merchantability, fitness for a particular purpose, availability, non-infringement, or security outcomes. Any relay bundled with a prerelease build is an optional temporary test endpoint, not a managed or production service; it may change or disappear without notice and has no promised uptime, retention, moderation, recovery, or security outcome. There are no developer-hosted production relays, managed infrastructure, moderation services, abuse handling services, recovery guarantees, legal compliance guarantees, or promised uptime. You are solely responsible for lawful use, key management, relay operation choices, compliance obligations, and operational security. To the maximum extent permitted by law, the software provider is not liable for any use or misuse of the software, including unlawful activity, data loss, compromise, metadata exposure, service interruption, account or identity loss, or any direct, indirect, incidental, consequential, special, exemplary, or punitive damages. You agree to indemnify and hold harmless the software provider from claims, liabilities, losses, and expenses arising from your use, deployment, or operation of the software."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .noctyraSheetBackground()
            .hideSheetNavigationBar()
        }
        .noctyraSheetPresentation()
    }
}
