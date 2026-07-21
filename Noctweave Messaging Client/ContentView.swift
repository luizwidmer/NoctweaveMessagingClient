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
    @Environment(\.appTheme) private var theme
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @State private var showingPairing = false
    @State private var showingNewGroup = false
    @State private var showingGroupExchange = false
    @State private var showingBurnConfirmation = false
    @State private var compactRoute: CompactRoute?

    private enum CompactRoute: Hashable, Identifiable {
        case relationship(UUID)
        case group(UUID)

        var id: String {
            switch self {
            case .relationship(let id): "relationship-\(id.uuidString)"
            case .group(let id): "group-\(id.uuidString)"
            }
        }
    }

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
                        Text("Verifying the local store before revealing conversations.")
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

    private func launchSurface<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ZStack {
            GlassBackground()
            VStack(spacing: 14, content: content)
                .padding(28)
                .frame(maxWidth: 430)
                .uniformGlassCard(cornerRadius: 24, padding: 22)
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

    @ViewBuilder
    private var clientShell: some View {
        ZStack {
            GlassBackground()
            #if os(iOS)
            if horizontalSizeClass == .compact {
                compactShell
            } else {
                splitShell
            }
            #else
            splitShell
            #endif
        }
        .tint(theme.accent)
    }

    private var splitShell: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 260, ideal: 310, max: 380)
        } detail: {
            selectedDetail
                .padding(12)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            sharedToolbar
        }
        #if os(macOS)
        .overlay(alignment: .bottomTrailing) {
            StatusBar(model: model)
        }
        #else
        .safeAreaInset(edge: .bottom) {
            StatusBar(model: model)
        }
        #endif
    }

    private var compactShell: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    compactIdentityCard

                    compactSectionHeader("Relationships", icon: "point.3.connected.trianglepath.dotted")
                    if model.relationships.isEmpty {
                        VStack(alignment: .center, spacing: 12) {
                            Text("Start a private conversation")
                                .font(.headline)
                            Text("A new relationship creates fresh post-quantum authority used only with that peer.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Button("New Relationship") { showingPairing = true }
                                .glassButton(prominent: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .multilineTextAlignment(.center)
                        .uniformGlassCard(cornerRadius: 20, padding: 18)
                    } else {
                        ForEach(model.relationships) { relationship in
                            Button {
                                model.selectedGroupID = nil
                                model.selectedRelationshipID = relationship.id
                                compactRoute = .relationship(relationship.id)
                            } label: {
                                RelationshipRow(relationship: relationship, isSelected: false)
                            }
                            .buttonStyle(.plain)
                            .uniformGlassCard(cornerRadius: 18, padding: 6)
                        }
                    }

                    compactSectionHeader("Groups", icon: "person.3.fill")
                    if model.groups.isEmpty {
                        Text("No groups in this persona")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .multilineTextAlignment(.center)
                            .uniformGlassCard(cornerRadius: 18, padding: 16)
                    } else {
                        ForEach(model.groups) { group in
                            Button {
                                model.selectedGroupID = group.groupId
                                model.selectedRelationshipID = nil
                                compactRoute = .group(group.groupId)
                            } label: {
                                GroupRow(group: group, isSelected: false)
                            }
                            .buttonStyle(.plain)
                            .uniformGlassCard(cornerRadius: 18, padding: 6)
                        }
                    }

                    if !model.pendingGroupAdmissions.isEmpty {
                        compactSectionHeader("Pending", icon: "person.crop.circle.badge.clock")
                        ForEach(model.pendingGroupAdmissions) { admission in
                            Button {
                                showingGroupExchange = true
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "envelope.badge.shield.half.filled")
                                        .font(.title3)
                                        .foregroundStyle(.orange)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("Group admission")
                                            .font(.headline)
                                        Text(String(admission.groupID.uuidString.prefix(8)))
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .buttonStyle(.plain)
                            .uniformGlassCard(cornerRadius: 18, padding: 14)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 96)
            }
            .scrollIndicators(.hidden)
            .navigationTitle("Messages")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            #endif
            .toolbar { sharedToolbar }
            .safeAreaInset(edge: .bottom) {
                StatusBar(model: model)
            }
            .navigationDestination(item: $compactRoute) { route in
                compactDestination(route)
            }
        }
    }

    private var compactIdentityCard: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(theme.accent.opacity(0.18))
                Image(systemName: "diamond.fill")
                    .font(.title2)
                    .foregroundStyle(theme.accent)
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 3) {
                Text(model.activePersona?.displayName ?? "Local Persona")
                    .font(.headline)
                    .lineLimit(1)
                Text("\(model.relationships.count) relationships · \(model.groups.count) groups")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button { model.syncAll() } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .glassCircleButton(diameter: 40)
            .disabled(model.isWorking)
            .accessibilityLabel("Sync")
        }
        .uniformGlassCard(cornerRadius: 22, padding: 16)
    }

    private func compactSectionHeader(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.headline)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
    }

    @ViewBuilder
    private func compactDestination(_ route: CompactRoute) -> some View {
        switch route {
        case .relationship(let id):
            if let relationship = model.relationships.first(where: { $0.id == id }) {
                ConversationView(model: model, relationship: relationship)
            } else {
                ContentUnavailableView("Relationship unavailable", systemImage: "person.crop.circle.badge.exclamationmark")
            }
        case .group(let id):
            if let group = model.groups.first(where: { $0.groupId == id }) {
                GroupConversationView(model: model, group: group)
            } else {
                ContentUnavailableView("Group unavailable", systemImage: "person.3.fill")
            }
        }
    }

    @ViewBuilder
    private var selectedDetail: some View {
        if let group = model.selectedGroup {
            GroupConversationView(model: model, group: group)
        } else if let relationship = model.selectedRelationship {
            ConversationView(model: model, relationship: relationship)
        } else {
            VStack(spacing: 14) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(theme.accent)
                Text("Your private conversations")
                    .font(.title2.weight(.bold))
                Text("Choose a relationship or create a one-use encrypted invitation.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("New Relationship") { showingPairing = true }
                    .glassButton(prominent: true)
            }
            .padding(30)
            .uniformGlassCard(cornerRadius: 26, padding: 24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ToolbarContentBuilder
    private var sharedToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.syncAll() } label: {
                Label("Sync", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(model.isWorking)

            Menu {
                Button { showingPairing = true } label: {
                    Label("New Relationship", systemImage: "person.crop.circle.badge.plus")
                }
                Button { showingNewGroup = true } label: {
                    Label("New Group", systemImage: "person.3.sequence.fill")
                }
            } label: {
                Label("Create", systemImage: "plus")
            }

            Menu {
                Button { model.maintainAllTransport() } label: {
                    Label("Maintain Routes", systemImage: "wrench.and.screwdriver")
                }
                Button { showingGroupExchange = true } label: {
                    Label("Group Admission Exchange", systemImage: "person.3.sequence")
                }
                Button { model.lockNow() } label: {
                    Label("Lock Now", systemImage: "lock.fill")
                }
                Divider()
                Button("Burn Local Persona", role: .destructive) {
                    showingBurnConfirmation = true
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }

    private var sidebar: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                #if os(macOS)
                sidebarBrand
                #endif

                compactIdentityCard

                compactSectionHeader("Relationships", icon: "point.3.connected.trianglepath.dotted")
                if model.relationships.isEmpty {
                    Text("No relationships yet")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
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
                    .uniformGlassCard(cornerRadius: 16, padding: 4)
                    .accessibilityIdentifier("relationship-\(relationship.id.uuidString.lowercased())")
                }

                compactSectionHeader("Groups", icon: "person.3.fill")
                if model.groups.isEmpty {
                    Text("No groups in this persona")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                }
                ForEach(model.groups) { group in
                    Button {
                        model.selectedGroupID = group.groupId
                        model.selectedRelationshipID = nil
                    } label: {
                        GroupRow(group: group, isSelected: model.selectedGroupID == group.groupId)
                    }
                    .buttonStyle(.plain)
                    .uniformGlassCard(cornerRadius: 16, padding: 4)
                }

                if !model.pendingGroupAdmissions.isEmpty {
                    compactSectionHeader("Pending", icon: "person.crop.circle.badge.clock")
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
                        .uniformGlassCard(cornerRadius: 16, padding: 6)
                    }
                }
            }
            .padding(12)
            #if os(macOS)
            .padding(.top, 32)
            #endif
            .padding(.bottom, 64)
        }
        .navigationTitle("")
    }

    #if os(macOS)
    private var sidebarBrand: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(theme.accent.opacity(0.18))
                Image(systemName: "diamond.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(theme.accent)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 1) {
                Text("Noctweave")
                    .font(.headline.weight(.semibold))
                Text("Private messaging")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }
    #endif
}

