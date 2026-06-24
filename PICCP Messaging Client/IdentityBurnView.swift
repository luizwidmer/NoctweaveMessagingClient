import SwiftUI
import PICCPCore

struct IdentityBurnView: View {
    @ObservedObject var model: ClientViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var requestedBurn = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SheetActionBar(closeLabel: "Cancel", onClose: { dismiss() }) {
                        Button {
                            beginBurn()
                        } label: {
                            Label(
                                model.isBurningIdentity ? "Burning…" : "Burn Identity",
                                systemImage: "flame.fill"
                            )
                        }
                        .glassButton(prominent: true, compact: true)
                        .disabled(model.isBurningIdentity)
                    }

                    SheetHero(
                        icon: "flame.fill",
                        title: "Burn Identity",
                        subtitle: "Replace this identity, inbox, and routing address."
                    )

                    SheetSection(title: "Operational Warning", icon: "exclamationmark.triangle.fill", role: .destructive) {
                        Text("A burn is intentionally irreversible. It creates a new inbox address and ends contactability through the current identity.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text("Only contacts previously marked in Contact Book will receive the signed replacement identity and remain available.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    let allowedContacts = model.state.contacts.filter { $0.allowIdentityReset }
                    SheetSection(
                        title: "Contacts To Notify",
                        subtitle: "\(allowedContacts.count) selected",
                        icon: "person.2.fill"
                    ) {
                    if allowedContacts.isEmpty {
                        SheetEmptyState(
                            icon: "person.crop.circle.badge.xmark",
                            title: "No contacts selected",
                            message: "No contacts will receive the replacement identity."
                        )
                    } else {
                        LazyVStack(spacing: 8) {
                            ForEach(allowedContacts) { contact in
                                HStack(spacing: 10) {
                                    Image(systemName: "person.fill.checkmark")
                                        .foregroundStyle(.green)
                                        .frame(width: 30, height: 30)
                                        .background(Color.green.opacity(0.12), in: Circle())
                                    Text(contact.displayName)
                                        .font(.subheadline.weight(.medium))
                                    Spacer()
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                            }
                        }
                    }
                    Text("Change this selection from Contact Book before burning.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
            .noctyraSheetBackground()
            .hideSheetNavigationBar()
            .interactiveDismissDisabled(model.isBurningIdentity)
            .onChange(of: model.isBurningIdentity) { _, isBurning in
                if requestedBurn, !isBurning {
                    dismiss()
                }
            }
        }
        .noctyraSheetPresentation()
    }

    private func beginBurn() {
        guard !model.isBurningIdentity else { return }
        requestedBurn = true
        Task {
            await model.burnIdentity()
        }
    }
}
