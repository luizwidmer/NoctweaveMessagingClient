import Foundation
import NoctweaveCore
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

private enum ClientDestination: String, CaseIterable, Identifiable {
    case chats
    case contacts
    case code
    case files
    case relays
    case identity
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chats: "Chats"
        case .contacts: "Contact Book"
        case .code: "My Code"
        case .files: "Files"
        case .relays: "Relays"
        case .identity: "Identity Management"
        case .settings: "Settings"
        }
    }

    var icon: String {
        switch self {
        case .chats: "bubble.left.and.bubble.right"
        case .contacts: "book.closed"
        case .code: "qrcode"
        case .files: "rectangle.stack"
        case .relays: "antenna.radiowaves.left.and.right"
        case .identity: "person.badge.shield.checkmark"
        case .settings: "gearshape"
        }
    }

    static func initialFromLaunchArguments() -> ClientDestination {
        guard let value = ProcessInfo.processInfo.arguments
            .first(where: { $0.hasPrefix("START_TAB=") })?
            .split(separator: "=", maxSplits: 1)
            .last else {
            return .chats
        }
        switch value.lowercased() {
        case "chats": return .chats
        case "contacts", "contactbook": return .contacts
        case "code", "mycode": return .code
        case "files", "attachments": return .files
        case "relays": return .relays
        case "identity": return .identity
        case "settings": return .settings
        default: return .chats
        }
    }
}

private enum CompactConversationRoute: Hashable {
    case relationship(UUID)
    case group(UUID)
}

struct MatureClientShell: View {
    @ObservedObject var model: ClientViewModel
    @ObservedObject private var pairingInbox = PairingInvitationInbox.shared
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #elseif os(macOS)
    @EnvironmentObject private var windowController: AppWindowController
    #endif

    @AppStorage("noctweave.appearance.palette") private var paletteRaw = ThemePalette.noir.rawValue
    @State private var preferredRelay = ""
    @AppStorage("noctweave.groupNames") private var groupNamesJSON = "{}"
    @State private var destination: ClientDestination = .chats
    @State private var compactRoute: CompactConversationRoute?
    @State private var showingPairing = false
    @State private var showingNewGroup = false
    @State private var showingGroupAdmission = false
    @State private var showingBurnConfirmation = false
    @State private var showingRelayEditor = false
    @State private var identityDetailsPersonaID: UUID?

    init(model: ClientViewModel) {
        self.model = model
        _destination = State(initialValue: ClientDestination.initialFromLaunchArguments())
    }

    private var selectedPalette: ThemePalette {
        ThemePalette(rawValue: paletteRaw) ?? .noir
    }

    private var theme: ThemeStyle { ThemeStyle(palette: selectedPalette) }

    var body: some View {
        protectedShell
        .environment(\.appTheme, theme)
        .preferredColorScheme(theme.preferredColorScheme)
        .tint(theme.accent)
        .sheet(isPresented: $showingPairing) {
            MaturePairingSheet(model: model, preferredRelay: $preferredRelay)
        }
        .sheet(isPresented: $showingNewGroup) {
            MatureNewGroupSheet(
                model: model,
                preferredRelay: $preferredRelay,
                onNameChosen: saveGroupName
            )
        }
        .sheet(isPresented: $showingGroupAdmission) {
            MatureGroupAdmissionSheet(model: model, preferredRelay: $preferredRelay)
        }
        .sheet(isPresented: $showingRelayEditor) {
            MatureRelayEditor(model: model, preferredRelay: $preferredRelay)
        }
        .sheet(
            isPresented: Binding(
                get: { identityDetailsPersonaID != nil },
                set: { if !$0 { identityDetailsPersonaID = nil } }
            )
        ) {
            if let personaID = identityDetailsPersonaID {
                MatureIdentityDetails(
                    model: model,
                    personaID: personaID,
                    onBurn: {
                        identityDetailsPersonaID = nil
                        showingBurnConfirmation = true
                    }
                )
            }
        }
        .confirmationDialog(
            "Burn this identity?",
            isPresented: $showingBurnConfirmation,
            titleVisibility: .visible
        ) {
            Button("Burn Identity", role: .destructive) {
                compactRoute = nil
                model.selectedRelationshipID = nil
                model.selectedGroupID = nil
                model.burnPersona(replacementName: "New Identity")
                destination = .identity
            }
        } message: {
            Text("All contacts and groups inside this identity are replaced without a continuity link. This cannot be undone.")
        }
        .onAppear {
            syncPreferredRelayFromModel()
            if pairingInbox.hasPendingItem { showingPairing = true }
            #if os(macOS)
            windowController.setBlockWindowCapture(model.privacySettings.macBlockWindowCapture)
            #endif
        }
        .onChange(of: pairingInbox.revision) { _, _ in
            showingPairing = true
        }
        .onChange(of: model.state?.activePersonaID) { _, _ in
            syncPreferredRelayFromModel()
        }
        .onChange(of: model.state?.relayPreferences) { _, _ in
            syncPreferredRelayFromModel()
        }
        #if os(macOS)
        .onChange(of: model.privacySettings.macBlockWindowCapture) { _, blocked in
            windowController.setBlockWindowCapture(blocked)
        }
        #endif
        .overlay {
            if shouldHideSensitiveContent {
                MaturePrivacyShield()
                    .transition(.opacity)
                    .zIndex(100)
            }
        }
    }

    @ViewBuilder
    private var protectedShell: some View {
        #if os(iOS)
        SecureContainer {
            ZStack {
                GlassBackground()
                platformShell
            }
        }
        #else
        ZStack {
            GlassBackground()
            platformShell
        }
        #endif
    }

    private var shouldHideSensitiveContent: Bool {
        guard model.privacySettings.hideSensitiveWhenUnfocused else { return false }
        #if os(macOS)
        return !windowController.isActiveForControls
        #else
        return scenePhase != .active
        #endif
    }

    private func syncPreferredRelayFromModel() {
        preferredRelay = model.activePersonaRelayPreference
            .map { RelayEditorView.endpointAddress($0.endpoint) } ?? ""
    }

    @ViewBuilder
    private var platformShell: some View {
        #if os(macOS)
        macShell
        #else
        GeometryReader { proxy in
            if horizontalSizeClass == .regular && proxy.size.width >= 700 {
                tabletShell
            } else {
                phoneShell
            }
        }
        #endif
    }

    #if os(macOS)
    private var macShell: some View {
        HStack(spacing: 0) {
            macSidebar
                .frame(width: 292)
            Rectangle()
                .fill(Color.white.opacity(0.07))
                .frame(width: 0.5)
            destinationView(compact: false)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var macSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Image("NoctweaveIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Noctweave")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                    Text("Post-quantum chat")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 50)
            .padding(.horizontal, 18)
            .padding(.bottom, 18)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    sidebarSection("Chats") {
                        if model.relationships.isEmpty && model.groups.isEmpty {
                            Text("No conversations yet")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)
                        }
                        ForEach(model.relationships) { relationship in
                            MatureSidebarConversationRow(
                                title: relationship.peerIdentity.relationshipPseudonym,
                                subtitle: lastPreview(for: relationship),
                                icon: "person.crop.circle",
                                isSelected: destination == .chats
                                    && model.selectedRelationshipID == relationship.id
                                    && model.selectedGroupID == nil
                            ) {
                                select(relationship: relationship)
                            }
                        }
                        ForEach(model.groups) { group in
                            MatureSidebarConversationRow(
                                title: groupName(for: group),
                                subtitle: "\(group.signedState.members.count) members",
                                icon: "person.3.fill",
                                isSelected: destination == .chats
                                    && model.selectedGroupID == group.groupId
                            ) {
                                select(group: group)
                            }
                        }
                    }