private struct RelationshipRow: View {
    @Environment(\.appTheme) private var theme
    let relationship: PairwiseRelationshipV2
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: relationship.localPolicy.consent == .blocked
                ? "person.crop.circle.badge.xmark"
                : "point.3.connected.trianglepath.dotted")
                .font(.title3)
                .foregroundStyle(relationship.localPolicy.consent == .blocked ? Color.red : theme.accent)
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
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .background(
            isSelected ? theme.accent.opacity(0.16) : Color.clear,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }
}

private struct GroupRow: View {
    @Environment(\.appTheme) private var theme
    let group: GroupRuntimeRecord
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.3.fill")
                .font(.title3)
                .foregroundStyle(theme.glowSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Group \(group.groupId.uuidString.prefix(8))")
                    .lineLimit(1)
                Text("Epoch \(group.signedState.epoch) · \(group.signedState.members.count) members")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(7)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .background(
            isSelected ? theme.accent.opacity(0.16) : Color.clear,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }
}

private struct ConversationView: View {
    @ObservedObject var model: ClientViewModel
    @Environment(\.appTheme) private var theme
    let relationship: PairwiseRelationshipV2

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(theme.accent.opacity(0.16))
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .foregroundStyle(theme.accent)
                }
                .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(relationship.peerIdentity.relationshipPseudonym)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    Text("Private relationship · \(relationship.localPolicy.consent.rawValue)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .uniformGlassCard(cornerRadius: 20, padding: 14)
            .padding(.horizontal, 12)
            .padding(.top, 10)

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
                        .padding(.horizontal, 14)
                        .padding(.vertical, 16)
                    }
                    .onChange(of: model.selectedEvents.count) { _, _ in
                        if let eventID = model.selectedEvents.last?.id {
                            withAnimation { proxy.scrollTo(eventID, anchor: .bottom) }
                        }
                    }
                }
            }

            HStack(alignment: .bottom, spacing: 10) {
                TextField("Message", text: $model.draftMessage, axis: .vertical)
                    .lineLimit(1...4)
                    .noctweaveInputField(cornerRadius: 17)
                    .onSubmit { model.sendDraft() }
                    .disabled(relationship.localPolicy.consent != .accepted)
                Button {
                    model.sendDraft()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.headline.weight(.bold))
                }
                .glassCircleButton(prominent: true, diameter: 44)
                .disabled(
                    model.draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || model.isWorking
                        || relationship.localPolicy.consent != .accepted
                )
            }
            .uniformGlassCard(cornerRadius: 22, padding: 10)
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .navigationTitle(relationship.peerIdentity.relationshipPseudonym)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

