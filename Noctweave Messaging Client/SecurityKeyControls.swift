import SwiftUI
import NoctweaveCore
import NoctweaveSecurityKeys

struct UnlockVisibilityControls: View {
    @ObservedObject var model: ClientViewModel
    let mode: AppLockMode

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Lock-screen privacy", systemImage: "eye.slash").font(.headline)
            Text("Hide key and biometric hints on the waiting screen. Its \(ClientUnlockCredentialPolicy.name.lowercased()) field disappears when authentication starts and returns at the required \(ClientUnlockCredentialPolicy.name.lowercased()) step.")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(AppLockFactor.allCases.filter { $0 != .pin && mode.requiredFactors.contains($0) }, id: \.self) { factor in
                Toggle("Hide \(unlockFactorName(factor))", isOn: Binding(
                    get: { model.pendingHiddenUnlockFactors.contains(factor) },
                    set: { model.setPendingUnlockFactorHidden(factor, hidden: $0) }))
                    .accessibilityIdentifier("unlock.hide.\(factor.rawValue)")
            }
            Text("Normal unlock order is security key, biometrics, then \(ClientUnlockCredentialPolicy.name.lowercased()). Connecting a USB key starts its authentication flow; biometrics start when the key check is complete. Unconfigured checks are skipped.")
                .font(.caption).foregroundStyle(.secondary)
            #if os(iOS)
            Text("If a connected key is not detected automatically, hold the lock emblem for two seconds to start authentication. No key hint is shown on the hidden lock screen.")
                .font(.caption).foregroundStyle(.secondary)
            #endif
            Text("System prompts appear when authentication starts. Avoid naming hidden methods in a custom lock message. The waiting \(ClientUnlockCredentialPolicy.name.lowercased()) screen accepts duress codes before the normal checks; cancel the key flow to return to it.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .disabled(model.securityKeyBusy || model.isSavingSettings)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .uniformGlassCard(cornerRadius: 20, padding: 0)
    }
}

private func unlockFactorName(_ factor: AppLockFactor) -> String {
    switch factor {
    case .biometrics: "biometrics"
    case .pin: ClientUnlockCredentialPolicy.name
    case .securityKey: "security key"
    }
}

/// PINs live only in this short-lived form and the active SDK request.
struct SecurityKeyPrompt: View {
    let busy: Bool
    let title: String
    var requiresUSB: Bool = false
    var showCancelWhileIdle = false
    /// nil means a new registration; existing records retain their original RP scope.
    var credentials: [AppLockSecurityKeyRecordV1]? = nil
    let cancel: () -> Void
    let submit: (String, SecurityKeyTransport, Bool) async -> Void
    @State private var keyPIN = ""
    @State private var transport: SecurityKeyTransport = .usb
    @State private var useEarlierRegistration = false

    private var hasLocal: Bool {
        credentials?.contains { $0.relyingPartyID == AppLockSecurityKeyRecordV1.localRelyingPartyID } == true
    }

    private var hasEarlier: Bool {
        credentials?.contains { $0.relyingPartyID == AppLockSecurityKeyRecordV1.nativeRelyingPartyID } == true
    }

    private var usesLocalFlow: Bool {
        #if os(iOS)
        credentials == nil || (hasLocal && !(hasEarlier && useEarlierRegistration))
        #else
        false
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            #if os(iOS)
            if hasLocal && hasEarlier {
                Toggle("Use earlier registration", isOn: $useEarlierRegistration)
                    .disabled(busy)
                    .onChange(of: useEarlierRegistration) { _, _ in keyPIN = "" }
            }
            #endif
            if usesLocalFlow {
                Text("Connect your security key, then continue in the on-device authentication sheet. Enter the key’s PIN and touch it there when prompted. This works offline.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("securityKey.localFlow")
            } else {
                #if os(iOS)
                Picker("Key connection", selection: $transport) {
                    Text("USB-C").tag(SecurityKeyTransport.usb)
                    if !requiresUSB && UIDevice.current.userInterfaceIdiom == .phone {
                        Text("NFC").tag(SecurityKeyTransport.nfc)
                    }
                }
                .pickerStyle(.segmented)
                #endif
                Text("Connect your FIDO2 key. Enter its PIN if it has one, then touch the key when it blinks.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                SecureField("Security key PIN", text: $keyPIN)
                    .noctweaveInputField()
                    .disabled(busy)
                    .accessibilityIdentifier("securityKey.pin")
                    .onSubmit { start() }
                Text("This is the key’s PIN. A key with built-in verification may not need it.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if busy {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for your key…").font(.callout)
                    Spacer(minLength: 0)
                    Button("Cancel", action: cancel)
                }
            } else {
                HStack {
                    Button(title, action: start)
                        .glassButton(prominent: true)
                        .accessibilityIdentifier("securityKey.submit")
                    if showCancelWhileIdle { Button("Cancel", action: cancel).glassButton() }
                }
            }
        }
        .onDisappear { keyPIN = ""; cancel() }
        .onChange(of: requiresUSB) { _, required in if required { transport = .usb } }
    }