                    sidebarSection("Library") {
                        sidebarDestination(.contacts)
                        sidebarDestination(.code)
                        sidebarDestination(.files)
                        sidebarDestination(.relays)
                        sidebarDestination(.identity)
                        sidebarDestination(.settings)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 18)
            }
            .scrollIndicators(.hidden)

            HStack(spacing: 8) {
                Circle()
                    .fill(model.lastError == nil ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Text(model.isWorking ? "Synchronizing…" : "Ready")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button { model.syncAll() } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.plain)
                .disabled(model.isWorking)
                .help("Sync now")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(.ultraThinMaterial)
        }
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private func sidebarSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.bottom, 2)
            content()
        }
    }

    private func sidebarDestination(_ item: ClientDestination) -> some View {
        Button {
            compactRoute = nil
            destination = item
        } label: {
            HStack(spacing: 11) {
                Image(systemName: item.icon)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 22)
                Text(item.title)
                    .font(.subheadline.weight(.medium))
                Spacer()
            }
            .foregroundStyle(destination == item ? Color.primary : Color.secondary)
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(
                destination == item ? theme.accent.opacity(0.16) : Color.clear,
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
    }
    #endif

    #if os(iOS)
    private var phoneShell: some View {
        VStack(spacing: 0) {
            destinationView(compact: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            MatureBottomBar(selection: $destination) {
                compactRoute = nil
            }
        }
    }

    private var tabletShell: some View {
        HStack(spacing: 0) {
            MatureSideRail(selection: $destination) {
                compactRoute = nil
            }
            Rectangle()
                .fill(Color.white.opacity(0.07))
                .frame(width: 0.5)
            destinationView(compact: false)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    #endif

    @ViewBuilder
    private func destinationView(compact: Bool) -> some View {
        switch destination {
        case .chats:
            if let compactRoute {
                switch compactRoute {
                case .relationship(let id):
                    if let relationship = model.relationships.first(where: { $0.id == id }) {
                        MatureConversationView(
                            model: model,
                            relationship: relationship,
                            compact: compact,
                            onBack: { self.compactRoute = nil },
                            onOpenFiles: { destination = .files }
                        )
                    } else {
                        chatHome(compact: compact)
                    }
                case .group(let id):
                    if let group = model.groups.first(where: { $0.groupId == id }) {
                        MatureGroupConversationView(
                            model: model,
                            group: group,
                            title: groupName(for: group),
                            compact: compact,
                            onBack: { self.compactRoute = nil },
                            onAdmission: { showingGroupAdmission = true },
                            onRename: { saveGroupName($0, group.groupId) }
                        )
                    } else {
                        chatHome(compact: compact)
                    }
                }
            } else if !compact, let relationship = model.selectedRelationship {
                MatureConversationView(
                    model: model,
                    relationship: relationship,
                    compact: false,
                    onBack: nil,
                    onOpenFiles: { destination = .files }
                )
            } else if !compact, let group = model.selectedGroup {
                MatureGroupConversationView(
                    model: model,
                    group: group,
                    title: groupName(for: group),
                    compact: false,
                    onBack: nil,
                    onAdmission: { showingGroupAdmission = true },
                    onRename: { saveGroupName($0, group.groupId) }
                )
            } else {
                chatHome(compact: compact)
            }
        case .contacts:
            MatureContactsView(
                model: model,
                onAdd: { showingPairing = true },
                onOpen: { relationship in
                    select(relationship: relationship)
                    if compact { compactRoute = .relationship(relationship.id) }
                }
            )
        case .code:
            MatureMyCodeView(
                model: model,
                onCreate: { showingPairing = true }
            )
        case .files:
            MatureFilesView(model: model)
        case .relays:
            MatureRelaysView(
                model: model,
                onEdit: { showingRelayEditor = true }
            )
        case .identity:
            MatureIdentityView(
                model: model,
                onDetails: { identityDetailsPersonaID = $0 },
                onMaintain: { model.maintainAllTransport() }
            )
        case .settings:
            MatureSettingsView(
                model: model,
                selectedPalette: $paletteRaw,
                onLock: { model.lockNow() }
            )
        }
    }

    private func chatHome(compact: Bool) -> some View {
        MatureChatsHome(
            model: model,
            compact: compact,
            groupName: groupName,
            onRelationship: { relationship in
                select(relationship: relationship)
                compactRoute = .relationship(relationship.id)
            },
            onGroup: { group in
                select(group: group)
                compactRoute = .group(group.groupId)
            },
            onAddContact: { showingPairing = true },
            onAddGroup: { showingNewGroup = true },
            onFiles: { destination = .files }
        )
    }

    private func select(relationship: PairwiseRelationshipV2) {
        destination = .chats
        model.selectedGroupID = nil
        model.selectedRelationshipID = relationship.id
    }

    private func select(group: GroupRuntimeRecord) {
        destination = .chats
        model.selectedRelationshipID = nil
        model.selectedGroupID = group.groupId
    }

    private func lastPreview(for relationship: PairwiseRelationshipV2) -> String {
        guard let event = relationship.events.last else { return "Private conversation" }
        if event.content.type == .text,
           let text = String(data: event.content.payload, encoding: .utf8) {
            return text.replacingOccurrences(of: "\n", with: " ")
        }
        if event.content.type == .attachment { return "Shared a file" }
        return "Secure activity"
    }

    private func groupName(for group: GroupRuntimeRecord) -> String {
        let names = (try? JSONDecoder().decode([String: String].self, from: Data(groupNamesJSON.utf8))) ?? [:]
        return names[group.groupId.uuidString.lowercased()] ?? "Private Group"
    }

    private func saveGroupName(_ name: String, _ id: UUID) {
        var names = (try? JSONDecoder().decode([String: String].self, from: Data(groupNamesJSON.utf8))) ?? [:]
        names[id.uuidString.lowercased()] = name
        if let data = try? JSONEncoder().encode(names),
           let value = String(data: data, encoding: .utf8) {
            groupNamesJSON = value
        }
    }
}

private struct MatureSidebarConversationRow: View {
    @Environment(\.appTheme) private var theme
    let title: String
    let subtitle: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(theme.accent.opacity(isSelected ? 0.22 : 0.10))
                    Image(systemName: icon)
                        .foregroundStyle(isSelected ? theme.accent : Color.secondary)
                }
                .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                isSelected ? theme.accent.opacity(0.14) : Color.clear,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

struct MatureTopBar<Trailing: View>: View {
    let title: String
    let subtitle: String
    let backAction: (() -> Void)?
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            if let backAction {
                Button(action: backAction) {
                    Image(systemName: "chevron.left")
                }
                .glassCircleButton(diameter: 38)
                .accessibilityLabel("Back")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 0.5)
        }
    }
}

private struct MatureChatsHome: View {
    @ObservedObject var model: ClientViewModel
    let compact: Bool
    let groupName: (GroupRuntimeRecord) -> String
    let onRelationship: (PairwiseRelationshipV2) -> Void
    let onGroup: (GroupRuntimeRecord) -> Void
    let onAddContact: () -> Void
    let onAddGroup: () -> Void
    let onFiles: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            MatureTopBar(title: "Chats", subtitle: "Private conversations and groups", backAction: nil) {
                Button(action: onFiles) { Image(systemName: "rectangle.stack") }
                    .glassCircleButton(diameter: 38)
                Menu {
                    Button("Add Contact", systemImage: "person.crop.circle.badge.plus", action: onAddContact)
                    Button("Create Group", systemImage: "person.3.fill", action: onAddGroup)
                } label: {
                    Image(systemName: "plus")
                }
                .glassCircleButton(prominent: true, diameter: 38)
            }

            if model.relationships.isEmpty && model.groups.isEmpty {
                VStack(spacing: 16) {
                    Image("NoctweaveIcon")
                        .resizable()
                        .scaledToFit()
                        .frame(width: compact ? 96 : 128, height: compact ? 96 : 128)
                    Text("Welcome to Noctweave")
                        .font(.system(size: compact ? 26 : 32, weight: .bold, design: .rounded))
                    Text("Start with a contact invitation. Every conversation receives its own post-quantum identity and encryption state.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 470)
                    HStack(spacing: 10) {
                        Button("Add Contact", action: onAddContact)
                            .glassButton(prominent: true)
                        Button("Create Group", action: onAddGroup)
                            .glassButton()
                    }
                }
                .padding(30)
                .frame(maxWidth: 620)
                .uniformGlassCard(cornerRadius: 28, padding: 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(model.relationships) { relationship in
                            MatureConversationListRow(
                                title: relationship.peerIdentity.relationshipPseudonym,
                                preview: preview(relationship),
                                timestamp: relationship.events.last?.createdAt ?? relationship.createdAt,
                                icon: "person.crop.circle"
                            ) { onRelationship(relationship) }
                        }
                        ForEach(model.groups) { group in
                            MatureConversationListRow(
                                title: groupName(group),
                                preview: "\(group.signedState.members.count) members",
                                timestamp: group.events.last?.createdAt ?? Date.distantPast,
                                icon: "person.3.fill"
                            ) { onGroup(group) }
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: 780)
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private func preview(_ relationship: PairwiseRelationshipV2) -> String {
        guard let event = relationship.events.last else { return "No messages yet" }
        if event.content.type == .text,
           let value = String(data: event.content.payload, encoding: .utf8) {
            return value.replacingOccurrences(of: "\n", with: " ")
        }
        return event.content.type == .attachment ? "Shared a file" : "Secure activity"
    }
}

private struct MatureConversationListRow: View {
    @Environment(\.appTheme) private var theme
    let title: String
    let preview: String
    let timestamp: Date
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 13) {
                ZStack {
                    Circle().fill(theme.accent.opacity(0.14))
                    Image(systemName: icon).foregroundStyle(theme.accent)
                }
                .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(title).font(.headline).lineLimit(1)
                        Spacer()
                        if timestamp != .distantPast {
                            Text(timestamp, style: .time)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Text(preview)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .uniformGlassCard(cornerRadius: 19, padding: 0, minHeight: 76)
    }
}

private struct MatureConversationView: View {
    @ObservedObject var model: ClientViewModel
    @Environment(\.appTheme) private var theme
    let relationship: PairwiseRelationshipV2
    let compact: Bool
    let onBack: (() -> Void)?
    let onOpenFiles: () -> Void
    @State private var showingFileImporter = false
    @State private var showingVoiceRecorder = false
    @State private var attachmentPreview: MatureAttachmentPreview?
    @State private var attachmentNotice: String?
    #if os(iOS)
    @State private var showingSecureCamera = false
    #endif

    var body: some View {
        VStack(spacing: 0) {
            MatureTopBar(
                title: relationship.peerIdentity.relationshipPseudonym,
                subtitle: relationship.localPolicy.consent == .accepted ? "Secure conversation" : "Approval pending",
                backAction: onBack
            ) {
                Button { model.syncAll() } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .glassCircleButton(diameter: 38)
                .disabled(model.isWorking)
            }

            ZStack {
                chatWallpaper
                if model.selectedEvents.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "lock.shield")
                            .font(.system(size: 30))
                            .foregroundStyle(theme.accent)
                        Text("Messages stay between you")
                            .font(.headline)
                        Text("Send the first message when you are ready.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 8) {
                                ForEach(model.selectedEvents) { event in
                                    MatureMessageBubble(
                                        model: model,
                                        event: event,
                                        outgoing: model.isOutgoing(
                                            event,
                                            relationshipID: relationship.id
                                        ),
                                        onOpen: openAttachment,
                                        onDownload: downloadAndOpen
                                    )
                                    .id(event.id)
                                }
                            }
                            .padding(.horizontal, compact ? 12 : 20)
                            .padding(.vertical, 18)
                        }
                        .scrollDismissesKeyboard(.interactively)
                        .onChange(of: model.selectedEvents.count) { _, _ in
                            if let id = model.selectedEvents.last?.id {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    proxy.scrollTo(id, anchor: .bottom)
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(alignment: .bottom, spacing: 9) {
                Menu {
                    Button("Choose File", systemImage: "doc.badge.plus") {
                        showingFileImporter = true
                    }
                    #if os(iOS)
                    Button("Secure Camera", systemImage: "camera.fill") {
                        showingSecureCamera = true
                    }
                    #endif
                    Button("Voice Message", systemImage: "waveform") {
                        showingVoiceRecorder = true
                    }
                    Divider()
                    Button("Open File Gallery", systemImage: "rectangle.stack") {
                        onOpenFiles()
                    }
                } label: {
                    Image(systemName: "paperclip")
                }
                .glassCircleButton(diameter: 42)
                TextField("Message", text: $model.draftMessage, axis: .vertical)
                    .lineLimit(1...2)
                    .autocorrectionDisabled(model.privacySettings.secureTypingEnabled)
                    .noctweaveInputField(cornerRadius: 18)
                    .onSubmit { model.sendDraft() }
                    .disabled(
                        model.isWorking
                            || relationship.localPolicy.consent != .accepted
                    )
                Button { model.sendDraft() } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 15, weight: .semibold))
                }
                .glassCircleButton(prominent: true, diameter: 42)
                .disabled(
                    model.draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || model.isWorking
                        || relationship.localPolicy.consent != .accepted
                )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
        }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                model.sendDirectAttachment(from: url, relationshipID: relationship.id)
            case .failure(let error):
                attachmentNotice = error.localizedDescription
            }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showingSecureCamera) {
            SecureCameraCaptureView(
                onCapture: { data in
                    model.sendSanitizedDirectAttachment(
                        data: data,
                        fileName: nil,
                        mimeType: "image/jpeg",
                        relationshipID: relationship.id
                    )
                    showingSecureCamera = false
                },
                onCancel: { showingSecureCamera = false }
            )
        }
        #endif
        .sheet(isPresented: $showingVoiceRecorder) {
            VoiceRecorderSheetView(
                onRecorded: { data, fileName, mimeType in
                    model.sendSanitizedDirectAttachment(
                        data: data,
                        fileName: fileName,
                        mimeType: mimeType,
                        relationshipID: relationship.id
                    )
                    showingVoiceRecorder = false
                },
                onError: { message in attachmentNotice = message },
                onCancel: { showingVoiceRecorder = false }
            )
        }
        .sheet(item: $attachmentPreview) { preview in
            MatureAttachmentViewer(preview: preview)
        }
        .alert(
            "Attachment unavailable",
            isPresented: Binding(
                get: { attachmentNotice != nil },
                set: { if !$0 { attachmentNotice = nil } }
            )
        ) {
            Button("OK") { attachmentNotice = nil }
        } message: {
            Text(attachmentNotice ?? "The attachment could not be opened.")
        }
    }

    private func openAttachment(_ descriptor: AttachmentDescriptor) {
        do {
            attachmentPreview = MatureAttachmentPreview(
                descriptor: descriptor,
                data: try model.decryptedAttachmentData(descriptor.id)
            )
        } catch {
            attachmentNotice = "Download this protected attachment before opening it."
        }
    }

    private func downloadAndOpen(_ event: ConversationEvent, _ descriptor: AttachmentDescriptor) {
        Task {
            guard await model.downloadAttachment(
                eventID: event.id,
                relationshipID: relationship.id
            ) != nil else {
                attachmentNotice = "The relay could not provide this attachment. It may have expired."
                return
            }
            openAttachment(descriptor)
        }
    }

    @ViewBuilder
    private var chatWallpaper: some View {
        GlassBackground()
        #if os(iOS)
        Image(compact ? "ChatDoodlesPhoneDark" : "ChatDoodlesTabletDark")
            .resizable(resizingMode: .tile)
            .opacity(0.10)
            .allowsHitTesting(false)
        #else
        Image("ChatDoodlesTabletDark")
            .resizable(resizingMode: .tile)
            .opacity(0.07)
            .allowsHitTesting(false)
        #endif
    }
}

private struct MatureMessageBubble: View {
    @ObservedObject var model: ClientViewModel
    let event: ConversationEvent
    let outgoing: Bool
    let onOpen: (AttachmentDescriptor) -> Void
    let onDownload: (ConversationEvent, AttachmentDescriptor) -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if outgoing { Spacer(minLength: 54) }
            VStack(alignment: .leading, spacing: 5) {
                if event.content.type == .attachment,
                   let descriptor = try? NoctweaveCoder.decode(AttachmentDescriptor.self, from: event.content.payload) {
                    HStack(spacing: 10) {
                        Image(systemName: attachmentIcon(descriptor.mimeType))
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(descriptor.fileName ?? "Protected file")
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(descriptor.byteCount), countStyle: .file))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        if model.isAttachmentAvailable(descriptor.id) {
                            Button {
                                onOpen(descriptor)
                            } label: {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Open attachment")
                        } else if !outgoing {
                            Button {
                                onDownload(event, descriptor)
                            } label: {
                                Image(systemName: "arrow.down.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Download attachment")
                        }
                    }
                } else {
                    Text(displayText)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(event.createdAt, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                outgoing ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.16),
                in: UnevenRoundedRectangle(
                    topLeadingRadius: 17,
                    bottomLeadingRadius: outgoing ? 17 : 5,
                    bottomTrailingRadius: outgoing ? 5 : 17,
                    topTrailingRadius: 17,
                    style: .continuous
                )
            )
            .frame(maxWidth: 520, alignment: outgoing ? .trailing : .leading)
            if !outgoing { Spacer(minLength: 54) }
        }
        .frame(maxWidth: .infinity)
    }

    private var displayText: String {
        if event.content.type == .text,
           let value = String(data: event.content.payload, encoding: .utf8) {
            return value
        }
        return event.content.fallbackText ?? "Secure message"
    }

    private func attachmentIcon(_ mime: String) -> String {
        if mime.hasPrefix("image/") { return "photo" }
        if mime.hasPrefix("audio/") { return "waveform" }
        if mime == "application/pdf" { return "doc.richtext" }
        return "doc"
    }
}

