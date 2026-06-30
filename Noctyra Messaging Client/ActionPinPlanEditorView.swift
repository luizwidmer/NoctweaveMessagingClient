import SwiftUI
import NoctweaveCore

struct ActionPlanEditorRequest: Identifiable {
    let id = UUID()
    let plan: AppLockActionPlan?
}

struct ActionPlanCommitConfig {
    let planId: UUID?
    let label: String
    let operations: [AppLockActionOperation]
}

struct ActionPinPlanEditorView: View {
    @ObservedObject var model: ClientViewModel
    let initialPlan: AppLockActionPlan?
    let onSave: (ActionPlanCommitConfig) -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme
    @State private var label: String
    @State private var selectedKinds: Set<AppLockActionKind>
    @State private var selectedIdentityIds: Set<UUID>
    @State private var selectedDeleteIdentityIds: Set<UUID>
    @State private var selectedDeleteGroupIds: Set<UUID>
    @State private var selectedDeleteContactIds: Set<UUID>
    @State private var selectedDeleteChatContactIds: Set<UUID>
    @State private var selectedDeleteChatGroupIds: Set<UUID>
    @State private var acknowledgedDangerKinds: Set<AppLockActionKind>
    @State private var phraseConfirmations: [AppLockActionKind: String]

    init(
        model: ClientViewModel,
        initialPlan: AppLockActionPlan?,
        onSave: @escaping (ActionPlanCommitConfig) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.model = model
        self.initialPlan = initialPlan
        self.onSave = onSave
        self.onCancel = onCancel

        let operations = initialPlan?.operations ?? []
        let selectedKinds = Set(operations.map(\.kind))
        let burnIdentityIds = Set(operations.filter { $0.kind == .burnIdentities }.flatMap(\.identityIds))
        let deleteIdentityIds = Set(operations.filter { $0.kind == .deleteIdentities }.flatMap(\.identityIds))
        let deleteGroupIds = Set(operations.filter { $0.kind == .deleteGroups }.flatMap(\.groupIds))
        let deleteContactIds = Set(operations.filter { $0.kind == .deleteContacts }.flatMap(\.contactIds))
        let deleteChatContactIds = Set(operations.filter { $0.kind == .deleteChats }.flatMap(\.chatContactIds))
        let deleteChatGroupIds = Set(operations.filter { $0.kind == .deleteChats }.flatMap(\.groupIds))

        _label = State(initialValue: initialPlan?.label ?? "")
        _selectedKinds = State(initialValue: selectedKinds)
        _selectedIdentityIds = State(initialValue: burnIdentityIds)
        _selectedDeleteIdentityIds = State(initialValue: deleteIdentityIds)
        _selectedDeleteGroupIds = State(initialValue: deleteGroupIds)
        _selectedDeleteContactIds = State(initialValue: deleteContactIds)
        _selectedDeleteChatContactIds = State(initialValue: deleteChatContactIds)
        _selectedDeleteChatGroupIds = State(initialValue: deleteChatGroupIds)
        _acknowledgedDangerKinds = State(initialValue: [])
        _phraseConfirmations = State(initialValue: [:])
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    SheetActionBar(closeLabel: "Cancel") {
                        onCancel()
                        dismiss()
                    } trailing: {
                        Button(initialPlan == nil ? "Continue" : "Update") {
                            savePlan()
                        }
                        .glassButton(prominent: true, compact: true)
                        .disabled(!canContinue)
                    }

                    SheetHero(
                        icon: "key.viewfinder",
                        title: initialPlan == nil ? "New Action PIN" : "Edit Action PIN",
                        subtitle: "Combine multiple emergency actions behind one six-digit PIN."
                    )

                    SheetSection(
                        title: "Plan",
                        subtitle: "Give this action PIN a recognizable purpose.",
                        icon: "tag.fill"
                    ) {
                        TextField("Plan label", text: $label)
                            .noctyraInputField()
                        Label(
                            "After the plan runs once, this PIN becomes the normal app unlock PIN.",
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    SheetSection(
                        title: "Actions",
                        subtitle: selectedKinds.isEmpty
                            ? "Select one or more actions."
                            : "\(selectedKinds.count) selected",
                        icon: "bolt.shield.fill"
                    ) {
                        VStack(spacing: 10) {
                            ForEach(AppLockActionKind.allCases) { kind in
                                actionCard(for: kind)
                            }
                        }
                    }

                    if !targetWarnings.isEmpty {
                        SheetSection(
                            title: "Targets Required",
                            subtitle: "Finish configuring the selected actions.",
                            icon: "exclamationmark.triangle.fill"
                        ) {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(targetWarnings, id: \.self) { warning in
                                    Label(warning, systemImage: "circle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                    }

                    if !selectedDangerKinds.isEmpty {
                        SheetSection(
                            title: "Final Confirmations",
                            subtitle: "Irreversible actions require explicit confirmation.",
                            icon: "exclamationmark.shield.fill",
                            role: .destructive
                        ) {
                            VStack(spacing: 10) {
                                ForEach(selectedDangerKinds) { kind in
                                    dangerConfirmationRow(kind: kind)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: 720)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
            .noctyraSheetBackground()
            .hideSheetNavigationBar()
        }
    }

    private func savePlan() {
        onSave(
            ActionPlanCommitConfig(
                planId: initialPlan?.id,
                label: label.trimmingCharacters(in: .whitespacesAndNewlines),
                operations: buildOperations()
            )
        )
        dismiss()
    }

    @ViewBuilder
    private func actionCard(for kind: AppLockActionKind) -> some View {
        let isSelected = selectedKinds.contains(kind)
        VStack(alignment: .leading, spacing: isSelected ? 12 : 0) {
            Button {
                binding(for: kind).wrappedValue.toggle()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: actionIcon(for: kind))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(isSelected ? theme.accent : .secondary)
                        .frame(width: 34, height: 34)
                        .background(
                            (isSelected ? theme.accent : Color.secondary).opacity(0.12),
                            in: Circle()
                        )
                    VStack(alignment: .leading, spacing: 3) {
                        Text(kind.displayName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(actionSummary(for: kind))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(isSelected ? theme.accent : .secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isSelected {
                Divider()
                    .opacity(0.24)
                if kind.targetHint != "No target list required." {
                    Text(kind.targetHint)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                targetsSection(for: kind)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isSelected ? theme.accent.opacity(0.09) : Color.black.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(
                            isSelected ? theme.accent.opacity(0.38) : Color.white.opacity(0.09),
                            lineWidth: 0.9
                        )
                )
        )
        .animation(.easeOut(duration: 0.18), value: isSelected)
    }

    private func actionIcon(for kind: AppLockActionKind) -> String {
        switch kind {
        case .appReset: return "arrow.counterclockwise.circle"
        case .burnIdentities: return "flame.fill"
        case .deleteGroups: return "person.3.fill"
        case .deleteIdentities: return "person.crop.circle.badge.minus"
        case .appCorruption: return "externaldrive.badge.xmark"
        case .throwAround: return "theatermasks.fill"
        case .deleteChats: return "bubble.left.and.exclamationmark.bubble.right.fill"
        case .deleteContacts: return "person.crop.circle.badge.xmark"
        case .wipePhotos: return "photo.badge.trash"
        case .wipeDocuments: return "doc.badge.ellipsis"
        }
    }

    private func actionSummary(for kind: AppLockActionKind) -> String {
        switch kind {
        case .appReset: return "Erase local state and return the app to onboarding."
        case .burnIdentities: return "Burn selected identities and their routing state."
        case .deleteGroups: return "Remove selected groups and local group history."
        case .deleteIdentities: return "Permanently remove selected identity profiles."
        case .appCorruption: return "Trigger the configured destructive tamper response."
        case .throwAround: return "Replace local state with a cover identity and decoy activity."
        case .deleteChats: return "Erase selected direct or group conversations."
        case .deleteContacts: return "Remove selected contacts and their trust records."
        case .wipePhotos: return "Erase locally stored image attachments."
        case .wipeDocuments: return "Erase locally stored documents and shared files."
        }
    }

    private func binding(for kind: AppLockActionKind) -> Binding<Bool> {
        Binding(
            get: { selectedKinds.contains(kind) },
            set: { enabled in
                if enabled {
                    selectedKinds.insert(kind)
                } else {
                    selectedKinds.remove(kind)
                    acknowledgedDangerKinds.remove(kind)
                    phraseConfirmations.removeValue(forKey: kind)
                }
            }
        )
    }

    @ViewBuilder
    private func targetsSection(for kind: AppLockActionKind) -> some View {
        switch kind {
        case .burnIdentities:
            selectableIdentityTargets(selection: $selectedIdentityIds)
        case .deleteIdentities:
            selectableIdentityTargets(selection: $selectedDeleteIdentityIds)
        case .deleteGroups:
            selectableGroupTargets(selection: $selectedDeleteGroupIds)
        case .deleteChats:
            selectableChatTargets(
                contactSelection: $selectedDeleteChatContactIds,
                groupSelection: $selectedDeleteChatGroupIds
            )
        case .deleteContacts:
            selectableContactTargets(selection: $selectedDeleteContactIds)
        default:
            EmptyView()
        }
    }

    private func selectableIdentityTargets(selection: Binding<Set<UUID>>) -> some View {
        let profiles = model.state.identityProfiles.sorted { lhs, rhs in
            if lhs.id == model.state.activeIdentityId { return true }
            if rhs.id == model.state.activeIdentityId { return false }
            return lhs.createdAt > rhs.createdAt
        }
        return VStack(alignment: .leading, spacing: 6) {
            if profiles.isEmpty {
                Text("No identities available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(profiles) { profile in
                    Toggle(isOn: uuidToggleBinding(profile.id, selection: selection)) {
                        HStack {
                            Text(profile.identity.displayName)
                            if profile.id == model.state.activeIdentityId {
                                Text("Active")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            } else if profile.isArchived {
                                Text("Archived")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .targetToggleStyle()
                }
            }
        }
    }

    private func selectableGroupTargets(selection: Binding<Set<UUID>>) -> some View {
        let groups = groupTargets
        return VStack(alignment: .leading, spacing: 6) {
            if groups.isEmpty {
                Text("No groups available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(groups) { entry in
                    Toggle(isOn: uuidToggleBinding(entry.id, selection: selection)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title)
                            Text(entry.profileName)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .targetToggleStyle()
                }
            }
        }
    }

    private func selectableContactTargets(selection: Binding<Set<UUID>>) -> some View {
        let contacts = contactTargets
        return VStack(alignment: .leading, spacing: 6) {
            if contacts.isEmpty {
                Text("No contacts available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(contacts) { entry in
                    Toggle(isOn: uuidToggleBinding(entry.id, selection: selection)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title)
                            Text(entry.profileName)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .targetToggleStyle()
                }
            }
        }
    }

    private func selectableChatTargets(contactSelection: Binding<Set<UUID>>, groupSelection: Binding<Set<UUID>>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Direct Chats")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            let chats = chatTargets
            if chats.isEmpty {
                Text("No direct chats available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(chats) { entry in
                    Toggle(isOn: uuidToggleBinding(entry.id, selection: contactSelection)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title)
                            Text(entry.profileName)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .targetToggleStyle()
                }
            }

            Text("Group Chats")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            let groups = groupTargets
            if groups.isEmpty {
                Text("No group chats available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(groups) { entry in
                    Toggle(isOn: uuidToggleBinding(entry.id, selection: groupSelection)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title)
                            Text(entry.profileName)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .targetToggleStyle()
                }
            }
        }
    }

    private func uuidToggleBinding(_ id: UUID, selection: Binding<Set<UUID>>) -> Binding<Bool> {
        Binding(
            get: { selection.wrappedValue.contains(id) },
            set: { enabled in
                if enabled {
                    selection.wrappedValue.insert(id)
                } else {
                    selection.wrappedValue.remove(id)
                }
            }
        )
    }

    private var canContinue: Bool {
        !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !selectedKinds.isEmpty
            && targetWarnings.isEmpty
            && dangerConfirmationsSatisfied
    }

    private var selectedDangerKinds: [AppLockActionKind] {
        AppLockActionKind.allCases.filter { kind in
            selectedKinds.contains(kind) && dangerRequirement(for: kind) != .none
        }
    }

    private var dangerConfirmationsSatisfied: Bool {
        for kind in selectedDangerKinds {
            switch dangerRequirement(for: kind) {
            case .none:
                continue
            case .ack:
                guard acknowledgedDangerKinds.contains(kind) else {
                    return false
                }
            case .phrase(let phrase):
                let typed = phraseConfirmations[kind, default: ""]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .uppercased()
                guard typed == phrase else {
                    return false
                }
            }
        }
        return true
    }

    private var targetWarnings: [String] {
        var warnings: [String] = []
        if selectedKinds.contains(.burnIdentities), selectedIdentityIds.isEmpty {
            warnings.append("Burn Identities requires at least one selected identity.")
        }
        if selectedKinds.contains(.deleteIdentities), selectedDeleteIdentityIds.isEmpty {
            warnings.append("Delete Identities requires at least one selected identity.")
        }
        if selectedKinds.contains(.deleteGroups), selectedDeleteGroupIds.isEmpty {
            warnings.append("Delete Groups requires at least one selected group.")
        }
        if selectedKinds.contains(.deleteChats), selectedDeleteChatContactIds.isEmpty && selectedDeleteChatGroupIds.isEmpty {
            warnings.append("Delete Chats requires at least one direct chat or group chat.")
        }
        if selectedKinds.contains(.deleteContacts), selectedDeleteContactIds.isEmpty {
            warnings.append("Delete Contacts requires at least one selected contact.")
        }
        return warnings
    }

    @ViewBuilder
    private func dangerConfirmationRow(kind: AppLockActionKind) -> some View {
        let message = dangerMessage(for: kind)
        switch dangerRequirement(for: kind) {
        case .none:
            EmptyView()
        case .ack:
            Toggle(isOn: Binding(
                get: { acknowledgedDangerKinds.contains(kind) },
                set: { enabled in
                    if enabled {
                        acknowledgedDangerKinds.insert(kind)
                    } else {
                        acknowledgedDangerKinds.remove(kind)
                    }
                }
            )) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Confirm \(kind.displayName)")
                        .font(.subheadline.weight(.semibold))
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .targetToggleStyle()
        case .phrase(let phrase):
            VStack(alignment: .leading, spacing: 6) {
                Text("Confirm \(kind.displayName)")
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                #if os(iOS)
                TextField("Type \(phrase)", text: phraseBinding(for: kind))
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .noctyraInputField()
                #else
                TextField("Type \(phrase)", text: phraseBinding(for: kind))
                    .noctyraInputField()
                #endif
            }
            .padding(12)
            .background(Color.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private enum DangerRequirement: Equatable {
        case none
        case ack
        case phrase(String)
    }

    private static func dangerRequirement(for kind: AppLockActionKind) -> DangerRequirement {
        switch kind {
        case .appReset:
            return .phrase("RESET")
        case .burnIdentities:
            return .phrase("BURN")
        case .deleteIdentities:
            return .phrase("ERASE")
        case .appCorruption:
            return .phrase("CORRUPT")
        case .throwAround:
            return .phrase("COVER")
        case .deleteGroups, .deleteChats, .deleteContacts, .wipePhotos, .wipeDocuments:
            return .ack
        }
    }

    private func dangerRequirement(for kind: AppLockActionKind) -> DangerRequirement {
        Self.dangerRequirement(for: kind)
    }

    private func dangerMessage(for kind: AppLockActionKind) -> String {
        switch kind {
        case .appReset:
            return "Resets local state and restarts onboarding. This is irreversible."
        case .burnIdentities:
            return "Burns selected identities, rotates routing, and drops their contacts/chats."
        case .deleteIdentities:
            return "Permanently removes selected identities and their local history."
        case .appCorruption:
            return "Intentionally writes bogus data to local state and storage for tamper response."
        case .throwAround:
            return "Replaces state with a new cover identity and fake chat artifacts."
        case .wipePhotos:
            return "Deletes all image attachments from local storage."
        case .wipeDocuments:
            return "Deletes non-image attachments and local share document files."
        case .deleteGroups:
            return "Permanently removes selected groups and their local messages."
        case .deleteChats:
            return "Permanently removes selected direct/group chat history."
        case .deleteContacts:
            return "Deletes selected contacts and their trust metadata."
        }
    }

    private func phraseBinding(for kind: AppLockActionKind) -> Binding<String> {
        Binding(
            get: { phraseConfirmations[kind] ?? "" },
            set: { phraseConfirmations[kind] = $0 }
        )
    }

    private func buildOperations() -> [AppLockActionOperation] {
        var operations: [AppLockActionOperation] = []
        for kind in AppLockActionKind.allCases where selectedKinds.contains(kind) {
            switch kind {
            case .burnIdentities:
                operations.append(
                    AppLockActionOperation(
                        kind: .burnIdentities,
                        identityIds: Array(selectedIdentityIds)
                    )
                )
            case .deleteIdentities:
                operations.append(
                    AppLockActionOperation(
                        kind: .deleteIdentities,
                        identityIds: Array(selectedDeleteIdentityIds)
                    )
                )
            case .deleteGroups:
                operations.append(
                    AppLockActionOperation(
                        kind: .deleteGroups,
                        groupIds: Array(selectedDeleteGroupIds)
                    )
                )
            case .deleteChats:
                operations.append(
                    AppLockActionOperation(
                        kind: .deleteChats,
                        groupIds: Array(selectedDeleteChatGroupIds),
                        chatContactIds: Array(selectedDeleteChatContactIds)
                    )
                )
            case .deleteContacts:
                operations.append(
                    AppLockActionOperation(
                        kind: .deleteContacts,
                        contactIds: Array(selectedDeleteContactIds)
                    )
                )
            default:
                operations.append(AppLockActionOperation(kind: kind))
            }
        }
        return operations
    }

    private var groupTargets: [TargetEntry] {
        stateTargets { profile in
            profile.groups.map { group in
                TargetEntry(id: group.id, title: group.title, profileName: profile.identity.displayName)
            }
        }
    }

    private var contactTargets: [TargetEntry] {
        stateTargets { profile in
            profile.contacts.map { contact in
                TargetEntry(id: contact.id, title: contact.displayName, profileName: profile.identity.displayName)
            }
        }
    }

    private var chatTargets: [TargetEntry] {
        stateTargets { profile in
            profile.conversations.map { conversation in
                let title = profile.contacts.first(where: { $0.id == conversation.contactId })?.displayName
                    ?? "Chat \(conversation.contactId.uuidString.prefix(6))"
                return TargetEntry(id: conversation.contactId, title: title, profileName: profile.identity.displayName)
            }
        }
    }

    private func stateTargets(_ build: (IdentityProfile) -> [TargetEntry]) -> [TargetEntry] {
        var seen = Set<UUID>()
        var entries: [TargetEntry] = []
        for profile in model.state.identityProfiles {
            for entry in build(profile) {
                if seen.insert(entry.id).inserted {
                    entries.append(entry)
                }
            }
        }
        return entries
    }

    private struct TargetEntry: Identifiable {
        let id: UUID
        let title: String
        let profileName: String
    }
}

private extension View {
    func targetToggleStyle() -> some View {
        self
            .toggleStyle(.switch)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}
