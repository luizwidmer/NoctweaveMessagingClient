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
    @State private var showingNewGroup = false
    @State private var showingGroupExchange = false
    @State private var showingBurnConfirmation = false

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
            if phase == .active {
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
        .sheet(isPresented: $showingPairing) {
            PairingView(model: model)
        }
        .sheet(isPresented: $showingNewGroup) {
            NewGroupView(model: model)
        }
        .sheet(isPresented: $showingGroupExchange) {
            GroupExchangeView(model: model)
        }
        .confirmationDialog(
            "Burn this local persona?",
            isPresented: $showingBurnConfirmation,
            titleVisibility: .visible
        ) {
            Button("Burn Persona", role: .destructive) {
                model.selectedGroupID = nil
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
            if let group = model.selectedGroup {
                GroupConversationView(model: model, group: group)
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

                Button {
                    showingNewGroup = true
                } label: {
                    Label("New Group", systemImage: "person.3.sequence.fill")
                }
                .disabled(model.isWorking)

                Menu {
                    Button {
                        model.maintainAllTransport()
                    } label: {
                        Label("Maintain Routes", systemImage: "wrench.and.screwdriver")
                    }
                    Button {
                        showingGroupExchange = true
                    } label: {
                        Label("Group Admission Exchange", systemImage: "person.3.sequence")
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
                        model.selectedGroupID = nil
                        model.selectedRelationshipID = relationship.id
                    } label: {
                        RelationshipRow(
                            relationship: relationship,
                            isSelected: model.selectedRelationshipID == relationship.id
                                && model.selectedGroupID == nil
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
                        model.selectedGroupID = group.groupId
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
                            model.selectedGroupID == group.groupId
                                ? Color.accentColor.opacity(0.12)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                    }
                    .buttonStyle(.plain)
                }

                if !model.pendingGroupAdmissions.isEmpty {
                    ForEach(model.pendingGroupAdmissions) { admission in
                        Button {
                            showingGroupExchange = true
                        } label: {
                            HStack {
                                Image(systemName: "person.crop.circle.badge.clock")
                                    .foregroundStyle(.orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Pending join \(admission.groupID.uuidString.prefix(8))")
                                    Text("Admission \(admission.id.uuidString.prefix(8))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 3)
                        }
                        .buttonStyle(.plain)
                    }
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

private struct GroupConversationView: View {
    @ObservedObject var model: ClientViewModel
    let group: GroupRuntimeRecord

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Group \(group.groupId.uuidString.prefix(8))")
                            .font(.title2.weight(.semibold))
                        Text("Group-scoped credentials only · no persona or relationship authority")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Maintain Routes") { model.maintainSelectedGroup() }
                        .disabled(model.isWorking)
                }
                HStack(spacing: 16) {
                    Label("Epoch \(group.signedState.epoch)", systemImage: "arrow.triangle.2.circlepath")
                    Label("\(group.signedState.members.count) members", systemImage: "person.3")
                    Label(
                        "\(group.inboundTransport.localRoutes.count) receive routes",
                        systemImage: "point.3.filled.connected.trianglepath.dotted"
                    )
                    Label(
                        "\(group.peerRouteCache.entries.count) peer route sets",
                        systemImage: "arrow.left.arrow.right"
                    )
                    Label(
                        "\(group.outboundTransportOperations.count) queued transport ops",
                        systemImage: "tray.and.arrow.up"
                    )
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Label("EXPERIMENTAL · UNAUDITED", systemImage: "exclamationmark.shield")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.orange)
                    Text(group.signedState.profile.rawValue)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Spacer()
                    if let status = model.groupMaintenanceStatus[group.groupId] {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
            Divider()

            if model.selectedGroupEvents.isEmpty {
                ContentUnavailableView(
                    "No group events yet",
                    systemImage: "person.3.fill",
                    description: Text("Messages are immutable events encrypted under this experimental group runtime.")
                )
                .frame(maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(model.selectedGroupEvents) { event in
                                GroupMessageEventRow(
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
                    .onChange(of: model.selectedGroupEvents.count) { _, _ in
                        if let eventID = model.selectedGroupEvents.last?.id {
                            withAnimation { proxy.scrollTo(eventID, anchor: .bottom) }
                        }
                    }
                }
            }

            Divider()
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Group message", text: $model.groupDraftMessage, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...6)
                    .onSubmit { model.sendGroupDraft() }
                Button {
                    model.sendGroupDraft()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(
                    model.groupDraftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || model.isWorking
                )
            }
            .padding()
        }
        .navigationTitle("Group \(group.groupId.uuidString.prefix(8))")
    }
}

private struct GroupMessageEventRow: View {
    let text: String
    let outgoing: Bool
    let kind: GroupConversationEventKindV2
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
                Text(text).textSelection(.enabled)
                Text(timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                outgoing ? Color.purple.opacity(0.22) : Color.secondary.opacity(0.12),
                in: RoundedRectangle(cornerRadius: 14)
            )
            if !outgoing { Spacer(minLength: 80) }
        }
    }
}

private struct NewGroupView: View {
    @ObservedObject var model: ClientViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var groupID = UUID().uuidString
    @State private var relay = "http://127.0.0.1:9340"

    var body: some View {
        NavigationStack {
            Form {
                Section("Explicit group scope") {
                    TextField("Group UUID", text: $groupID)
                        .font(.system(.body, design: .monospaced))
                    Button("Generate Fresh UUID") { groupID = UUID().uuidString }
                    Text("The UUID identifies this group only. Creation mints fresh post-quantum group credential material and does not reuse persona or relationship authority.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Initial opaque receive route") {
                    TextField("Relay URL", text: $relay)
                        .textContentType(.URL)
                }
                Section {
                    Button("Create Experimental Group") {
                        model.createGroup(groupIDText: groupID, relayText: relay)
                        dismiss()
                    }
                    .disabled(model.isWorking || groupID.isEmpty || relay.isEmpty)
                    Label("The current group cryptographic profile is experimental and unaudited.", systemImage: "exclamationmark.shield")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("New Group")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .frame(minWidth: 560, minHeight: 450)
    }
}

private struct GroupExchangeView: View {
    @ObservedObject var model: ClientViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var mode = 0
    @State private var groupID = UUID().uuidString
    @State private var relay = "http://127.0.0.1:9340"
    @State private var importedLink = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(
                        "Copy and paste these artifacts only through an already authenticated, encrypted channel.",
                        systemImage: "lock.shield"
                    )
                    .foregroundStyle(.orange)
                    Text("The exchange creates authority only inside the selected group. It does not authorize a device, link personas, or establish a global identity.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Picker("Step", selection: $mode) {
                    Text("Request Join").tag(0)
                    Text("Admit Member").tag(1)
                    Text("Accept Welcome").tag(2)
                }
                .pickerStyle(.segmented)

                if mode == 0 {
                    Section("Prospective member") {
                        TextField("Existing group UUID", text: $groupID)
                            .font(.system(.body, design: .monospaced))
                        TextField("Relay URL for your group-only route", text: $relay)
                            .textContentType(.URL)
                        Button("Prepare Saved One-Use Request") {
                            model.prepareGroupJoinRequest(
                                groupIDText: groupID,
                                relayText: relay
                            )
                        }
                        .disabled(model.isWorking || groupID.isEmpty || relay.isEmpty)
                    }
                } else {
                    Section(mode == 1 ? "Member admission request" : "Owner welcome package") {
                        TextEditor(text: $importedLink)
                            .font(.system(.caption2, design: .monospaced))
                            .frame(minHeight: 150)
                        if mode == 1 {
                            Button("Verify and Prepare Welcome") {
                                model.prepareGroupMemberResponse(requestLink: importedLink)
                            }
                            .disabled(model.isWorking || importedLink.isEmpty)
                        } else {
                            Button("Verify and Consume Welcome") {
                                model.acceptGroupMemberResponse(responseLink: importedLink)
                            }
                            .disabled(model.isWorking || importedLink.isEmpty)
                        }
                    }
                }

                if !model.pendingGroupAdmissions.isEmpty {
                    Section("Saved one-use admissions") {
                        ForEach(model.pendingGroupAdmissions) { admission in
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Group \(admission.groupID.uuidString)")
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                Text("Admission \(admission.id.uuidString)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                HStack {
                                    Text(admission.advertisedRouteSet == nil
                                        ? "Route registration pending"
                                        : "Request ready")
                                        .font(.caption)
                                    Spacer()
                                    Button("Resume / Show Request") {
                                        mode = 0
                                        model.resumeGroupJoinRequest(admissionID: admission.id)
                                    }
                                    .disabled(model.isWorking)
                                }
                            }
                        }
                    }
                }

                if let link = model.groupExchangeLink {
                    Section("Authenticated-channel artifact") {
                        TextEditor(text: .constant(link))
                            .font(.system(.caption2, design: .monospaced))
                            .frame(minHeight: 180)
                        HStack {
                            Button("Copy Artifact") { copyToPasteboard(link) }
                            Button("Clear") { model.clearGroupExchangeLink() }
                        }
                    }
                }

                if !model.groupExchangeStatus.isEmpty {
                    Section("Status") {
                        HStack(alignment: .top) {
                            if model.isWorking { ProgressView().controlSize(.small) }
                            Text(model.groupExchangeStatus)
                        }
                    }
                }

                if let error = model.lastError {
                    Section("Last error") {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Label("Group crypto profile: experimental and unaudited", systemImage: "exclamationmark.shield")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Group Admission Exchange")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .disabled(model.isWorking)
                }
            }
        }
        .frame(minWidth: 680, minHeight: 680)
        .interactiveDismissDisabled(model.isWorking)
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