private struct MatureAttachmentPreview: Identifiable {
    let descriptor: AttachmentDescriptor
    let data: Data

    var id: UUID { descriptor.id }
}

private struct MatureAttachmentViewer: View {
    @Environment(\.dismiss) private var dismiss
    let preview: MatureAttachmentPreview

    var body: some View {
        NavigationStack {
            Group {
                if preview.descriptor.mimeType.hasPrefix("image/") {
                    imageView
                } else if preview.descriptor.mimeType == "application/pdf" {
                    InMemoryPDFView(data: preview.data)
                } else if preview.descriptor.mimeType.hasPrefix("text/"),
                          let text = String(data: preview.data, encoding: .utf8) {
                    ScrollView {
                        Text(text)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(18)
                    }
                } else {
                    ContentUnavailableView {
                        Label("Stored securely", systemImage: "lock.doc")
                    } description: {
                        Text("This sanitized file is encrypted locally. Noctweave does not hand unknown content to an automatic previewer.")
                    }
                }
            }
            .navigationTitle(attachmentTitle)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 720, minHeight: 560)
        #endif
        .noctweaveSheetPresentation()
    }

    @ViewBuilder
    private var imageView: some View {
        #if os(macOS)
        if let image = NSImage(data: preview.data) {
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(16)
            }
        } else {
            invalidPreview
        }
        #else
        if let image = UIImage(data: preview.data) {
            ScrollView([.horizontal, .vertical]) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(16)
            }
        } else {
            invalidPreview
        }
        #endif
    }

    private var invalidPreview: some View {
        ContentUnavailableView(
            "Preview unavailable",
            systemImage: "exclamationmark.triangle",
            description: Text("The sanitized attachment could not be rendered.")
        )
    }

    private var attachmentTitle: String {
        if preview.descriptor.mimeType.hasPrefix("image/") { return "Image" }
        if preview.descriptor.mimeType == "application/pdf" { return "PDF" }
        if preview.descriptor.mimeType.hasPrefix("text/") { return "Text Document" }
        if preview.descriptor.mimeType.hasPrefix("audio/") { return "Audio" }
        return "Protected File"
    }
}