private struct MessageEventRow: View {
    let text: String
    let outgoing: Bool
    let kind: ConversationEventKind
    let timestamp: Date

    var body: some View {
        HStack(alignment: .bottom) {
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
                in: UnevenRoundedRectangle(
                    topLeadingRadius: 16,
                    bottomLeadingRadius: outgoing ? 16 : 5,
                    bottomTrailingRadius: outgoing ? 5 : 16,
                    topTrailingRadius: 16,
                    style: .continuous
                )
            )
        }
        .frame(maxWidth: .infinity, alignment: outgoing ? .trailing : .leading)
    }
}

private struct GroupConversationView: View {
    @ObservedObject var model: ClientViewModel
    @Environment(\.appTheme) private var theme
    let group: GroupRuntimeRecord

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(theme.glowSecondary.opacity(0.16))
                        Image(systemName: "person.3.fill")
                            .foregroundStyle(theme.glowSecondary)
                    }
                    .frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Group \(group.groupId.uuidString.prefix(8))")
                            .font(.title3.weight(.semibold))
                        Text("Private group credentials")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu {
                        Button("Maintain Routes") { model.maintainSelectedGroup() }
                        Divider()
                        Label("\(group.inboundTransport.localRoutes.count) receive routes", systemImage: "arrow.down")
                        Label("\(group.peerRouteCache.entries.count) peer route sets", systemImage: "arrow.left.arrow.right")
                        Label("\(group.outboundTransportOperations.count) queued operations", systemImage: "tray.and.arrow.up")
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .glassCircleButton(diameter: 40)
                    .disabled(model.isWorking)
                }
                HStack(spacing: 8) {
                    GroupMetricChip(text: "Epoch \(group.signedState.epoch)", icon: "arrow.triangle.2.circlepath")
                    GroupMetricChip(text: "\(group.signedState.members.count) members", icon: "person.3")
                    Spacer(minLength: 0)
                }
                if let status = model.groupMaintenanceStatus[group.groupId] {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Label("Experimental group profile", systemImage: "exclamationmark.shield")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .accessibilityHint(group.signedState.profile.rawValue)
            }
            .uniformGlassCard(cornerRadius: 20, padding: 14)
            .padding(.horizontal, 12)
            .padding(.top, 10)

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
                        .padding(.horizontal, 14)
                        .padding(.vertical, 16)
                    }
                    .onChange(of: model.selectedGroupEvents.count) { _, _ in
                        if let eventID = model.selectedGroupEvents.last?.id {
                            withAnimation { proxy.scrollTo(eventID, anchor: .bottom) }
                        }
                    }
                }
            }

            HStack(alignment: .bottom, spacing: 10) {
                TextField("Group message", text: $model.groupDraftMessage, axis: .vertical)
                    .lineLimit(1...4)
                    .noctweaveInputField(cornerRadius: 17)
                    .onSubmit { model.sendGroupDraft() }
                Button {
                    model.sendGroupDraft()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.headline.weight(.bold))
                }
                .glassCircleButton(prominent: true, diameter: 44)
                .disabled(
                    model.groupDraftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || model.isWorking
                )
            }
            .uniformGlassCard(cornerRadius: 22, padding: 10)
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .navigationTitle("Group \(group.groupId.uuidString.prefix(8))")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