    private func start() {
        guard !busy else { return }
        let submittedPIN = keyPIN
        keyPIN = ""
        let legacy = !usesLocalFlow
        Task { await submit(submittedPIN, transport, legacy) }
    }
}

struct SecurityKeySetupControls: View {
    @ObservedObject var model: ClientViewModel
    @State private var keyName = "Security key"
    @State private var verifyingExisting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Your security keys", systemImage: "key.horizontal.fill").font(.headline)
            Text("A spare key helps if your main key is lost. Only a registered key can unlock the app; there is no app \(ClientUnlockCredentialPolicy.name.lowercased()) or biometric fallback. Keep at least one key accessible.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.continuousKeyPresenceAvailable {
                Toggle("Keep key connected", isOn: Binding(
                    get: { model.pendingKeyPresenceRequired }, set: model.setPendingKeyPresenceRequirement))
                    .disabled(model.securityKeyBusy || model.isSavingSettings)
                    .accessibilityIdentifier("securityKey.keepConnected")
                Text("When enabled, disconnecting the verified USB key locks Noctweave. Reconnecting requires every selected check again.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(model.pendingSecurityKeys) { key in
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.shield.fill").foregroundStyle(.green)
                    Text(key.name).lineLimit(2)
                    Spacer(minLength: 8)
                    Button { model.removePendingSecurityKey(key.id) } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(key.name) from this setup")
                    .disabled(model.securityKeyBusy || model.isSavingSettings)
                }
                .padding(12)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
            if !model.pendingSecurityKeys.isEmpty {
                Picker("Key action", selection: $verifyingExisting) {
                    Text("Verify registered key").tag(true)
                    if model.pendingSecurityKeys.count < 8 { Text("Add another key").tag(false) }
                }
                .pickerStyle(.menu)
                .disabled(model.securityKeyBusy)
            }
            if model.pendingSecurityKeys.count < 8 || verifyingExisting {
                if !verifyingExisting {
                TextField("Key name", text: $keyName)
                    .noctweaveInputField()
                    .disabled(model.securityKeyBusy)
                    .accessibilityIdentifier("securityKey.name")
                    .onChange(of: keyName) { _, value in
                        if value.utf8.count > 128 { keyName = String(value.prefix(32)) }
                    }
                }
                SecurityKeyPrompt(busy: model.securityKeyBusy, title: verifyingExisting ? "Verify Key" : "Register Key",
                                  requiresUSB: model.pendingKeyPresenceRequired,
                                  credentials: verifyingExisting ? model.pendingSecurityKeys : nil,
                                  cancel: model.cancelSecurityKeyOperation) { pin, transport, legacy in
                    if verifyingExisting { await model.verifyPendingSecurityKey(pin: pin, transport: transport, legacy: legacy) }
                    else { await model.registerSecurityKey(name: keyName, pin: pin, transport: transport) }
                }
                .disabled(model.isSavingSettings || (!verifyingExisting && keyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                Text(verifyingExisting
                     ? "Verify a registered key before saving protection. Touch it when prompted."
                     : "Setup asks the key to register, then verify. You may need to touch it twice. Changes apply when you save protection.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if model.canEnableSecurityKeyProtection {
                Label("Key verified. Ready to save protection.", systemImage: "checkmark.shield.fill")
                    .font(.callout).foregroundStyle(.green)
                    .accessibilityIdentifier("securityKey.verified")
            }
        }
        .onAppear { verifyingExisting = !model.pendingSecurityKeys.isEmpty }
        .onChange(of: model.pendingSecurityKeys.count) { _, count in
            if count == 0 { verifyingExisting = false }
            if count == 8 { verifyingExisting = true }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .uniformGlassCard(cornerRadius: 20, padding: 0)
    }
}


struct DuressPlanControls: View {
    @ObservedObject var model: ClientViewModel
    @State private var label = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var action: AppLockDuressAction = .decoy
    @State private var acknowledged = false
    @State private var selectedChats = Set<AppLockDecoyChat>()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(ClientUnlockCredentialPolicy.usesPassword ? "Duress passwords" : "Duress PINs", systemImage: "shield.lefthalf.filled").font(.headline)
            Text("Enter these in the ordinary \(ClientUnlockCredentialPolicy.name.lowercased()) field. Each code runs its action immediately, then becomes the only unlock \(ClientUnlockCredentialPolicy.name.lowercased()). Previous unlock methods and all duress actions are removed.")
                .font(.callout).foregroundStyle(.secondary)
            if !model.appLockSettings.actionPlans.isEmpty {
                Text("Older action plans are inactive. Recreate the actions you want here.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.pendingDuressPlans) { plan in
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(plan.label).font(.headline)
                            Text(plan.action.displayName).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 12)
                        Button("Remove") { model.removePendingDuressPlan(plan.id) }
                    }
                    if plan.action == .decoy {
                        DisclosureGroup("Chats to keep (\(plan.decoyChats.count))") {
                            chatSelection(selected: plan.decoyChats) { selection, keep in
                                model.setPendingDecoyChat(selection, in: plan.id, retained: keep)
                            }
                        }
                    }
                }
                .padding(12)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
            if model.pendingDuressPlans.count < 4 {
                TextField("Label for your reference", text: $label).noctweaveInputField().accessibilityIdentifier("duress.label")
                Picker("Action", selection: $action) {
                    ForEach(AppLockDuressAction.allCases) { value in Text(value.displayName).tag(value) }
                }
                Text(action.explanation).font(.caption).foregroundStyle(.secondary)
                if action == .decoy {
                    DisclosureGroup("Chats to keep (\(selectedChats.count))") {
                        chatSelection(selected: selectedChats) { selection, keep in
                            if keep { selectedChats.insert(selection) } else { selectedChats.remove(selection) }
                        }
                    }
                    Text("These chats keep their history and can still send and receive. Everything outside this selection is erased, including chats in other personas.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                SecureField("Duress \(ClientUnlockCredentialPolicy.name.lowercased())", text: $password)
                    .appUnlockKeyboard(usesPassword: ClientUnlockCredentialPolicy.usesPassword).noctweaveInputField().accessibilityIdentifier("duress.password")
                SecureField("Repeat duress \(ClientUnlockCredentialPolicy.name.lowercased())", text: $confirmation)
                    .appUnlockKeyboard(usesPassword: ClientUnlockCredentialPolicy.usesPassword).noctweaveInputField().accessibilityIdentifier("duress.confirmation")
                Text(ClientUnlockCredentialPolicy.rules + " Choose a different value from your ordinary unlock and other duress codes.")
                    .font(.caption).foregroundStyle(.secondary)
                if action.destroysKeys {
                    Toggle("I understand that this action permanently erases data and replaces my unlock methods.", isOn: $acknowledged)
                    Text("It cannot erase recipient copies, exports, backups, or data already copied from this process.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Add action to setup") {
                    let submitted = password
                    let chats = action == .decoy ? selectedChats : []
                    password = ""; confirmation = ""
                    Task {
                        if await model.addPendingDuressPlan(password: submitted, label: label, action: action, decoyChats: chats) {
                            label = ""; acknowledged = false; selectedChats = []
                        }
                    }
                }
                .glassButton()
                .accessibilityIdentifier("duress.add")
                .disabled(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !ClientUnlockCredentialPolicy.isValidNewCredential(password)
                    || password != confirmation || selectedChats.count > 4_096 || (action.destroysKeys && !acknowledged))
            }
            Text("Changes take effect only after Save Protection. Test your chosen flow with disposable data before relying on it.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(16).uniformGlassCard(cornerRadius: 20, padding: 0)
        .disabled(model.isSavingSettings || model.securityKeyBusy)
        .disclosureGroupStyle(ChatSelectionDisclosureStyle())
        .onChange(of: action) { _, _ in acknowledged = false; selectedChats = [] }
        .onDisappear { password = ""; confirmation = "" }
    }

    private func chatSelection(selected: Set<AppLockDecoyChat>, change: @escaping (AppLockDecoyChat, Bool) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.decoyChatChoices.isEmpty {
                Text("No chats available. This action will keep an empty profile.")
                    .font(.callout).foregroundStyle(.secondary)
            } else if model.decoyChatChoices.count <= 6 {
                VStack(alignment: .leading, spacing: 10) { chatChoiceRows(selected: selected, change: change) }
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) { chatChoiceRows(selected: selected, change: change) }
                        .padding(.vertical, 8)
                }.frame(height: 230)
            }
        }.padding(.top, 8)
    }

    private func chatChoiceRows(selected: Set<AppLockDecoyChat>, change: @escaping (AppLockDecoyChat, Bool) -> Void) -> some View {
        ForEach(model.decoyChatChoices, id: \.selection) { choice in
                Toggle(isOn: Binding(get: { selected.contains(choice.selection) }, set: { change(choice.selection, $0) })) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(choice.title).lineLimit(2)
                        Text(choice.persona).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.automatic)
                .accessibilityLabel("\(choice.title), \(choice.persona)")
                .accessibilityIdentifier("duress.chat.\(choice.selection.chatID.uuidString)")
        }
    }

}

/// The entire label is a click/tap target, including on macOS where the native
/// disclosure style otherwise exposes a much smaller expansion affordance.
private struct ChatSelectionDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { configuration.isExpanded.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    configuration.label
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            if configuration.isExpanded { configuration.content }
        }
    }
}