#if os(macOS)
private struct InMemoryPDFView: NSViewRepresentable {
    let data: Data

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = PDFDocument(data: data)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        view.document = PDFDocument(data: data)
    }
}
#else
private struct InMemoryPDFView: UIViewRepresentable {
    let data: Data

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = PDFDocument(data: data)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        view.document = PDFDocument(data: data)
    }
}
#endif

private struct MatureGroupConversationView: View {
    @ObservedObject var model: ClientViewModel
    @Environment(\.appTheme) private var theme
    let group: GroupRuntimeRecord
    let title: String
    let compact: Bool
    let onBack: (() -> Void)?
    let onAdmission: () -> Void
    let onRename: (String) -> Void
    @State private var showingSettings = false

    private var activeMemberCount: Int {
        group.signedState.activeMembers.count
    }

    private var localRole: GroupRole {
        group.signedState.activeMembers.first {
            $0.id == group.localCredential.memberHandle
        }?.role ?? .member
    }

    var body: some View {
        VStack(spacing: 0) {
            MatureTopBar(
                title: title,
                subtitle: "\(activeMemberCount) members · Private group",
                backAction: onBack
            ) {
                Menu {
                    Button("Group Settings", systemImage: "slider.horizontal.3") {
                        showingSettings = true
                    }
                    if group.signedState.permissions.allows(.addMember, for: localRole) {
                        Button("Invite Member", systemImage: "person.badge.plus", action: onAdmission)
                    }
                    Button("Refresh Group", systemImage: "arrow.triangle.2.circlepath") {
                        model.maintainSelectedGroup()
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .glassCircleButton(diameter: 38)
            }

            ZStack {
                GlassBackground()
                Image(compact ? "ChatDoodlesPhoneDark" : "ChatDoodlesTabletDark")
                    .resizable(resizingMode: .tile)
                    .opacity(0.08)
                    .allowsHitTesting(false)
                if model.selectedGroupEvents.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "person.3.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(theme.accent)
                        Text("The group is ready")
                            .font(.headline)
                        Text("Messages use credentials created only for this group.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(model.selectedGroupEvents) { event in
                                MatureGroupBubble(
                                    text: model.displayText(for: event),
                                    outgoing: model.isOutgoing(event),
                                    timestamp: event.createdAt
                                )
                            }
                        }
                        .padding(compact ? 12 : 20)
                    }
                    .scrollDismissesKeyboard(.interactively)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(alignment: .bottom, spacing: 9) {
                TextField("Message the group", text: $model.groupDraftMessage, axis: .vertical)
                    .lineLimit(1...2)
                    .autocorrectionDisabled(model.privacySettings.secureTypingEnabled)
                    .noctweaveInputField(cornerRadius: 18)
                    .onSubmit { model.sendGroupDraft() }
                Button { model.sendGroupDraft() } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 15, weight: .semibold))
                }
                .glassCircleButton(prominent: true, diameter: 42)
                .disabled(model.groupDraftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isWorking)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
        }
        .sheet(isPresented: $showingSettings) {
            MatureGroupSettingsSheet(
                model: model,
                group: group,
                title: title,
                onRename: onRename,
                onInvite: onAdmission
            )
        }
    }
}

private struct MatureGroupSettingsSheet: View {
    @ObservedObject var model: ClientViewModel
    let group: GroupRuntimeRecord
    let title: String
    let onRename: (String) -> Void
    let onInvite: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var editedTitle: String
    @State private var memberToRemove: GroupMemberV2?
    @State private var showingLeaveConfirmation = false
    @State private var showingExtinguishConfirmation = false

    init(
        model: ClientViewModel,
        group: GroupRuntimeRecord,
        title: String,
        onRename: @escaping (String) -> Void,
        onInvite: @escaping () -> Void
    ) {
        self.model = model
        self.group = group
        self.title = title
        self.onRename = onRename
        self.onInvite = onInvite
        _editedTitle = State(initialValue: title)
    }

    private var activeMembers: [GroupMemberV2] {
        group.signedState.activeMembers.sorted {
            if $0.role != $1.role { return roleRank($0.role) > roleRank($1.role) }
            return $0.id.rawValue < $1.id.rawValue
        }
    }

    private var localMember: GroupMemberV2? {
        activeMembers.first { $0.id == group.localCredential.memberHandle }
    }

