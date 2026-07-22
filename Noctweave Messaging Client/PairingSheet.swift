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

    @State private var direction = PairingDirection.share
    @State private var method = PairingTransferMethod.qr
    @State private var contactName = "New Contact"
    @State private var invitation = ""
    @State private var showingAdvanced = false
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
                    pairingExplanation
                    directionPicker
                    contactNameCard
                    methodPicker
                    transferPanel
                    relayOptions
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
                    if model.isPairing {
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
            defaultFilename: "Noctweave Invitation"
        ) { result in
            switch result {
            case .success:
                transferFeedback = "Protected invitation exported. Send its password separately."
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
            outboundQRFrames = link.map {
                QRCodeTransfer.encodeFrames($0, maxChunkSize: 600)
            } ?? []
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

    private var pairingExplanation: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "person.2.badge.key.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 42, height: 42)
                .background(Color.accentColor.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 5) {
                Text("Choose how the invitation travels")
                    .font(.headline)
                Text("QR, AirDrop, and protected files hand the one-use secret directly to the other device. Both devices still connect to the selected relay to verify the exchange and create their private routes.")
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
            Text("Contact name").font(.headline)
            TextField("Name shown in your contact book", text: $contactName)
                .noctweaveInputField()
                .disabled(model.isPairing)
            Text("This label remains on your device. It is never published as an account or global identity.")
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
    private var sharePanel: some View {
        if let link = model.pairingLink {
            switch method {
            case .qr:
                shareQRCode(link: link)
            case .nearby:
                protectedFileControls(destination: .systemShare)
            case .file:
                protectedFileControls(destination: .export)
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
                        pseudonym: contactName
                    )
                }
                .glassButton(prominent: true)
                .disabled(
                    model.isPairing
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

    private func protectedFileControls(destination: ProtectedFileDestination) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                destination == .systemShare ? "Protected AirDrop or share" : "Password-protected file",
                systemImage: destination == .systemShare ? "square.and.arrow.up" : "lock.doc.fill"
            )
            .font(.headline)
            Text(destination == .systemShare
                 ? "Noctweave encrypts the invitation before opening the system share sheet."
                 : "Save an encrypted invitation that can be moved by removable storage or another offline channel.")
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
                prepareProtectedFile(destination: destination)
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
            Label("Scan visual invitation", systemImage: "qrcode.viewfinder")
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
            Label("Open protected invitation", systemImage: "lock.open.display")
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
                    Button("Unlock Invitation") { unlockImportedPackage() }
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
            if !invitation.isEmpty, !looksLikeInvitation(invitation) {
                Text("This does not look like a current Noctweave invitation.")
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
            Label("Invitation captured", systemImage: "checkmark.seal.fill")
                .font(.headline)
                .foregroundStyle(.green)
            Text("No permanent identity has been added yet. Continue to verify the encrypted pairing transcript.")
                .font(.caption)
                .foregroundStyle(.secondary)
            acceptInvitationButton
        }
    }

    private var acceptInvitationButton: some View {
        Button("Accept and Pair") {
            model.startAcceptingPairing(
                link: invitation,
                pseudonym: contactName
            )
        }
        .glassButton(prominent: true)
        .disabled(
            model.isPairing
                || !looksLikeInvitation(invitation)
                || contactName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
    }

    @ViewBuilder
    private var relayOptions: some View {
        if direction == .share {
            DisclosureGroup("Relay used to finish pairing", isExpanded: $showingAdvanced) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Relay URL", text: $preferredRelay)
                        .textContentType(.URL)
                        .noctweaveInputField()
                    Text("The invitation records this endpoint. QR and files move the secret locally, but both devices must reach this relay before the invitation expires.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)
            }
            .disabled(model.isPairing)
            .uniformGlassCard(cornerRadius: 18, padding: 14)
        }
    }

    @ViewBuilder
    private var pairingStatus: some View {
        if !model.pairingStatus.isEmpty {
            HStack(alignment: .center, spacing: 10) {
                if model.isPairing { ProgressView().controlSize(.small) }
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
            return [
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
                ),
                PairingMethodOption(
                    method: .link,
                    title: "Remote Link",
                    subtitle: "Copy through an existing trusted channel",
                    icon: "link"
                )
            ]
        }
        return [
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
            ),
            PairingMethodOption(
                method: .link,
                title: "Paste Link",
                subtitle: "Use a link received through a trusted channel",
                icon: "doc.on.clipboard"
            )
        ]
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
                resetInboundTransfer()
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
            guard looksLikeInvitation(value) else {
                qrProgress = "That QR code is not a current Noctweave invitation."
                return
            }
            invitation = value
            showingQRScanner = false
            qrProgress = "Invitation captured."
        case .partial(_, let received, let total):
            qrProgress = "Collected \(received) of \(total) frames. Keep scanning."
        case .invalid:
            qrProgress = "A frame was invalid. Keep the code in view and try again."
        }
    }

    private func prepareProtectedFile(destination: ProtectedFileDestination) {
        guard let link = model.pairingLink, passwordIsReady else { return }
        isProtectingFile = true
        fileError = ""
        transferFeedback = ""
        let password = filePassword
        Task {
            do {
                let package = try await Task.detached(priority: .userInitiated) {
                    try PasswordProtectedPairingPackageV1.seal(
                        invitation: link,
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
                        .appendingPathComponent("Noctweave Invitation")
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
            transferFeedback = "Protected invitation selected. Enter its password."
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
            transferFeedback = "Protected invitation received. Enter its password."
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
                guard looksLikeInvitation(opened) else {
                    throw PairingTransferError.invalidInvitation
                }
                invitation = opened
                self.importedPackage = nil
                importPassword = ""
                transferFeedback = "Invitation decrypted in memory."
            } catch {
                fileError = describeTransferError(error)
            }
            isProtectingFile = false
        }
    }

    private func looksLikeInvitation(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("noctweave-pair-v1:")
            && trimmed.count <= QRCodeTransfer.maximumAssembledCharacters
    }

    private func resetInboundTransfer() {
        invitation = ""
        importedPackage = nil
        importPassword = ""
        qrCollector = QRChunkCollector()
        showingQRScanner = false
        qrProgress = "Point the camera at the other device. Animated codes are collected automatically."
        fileError = ""
        transferFeedback = ""
    }

    private func describeTransferError(_ error: Error) -> String {
        switch error as? PasswordProtectedPairingPackageV1Error {
        case .invalidPassword:
            return "Use a password with at least 8 characters."
        case .decryptionFailed:
            return "The password is incorrect or the file was modified."
        case .invalidPackage:
            return "This is not a valid protected Noctweave invitation."
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