private struct GroupMetricChip: View {
    let text: String
    let icon: String

    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(.thinMaterial, in: Capsule())
    }
}

private struct GroupMessageEventRow: View {
    let text: String
    let outgoing: Bool
    let kind: GroupConversationEventKindV2
    let timestamp: Date

    var body: some View {
        HStack(alignment: .bottom) {
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
                outgoing ? Color.noctweaveCoral.opacity(0.22) : Color.secondary.opacity(0.12),
                in: UnevenRoundedRectangle(
                    topLeadingRadius: 16,
                    bottomLeadingRadius: outgoing ? 16 : 5,
                    bottomTrailingRadius: outgoing ? 5 : 16,
                    topTrailingRadius: 16,
                    style: .continuous
                )
            )
        }
        .frame(maxWidth: .infinity, alignment: outgoing ? .trailing : .leading)
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
            .scrollContentBackground(.hidden)
            .navigationTitle("New Group")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 450)
        #endif
        .noctweaveSheetBackground()
        .noctweaveSheetPresentation()
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
            .scrollContentBackground(.hidden)
            .navigationTitle("Group Admission Exchange")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .disabled(model.isWorking)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 680, minHeight: 680)
        #endif
        .noctweaveSheetBackground()
        .noctweaveSheetPresentation()
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
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        #if os(macOS)
        .frame(maxWidth: 360, alignment: .trailing)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 0.7)
        }
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        .padding(14)
        #else
        .frame(maxWidth: .infinity, alignment: .center)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
            Capsule()
                .stroke(Color.white.opacity(0.12), lineWidth: 0.7)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        #endif
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
            .scrollContentBackground(.hidden)
            .navigationTitle("New Relationship")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .disabled(model.isPairing)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: mode == 0 && model.pairingLink == nil ? 430 : 540)
        #endif
        .noctweaveSheetBackground()
        .noctweaveSheetPresentation()
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
                Text(model.appLockMessage)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)

                switch model.appLockMode {
                case .off:
                    Button("Unlock") { model.unlockWithPIN("") }
                        .glassButton(prominent: true)
                        .onAppear { Task { await model.unlockWithBiometrics() } }
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
            .frame(maxWidth: 460)
            .uniformGlassCard(cornerRadius: 26, padding: 22)
            .padding(24)
        }
        .ignoresSafeArea()
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