    private var localRole: GroupRole { localMember?.role ?? .member }
    private var isOwner: Bool { localRole == .owner }
    private var canInvite: Bool {
        group.signedState.permissions.allows(.addMember, for: localRole)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    SheetHero(
                        icon: "person.3.sequence.fill",
                        title: title,
                        subtitle: "Group-only identities · \(activeMembers.count) active members"
                    )

                    VStack(alignment: .leading, spacing: 12) {
                        Label("Local Presentation", systemImage: "textformat")
                            .font(.headline)
                        TextField("Group name", text: $editedTitle)
                            .noctweaveInputField()
                        Text("This label is stored only on this device. It does not expose or rename anyone's private identity.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Save Name") {
                            onRename(editedTitle.trimmingCharacters(in: .whitespacesAndNewlines))
                        }
                        .glassButton(compact: true)
                        .disabled(editedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .uniformGlassCard(cornerRadius: 20, padding: 16)

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label("Members and Roles", systemImage: "person.3")
                                .font(.headline)
                            Spacer()
                            if canInvite {
                                Button("Invite", systemImage: "person.badge.plus") {
                                    dismiss()
                                    onInvite()
                                }
                                .glassButton(compact: true)
                            }
                        }
                        ForEach(activeMembers) { member in
                            HStack(spacing: 12) {
                                Image(systemName: member.id == group.localCredential.memberHandle
                                    ? "person.crop.circle.badge.checkmark"
                                    : "person.crop.circle")
                                    .font(.title3)
                                    .foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(member.id == group.localCredential.memberHandle
                                        ? "You"
                                        : "Member \(member.id.rawValue.prefix(8))")
                                        .font(.body.weight(.semibold))
                                    Text(member.role.rawValue.capitalized)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if mayRemove(member) {
                                    Button("Remove", role: .destructive) {
                                        memberToRemove = member
                                    }
                                    .buttonStyle(.borderless)
                                    .disabled(model.isWorking)
                                }
                            }
                            .padding(.vertical, 5)
                            if member.id != activeMembers.last?.id {
                                Divider().opacity(0.35)
                            }
                        }
                    }
                    .uniformGlassCard(cornerRadius: 20, padding: 16)

                    VStack(alignment: .leading, spacing: 10) {
                        Label(isOwner ? "Extinguish Group" : "Leave Group", systemImage: "exclamationmark.triangle")
                            .font(.headline)
                        Text(isOwner
                            ? "Publish a signed tombstone to every member and permanently close this group."
                            : "Publish a signed self-removal, retire your group-only identity, and remove the conversation locally.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Button(isOwner ? "Extinguish Group" : "Leave Group", role: .destructive) {
                            if isOwner {
                                showingExtinguishConfirmation = true
                            } else {
                                showingLeaveConfirmation = true
                            }
                        }
                        .glassButton(compact: true)
                        .disabled(model.isWorking)
                    }
                    .uniformGlassCard(cornerRadius: 20, padding: 16)
                }
                .padding(18)
            }
            .navigationTitle("Group Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 580, minHeight: 620)
        #endif
        .noctweaveSheetBackground()
        .noctweaveSheetPresentation()
        .confirmationDialog(
            "Remove this group member?",
            isPresented: Binding(
                get: { memberToRemove != nil },
                set: { if !$0 { memberToRemove = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove Member", role: .destructive) {
                guard let memberToRemove else { return }
                model.removeGroupMember(
                    groupID: group.groupId,
                    memberHandle: memberToRemove.id
                )
                self.memberToRemove = nil
                dismiss()
            }
        } message: {
            Text("Their group-only credential will be retired. This does not reveal or delete any identity outside this group.")
        }
        .confirmationDialog(
            "Leave this group?",
            isPresented: $showingLeaveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Leave Group", role: .destructive) {
                model.leaveGroup(groupID: group.groupId)
                dismiss()
            }
        } message: {
            Text("Your group-only identity will be retired after the signed departure reaches the other members.")
        }
        .confirmationDialog(
            "Extinguish this group?",
            isPresented: $showingExtinguishConfirmation,
            titleVisibility: .visible
        ) {
            Button("Extinguish Group", role: .destructive) {
                model.extinguishGroup(groupID: group.groupId)
                dismiss()
            }
        } message: {
            Text("Every member will receive a signed terminal tombstone. This cannot be undone.")
        }
    }

    private func mayRemove(_ member: GroupMemberV2) -> Bool {
        guard member.id != group.localCredential.memberHandle,
              group.signedState.permissions.allows(.removeMember, for: localRole) else {
            return false
        }
        switch localRole {
        case .owner:
            return true
        case .admin:
            return member.role == .member
        case .member:
            return false
        }
    }

    private func roleRank(_ role: GroupRole) -> Int {
        switch role {
        case .owner: 2
        case .admin: 1
        case .member: 0
        }
    }
}

private struct MatureGroupBubble: View {
    let text: String
    let outgoing: Bool
    let timestamp: Date

    var body: some View {
        HStack {
            if outgoing { Spacer(minLength: 54) }
            VStack(alignment: .leading, spacing: 5) {
                Text(text).textSelection(.enabled)
                Text(timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                outgoing ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.16),
                in: RoundedRectangle(cornerRadius: 17, style: .continuous)
            )
            .frame(maxWidth: 520)
            if !outgoing { Spacer(minLength: 54) }
        }
    }
}

private struct MatureContactsView: View {
    @ObservedObject var model: ClientViewModel
    let onAdd: () -> Void
    let onOpen: (PairwiseRelationshipV2) -> Void
    @State private var contactToDelete: PairwiseRelationshipV2?

