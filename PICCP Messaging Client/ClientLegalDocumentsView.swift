import SwiftUI

struct ClientLegalDocumentsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Privacy Policy")
                        .font(.headline)
                    Text(
                        "Noctyra stores selected profile data locally on your device and transmits encrypted envelopes through relays you configure. Even with end-to-end encryption, relay operators and network observers may infer metadata such as timing, source IP, destination relay, online status, and traffic volume patterns. You are solely responsible for selecting trustworthy relays, hardening your devices, controlling backups, and evaluating metadata exposure in your threat model."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)

                    Divider().opacity(0.25)

                    Text("Terms of Use")
                        .font(.headline)
                    Text(
                        "By continuing, you agree this software is provided \"as is\" and \"as available\" without warranties or guarantees of any kind, express or implied, including merchantability, fitness for a particular purpose, availability, non-infringement, or security outcomes. There are no developer-hosted relays, managed infrastructure, moderation services, abuse handling services, recovery guarantees, legal compliance guarantees, or promised uptime. You are solely responsible for lawful use, key management, relay operation choices, compliance obligations, and operational security. To the maximum extent permitted by law, the software provider is not liable for any use or misuse of the software, including unlawful activity, data loss, compromise, metadata exposure, service interruption, account or identity loss, or any direct, indirect, incidental, consequential, special, exemplary, or punitive damages. You agree to indemnify and hold harmless the software provider from claims, liabilities, losses, and expenses arising from your use, deployment, or operation of the software."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            .navigationTitle("Policies")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
