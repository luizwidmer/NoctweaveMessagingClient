import SwiftUI
import PICCPCore

struct IdentityBurnView: View {
    @ObservedObject var model: ClientViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Warning") {
                    Text("Burning your identity creates a new inbox address. Only contacts marked in Contact Book will be notified and retained.")
                        .foregroundStyle(.secondary)
                }

                Section("Contacts To Notify") {
                    let allowedContacts = model.state.contacts.filter { $0.allowIdentityReset }
                    if allowedContacts.isEmpty {
                        Text("No contacts are marked to receive your new identity.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(allowedContacts) { contact in
                            Text(contact.displayName)
                        }
                        Text("Manage this list in Contact Book.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Burn Identity")
            .scrollContentBackground(.hidden)
            #if os(macOS)
            .formStyle(.grouped)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Burn") {
                        Task {
                            await model.burnIdentity()
                            dismiss()
                        }
                    }
                    .glassButton(prominent: true)
                }
            }
        }
    }
}