    var body: some View {
        VStack(spacing: 0) {
            MatureTopBar(title: "Contact Book", subtitle: "People you trust", backAction: nil) {
                Button(action: onAdd) { Image(systemName: "person.badge.plus") }
                    .glassCircleButton(prominent: true, diameter: 38)
            }
            ScrollView {
                LazyVStack(spacing: 10) {
                    if model.relationships.isEmpty {
                        MatureEmptyCard(
                            icon: "person.2.slash",
                            title: "No contacts yet",
                            message: "Add someone with a one-use encrypted invitation.",
                            buttonTitle: "Add Contact",
                            action: onAdd
                        )
                    } else {
                        ForEach(model.relationships) { relationship in
                            HStack(spacing: 8) {
                                Button { onOpen(relationship) } label: {
                                    HStack(spacing: 14) {
                                        Image(systemName: "person.crop.circle.fill")
                                            .font(.system(size: 34))
                                            .foregroundStyle(.tint)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(relationship.peerIdentity.relationshipPseudonym)
                                                .font(.headline)
                                            Label("Post-quantum relationship", systemImage: "checkmark.shield")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                Menu {
                                    Button("Open Chat") { onOpen(relationship) }
                                    Button("Delete Contact", role: .destructive) {
                                        contactToDelete = relationship
                                    }
                                } label: {
                                    Image(systemName: "ellipsis")
                                }
                                .glassCircleButton(diameter: 36)
                                .accessibilityLabel("Contact Actions")
                            }
                            .padding(16)
                            .uniformGlassCard(cornerRadius: 20, padding: 0, minHeight: 82)
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
        }
        .confirmationDialog(
            "Delete this contact?",
            isPresented: Binding(
                get: { contactToDelete != nil },
                set: { if !$0 { contactToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let contactToDelete {
                Button("Delete Contact", role: .destructive) {
                    model.deleteContact(relationshipID: contactToDelete.id)
                    self.contactToDelete = nil
                }
            }
        } message: {
            Text("This removes the relationship and local chat history. Pair again to communicate in the future.")
        }
    }
}

private struct MatureMyCodeView: View {
    @ObservedObject var model: ClientViewModel
    let onCreate: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            MatureTopBar(title: "My Code", subtitle: "Share a one-use invitation", backAction: nil) {
                Button(action: onCreate) { Image(systemName: "plus") }
                    .glassCircleButton(prominent: true, diameter: 38)
            }
            ScrollView {
                VStack(spacing: 18) {
                    if let link = model.pairingLink {
                        let frames = QRCodeTransfer.encodeFrames(link, maxChunkSize: 600)
                        VStack(spacing: 14) {
                            AnimatedQRCodeView(frames: frames, size: 290, interval: 0.65)
                                .padding(16)
                                .background(Color.white, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                            Text(frames.count > 1 ? "Animated code · scan every frame" : "Scan to accept this invitation")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Copy Invitation") { copy(link) }
                                .glassButton(prominent: true)
                        }
                        .uniformGlassCard(cornerRadius: 26, padding: 20)
                    } else {
                        VStack(spacing: 15) {
                            Image("NoctweaveIcon")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 132, height: 132)
                            Text("Nothing permanent to expose")
                                .font(.title2.weight(.bold))
                            Text("Noctweave creates a fresh invitation for each person. Your identity is never published as a global code.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 440)
                            Button("Create One-Use Code", action: onCreate)
                                .glassButton(prominent: true)
                        }
                        .uniformGlassCard(cornerRadius: 26, padding: 26)
                    }
                }
                .padding(18)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func copy(_ value: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        #else
        UIPasteboard.general.string = value
        #endif
    }
}

private struct MatureFilesView: View {
    @ObservedObject var model: ClientViewModel
    @State private var attachmentPreview: MatureAttachmentPreview?
    @State private var attachmentNotice: String?

    private struct FileRecord: Identifiable {
        let descriptor: AttachmentDescriptor
        let contact: String
        let date: Date
        let relationshipID: UUID
        let eventID: UUID
        let outgoing: Bool

        var id: UUID { descriptor.id }
    }

    private var files: [FileRecord] {
        model.relationships.flatMap { relationship in
            relationship.events.compactMap { event in
                guard event.content.type == .attachment,
                      let descriptor = try? NoctweaveCoder.decode(AttachmentDescriptor.self, from: event.content.payload) else {
                    return nil
                }
                return FileRecord(
                    descriptor: descriptor,
                    contact: relationship.peerIdentity.relationshipPseudonym,
                    date: event.createdAt,
                    relationshipID: relationship.id,
                    eventID: event.id,
                    outgoing: model.isOutgoing(event, relationshipID: relationship.id)
                )
            }
        }
        .sorted { $0.date > $1.date }
    }

    var body: some View {
        VStack(spacing: 0) {
            MatureTopBar(title: "Files", subtitle: "Media and documents shared in chats", backAction: nil) {
                EmptyView()
            }
            ScrollView {
                if files.isEmpty {
                    MatureEmptyCard(
                        icon: "rectangle.stack.badge.person.crop",
                        title: "No shared files",
                        message: "Files received through your conversations will appear here.",
                        buttonTitle: nil,
                        action: nil
                    )
                    .padding(16)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
                        ForEach(files) { file in
                            Button {
                                openOrDownload(file)
                            } label: {
                                VStack(alignment: .leading, spacing: 10) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                                            .fill(.thinMaterial)
                                        Image(systemName: fileIcon(file.descriptor.mimeType))
                                            .font(.system(size: 32))
                                            .foregroundStyle(.tint)
                                        VStack {
                                            Spacer()
                                            HStack {
                                                Spacer()
                                                Image(systemName: model.isAttachmentAvailable(file.id)
                                                    ? "arrow.up.left.and.arrow.down.right"
                                                    : "arrow.down.circle")
                                                    .font(.caption.weight(.semibold))
                                                    .padding(8)
                                            }
                                        }
                                    }
                                    .frame(height: 96)
                                    Text(file.descriptor.mimeType)
                                        .font(.subheadline.weight(.semibold))
                                        .lineLimit(1)
                                    Text("\(file.contact) · \(file.date.formatted(date: .abbreviated, time: .omitted))")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .uniformGlassCard(cornerRadius: 20, padding: 12)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .sheet(item: $attachmentPreview) { preview in
            MatureAttachmentViewer(preview: preview)
        }
        .alert(
            "Attachment unavailable",
            isPresented: Binding(
                get: { attachmentNotice != nil },
                set: { if !$0 { attachmentNotice = nil } }
            )
        ) {
            Button("OK") { attachmentNotice = nil }
        } message: {
            Text(attachmentNotice ?? "The attachment could not be opened.")
        }
    }

    private func openOrDownload(_ file: FileRecord) {
        if model.isAttachmentAvailable(file.id) {
            do {
                attachmentPreview = MatureAttachmentPreview(
                    descriptor: file.descriptor,
                    data: try model.decryptedAttachmentData(file.id)
                )
            } catch {
                attachmentNotice = "The encrypted local copy failed integrity verification."
            }
            return
        }
        guard !file.outgoing else {
            attachmentNotice = "This outgoing attachment is still queued locally."
            return
        }
        Task {
            guard await model.downloadAttachment(
                eventID: file.eventID,
                relationshipID: file.relationshipID
            ) != nil else {
                attachmentNotice = "The relay could not provide this attachment. It may have expired."
                return
            }
            openOrDownload(file)
        }
    }

    private func fileIcon(_ mime: String) -> String {
        if mime.hasPrefix("image/") { return "photo" }
        if mime.hasPrefix("audio/") { return "waveform" }
        if mime == "application/pdf" { return "doc.richtext" }
        return "doc"
    }
}

private struct MatureRelaysView: View {
    @ObservedObject var model: ClientViewModel
    let onEdit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            MatureTopBar(
                title: "Relays",
                subtitle: "\(preferences.count) saved · relationship routes remain independent",
                backAction: nil
            ) {
                Button(action: onEdit) { Image(systemName: "plus") }
                    .glassCircleButton(diameter: 38)
                    .accessibilityLabel("Add Relay")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if preferences.isEmpty {
                        MatureEmptyCard(
                            icon: "antenna.radiowaves.left.and.right.slash",
                            title: "Choose a relay",
                            message: "Add a relay and pass a live protocol check before creating remote invitations or groups.",
                            buttonTitle: "Add Relay",
                            action: onEdit
                        )
                    } else {
                        Text("Saved Relays").font(.headline)
                        ForEach(preferences) { preference in
                            HStack(spacing: 14) {
                                Image(systemName: preference.endpoint.useTLS ? "lock.shield.fill" : "network")
                                    .font(.title3)
                                    .foregroundStyle(preference.endpoint.useTLS ? Color.green : Color.orange)
                                    .frame(width: 46, height: 46)
                                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack(spacing: 8) {
                                        Text(preference.name)
                                            .font(.headline)
                                            .lineLimit(1)
                                        if preference.id == preferredID {
                                            Text("PREFERRED")
                                                .font(.caption2.weight(.bold))
                                                .foregroundStyle(.green)
                                                .padding(.horizontal, 7)
                                                .padding(.vertical, 3)
                                                .background(Color.green.opacity(0.13), in: Capsule())
                                        }
                                    }
                                    Text(RelayEditorView.endpointAddress(preference.endpoint))
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    Label(
                                        preference.endpoint.useTLS ? "Encrypted transport" : "Plain transport",
                                        systemImage: preference.endpoint.useTLS ? "lock.fill" : "exclamationmark.triangle"
                                    )
                                    .font(.caption2)
                                    .foregroundStyle(preference.endpoint.useTLS ? Color.green : Color.orange)
                                }
                                Spacer(minLength: 8)
                                Menu {
                                    if preference.id != preferredID,
                                       let personaID = model.activePersona?.id {
                                        Button("Use for This Persona") {
                                            model.selectRelayPreference(preference.id, forPersonaID: personaID)
                                        }
                                    }
                                    Button("Check Now") {
                                        model.validateAndSaveRelay(
                                            relayText: RelayEditorView.endpointAddress(preference.endpoint),
                                            password: preference.accessPassword ?? "",
                                            preferredForPersonaID: preference.id == preferredID
                                                ? model.activePersona?.id
                                                : nil
                                        )
                                    }
                                    Button("Remove", role: .destructive) {
                                        model.deleteRelayPreference(preference.id)
                                    }
                                } label: {
                                    Image(systemName: "ellipsis")
                                }
                                .glassCircleButton(diameter: 36)
                            }
                            .uniformGlassCard(cornerRadius: 22, padding: 16)
                        }

                        Button {
                            onEdit()
                        } label: {
                            Label("Add Relay", systemImage: "plus")
                        }
                        .glassButton(prominent: true)
                    }

                    relayCheckStatus

                    Text("Relay privacy")
                        .font(.headline)
                        .padding(.top, 6)
                    Text("Relays store and route encrypted envelopes. They never receive plaintext or a reusable global identity. Changing this preference affects new relationships; existing contacts retain their own routes.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .uniformGlassCard(cornerRadius: 20, padding: 16)
                }
                .padding(16)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var preferences: [LocalRelayPreference] {
        model.state?.relayPreferences ?? []
    }

    private var preferredID: UUID? {
        guard let state = model.state else { return nil }
        return state.preferredRelayPreferenceID(forPersonaID: state.activePersonaID)
    }

    @ViewBuilder
    private var relayCheckStatus: some View {
        switch model.relayManagementCheckState {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Checking relay capabilities…")
            }
            .font(.subheadline)
            .uniformGlassCard(cornerRadius: 18, padding: 14)
        case .ready(let readiness):
            Label(
                "\(readiness.relayInfo.relayName ?? readiness.endpoint.host) is reachable and compatible.",
                systemImage: "checkmark.circle.fill"
            )
            .font(.subheadline)
            .foregroundStyle(.green)
            .uniformGlassCard(cornerRadius: 18, padding: 14)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .foregroundStyle(.orange)
                .uniformGlassCard(cornerRadius: 18, padding: 14)
        }
    }
}

private struct MatureIdentityView: View {
    @ObservedObject var model: ClientViewModel
    let onDetails: (UUID) -> Void
    let onMaintain: () -> Void
    @State private var showingCreatePersona = false
    @State private var newPersonaName = ""

    var body: some View {
        VStack(spacing: 0) {
            MatureTopBar(
                title: "Identity Management",
                subtitle: "Local personas with independent contacts and relay choices",
                backAction: nil
            ) {
                Button { showingCreatePersona = true } label: {
                    Image(systemName: "plus")
                }
                .glassCircleButton(diameter: 38)
                .accessibilityLabel("Create Persona")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Identity Book").font(.headline)
                        Spacer()
                        Text("\(personas.count) persona\(personas.count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    ForEach(personas) { persona in
                        Button { onDetails(persona.id) } label: {
                            HStack(spacing: 15) {
                                Image("NoctweaveIcon")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 50, height: 50)
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack(spacing: 8) {
                                        Text(persona.displayName).font(.headline)
                                        if persona.id == model.state?.activePersonaID {
                                            identityBadge("ACTIVE", color: .green)
                                        } else if model.state?.isPersonaArchived(persona.id) == true {
                                            identityBadge("ARCHIVED", color: .secondary)
                                        }
                                    }
                                    Text("\(persona.relationships.count) contacts · \(persona.groupRuntimes.count) groups")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    if let relay = relay(for: persona.id) {
                                        Label(relay.name, systemImage: relay.endpoint.useTLS ? "lock.fill" : "network")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    } else {
                                        Label("No preferred relay", systemImage: "antenna.radiowaves.left.and.right.slash")
                                            .font(.caption)
                                            .foregroundStyle(.orange)
                                    }
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                            .padding(17)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .uniformGlassCard(cornerRadius: 22, padding: 0, minHeight: 98)
                    }

                    Text("Transport").font(.headline).padding(.top, 4)
                    MatureActionCard(
                        icon: "arrow.triangle.2.circlepath",
                        title: "Refresh Secure Routes",
                        message: "Renew expiring routes and retry durable encrypted delivery for the active persona.",
                        destructive: false,
                        action: onMaintain
                    )
                }
                .padding(16)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }
        }
        .sheet(isPresented: $showingCreatePersona) {
            NavigationStack {
                VStack(alignment: .leading, spacing: 16) {
                    SheetHero(
                        icon: "person.badge.plus",
                        title: "New Persona",
                        subtitle: "Create a separate local compartment for contacts, groups, and relay preference."
                    )
                    TextField("Display name", text: $newPersonaName)
                        .noctweaveInputField()
                    Button("Create Persona") {
                        model.createPersona(displayName: newPersonaName)
                        newPersonaName = ""
                        showingCreatePersona = false
                    }
                    .glassButton(prominent: true)
                    .disabled(newPersonaName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Spacer()
                }
                .padding(18)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showingCreatePersona = false }
                    }
                }
            }
            #if os(macOS)
            .frame(minWidth: 520, minHeight: 340)
            #endif
            .noctweaveSheetBackground()
            .noctweaveSheetPresentation()
        }
    }

    private var personas: [PersonaProfileV1] {
        (model.state?.personas ?? []).sorted { lhs, rhs in
            if lhs.id == model.state?.activePersonaID { return true }
            if rhs.id == model.state?.activePersonaID { return false }
            let lhsArchived = model.state?.isPersonaArchived(lhs.id) == true
            let rhsArchived = model.state?.isPersonaArchived(rhs.id) == true
            if lhsArchived != rhsArchived { return !lhsArchived }
            return lhs.createdAt < rhs.createdAt
        }
    }

    private func relay(for personaID: UUID) -> LocalRelayPreference? {
        guard let state = model.state,
              let relayID = state.preferredRelayPreferenceID(forPersonaID: personaID) else {
            return nil
        }
        return state.relayPreferences.first { $0.id == relayID }
    }

    private func identityBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.14), in: Capsule())
    }
}

private struct MatureActionCard: View {
    let icon: String
    let title: String
    let message: String
    let destructive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(destructive ? Color.red : Color.accentColor)
                    .frame(width: 44, height: 44)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .uniformGlassCard(cornerRadius: 21, padding: 0, minHeight: 86)
    }
}

private struct MatureEmptyCard: View {
    let icon: String
    let title: String
    let message: String
    let buttonTitle: String?
    let action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 34))
                .foregroundStyle(.tint)
            Text(title).font(.title3.weight(.bold))
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let buttonTitle, let action {
                Button(buttonTitle, action: action).glassButton(prominent: true)
            }
        }
        .padding(24)
        .frame(maxWidth: 580)
        .frame(maxWidth: .infinity)
        .uniformGlassCard(cornerRadius: 24, padding: 18)
    }
}

private struct MatureNewGroupSheet: View {
    @ObservedObject var model: ClientViewModel
    @Binding var preferredRelay: String
    let onNameChosen: (String, UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = "Private Group"
    @State private var groupID = UUID()
    @State private var showingAdvanced = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Group name").font(.headline)
                        TextField("Name visible on your devices", text: $name)
                            .noctweaveInputField()
                        Text("The name is local presentation. Members receive only group-scoped cryptographic credentials.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .uniformGlassCard(cornerRadius: 20, padding: 16)

                    DisclosureGroup("Advanced", isExpanded: $showingAdvanced) {
                        VStack(spacing: 10) {
                            LabeledContent("Group identifier", value: groupID.uuidString)
                                .font(.caption.monospaced())
                            TextField("Relay URL", text: $preferredRelay)
                                .textContentType(.URL)
                                .noctweaveInputField()
                        }
                        .padding(.top, 8)
                    }
                    .uniformGlassCard(cornerRadius: 18, padding: 14)

                    Button("Create Group") {
                        onNameChosen(name.trimmingCharacters(in: .whitespacesAndNewlines), groupID)
                        model.createGroup(groupIDText: groupID.uuidString, relayText: preferredRelay)
                        dismiss()
                    }
                    .glassButton(prominent: true)
                    .disabled(
                        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || (try? RelayEndpointParser.parse(preferredRelay)) == nil
                            || model.isWorking
                    )
                }
                .padding(18)
            }
            .navigationTitle("New Group")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 420)
        #endif
        .noctweaveSheetBackground()
        .noctweaveSheetPresentation()
    }
}

private struct MatureGroupAdmissionSheet: View {
    @ObservedObject var model: ClientViewModel
    @Binding var preferredRelay: String
    @Environment(\.dismiss) private var dismiss

    @State private var step = 0
    @State private var groupID = ""
    @State private var importedArtifact = ""
    @State private var showingAdvanced = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Picker("Group invitation", selection: $step) {
                        Text("Request Access").tag(0)
                        Text("Invite Member").tag(1)
                        Text("Accept Invite").tag(2)
                    }
                    .pickerStyle(.segmented)

                    VStack(alignment: .leading, spacing: 8) {
                        Label(stepTitle, systemImage: stepIcon)
                            .font(.headline)
                        Text(stepExplanation)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .uniformGlassCard(cornerRadius: 20, padding: 16)

                    if step == 0 {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Group invitation ID").font(.headline)
                            TextField("Paste the group ID", text: $groupID)
                                .font(.system(.body, design: .monospaced))
                                .noctweaveInputField()
                            Button("Create Access Request") {
                                model.prepareGroupJoinRequest(
                                    groupIDText: groupID,
                                    relayText: preferredRelay
                                )
                            }
                            .glassButton(prominent: true)
                            .disabled(model.isWorking || UUID(uuidString: groupID) == nil)
                        }
                        .uniformGlassCard(cornerRadius: 20, padding: 16)
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(step == 1 ? "Member access request" : "Group invitation package")
                                .font(.headline)
                            TextEditor(text: $importedArtifact)
                                .font(.system(.caption, design: .monospaced))
                                .frame(minHeight: 150)
                                .noctweaveInputField()
                            Button(step == 1 ? "Prepare Invitation" : "Join Group") {
                                if step == 1 {
                                    model.prepareGroupMemberResponse(requestLink: importedArtifact)
                                } else {
                                    model.acceptGroupMemberResponse(responseLink: importedArtifact)
                                }
                            }
                            .glassButton(prominent: true)
                            .disabled(model.isWorking || importedArtifact.isEmpty)
                        }
                        .uniformGlassCard(cornerRadius: 20, padding: 16)
                    }

                    if let artifact = model.groupExchangeLink {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(step == 0 ? "Access request ready" : "Invitation ready")
                                .font(.headline)
                            Text("Send this one-use package through an authenticated private channel.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextEditor(text: .constant(artifact))
                                .font(.system(.caption2, design: .monospaced))
                                .frame(minHeight: 120)
                                .noctweaveInputField()
                            Button("Copy Package") { copy(artifact) }
                                .glassButton(prominent: true)
                        }
                        .uniformGlassCard(cornerRadius: 20, padding: 16)
                    }

                    DisclosureGroup("Advanced Relay Options", isExpanded: $showingAdvanced) {
                        TextField("Relay URL", text: $preferredRelay)
                            .textContentType(.URL)
                            .noctweaveInputField()
                            .padding(.top, 8)
                    }
                    .uniformGlassCard(cornerRadius: 18, padding: 14)

                    if !model.groupExchangeStatus.isEmpty {
                        HStack(alignment: .top, spacing: 10) {
                            if model.isWorking { ProgressView().controlSize(.small) }
                            Text(model.groupExchangeStatus)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .uniformGlassCard(cornerRadius: 18, padding: 14)
                    }
                }
                .padding(18)
            }
            .navigationTitle("Group Invitation")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.disabled(model.isWorking)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 640, minHeight: 620)
        #endif
        .noctweaveSheetBackground()
        .noctweaveSheetPresentation()
        .interactiveDismissDisabled(model.isWorking)
    }

    private var stepTitle: String {
        switch step {
        case 0: "Ask to join a group"
        case 1: "Invite someone to your group"
        default: "Accept a group invitation"
        }
    }

    private var stepIcon: String {
        switch step {
        case 0: "person.crop.circle.badge.plus"
        case 1: "person.badge.plus"
        default: "checkmark.shield"
        }
    }

    private var stepExplanation: String {
        switch step {
        case 0:
            "Create a one-use access request using the group ID supplied by a member."
        case 1:
            "Paste a member's request. Noctweave will prepare credentials that work only inside this group."
        default:
            "Paste the invitation package you received to verify it and enter the group."
        }
    }

    private func copy(_ value: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        #else
        UIPasteboard.general.string = value
        #endif
    }
}