/// Presentation values only: no persona, relationship, key, capability, or attachment objects.
struct LocalChatPreview: Identifiable {
    let id = UUID()
    let title: String
    let messages: [Message]
    struct Message: Identifiable {
        let id = UUID()
        let text: String
        let outgoing: Bool
    }
}

struct LocalSessionPreviewView: View {
    let chats: [LocalChatPreview]
    @State private var selected: UUID?
    @State private var draft = ""
    @Environment(\.appTheme) private var theme

    private var activeChat: LocalChatPreview? { chats.first { $0.id == selected } ?? chats.first }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                if geometry.size.width >= 680 {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("Noctweave").font(.title2.bold())
                        Text("Chats").font(.headline)
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 10) {
                                ForEach(chats) { chat in
                                    Button { selected = chat.id } label: {
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(chat.title).font(.headline)
                                            Text(chat.messages.last?.text ?? "").font(.caption).lineLimit(1).foregroundStyle(.secondary)
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                    }.glassButton()
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24).padding(.top, 48).padding(.bottom, 20)
                    .frame(width: 260).background(.ultraThinMaterial)
                }
                VStack(spacing: 18) {
                    HStack {
                        Text(activeChat?.title ?? "Chats").font(.title2.bold())
                        Spacer()
                        if geometry.size.width < 680 && chats.count > 1 {
                            Menu("Chats") {
                                ForEach(chats) { chat in Button(chat.title) { selected = chat.id } }
                            }
                        }
                    }.padding(.horizontal, 24).padding(.top, 48)
                    if let chat = activeChat {
                        ScrollView {
                            LazyVStack(spacing: 12) {
                                ForEach(chat.messages) { message in
                                    HStack {
                                        if message.outgoing { Spacer(minLength: 36) }
                                        Text(message.text).padding(14)
                                            .background(message.outgoing ? theme.accent.opacity(0.18) : .primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
                                        if !message.outgoing { Spacer(minLength: 36) }
                                    }
                                }
                            }.padding(24)
                        }
                    } else {
                        Spacer()
                        Text("No conversations yet").font(.title3.weight(.semibold))
                        Spacer()
                    }
                    HStack {
                        TextField("Message", text: $draft).noctweaveInputField()
                        Button("Send") { }.glassButton().disabled(true)
                    }.padding(20)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(GlassBackground().ignoresSafeArea())
        .onDisappear { draft = "" }
    }
}
