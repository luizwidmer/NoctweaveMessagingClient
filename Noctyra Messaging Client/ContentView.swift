import NoctweaveCore
import SwiftUI

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

struct ContentView: View {
    @ObservedObject var model: ClientViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingPairing = false
    @State private var showingBurnConfirmation = false
    @State private var selectedGroupID: UUID?

    var body: some View {
        Group {
            if model.isLocked {
                ClientLockView(model: model)
            } else {
                switch model.bootState {
                case .loading:
                    ProgressView("Opening encrypted local state…")
                        .controlSize(.large)
                case .failed(let message):
                    ContentUnavailableView {
                        Label("State unavailable", systemImage: "lock.trianglebadge.exclamationmark")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Try Again") { Task { await model.open() } }
                    }
                case .ready:
                    clientShell
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model.lockForBackgroundIfConfigured() }
        }
        .sheet(isPresented: $showingPairing) {
            PairingView(model: model)
        }
        .confirmationDialog(
            "Burn this local persona?",
            isPresented: $showingBurnConfirmation,
            titleVisibility: .visible
        ) {
            Button("Burn Persona", role: .destructive) {
                selectedGroupID = nil
                model.burnPersona()
            }
        } message: {
            Text("Every relationship and group in this local persona will be replaced without a continuity link. This cannot be undone.")
        }
    }

    private var clientShell: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 380)
        } detail: {
            if let groupID = selectedGroupID,
               let group = model.groups.first(where: { $0.groupId == groupID }) {
                GroupSummaryView(group: group)
            } else if let relationship = model.selectedRelationship {
                ConversationView(model: model, relationship: relationship)
            } else {
                ContentUnavailableView {
                    Label("No relationship selected", systemImage: "point.3.connected.trianglepath.dotted")
                } description: {
                    Text("Create a one-use encrypted rendezvous to establish a fresh relationship-scoped authority.")
                } actions: {
                    Button("New Relationship") { showingPairing = true }
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.syncAll()
                } label: {
                    Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(model.isWorking)

                Button {
                    showingPairing = true
                } label: {
                    Label("New Relationship", systemImage: "person.crop.circle.badge.plus")
                }
                .disabled(model.isPairing)

                Menu {
                    Button {
                        model.maintainRelationships()
                    } label: {
                        Label("Maintain Routes", systemImage: "wrench.and.screwdriver")
                    }
                    Button {
                        model.lockNow()
                    } label: {
                        Label("Lock Now", systemImage: "lock.fill")
                    }
                    Divider()
                    Button("Burn Local Persona", role: .destructive) {
                        showingBurnConfirmation = true
                    }
                } label: {
                    Label("Actions", systemImage: "ellipsis.circle")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            StatusBar(model: model)
        }
    }

    private var sidebar: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.activePersona?.displayName ?? "Local Persona")
                        .font(.headline)
                    Text("Local organization only")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            }

            Section("Relationships") {
                if model.relationships.isEmpty {
                    Text("No relationships yet")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.relationships) { relationship in
                    Button {
                        selectedGroupID = nil
                        model.selectedRelationshipID = relationship.id
                    } label: {
                        RelationshipRow(
                            relationship: relationship,
                            isSelected: model.selectedRelationshipID == relationship.id
                                && selectedGroupID == nil
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("relationship-\(relationship.id.uuidString.lowercased())")
                }
            }

            Section("Groups") {
                if model.groups.isEmpty {
                    Text("No groups in this persona")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.groups) { group in
                    Button {
                        selectedGroupID = group.groupId
                        model.selectedRelationshipID = nil
                    } label: {
                        HStack {
                            Image(systemName: "person.3.fill")
                                .foregroundStyle(.purple)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Group \(group.groupId.uuidString.prefix(8))")
                                Text("Epoch \(group.signedState.epoch) · \(group.signedState.members.count) members")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                        .background(
                            selectedGroupID == group.groupId
                                ? Color.accentColor.opacity(0.12)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("Noctyra")
    }
}

private struct RelationshipRow: View {
    let relationship: PairwiseRelationshipV2
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: relationship.localPolicy.consent == .blocked
                ? "person.crop.circle.badge.xmark"
                : "point.3.connected.trianglepath.dotted")
                .font(.title3)
                .foregroundStyle(relationship.localPolicy.consent == .blocked ? .red : .blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(relationship.peerIdentity.relationshipPseudonym)
                    .lineLimit(1)
                Text(relationship.events.last?.content.fallbackText ?? "Fresh pairwise relationship")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(7)
        .contentShape(Rectangle())
        .background(
            isSelected ? Color.accentColor.opacity(0.12) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
    }
}

private struct ConversationView: View {
    @ObservedObject var model: ClientViewModel
    let relationship: PairwiseRelationshipV2

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(relationship.peerIdentity.relationshipPseudonym)
                        .font(.title2.weight(.semibold))
                    Text("Relationship-scoped authority · \(relationship.localPolicy.consent.rawValue)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()
            Divider()

            if model.selectedEvents.isEmpty {
                ContentUnavailableView(
                    "No events yet",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Messages are typed immutable events delivered through opaque relationship routes.")
                )
                .frame(maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(model.selectedEvents) { event in
                                MessageEventRow(
                                    text: model.displayText(for: event),
                                    outgoing: model.isOutgoing(event),
                                    kind: event.kind,
                                    timestamp: event.createdAt
                                )
                                .id(event.id)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: model.selectedEvents.count) { _, _ in
                        if let eventID = model.selectedEvents.last?.id {
                            withAnimation { proxy.scrollTo(eventID, anchor: .bottom) }
                        }
                    }
                }
            }

            Divider()
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Message", text: $model.draftMessage, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...6)
                    .onSubmit { model.sendDraft() }
                    .disabled(relationship.localPolicy.consent != .accepted)
                Button {
                    model.sendDraft()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(
                    model.draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || model.isWorking
                        || relationship.localPolicy.consent != .accepted
                )
            }
            .padding()
        }
        .navigationTitle(relationship.peerIdentity.relationshipPseudonym)
    }
}

private struct MessageEventRow: View {
    let text: String
    let outgoing: Bool
    let kind: ConversationEventKind
    let timestamp: Date

    var body: some View {
        HStack {
            if outgoing { Spacer(minLength: 80) }
            VStack(alignment: .leading, spacing: 4) {
                if kind != .application {
                    Text(kind.rawValue.uppercased())
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                Text(text)
                    .textSelection(.enabled)
                Text(timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                outgoing ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.12),
                in: RoundedRectangle(cornerRadius: 14)
            )
            if !outgoing { Spacer(minLength: 80) }
        }
    }
}

private struct GroupSummaryView: View {
    let group: GroupRuntimeRecord

    var body: some View {
        Form {
            Section("Group-scoped runtime") {
                LabeledContent("Group", value: group.groupId.uuidString)
                LabeledContent("Epoch", value: String(group.signedState.epoch))
                LabeledContent("Members", value: String(group.signedState.members.count))
                LabeledContent("Events", value: String(group.events.count))
                LabeledContent("Protocol", value: group.signedState.profile.rawValue)
            }
            Section {
                Text("Each group credential and transport operation is confined to this group. Relationship authority is never reused here.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Group \(group.groupId.uuidString.prefix(8))")
    }
}

private struct StatusBar: View {
    @ObservedObject var model: ClientViewModel

    var body: some View {
        HStack(spacing: 8) {
            if model.isWorking { ProgressView().controlSize(.small) }
            Image(systemName: model.lastError == nil ? "checkmark.shield" : "exclamationmark.triangle")
                .foregroundStyle(model.lastError == nil ? Color.secondary : Color.orange)
            Text(model.lastError ?? model.statusMessage)
                .font(.caption)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
    }
}

private struct PairingView: View {
    @ObservedObject var model: ClientViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var mode = 0
    @State private var relay = "http://127.0.0.1:9340"
    @State private var pseudonym = "Noctweave peer"
    @State private var importedLink = ""

    var body: some View {
        NavigationStack {
            Form {
                Picker("Role", selection: $mode) {
                    Text("Create Invitation").tag(0)
                    Text("Accept Invitation").tag(1)
                }
                .pickerStyle(.segmented)

                Section("Relationship-local presentation") {
                    TextField("Pseudonym shown only to this peer", text: $pseudonym)
                    Text("A fresh post-quantum authority and endpoint are minted for this relationship. The local persona name is never shared.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if mode == 0 {
                    Section("Temporary rendezvous relay") {
                        TextField("Relay URL", text: $relay)
                            .textContentType(.URL)
                        Button("Create One-Use Invitation") {
                            model.startOfferingPairing(relayText: relay, pseudonym: pseudonym)
                        }
                        .disabled(model.isPairing)
                    }
                } else {
                    Section("One-use invitation") {
                        TextEditor(text: $importedLink)
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 130)
                        Button("Accept and Pair") {
                            model.startAcceptingPairing(link: importedLink, pseudonym: pseudonym)
                        }
                        .disabled(model.isPairing || importedLink.isEmpty)
                    }
                }

                if let pairingLink = model.pairingLink {
                    Section("Share privately") {
                        TextEditor(text: .constant(pairingLink))
                            .font(.system(.caption2, design: .monospaced))
                            .frame(minHeight: 150)
                        Button("Copy One-Use Invitation") {
                            copyToPasteboard(pairingLink)
                        }
                    }
                }

                if !model.pairingStatus.isEmpty {
                    Section("Status") {
                        HStack {
                            if model.isPairing { ProgressView().controlSize(.small) }
                            Text(model.pairingStatus)
                        }
                        if model.isPairing {
                            Button("Cancel Pairing", role: .destructive) {
                                model.cancelPairing()
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("New Relationship")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .disabled(model.isPairing)
                }
            }
        }
        .frame(minWidth: 560, minHeight: 540)
        .interactiveDismissDisabled(model.isPairing)
    }

    private func copyToPasteboard(_ value: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        #elseif os(iOS)
        UIPasteboard.general.string = value
        #endif
    }
}

private struct ClientLockView: View {
    @ObservedObject var model: ClientViewModel
    @State private var pin = ""

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 48))
                .foregroundStyle(.blue)
            Text("Noctyra is locked")
                .font(.title2.weight(.semibold))
            Text(model.appLockMessage)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

            switch model.appLockMode {
            case .off:
                Button("Unlock") { model.unlockWithPIN("") }
                    .onAppear { Task { await model.unlockWithBiometrics() } }
            case .biometrics:
                Button("Unlock with Biometrics") {
                    Task { await model.unlockWithBiometrics() }
                }
            case .pinOnly:
                pinEntry
            case .biometricsAndPin:
                if model.biometricStepPassed {
                    pinEntry
                } else {
                    Button("Verify Biometrics") {
                        Task { await model.unlockWithBiometrics() }
                    }
                }
            }

            if let error = model.lockError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(40)
    }

    private var pinEntry: some View {
        HStack {
            SecureField("Six-digit PIN", text: $pin)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
                .onSubmit { submitPIN() }
            Button("Unlock") { submitPIN() }
        }
    }

    private func submitPIN() {
        model.unlockWithPIN(pin)
        pin = ""
    }
}