private struct MatureRelayEditor: View {
    @ObservedObject var model: ClientViewModel
    @Binding var preferredRelay: String

    var body: some View {
        RelayEditorView(
            title: "Add Relay",
            initial: nil,
            requiresReachableRelay: true
        ) { name, endpoint, _, password, _ in
            preferredRelay = RelayEditorView.endpointAddress(endpoint)
            if let personaID = model.activePersona?.id {
                model.saveVerifiedRelayPreference(
                    endpoint: endpoint,
                    name: name,
                    accessPassword: password,
                    preferredForPersonaID: personaID
                )
            }
        }
        #if os(macOS)
        .frame(minWidth: 620, minHeight: 600)
        #endif
    }
}

private struct MatureIdentityDetails: View {
    @ObservedObject var model: ClientViewModel
    let personaID: UUID
    let onBurn: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var revealIdentifier = false
    @State private var displayName: String
    @State private var showingDeleteConfirmation = false

    init(model: ClientViewModel, personaID: UUID, onBurn: @escaping () -> Void) {
        self.model = model
        self.personaID = personaID
        self.onBurn = onBurn
        _displayName = State(
            initialValue: model.state?.personas.first(where: { $0.id == personaID })?.displayName ?? ""
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    SheetHero(
                        icon: "person.badge.shield.checkmark",
                        title: persona?.displayName ?? "Persona",
                        subtitle: active ? "Active local compartment" : (archived ? "Archived local compartment" : "Inactive local compartment")
                    )

                    VStack(alignment: .leading, spacing: 12) {
                        Label("Profile Management", systemImage: "person.text.rectangle")
                            .font(.headline)
                        TextField("Display name", text: $displayName)
                            .noctweaveInputField()
                        Button("Save Name") {
                            model.renamePersona(personaID, displayName: displayName)
                        }
                        .glassButton(compact: true)
                        .disabled(displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        HStack {
                            Label("\(persona?.relationships.count ?? 0) contacts", systemImage: "person.2")
                            Spacer()
                            Label("\(persona?.groupRuntimes.count ?? 0) groups", systemImage: "person.3")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .uniformGlassCard(cornerRadius: 20, padding: 16)

                    VStack(alignment: .leading, spacing: 12) {
                        Label("Preferred Relay", systemImage: "antenna.radiowaves.left.and.right")
                            .font(.headline)
                        if relayPreferences.isEmpty {
                            Text("Add a verified relay from the Relays tab before assigning one to this persona.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(relayPreferences) { relay in
                                Button {
                                    model.selectRelayPreference(relay.id, forPersonaID: personaID)
                                } label: {
                                    HStack {
                                        Image(systemName: relay.endpoint.useTLS ? "lock.fill" : "network")
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(relay.name).font(.subheadline.weight(.semibold))
                                            Text(RelayEditorView.endpointAddress(relay.endpoint))
                                                .font(.caption2.monospaced())
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: relay.id == selectedRelayID ? "checkmark.circle.fill" : "circle")
                                    }
                                    .padding(11)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                        }
                    }
                    .uniformGlassCard(cornerRadius: 20, padding: 16)

                    VStack(alignment: .leading, spacing: 10) {
                        Label("Local Identifier", systemImage: "number.square")
                            .font(.headline)
                        if revealIdentifier {
                            Text(personaID.uuidString)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        } else {
                            Button("Reveal Local Identifier") { revealIdentifier = true }
                                .glassButton(compact: true)
                        }
                        Text("This value organizes encrypted state on this device. It is not a public address and is never shared with contacts.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .uniformGlassCard(cornerRadius: 20, padding: 16)

                    Text("Persona Actions").font(.headline).padding(.top, 4)
                    if !active {
                        MatureActionCard(
                            icon: "checkmark.circle.fill",
                            title: "Use Persona",
                            message: "Make this the active compartment and resume its independent routes.",
                            destructive: false
                        ) {
                            model.switchPersona(personaID)
                            dismiss()
                        }
                        MatureActionCard(
                            icon: archived ? "archivebox.fill" : "archivebox",
                            title: archived ? "Restore from Archive" : "Archive Persona",
                            message: archived
                                ? "Return this encrypted compartment to the active identity book."
                                : "Keep its encrypted state but move it out of the active identity list.",
                            destructive: false
                        ) {
                            if archived {
                                model.unarchivePersona(personaID)
                            } else {
                                model.archivePersona(personaID)
                            }
                        }
                        MatureActionCard(
                            icon: "trash.fill",
                            title: "Delete Persona",
                            message: "Permanently remove this inactive persona and its local encrypted state.",
                            destructive: true
                        ) {
                            showingDeleteConfirmation = true
                        }
                    } else {
                        MatureActionCard(
                            icon: "flame.fill",
                            title: "Burn Identity",
                            message: "Destroy every relationship and group in this persona, then begin without continuity.",
                            destructive: true,
                            action: onBurn
                        )
                    }
                }
                .padding(16)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Profile Management")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 430)
        #endif
        .noctweaveSheetBackground()
        .noctweaveSheetPresentation()
        .confirmationDialog(
            "Delete this inactive persona?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Persona", role: .destructive) {
                model.deleteInactivePersona(personaID)
                dismiss()
            }
        } message: {
            Text("This permanently removes its contacts, groups, and local history. It cannot be undone.")
        }
    }

    private var persona: PersonaProfileV1? {
        model.state?.personas.first { $0.id == personaID }
    }

    private var active: Bool {
        model.state?.activePersonaID == personaID
    }

    private var archived: Bool {
        model.state?.isPersonaArchived(personaID) == true
    }

    private var relayPreferences: [LocalRelayPreference] {
        model.state?.relayPreferences ?? []
    }

    private var selectedRelayID: UUID? {
        model.state?.preferredRelayPreferenceID(forPersonaID: personaID)
    }
}

#if os(iOS)
private struct MatureBottomBar: View {
    @Binding var selection: ClientDestination
    let didSelect: () -> Void

    private let items: [ClientDestination] = [.chats, .contacts, .code, .relays, .identity, .settings]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(items) { item in
                Button {
                    selection = item
                    didSelect()
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: item.icon)
                            .font(.system(size: 18, weight: selection == item ? .semibold : .regular))
                        Text(bottomTitle(item))
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(selection == item ? Color.accentColor : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(selection == item ? Color.accentColor.opacity(0.15) : Color.clear, in: Capsule())
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 0.5)
        }
    }

    private func bottomTitle(_ item: ClientDestination) -> String {
        switch item {
        case .contacts: "Contacts"
        case .code: "Code"
        case .identity: "Identity"
        default: item.title
        }
    }
}

private struct MatureSideRail: View {
    @Binding var selection: ClientDestination
    let didSelect: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Image("NoctweaveIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 44, height: 44)
                .padding(.bottom, 8)
            ForEach(ClientDestination.allCases) { item in
                Button {
                    selection = item
                    didSelect()
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: item.icon).font(.title3)
                        Text(item == .contacts ? "Contacts" : item == .identity ? "Identity" : item.title)
                            .font(.caption2.weight(.medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(selection == item ? Color.accentColor : Color.secondary)
                    .frame(width: 86, height: 60)
                    .background(selection == item ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.top, 16)
        .padding(.horizontal, 8)
        .background(.ultraThinMaterial)
    }
}
#endif
