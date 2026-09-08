import SwiftUI
import NoctweaveCore
import NoctweaveSecurityKeys

/// PINs live only in this short-lived form and the active SDK request.
struct SecurityKeyPrompt: View {
    let busy: Bool
    let title: String
    var requiresUSB: Bool = false
    let cancel: () -> Void
    let submit: (String, SecurityKeyTransport) async -> Void
    @State private var keyPIN = ""
    @State private var transport: SecurityKeyTransport = .usb

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
            if busy {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for your key…").font(.callout)
                    Spacer(minLength: 0)
                    Button("Cancel", action: cancel)
                }
            } else {
                Button(title, action: start)
                    .glassButton(prominent: true)
                    .accessibilityIdentifier("securityKey.submit")
            }
        }
        .onDisappear { keyPIN = ""; cancel() }
        .onChange(of: requiresUSB) { _, required in if required { transport = .usb } }
    }

    private func start() {
        guard !busy else { return }
        let submittedPIN = keyPIN
        keyPIN = ""
        Task { await submit(submittedPIN, transport) }
    }
}

struct SecurityKeySetupControls: View {
    @ObservedObject var model: ClientViewModel
    @State private var keyName = "Security key"
    @State private var verifyingExisting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Your security keys", systemImage: "key.horizontal.fill").font(.headline)
            Text("A spare key helps if your main key is lost. Only a registered key can unlock the app; there is no PIN or biometric fallback. Keep at least one key accessible.")
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
                                  requiresUSB: model.pendingKeyPresenceRequired, cancel: model.cancelSecurityKeyOperation) { pin, transport in
                    if verifyingExisting { await model.verifyPendingSecurityKey(pin: pin, transport: transport) }
                    else { await model.registerSecurityKey(name: keyName, pin: pin, transport: transport) }
                }
                .disabled(model.isSavingSettings || (!verifyingExisting && keyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                Text(verifyingExisting
                     ? "Verify a registered key before saving protection. Touch it when prompted."
                     : "Setup asks the key to register, then verify. You may need to touch it twice. Changes apply when you save protection.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
