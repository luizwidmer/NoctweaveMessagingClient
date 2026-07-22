import Foundation
import NoctweaveCore
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

struct MaturePairingSheet: View {
    @ObservedObject var model: ClientViewModel
    @Binding var preferredRelay: String
    @ObservedObject private var pairingInbox = PairingInvitationInbox.shared

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var pairingMode = PairingMode.relay
    @State private var direction = PairingDirection.share
    @State private var method = PairingTransferMethod.qr
    @State private var contactName = "My relationship name"
    @State private var invitation = ""
    @State private var relayPassword = ""
    @State private var revealInvitation = false
    @State private var qrCollector = QRChunkCollector()
    @State private var qrProgress = "Point the camera at the other device. Animated codes are collected automatically."
    @State private var showingQRScanner = false
    @State private var outboundQRFrames: [String] = []

    @State private var filePassword = ""
    @State private var filePasswordConfirmation = ""
    @State private var importedPackage: Data?
    @State private var importPassword = ""
    @State private var exportedDocument = PairingInvitationDocument()
    @State private var showingFileExporter = false
    @State private var showingFileImporter = false
    @State private var isProtectingFile = false
    @State private var transferFeedback = ""
    @State private var fileError = ""

    @State private var shareURL: URL?
    @State private var showingShareSheet = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    pairingModePicker
                    pairingExplanation
                    directionPicker
                    contactNameCard
                    methodPicker
                    relayOptions
                    relayReadiness
                    if pairingMode == .relay {
                        transferPanel
                    } else {
                        directTransferPanel
                    }
                    pairingStatus
                }
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
                .padding(18)
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Add Contact")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if model.directPairingCanFinish {
                        Button("Finish") {
                            model.finishDirectPairing()
                            dismiss()
                        }
                    } else if model.isPairing {
                        Button("Cancel", role: .destructive) {
                            model.cancelPairing()
                        }
                    } else {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 640, minHeight: 680)
        #endif
        .noctweaveSheetBackground()
        .noctweaveSheetPresentation()
        .interactiveDismissDisabled(model.isPairing)
        .fileExporter(
            isPresented: $showingFileExporter,
            document: exportedDocument,
            contentType: .noctweavePairingInvitation,
            defaultFilename: "Noctweave Pairing"
        ) { result in
            switch result {
            case .success:
                transferFeedback = "Protected pairing stage exported. Send its password separately."
            case .failure(let error):
                fileError = error.localizedDescription
            }
        }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.noctweavePairingInvitation],
            allowsMultipleSelection: false,
            onCompletion: importFile
        )
        .onChange(of: model.pairingLink) { _, link in
            if pairingMode == .relay {
                updateOutboundFrames(link)
            }
        }
        .onChange(of: model.directPairingPayload) { _, payload in
            if pairingMode == .direct {
                updateOutboundFrames(payload)
            }
        }
        .onChange(of: model.pairingStatus) { _, status in
            if status == "A fresh unlinkable relationship is ready." {
                removeTemporaryShareFile()
                dismiss()
            }
        }
        .onChange(of: pairingInbox.revision) { _, _ in
            consumePendingFile()
        }
        .onAppear {
            consumePendingFile()
            checkRelayReadiness()
        }
        .onDisappear {
            removeTemporaryShareFile()
        }
        #if os(iOS)
        .sheet(isPresented: $showingShareSheet, onDismiss: removeTemporaryShareFile) {
            if let shareURL {
                ShareSheet(activityItems: [shareURL])
            }
        }
        #elseif os(macOS)
        .background {
            if let shareURL {
                ShareSheet(items: [shareURL], isPresented: $showingShareSheet)
                    .frame(width: 1, height: 1)
            }
        }
        #endif
    }

    private var pairingModePicker: some View {
        Picker("Pairing path", selection: $pairingMode) {
            Text("Relay").tag(PairingMode.relay)
            Text("Direct / Offline").tag(PairingMode.direct)
        }
        .pickerStyle(.segmented)
        .disabled(model.isPairing)
        .accessibilityIdentifier("pairing.mode")
        .onChange(of: pairingMode) { _, _ in
            method = .qr
            model.clearPairingLink()
            resetInboundTransfer()
            updateOutboundFrames(nil)
            checkRelayReadiness()
        }
    }

    private var pairingExplanation: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "person.2.badge.key.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 42, height: 42)
                .background(Color.accentColor.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 5) {
                Text(pairingMode == .relay
                     ? "Pair through a relay"
                     : "Pair directly between devices")
                    .font(.headline)
                Text(pairingMode == .relay
                     ? "One device creates a one-use invitation and the other accepts it. The selected relay carries only the encrypted, expiring handshake frames."
                     : "QR or protected files carry every authenticated handshake stage directly. No relay stores the pairing transcript, although each device still contacts its own relay once to create its private message route.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .uniformGlassCard(cornerRadius: 22, padding: 16)
    }

    private var directionPicker: some View {
        Picker("Pairing direction", selection: directionSelection) {
            Text("Share Invitation").tag(PairingDirection.share)
            Text("Receive Invitation").tag(PairingDirection.receive)
        }
        .pickerStyle(.segmented)
        .disabled(model.isPairing)
        .accessibilityIdentifier("pairing.direction")
    }

    private var contactNameCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your relationship name").font(.headline)
            TextField("Name the other person will see", text: $contactName)
                .noctweaveInputField()
                .disabled(model.isPairing)
            Text("This pseudonym exists only inside the new relationship. It is never published as an account or global identity.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .uniformGlassCard(cornerRadius: 20, padding: 16)
    }

    private var methodPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(direction == .share ? "How will you share it?" : "How did you receive it?")
                .font(.headline)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 190), spacing: 12)],
                spacing: 12
            ) {
                ForEach(availableMethods) { option in
                    PairingMethodCard(
                        option: option,
                        selected: method == option.method
                    ) {
                        selectMethod(option.method)
                    }
                }
            }
        }
        .uniformGlassCard(cornerRadius: 22, padding: 16)
    }

    @ViewBuilder
    private var transferPanel: some View {
        if direction == .share {
            sharePanel
        } else {
            receivePanel
        }
    }

    @ViewBuilder
    private var directTransferPanel: some View {
        if !model.isPairing, model.directPairingPayload == nil {
            if direction == .share {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Start a direct exchange", systemImage: "arrow.left.arrow.right.circle.fill")
                        .font(.headline)
                    Text("The devices will alternate a few encrypted QR or file stages. Keep this sheet open until both sides confirm completion.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("Begin Direct Pairing") {
                        model.startDirectPairing(
                            relayText: preferredRelay,
                            pseudonym: contactName,
                            relayPassword: relayPassword
                        )
                    }
                    .glassButton(prominent: true)
                    .disabled(
                        !relayIsReady
                            || contactName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .uniformGlassCard(cornerRadius: 22, padding: 18)
            } else {
                receivePanel
            }
        } else if model.isPairingProcessing, model.directPairingPayload == nil {
            ProgressView("Preparing direct pairing…")
                .frame(maxWidth: .infinity, alignment: .leading)
                .uniformGlassCard(cornerRadius: 22, padding: 18)
        } else {
            if let payload = model.directPairingPayload {
                directOutboundPanel(payload: payload)
            }
            if model.directPairingCanFinish {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Final receipt", systemImage: "checkmark.seal.fill")
                        .font(.headline)
                        .foregroundStyle(.green)
                    Text("After the other device scans or imports the receipt above, finish this exchange. Your relationship is already stored locally.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("Finish Pairing") {
                        model.finishDirectPairing()
                        dismiss()
                    }
                    .glassButton(prominent: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .uniformGlassCard(cornerRadius: 22, padding: 18)
            } else if !model.isPairingProcessing {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Receive the next stage", systemImage: "arrow.down.circle")
                        .font(.headline)
                    Text("Once the other device has read your stage, scan or import the stage it shows next.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .uniformGlassCard(cornerRadius: 18, padding: 14)
                receivePanel
            }
        }
    }

    @ViewBuilder
    private func directOutboundPanel(payload: String) -> some View {
        switch method {
        case .qr:
            let qrSize: CGFloat = horizontalSizeClass == .compact ? 232 : 280
            VStack(spacing: 12) {
                Label("Show this stage to the other device", systemImage: "qrcode")
                    .font(.headline)
                if outboundQRFrames.isEmpty {
                    ProgressView("Preparing visual exchange…")
                } else {
                    AnimatedQRCodeView(
                        frames: outboundQRFrames,
                        size: qrSize,
                        interval: 0.65
                    )
                    .padding(12)
                    .background(
                        Color.white,
                        in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                    )
                    Text("Keep the code visible until the other device has collected every frame.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .uniformGlassCard(cornerRadius: 22, padding: 18)
        case .nearby:
            protectedFileControls(payload: payload, destination: .systemShare)
        case .file:
            protectedFileControls(payload: payload, destination: .export)
        case .link:
            EmptyView()
        }
    }

    @ViewBuilder
    private var sharePanel: some View {
        if let link = model.pairingLink {
            switch method {
            case .qr:
                shareQRCode(link: link)
            case .nearby:
                protectedFileControls(payload: link, destination: .systemShare)
            case .file:
                protectedFileControls(payload: link, destination: .export)
            case .link:
                remoteLinkControls(link: link)
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Label("Fresh for one person", systemImage: "sparkles")
                    .font(.headline)
                Text("Creating an invitation mints temporary rendezvous material. It expires after 10 minutes and cannot be reused.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Create One-Use Invitation") {
                    model.startOfferingPairing(
                        relayText: preferredRelay,
                        pseudonym: contactName,
                        relayPassword: relayPassword
                    )
                }
                .glassButton(prominent: true)
                .disabled(
                    model.isPairing
                        || !relayIsReady
                        || contactName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .uniformGlassCard(cornerRadius: 22, padding: 18)
        }
    }

    private func shareQRCode(link: String) -> some View {
        let qrSize: CGFloat = horizontalSizeClass == .compact ? 232 : 280
        return VStack(spacing: 12) {
            if outboundQRFrames.isEmpty {
                ProgressView("Preparing visual invitation…")
            } else {
                AnimatedQRCodeView(frames: outboundQRFrames, size: qrSize, interval: 0.65)
                    .padding(12)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                Text(outboundQRFrames.count > 1
                     ? "Keep this screen steady while the other device scans every frame."
                     : "The other device can scan this code once.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Copy Invitation") { copyToPasteboard(link) }
                    .glassButton()
            }
        }
        .frame(maxWidth: .infinity)
        .uniformGlassCard(cornerRadius: 22, padding: 18)
    }

    private func protectedFileControls(
        payload: String,
        destination: ProtectedFileDestination
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                destination == .systemShare ? "Protected AirDrop or share" : "Password-protected file",
                systemImage: destination == .systemShare ? "square.and.arrow.up" : "lock.doc.fill"
            )
            .font(.headline)
            Text(destination == .systemShare
                 ? "Noctweave encrypts this pairing stage before opening the system share sheet."
                 : "Save this encrypted pairing stage for removable storage or another offline channel.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            SecureField("Password — at least 8 characters", text: $filePassword)
                .textContentType(.newPassword)
                .noctweaveInputField()
            SecureField("Repeat password", text: $filePasswordConfirmation)
                .textContentType(.newPassword)
                .noctweaveInputField()
            Text("Send the password through a different channel. It is never written into the file.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(destination == .systemShare ? "Protect and Share" : "Export Protected File") {
                prepareProtectedFile(payload: payload, destination: destination)
            }
            .glassButton(prominent: true)
            .disabled(!passwordIsReady || isProtectingFile)
            if isProtectingFile {
                ProgressView("Encrypting invitation…")
                    .controlSize(.small)
            }
            transferFeedbackView
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .uniformGlassCard(cornerRadius: 22, padding: 18)
    }

    private func remoteLinkControls(link: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Remote invitation link", systemImage: "link")
                .font(.headline)
            Text("Use an already trusted channel. Anyone who obtains this link before it expires can attempt to redeem it.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if revealInvitation {
                Text(link)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(6)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
            }
            HStack(spacing: 10) {
                Button(revealInvitation ? "Hide Link" : "Reveal Link") {
                    revealInvitation.toggle()
                }
                .glassButton()
                Button("Copy Link") { copyToPasteboard(link) }
                    .glassButton(prominent: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .uniformGlassCard(cornerRadius: 22, padding: 18)
    }

    @ViewBuilder
    private var receivePanel: some View {
        switch method {
        case .qr:
            qrScannerPanel
        case .file, .nearby:
            importProtectedFilePanel
        case .link:
            pasteLinkPanel
        }
    }

    private var qrScannerPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                pairingMode == .relay ? "Scan visual invitation" : "Scan pairing stage",
                systemImage: "qrcode.viewfinder"
            )
                .font(.headline)
            if invitation.isEmpty {
                if showingQRScanner {
                    QRCodeScannerView(
                        onScan: consumeScannedFrame,
                        onError: { fileError = $0 },
                        allowsMultiple: true
                    )
                    Button("Close Scanner") { showingQRScanner = false }
                        .glassButton()
                } else {
                    Text("Camera access is requested only after you open the scanner.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("Open QR Scanner") { showingQRScanner = true }
                        .glassButton(prominent: true)
                }
                Text(qrProgress)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                invitationReadyView
            }
            transferFeedbackView
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .uniformGlassCard(cornerRadius: 22, padding: 18)
    }

    private var importProtectedFilePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Open protected pairing stage", systemImage: "lock.open.display")
                .font(.headline)
            Text("Choose the .noctpair file received through AirDrop, removable storage, or another channel.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if invitation.isEmpty {
                Button(importedPackage == nil ? "Choose Protected File" : "Choose Another File") {
                    showingFileImporter = true
                }
                .glassButton()
                if importedPackage != nil {
                    SecureField("File password", text: $importPassword)
                        .textContentType(.password)
                        .noctweaveInputField()
                    Button("Unlock Pairing Stage") { unlockImportedPackage() }
                        .glassButton(prominent: true)
                        .disabled(
                            importPassword.count
                                < PasswordProtectedPairingPackageV1.minimumPasswordCharacters
                                || isProtectingFile
                        )
                }
            } else {
                invitationReadyView
            }
            transferFeedbackView
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .uniformGlassCard(cornerRadius: 22, padding: 18)
    }

    private var pasteLinkPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Paste invitation link", systemImage: "doc.on.clipboard")
                .font(.headline)
            TextEditor(text: $invitation)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 130)
                .noctweaveInputField()
            if !invitation.isEmpty, !looksLikePairingPayload(invitation) {
                Text("This does not look like the expected Noctweave pairing data.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            acceptInvitationButton
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .uniformGlassCard(cornerRadius: 22, padding: 18)
    }

    private var invitationReadyView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                pairingMode == .relay ? "Invitation captured" : "Pairing stage captured",
                systemImage: "checkmark.seal.fill"
            )
                .font(.headline)
                .foregroundStyle(.green)
            Text("Continue only if this came from the person and device you intend to pair with.")
                .font(.caption)
                .foregroundStyle(.secondary)
            acceptInvitationButton
        }
    }

    private var acceptInvitationButton: some View {
        Button(pairingMode == .relay ? "Accept and Pair" : "Continue Exchange") {
            let payload = invitation
            if pairingMode == .relay {
                model.startAcceptingPairing(
                    link: payload,
                    pseudonym: contactName,
                    relayPassword: relayPassword
                )
            } else {
                model.continueDirectPairing(
                    payload: payload,
                    relayText: preferredRelay,
                    pseudonym: contactName,
                    relayPassword: relayPassword
                )
                clearInboundCapture()
            }
        }
        .glassButton(prominent: true)
        .disabled(
            model.isPairingProcessing
                || (pairingMode == .relay && model.isPairing)
                || !relayIsReady
                || !looksLikePairingPayload(invitation)
                || contactName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
    }

    private var relayOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                pairingMode == .relay ? "Pairing relay" : "Your message relay",
                systemImage: "network"
            )
            .font(.headline)
            if pairingMode == .direct || direction == .share {
                TextField("Relay URL", text: $preferredRelay)
                    .textContentType(.URL)
                    .noctweaveInputField()
                    .disabled(model.isPairing)
            } else {
                Text("The relay endpoint is authenticated from the captured invitation.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            SecureField("Relay password, if required", text: $relayPassword)
                .textContentType(.password)
                .noctweaveInputField()
                .disabled(model.isPairing)
            Text(pairingMode == .relay
                 ? "This relay must support one-use rendezvous and opaque relationship routes. It is checked before pairing starts."
                 : "The direct transcript never enters this relay. Only your private relationship route is provisioned here.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .uniformGlassCard(cornerRadius: 18, padding: 14)
        .onChange(of: preferredRelay) { _, _ in
            guard !model.isPairing else { return }
            model.resetPairingRelayCheck()
        }
        .onChange(of: relayPassword) { _, _ in
            guard !model.isPairing else { return }
            model.resetPairingRelayCheck()
        }
    }

    private var relayReadiness: some View {
        HStack(alignment: .center, spacing: 12) {
            relayReadinessIcon
            VStack(alignment: .leading, spacing: 3) {
                Text(relayReadinessTitle)
                    .font(.subheadline.weight(.semibold))
                Text(relayReadinessDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(model.pairingRelayCheckState == .checking ? "Checking…" : "Check Relay") {
                checkRelayReadiness()
            }
            .glassButton(prominent: !relayIsReady)
            .disabled(
                model.isPairing
                    || model.pairingRelayCheckState == .checking
                    || (pairingMode == .relay && direction == .receive && invitation.isEmpty)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .uniformGlassCard(cornerRadius: 18, padding: 14)
    }

    @ViewBuilder
    private var pairingStatus: some View {
        if !model.pairingStatus.isEmpty {
            HStack(alignment: .center, spacing: 10) {
                if model.isPairingProcessing { ProgressView().controlSize(.small) }
                Text(model.pairingStatus)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if model.isPairing {
                    Button("Cancel", role: .destructive) { model.cancelPairing() }
                        .buttonStyle(.borderless)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .uniformGlassCard(cornerRadius: 18, padding: 14)
        }
    }

    @ViewBuilder
    private var transferFeedbackView: some View {
        if !fileError.isEmpty {
            Label(fileError, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        } else if !transferFeedback.isEmpty {
            Label(transferFeedback, systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var availableMethods: [PairingMethodOption] {
        if direction == .share {
            var methods = [
                PairingMethodOption(
                    method: .qr,
                    title: "Show QR",
                    subtitle: "Best when both devices are together",
                    icon: "qrcode"
                ),
                PairingMethodOption(
                    method: .nearby,
                    title: "AirDrop or Share",
                    subtitle: "Send a password-protected file nearby",
                    icon: "square.and.arrow.up"
                ),
                PairingMethodOption(
                    method: .file,
                    title: "Protected File",
                    subtitle: "Move it by drive or another offline path",
                    icon: "lock.doc"
                )
            ]
            if pairingMode == .relay {
                methods.append(PairingMethodOption(
                    method: .link,
                    title: "Remote Link",
                    subtitle: "Copy through an existing trusted channel",
                    icon: "link"
                ))
            }
            return methods
        }
        var methods = [
            PairingMethodOption(
                method: .qr,
                title: "Scan QR",
                subtitle: "Collect a visual invitation in person",
                icon: "qrcode.viewfinder"
            ),
            PairingMethodOption(
                method: .file,
                title: "Open Protected File",
                subtitle: "Use a file received by AirDrop or offline",
                icon: "lock.open"
            )
        ]
        if pairingMode == .relay {
            methods.append(PairingMethodOption(
                method: .link,
                title: "Paste Link",
                subtitle: "Use a link received through a trusted channel",
                icon: "doc.on.clipboard"
            ))
        }
        return methods
    }

    private var passwordIsReady: Bool {
        filePassword.count >= PasswordProtectedPairingPackageV1.minimumPasswordCharacters
            && filePassword == filePasswordConfirmation
    }

    private var directionSelection: Binding<PairingDirection> {
        Binding(
            get: { direction },
            set: { newDirection in
                guard newDirection != direction else { return }
                direction = newDirection
                method = .qr
                filePassword = ""
                filePasswordConfirmation = ""
                revealInvitation = false
                model.clearPairingLink()
                resetInboundTransfer()
                checkRelayReadiness()
            }
        )
    }

    private func selectMethod(_ newMethod: PairingTransferMethod) {
        guard newMethod != method else { return }
        method = newMethod
        if direction == .receive {
            resetInboundTransfer()
        } else {
            revealInvitation = false
            fileError = ""
            transferFeedback = ""
        }
    }

    private func consumeScannedFrame(_ text: String) {
        var collector = qrCollector
        let result = collector.consume(text)
        qrCollector = collector
        switch result {
        case .single(let value), .complete(let value):
            guard looksLikePairingPayload(value) else {
                qrProgress = "That QR code is not the expected Noctweave pairing stage."
                return
            }
            invitation = value
            showingQRScanner = false
            qrProgress = "Pairing stage captured."
            if pairingMode == .relay {
                checkRelayReadiness()
            }
        case .partial(_, let received, let total):
            qrProgress = "Collected \(received) of \(total) frames. Keep scanning."
        case .invalid:
            qrProgress = "A frame was invalid. Keep the code in view and try again."
        }
    }

    private func prepareProtectedFile(
        payload: String,
        destination: ProtectedFileDestination
    ) {
        guard passwordIsReady else { return }
        isProtectingFile = true
        fileError = ""
        transferFeedback = ""
        let password = filePassword
        Task {
            do {
                let package = try await Task.detached(priority: .userInitiated) {
                    try PasswordProtectedPairingPackageV1.seal(
                        invitation: payload,
                        password: password
                    )
                }.value
                switch destination {
                case .export:
                    exportedDocument = PairingInvitationDocument(payload: package)
                    showingFileExporter = true
                case .systemShare:
                    removeTemporaryShareFile()
                    let url = FileManager.default.temporaryDirectory
                        .appendingPathComponent("Noctweave Pairing")
                        .appendingPathExtension("noctpair")
                    try package.write(to: url, options: .atomic)
                    shareURL = url
                    showingShareSheet = true
                }
            } catch {
                fileError = describeTransferError(error)
            }
            isProtectingFile = false
        }
    }

    private func importFile(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard !data.isEmpty,
                  data.count <= PasswordProtectedPairingPackageV1.maximumPackageBytes else {
                throw CocoaError(.fileReadCorruptFile)
            }
            importedPackage = data
            importPassword = ""
            invitation = ""
            fileError = ""
            transferFeedback = "Protected pairing stage selected. Enter its password."
        } catch {
            fileError = error.localizedDescription
        }
    }

    private func consumePendingFile() {
        guard pairingInbox.hasPendingItem else { return }
        let pending = pairingInbox.takePendingItem()
        direction = .receive
        method = .file
        invitation = ""
        importPassword = ""
        if let package = pending.package {
            importedPackage = package
            fileError = ""
            transferFeedback = "Protected pairing stage received. Enter its password."
        } else {
            importedPackage = nil
            fileError = pending.error ?? "The protected invitation could not be opened."
            transferFeedback = ""
        }
    }

    private func unlockImportedPackage() {
        guard let importedPackage else { return }
        isProtectingFile = true
        fileError = ""
        transferFeedback = ""
        let password = importPassword
        Task {
            do {
                let opened = try await Task.detached(priority: .userInitiated) {
                    try PasswordProtectedPairingPackageV1.open(
                        package: importedPackage,
                        password: password
                    )
                }.value
                guard looksLikePairingPayload(opened) else {
                    throw PairingTransferError.invalidInvitation
                }
                invitation = opened
                self.importedPackage = nil
                importPassword = ""
                transferFeedback = "Pairing stage decrypted in memory."
                if pairingMode == .relay {
                    checkRelayReadiness()
                }
            } catch {
                fileError = describeTransferError(error)
            }
            isProtectingFile = false
        }
    }

    private func looksLikePairingPayload(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let expectedPrefix = pairingMode == .relay
            ? "noctweave-pair-v1:"
            : DirectPairingTransferV2.prefix
        return trimmed.hasPrefix(expectedPrefix)
            && trimmed.count <= QRCodeTransfer.maximumAssembledCharacters
    }

    private func clearInboundCapture() {
        invitation = ""
        importedPackage = nil
        importPassword = ""
        qrCollector = QRChunkCollector()
        showingQRScanner = false
        qrProgress = "Point the camera at the other device. Animated codes are collected automatically."
        fileError = ""
        transferFeedback = ""
    }

    private func resetInboundTransfer() {
        clearInboundCapture()
    }

    private func describeTransferError(_ error: Error) -> String {
        switch error as? PasswordProtectedPairingPackageV1Error {
        case .invalidPassword:
            return "Use a password with at least 8 characters."
        case .decryptionFailed:
            return "The password is incorrect or the file was modified."
        case .invalidPackage:
            return "This is not a valid protected Noctweave pairing stage."
        default:
            return error.localizedDescription
        }
    }

    private func copyToPasteboard(_ value: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        #elseif os(iOS)
        UIPasteboard.general.string = value
        #endif
        transferFeedback = "Invitation copied."
    }

    private func removeTemporaryShareFile() {
        guard let shareURL else { return }
        try? FileManager.default.removeItem(at: shareURL)
        self.shareURL = nil
    }

    private var relayRequirement: RelayPairingRequirement {
        pairingMode == .relay ? .rendezvous : .opaqueRouteOnly
    }

    private var relayIsReady: Bool {
        guard case .ready(let readiness) = model.pairingRelayCheckState else {
            return false
        }
        return readiness.requirement == relayRequirement
    }

    @ViewBuilder
    private var relayReadinessIcon: some View {
        switch model.pairingRelayCheckState {
        case .idle:
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.secondary)
        case .checking:
            ProgressView().controlSize(.small)
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    private var relayReadinessTitle: String {
        switch model.pairingRelayCheckState {
        case .idle: "Relay not checked"
        case .checking: "Checking relay"
        case .ready(let readiness): readiness.relayInfo.relayName ?? "Relay ready"
        case .failed: "Relay unavailable or incompatible"
        }
    }

    private var relayReadinessDetail: String {
        switch model.pairingRelayCheckState {
        case .idle:
            return "Run the check before creating or accepting pairing data."
        case .checking:
            return "Verifying health, protocol capabilities, authentication, and a temporary route."
        case .ready(let readiness):
            return readiness.requirement == .rendezvous
                ? "Reachable; message routes and one-use relay rendezvous are functional."
                : "Reachable; a temporary private message route was created and removed successfully."
        case .failed(let message):
            return message
        }
    }

    private func checkRelayReadiness() {
        if pairingMode == .relay, direction == .receive {
            guard looksLikePairingPayload(invitation) else {
                model.resetPairingRelayCheck()
                return
            }
            model.checkPairingInvitationRelay(
                link: invitation,
                relayPassword: relayPassword
            )
        } else {
            model.checkPairingRelay(
                relayText: preferredRelay,
                relayPassword: relayPassword,
                requirement: relayRequirement
            )
        }
    }

    private func updateOutboundFrames(_ payload: String?) {
        outboundQRFrames = payload.map {
            QRCodeTransfer.encodeFrames($0, maxChunkSize: 600)
        } ?? []
    }
}

private enum PairingMode: Hashable {
    case relay
    case direct
}

private enum PairingDirection: Hashable {
    case share
    case receive
}

private enum PairingTransferMethod: String, Hashable {
    case qr
    case nearby
    case file
    case link
}

private enum ProtectedFileDestination {
    case systemShare
    case export
}

private enum PairingTransferError: Error {
    case invalidInvitation
}

private struct PairingMethodOption: Identifiable {
    let method: PairingTransferMethod
    let title: String
    let subtitle: String
    let icon: String

    var id: String { method.rawValue }
}

private struct PairingMethodCard: View {
    let option: PairingMethodOption
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: option.icon)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .frame(width: 34, height: 34)
                    .background(Color.accentColor.opacity(selected ? 0.18 : 0.08), in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(option.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(option.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.55))
            }
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
            .padding(13)
            .background(
                Color.accentColor.opacity(selected ? 0.11 : 0.035),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(
                        selected ? Color.accentColor.opacity(0.65) : Color.primary.opacity(0.08),
                        lineWidth: selected ? 1.4 : 1
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("pairing.method.\(option.method.rawValue)")
        .accessibilityValue(selected ? "Selected" : "Not selected")
    }
}
