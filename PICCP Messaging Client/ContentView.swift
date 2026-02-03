import SwiftUI
import PICCPCore
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
import PhotosUI
#elseif os(macOS)
import AppKit
import Carbon.HIToolbox
#endif

private enum SidebarItem: Hashable {
    case contact(UUID)
    case contactBook
    case myCode
    case relays
    case identityManagement
    case settings
}

struct ContentView: View {
    @StateObject private var model = ClientViewModel()
    @StateObject private var screenProtection = ScreenProtectionMonitor()
    @State private var selection: SidebarItem?
    @State private var showingAddContact = false
    @State private var showIntro = !ProcessInfo.processInfo.arguments.contains("UI_TESTING")
    @State private var introOpacity = 1.0
    @State private var introScale: CGFloat = 1.0
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        let themeStyle = ThemeStyle(palette: model.state.appearance.theme)
        ZStack {
            #if os(iOS)
            WarningBackground()
            #else
            GlassBackground()
            #endif
            NavigationSplitView {
                sidebarView
            } detail: {
                detailView
            }
            #if os(iOS)
            .background(Color.clear)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarBackground(.hidden, for: .automatic)
            #endif
            .clearNavigationContainerBackground()
            .hideWindowToolbarIfNeeded()
            .secureContainerIfAvailable()
            #if os(iOS)
            HostingBackgroundClearer()
                .frame(width: 0, height: 0)
            #endif
            if showIntro {
                IntroOverlay(opacity: introOpacity, scale: introScale)
                    .allowsHitTesting(false)
            }
            if model.isLocked {
                AppLockView(model: model)
            }
            if model.requiresStorageChoice {
                StorageChoiceView { mode in
                    model.selectStorageProtection(mode)
                }
            }
            if let status = model.storageProtectionStatus {
                StorageStatusToast(message: status)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .environment(\.appTheme, themeStyle)
        .tint(themeStyle.accent)
        .environmentObject(screenProtection)
        .sheet(isPresented: $showingAddContact) {
            AddContactView(model: model)
        }
        .task(id: showIntro) {
            guard showIntro else { return }
            introOpacity = 1
            introScale = 1
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation(.easeIn(duration: 0.4)) {
                introOpacity = 0
                introScale = 0.98
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
            showIntro = false
        }
        .onAppear {
            screenProtection.refresh()
        }
        .onChange(of: scenePhase) { _, newValue in
            model.handleScenePhaseChange(newValue)
            if newValue == .active {
                screenProtection.refresh()
            }
        }
    }

    private var sidebarView: some View {
        List(selection: $selection) {
            #if os(macOS)
            SidebarHeader()
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            #endif

            Section("Contacts") {
                if screenProtection.isSensitiveHidden {
                    Label("Contacts hidden while capture is active", systemImage: "eye.slash")
                        .foregroundStyle(.secondary)
                } else {
                    if model.state.contacts.isEmpty {
                        Text("No contacts yet")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.state.contacts) { contact in
                        NavigationLink(value: SidebarItem.contact(contact.id)) {
                            HStack {
                                Label(contact.displayName, systemImage: "person.circle")
                                Spacer()
                                if unreadCount(for: contact) > 0 {
                                    UnreadBadge(count: unreadCount(for: contact))
                                }
                            }
                        }
                        .accessibilityIdentifier("contact-\(contact.id.uuidString)")
                        .contextMenu {
                            Button("Remove Contact", role: .destructive) {
                                Task { await model.removeContact(id: contact.id) }
                            }
                        }
                    }
                }
            }

            Section("Tools") {
                NavigationLink(value: SidebarItem.contactBook) {
                    Label("Contact Book", systemImage: "book.closed")
                }
                NavigationLink(value: SidebarItem.myCode) {
                    Label("My Code", systemImage: "qrcode")
                }
                NavigationLink(value: SidebarItem.relays) {
                    Label("Relays", systemImage: "antenna.radiowaves.left.and.right")
                }
                NavigationLink(value: SidebarItem.identityManagement) {
                    Label("Identity Management", systemImage: "person.badge.shield.checkmark")
                }
                NavigationLink(value: SidebarItem.settings) {
                    Label("Settings", systemImage: "gearshape")
                }
                .accessibilityIdentifier("sidebar-settings")
            }
        }
        #if os(macOS)
        .navigationTitle("")
        #else
        .navigationTitle("Lattice")
        #endif
        .scrollContentBackground(.hidden)
        .listRowBackground(Color.clear)
        .glassBackgroundIfNeeded()
        #if os(macOS)
        .listSectionSeparator(.hidden)
        .listRowSeparator(.hidden)
        .listStyle(.sidebar)
        .background(.ultraThinMaterial)
        #endif
        .privacySensitive()
    }

    @ViewBuilder
    private var detailView: some View {
        switch selection {
        case .contact(let contactId):
            if let contact = model.state.contacts.first(where: { $0.id == contactId }) {
                ConversationView(model: model, contact: contact)
            } else {
                PlaceholderView(title: "Select a contact")
            }
        case .myCode:
            MyCodeView(model: model)
        case .settings:
            SettingsView(model: model)
        case .relays:
            RelaysView(model: model)
        case .identityManagement:
            IdentityManagementView(model: model)
        case .contactBook:
            ContactBookView(model: model) { contactId in
                selection = .contact(contactId)
            } onAdd: {
                showingAddContact = true
            }
        case .none:
            PlaceholderView(title: "Select a contact")
        }
    }

    private func unreadCount(for contact: Contact) -> Int {
        model.state.conversation(for: contact.id)?.unreadCount ?? 0
    }

}

private struct IntroOverlay: View {
    let opacity: Double
    let scale: CGFloat

    var body: some View {
        VStack {
            WelcomeContent(title: "Welcome to Lattice", subtitle: "Post-quantum chat", imageSize: 300)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .opacity(opacity)
        .scaleEffect(scale)
    }
}

private struct SidebarHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Lattice")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
            Text("Post-quantum chat")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }
}

private struct PlaceholderView: View {
    let title: String
    let subtitle: String?

    init(title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(macOS)
        .navigationTitle("")
        #endif
    }
}

private struct SensitiveContentPlaceholder: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "eye.slash")
                .font(.system(size: 34, weight: .semibold))
            Text(title)
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .glassBackgroundIfNeeded()
    }
}


private struct WelcomeContent: View {
    let title: String
    let subtitle: String?
    let imageSize: CGFloat

    init(title: String, subtitle: String?, imageSize: CGFloat = 280) {
        self.title = title
        self.subtitle = subtitle
        self.imageSize = imageSize
    }

    var body: some View {
        VStack(spacing: 12) {
            Image("Rhombus")
                .resizable()
                .scaledToFit()
                .frame(width: imageSize, height: imageSize)
                .shadow(color: .white.opacity(0.2), radius: 12, x: 0, y: 8)
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct PaneHeader: View {
    let title: String
    var subtitle: String? = nil

    @ViewBuilder
    var body: some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 4)
        #else
        EmptyView()
        #endif
    }
}

private struct ConversationView: View {
    @ObservedObject var model: ClientViewModel
    let contact: Contact
    @State private var messageText = ""
    @State private var revealMessages = false
    @State private var showingClearChatConfirm = false
    @EnvironmentObject private var screenProtection: ScreenProtectionMonitor
    #if os(iOS)
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showingSecureCamera = false
    @State private var showingInsecureCamera = false
    @State private var showCameraChoiceAlert = false
    @AppStorage("lattice.secureCameraPromptShown.v1") private var secureCameraPromptShown = false
    #else
    @State private var showingAttachmentImporter = false
    #endif
    @Environment(\.appTheme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
    @FocusState private var isComposerFocused: Bool
    #endif

    var body: some View {
        let conversation = model.state.conversation(for: contact.id)
        let messages = conversation?.messages ?? []
        let isSensitiveHidden = screenProtection.isSensitiveHidden
        let isRevealed = revealMessages && !isSensitiveHidden
        VStack(spacing: 0) {
            #if os(macOS)
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    if isSensitiveHidden {
                        Text("Secure chat hidden")
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                        Text("Screen capture is active")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(contact.displayName)
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                        Text("Secure chat")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button {
                    showingClearChatConfirm = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 14, weight: .semibold))
                }
                .accessibilityLabel("Clear Chat")
                .glassCircleButton(diameter: 30)
                .hoverLift()
                RevealToggleButton(isRevealed: $revealMessages, isDisabled: isSensitiveHidden)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 4)
            #endif
            ScrollViewReader { proxy in
                List {
                    if !messages.isEmpty {
                        ForEach(messages) { message in
                            MessageRow(model: model, message: message, isRevealed: isRevealed, onRetry: message.isMismatch ? {
                                Task { await model.retryMismatch(contactId: contact.id) }
                            } : nil)
                                .id(message.id)
                                .contextMenu {
                                    Button("Delete Message", role: .destructive) {
                                        Task { await model.deleteMessage(contactId: contact.id, messageId: message.id) }
                                    }
                                }
                                #if os(iOS)
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        Task { await model.deleteMessage(contactId: contact.id, messageId: message.id) }
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                                #else
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        Task { await model.deleteMessage(contactId: contact.id, messageId: message.id) }
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                                #endif
                        }
                    } else {
                        Text("No messages yet")
                            .foregroundStyle(.secondary)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .glassBackgroundIfNeeded()
                .onAppear {
                    scrollToBottom(messages, proxy: proxy, animated: false)
                }
                .onChange(of: messages.count) { _, _ in
                    scrollToBottom(messages, proxy: proxy, animated: true)
                }
            }

            HStack(spacing: 8) {
                #if os(iOS)
                Button {
                    handleCameraButtonTap()
                } label: {
                    Image(systemName: "camera")
                        .font(.system(size: 14, weight: .semibold))
                }
                .accessibilityLabel("Capture Photo")
                .accessibilityHint("Enable in Settings > Privacy to capture within Lattice.")
                .glassCircleButton(diameter: 34)
                .hoverLift()
                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 14, weight: .semibold))
                }
                .accessibilityLabel("Attach Image")
                .glassCircleButton(diameter: 34)
                .hoverLift()
                #else
                Button {
                    showingAttachmentImporter = true
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 14, weight: .semibold))
                }
                .accessibilityLabel("Attach Image")
                .glassCircleButton(diameter: 34)
                .hoverLift()
                #endif
                #if os(iOS)
                MessageInputField(text: $messageText, secureTypingEnabled: model.state.privacy.secureTypingEnabled) {
                    sendMessage()
                }
                #else
                TextField("Message", text: $messageText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .submitLabel(.send)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .focused($isComposerFocused)
                    .onSubmit {
                        sendMessage()
                    }
                #endif
                Button {
                    sendMessage()
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 15, weight: .semibold))
                }
                .accessibilityLabel("Send")
                .glassCircleButton(prominent: true, diameter: 34)
                .hoverLift()
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            #if os(iOS)
            .background(Color.clear)
            #else
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            #endif
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
        }
        .glassBackgroundIfNeeded()
        .privacySensitive()
        #if os(iOS)
        .onChange(of: selectedPhoto) { _, newItem in
            guard let newItem else { return }
            Task { await handlePickedPhoto(newItem) }
        }
        .sheet(isPresented: $showingSecureCamera) {
            SecureCameraCaptureView(
                onCapture: { data in
                    Task {
                        await model.sendAttachment(
                            data: data,
                            fileName: "camera.jpg",
                            mimeType: "image/jpeg",
                            to: contact.id
                        )
                    }
                    showingSecureCamera = false
                },
                onCancel: {
                    showingSecureCamera = false
                }
            )
        }
        .sheet(isPresented: $showingInsecureCamera) {
            SystemCameraPickerView(
                onCapture: { data in
                    Task {
                        await model.sendAttachment(
                            data: data,
                            fileName: "camera.jpg",
                            mimeType: "image/jpeg",
                            to: contact.id
                        )
                    }
                    showingInsecureCamera = false
                },
                onCancel: {
                    showingInsecureCamera = false
                },
                onError: { message in
                    model.lastError = message
                    showingInsecureCamera = false
                }
            )
        }
        .alert("Use secure camera capture?", isPresented: $showCameraChoiceAlert) {
            Button("Use In-App Camera") {
                secureCameraPromptShown = true
                enableSecureCameraCapture()
                showingSecureCamera = true
            }
            Button("Use System Camera") {
                secureCameraPromptShown = true
                openInsecureCamera()
            }
            Button("Cancel", role: .cancel) {
                secureCameraPromptShown = true
            }
        } message: {
            Text("In-app capture keeps images out of Photos. The system camera may save to Photos and is more exposed to OS-level access.")
        }
        #else
        .fileImporter(
            isPresented: $showingAttachmentImporter,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    Task { await handleAttachmentURL(url) }
                }
            case .failure(let error):
                model.lastError = "Failed to import attachment: \(error.localizedDescription)"
            }
        }
        #endif
        .navigationTitle(isSensitiveHidden ? "Secure Chat" : contact.displayName)
        .toolbar {
            #if os(iOS)
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    showingClearChatConfirm = true
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("Clear Chat")
                RevealToggleButton(isRevealed: $revealMessages, isDisabled: isSensitiveHidden)
            }
            #endif
        }
        .confirmationDialog("Clear chat?", isPresented: $showingClearChatConfirm) {
            Button("Clear Chat", role: .destructive) {
                Task { await model.clearConversation(contactId: contact.id) }
            }
        } message: {
            Text("This removes messages from this device only and does not affect encryption or your contact.")
        }
        .onAppear {
            model.activeContactId = contact.id
            revealMessages = false
            screenProtection.refresh()
            #if os(macOS)
            updateSecureInput()
            #endif
            Task { await model.markConversationRead(contactId: contact.id) }
        }
        .onDisappear {
            if model.activeContactId == contact.id {
                model.activeContactId = nil
            }
            revealMessages = false
            #if os(macOS)
            SecureEventInputController.shared.setEnabled(false)
            #endif
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active {
                revealMessages = false
                #if os(macOS)
                SecureEventInputController.shared.setEnabled(false)
                #endif
            }
        }
        .onChange(of: screenProtection.isSensitiveHidden) { _, newValue in
            if newValue {
                revealMessages = false
            }
        }
        #if os(macOS)
        .onChange(of: isComposerFocused) { _, _ in
            updateSecureInput()
        }
        .onChange(of: model.state.privacy.secureTypingEnabled) { _, _ in
            updateSecureInput()
        }
        #endif
    }

    #if os(macOS)
    private func updateSecureInput() {
        let shouldEnable = model.state.privacy.secureTypingEnabled && isComposerFocused && scenePhase == .active
        SecureEventInputController.shared.setEnabled(shouldEnable)
    }
    #endif

    private func sendMessage() {
        let trimmed = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task { await model.sendMessage(text: trimmed, to: contact.id) }
        messageText = ""
    }

    #if os(iOS)
    private func handleCameraButtonTap() {
        if model.state.privacy.useSecureCameraCapture {
            showingSecureCamera = true
            return
        }
        if !secureCameraPromptShown {
            showCameraChoiceAlert = true
            return
        }
        openInsecureCamera()
    }

    private func openInsecureCamera() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            model.lastError = "Camera is not available on this device."
            return
        }
        showingInsecureCamera = true
    }

    private func enableSecureCameraCapture() {
        var settings = model.state.privacy
        settings.useSecureCameraCapture = true
        Task { await model.updatePrivacy(settings) }
    }

    private func handlePickedPhoto(_ item: PhotosPickerItem) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { return }
            let mimeType = item.supportedContentTypes.first?.preferredMIMEType ?? "image/jpeg"
            await model.sendAttachment(data: data, fileName: nil, mimeType: mimeType, to: contact.id)
        } catch {
            await MainActor.run {
                model.lastError = "Failed to load photo: \(error.localizedDescription)"
            }
        }
        await MainActor.run {
            selectedPhoto = nil
        }
    }
    #else
    private func handleAttachmentURL(_ url: URL) async {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            let data = try Data(contentsOf: url)
            let fileName = url.lastPathComponent
            let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "image/jpeg"
            await model.sendAttachment(data: data, fileName: fileName, mimeType: mimeType, to: contact.id)
        } catch {
            await MainActor.run {
                model.lastError = "Failed to read attachment: \(error.localizedDescription)"
            }
        }
    }
    #endif

    private func scrollToBottom(_ messages: [Message], proxy: ScrollViewProxy, animated: Bool) {
        guard let last = messages.last else { return }
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }
}

private struct MessageRow: View {
    @ObservedObject var model: ClientViewModel
    let message: Message
    let isRevealed: Bool
    let onRetry: (() -> Void)?
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack {
            if message.direction == .received {
                bubble
                Spacer()
            } else {
                Spacer()
                bubble
            }
        }
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            if message.isMismatch {
                HStack(spacing: 8) {
                    MismatchInlineBadge()
                    if let onRetry {
                        Button("Retry") {
                            onRetry()
                        }
                        .font(.caption2)
                        .glassButton()
                        .hoverLift()
                    }
                }
            }
            if let attachment = message.attachment {
                AttachmentBubble(
                    model: model,
                    attachment: attachment,
                    title: message.body,
                    isRevealed: isRevealed
                )
            } else {
                Text(messageText)
                    .foregroundStyle(isRevealed ? .primary : .secondary)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(bubbleTint.opacity(0.22))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.55),
                                    Color.white.opacity(0.08)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.8
                        )
                )
        )
    }

    private var bubbleTint: Color {
        if message.isMismatch {
            return Color.orange
        }
        return message.direction == .received ? theme.bubbleReceived : theme.bubbleSent
    }

    private var messageText: String {
        if isRevealed {
            return message.body
        }
        return message.isMismatch ? "Mismatched message" : "Hidden message"
    }
}

private struct AttachmentBubble: View {
    @ObservedObject var model: ClientViewModel
    let attachment: AttachmentInfo
    let title: String
    let isRevealed: Bool
    @State private var image: Image?
    @State private var isLoading = false
    @State private var didFail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            attachmentPreview
            Text(title)
                .font(.callout)
                .foregroundStyle(isRevealed ? .primary : .secondary)
            Text(sizeLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .onAppear {
            loadImageIfNeeded()
        }
        .onChange(of: attachment.localFileName) { _, _ in
            image = nil
            didFail = false
            loadImageIfNeeded()
        }
        .onChange(of: isRevealed) { _, newValue in
            if newValue {
                loadImageIfNeeded()
            }
        }
    }

    private var attachmentPreview: some View {
        let size = previewSize
        return ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.08))
            if !isRevealed {
                Text("Hidden attachment")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let image {
                image
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipped()
            } else if isLoading {
                ProgressView()
            } else {
                Text(didFail ? "Attachment unavailable" : "Loading")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var previewSize: CGFloat {
        #if os(macOS)
        return 220
        #else
        return 180
        #endif
    }

    private var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(attachment.descriptor.byteCount), countStyle: .file)
    }

    private func loadImageIfNeeded() {
        guard isRevealed else { return }
        guard image == nil, !isLoading, !didFail else { return }
        guard let fileName = attachment.localFileName else {
            didFail = true
            return
        }
        isLoading = true
        Task {
            let data = await model.loadAttachmentData(fileName: fileName)
            await MainActor.run {
                defer { isLoading = false }
                guard let data, let image = makeImage(from: data) else {
                    didFail = true
                    return
                }
                self.image = image
            }
        }
    }

    private func makeImage(from data: Data) -> Image? {
        #if os(iOS)
        guard let uiImage = UIImage(data: data) else { return nil }
        return Image(uiImage: uiImage)
        #else
        guard let nsImage = NSImage(data: data) else { return nil }
        return Image(nsImage: nsImage)
        #endif
    }
}

private struct RevealToggleButton: View {
    @Binding var isRevealed: Bool
    var isDisabled: Bool = false

    var body: some View {
        Button {
            isRevealed.toggle()
        } label: {
            Image(systemName: isRevealed ? "eye" : "eye.slash")
                .font(.system(size: 14, weight: .semibold))
        }
        .accessibilityLabel(isRevealed ? "Hide Messages" : "Reveal Messages")
        .accessibilityIdentifier("reveal-toggle")
        .glassCircleButton(diameter: 32)
        .hoverLift()
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.5 : 1.0)
    }
}

#if os(macOS)
private final class SecureEventInputController {
    static let shared = SecureEventInputController()
    private var isEnabled = false

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled {
            EnableSecureEventInput()
        } else {
            DisableSecureEventInput()
        }
    }
}
#endif

#if os(iOS)
private struct MessageInputField: View {
    @Binding var text: String
    let secureTypingEnabled: Bool
    let onSubmit: () -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        ZStack(alignment: .leading) {
            if text.isEmpty {
                Text("Message")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .padding(.leading, 8)
            }
            UIKitMessageInput(text: $text, secureTypingEnabled: secureTypingEnabled, onSubmit: onSubmit)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .padding(.horizontal, 2)
        }
        .frame(height: 42)
        .background(Color.clear)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 0.8)
        )
    }
}

private struct UIKitMessageInput: UIViewRepresentable {
    @Binding var text: String
    let secureTypingEnabled: Bool
    let onSubmit: () -> Void

    func makeUIView(context: Context) -> UITextView {
        let view = CenteredTextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.isOpaque = false
        view.textColor = .label
        view.font = UIFont.preferredFont(forTextStyle: .body)
        view.isScrollEnabled = true
        view.textContainerInset = .zero
        view.textContainer.maximumNumberOfLines = 2
        view.textContainer.lineBreakMode = .byTruncatingTail
        view.textContainer.lineFragmentPadding = 0
        view.returnKeyType = .send
        view.keyboardDismissMode = .interactive
        applyPrivacyTraits(to: view)
        view.text = text
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }
        applyPrivacyTraits(to: uiView)
        uiView.setNeedsLayout()
    }

    private func applyPrivacyTraits(to view: UITextView) {
        view.isSecureTextEntry = secureTypingEnabled
        view.autocorrectionType = secureTypingEnabled ? .no : .default
        view.spellCheckingType = secureTypingEnabled ? .no : .default
        view.autocapitalizationType = secureTypingEnabled ? .none : .sentences
        view.smartQuotesType = secureTypingEnabled ? .no : .default
        view.smartDashesType = secureTypingEnabled ? .no : .default
        view.textContentType = secureTypingEnabled ? .none : nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        private let parent: UIKitMessageInput

        init(_ parent: UIKitMessageInput) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard text == "\n" else { return true }
            let trimmed = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
            parent.text = textView.text
            if !trimmed.isEmpty {
                parent.onSubmit()
            }
            return false
        }
    }
}

private final class CenteredTextView: UITextView {
    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.height > 0 else { return }
        layoutManager.ensureLayout(for: textContainer)
        let contentHeight = layoutManager.usedRect(for: textContainer).height
        let verticalInset = max((bounds.height - contentHeight) / 2, 0)
        let newInset = UIEdgeInsets(top: verticalInset, left: 0, bottom: verticalInset, right: 0)
        if textContainerInset != newInset {
            textContainerInset = newInset
        }
    }
}
#endif

private struct UnreadBadge: View {
    let count: Int

    var body: some View {
        Text("\(min(count, 99))")
            .font(.caption2)
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(Color.red)
            )
    }
}

private struct MismatchInlineBadge: View {
    var body: some View {
        Text("Mismatch")
            .font(.caption2)
            .foregroundStyle(.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(Color.orange.opacity(0.2))
            )
    }
}

private struct StorageStatusToast: View {
    let message: String

    var body: some View {
        VStack {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 14, weight: .semibold))
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .opacity(0.95)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12))
            )
            Spacer()
        }
        .padding(.top, 16)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct MyCodeView: View {
    @ObservedObject var model: ClientViewModel
    @EnvironmentObject private var screenProtection: ScreenProtectionMonitor
    @State private var code = ""
    @State private var sharePassword = ""
    @State private var exportDocument = ContactShareDocument(data: Data())
    @State private var showingExporter = false
    @State private var qrFrames: [String] = []
    @State private var showingFullScreenQR = false
    @State private var showingShareSheet = false
    @State private var shareURL: URL?
    @State private var showingCode = false

    var body: some View {
        Group {
            if screenProtection.isSensitiveHidden {
                SensitiveContentPlaceholder(
                    title: "My Code Hidden",
                    message: "Screen capture or an external display is active. Your contact code is hidden to protect your OPSEC."
                )
            } else {
                codeContent
            }
        }
        .navigationTitle("My Code")
        .onChange(of: screenProtection.isSensitiveHidden) { _, newValue in
            if newValue {
                showingExporter = false
                showingFullScreenQR = false
                showingShareSheet = false
                showingCode = false
            }
        }
    }

    private var codeContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                #if os(macOS)
                PaneHeader(title: "My Code")
                #endif
                Text("Share your contact code or export a password-protected file.")
                    .font(.headline)

                VStack(spacing: 8) {
                    if qrFrames.count > 1 {
                        AnimatedQRCodeView(frames: qrFrames, size: 260, interval: 0.7)
                        Text("Animated QR (scan frames in order)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        QRCodeView(text: code, size: 260)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Password-Protected Share")
                        .font(.subheadline.weight(.semibold))
                    Text("Create a file share or AirDrop payload protected by a password.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    SecureField("Password", text: $sharePassword)
                    HStack {
                        Button("Export File") {
                            Task {
                                guard !sharePassword.isEmpty else {
                                    model.lastError = "Password required for export."
                                    return
                                }
                                if let data = await model.contactShareData(password: sharePassword) {
                                    exportDocument = ContactShareDocument(data: data)
                                    showingExporter = true
                                }
                            }
                        }
                        .glassButton(prominent: true)
                        .disabled(sharePassword.isEmpty)
                        .hoverLift()
                        Button("Share via AirDrop") {
                            Task {
                                await prepareAirDropShare()
                            }
                        }
                        .glassButton()
                        .disabled(sharePassword.isEmpty)
                        .hoverLift()
                    }
                    Text("Use Import File on the other device to accept an AirDrop share.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12))
                )

                Text("Contact Code")
                    .font(.subheadline)
                if showingCode {
                    TextEditor(text: $code)
                        .font(.callout)
                        .frame(minHeight: 180)
                        .border(Color.gray.opacity(0.3))
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Contact code hidden.")
                            .font(.callout.weight(.semibold))
                        Text("Reveal to show the full share string.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 16)
                    .padding(.horizontal, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(.ultraThinMaterial)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.12))
                    )
                }

                HStack {
                    Button(showingCode ? "Hide" : "Reveal") {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            showingCode.toggle()
                        }
                    }
                    .glassButton()
                    .hoverLift()
                    Button("Copy") {
                        Clipboard.copy(code)
                        model.lastInfo = "Copied contact code."
                    }
                    .glassButton()
                    .hoverLift()
                    Button("Refresh") {
                        refreshCode()
                    }
                    .glassButton()
                    .hoverLift()
                    #if os(iOS)
                    Button("Full Screen QR") {
                        showingFullScreenQR = true
                    }
                    .glassButton()
                    .hoverLift()
                    #endif
                }

                Text("Refresh regenerates the share code and QR frames from your current identity and relay. It does not rotate keys.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .privacySensitive()
        .onAppear {
            refreshCode()
            showingCode = false
        }
        .fileExporter(
            isPresented: $showingExporter,
            document: exportDocument,
            contentType: .piccpContactShare,
            defaultFilename: "piccp-contact"
        ) { result in
            switch result {
            case .success:
                model.lastInfo = "Contact file exported."
            case .failure(let error):
                model.lastError = "Export failed: \(error.localizedDescription)"
            }
        }
        .sheet(isPresented: $showingFullScreenQR) {
            FullScreenQRView(frames: qrFrames, code: code)
        }
        #if os(iOS)
        .sheet(isPresented: $showingShareSheet) {
            if let shareURL {
                ShareSheet(activityItems: [shareURL])
            }
        }
        #elseif os(macOS)
        .background(
            ShareSheet(items: shareURL.map { [$0] } ?? [], isPresented: $showingShareSheet)
        )
        #endif
    }

    private func refreshCode() {
        code = model.contactOfferCode()
        qrFrames = QRCodeTransfer.encodeFrames(code, maxChunkSize: 360)
    }

    private func prepareAirDropShare() async {
        guard !sharePassword.isEmpty else {
            model.lastError = "Password required for AirDrop."
            return
        }
        guard let data = await model.contactShareData(password: sharePassword) else {
            return
        }
        do {
            let url = try writeShareFile(data: data)
            shareURL = url
            showingShareSheet = true
        } catch {
            model.lastError = "Failed to prepare AirDrop file: \(error.localizedDescription)"
        }
    }

    private func writeShareFile(data: Data) throws -> URL {
        let filename = "piccp-contact-\(UUID().uuidString).piccp"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try data.write(to: url, options: [.atomic])
        return url
    }
}

private struct AddContactView: View {
    @ObservedObject var model: ClientViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var method: PairingMethod = .scanQR
    @State private var code = ""
    @State private var sharePassword = ""
    @State private var insecureSettings = InsecurePairingSettings()
    @State private var showingImporter = false
    @State private var showingScanner = false
    @State private var qrCollector = QRChunkCollector()
    @State private var qrProgress = ""
    @State private var importedFileData: Data?
    @State private var importedFileName: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Pairing Method") {
                    Picker("Method", selection: $method) {
                        ForEach(PairingMethod.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                switch method {
                case .scanQR:
                    Section("Scan QR") {
                        Button("Scan QR Code") {
                            showingScanner = true
                        }
                        .hoverLift()
                        if !qrProgress.isEmpty {
                            Text(qrProgress)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                case .pasteCode:
                    Section("Contact Code") {
                        TextEditor(text: $code)
                            .frame(minHeight: 160)
                        Button("Add Contact") {
                            Task {
                                await model.addContact(code: code)
                                dismiss()
                            }
                        }
                        .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .hoverLift()
                    }
                case .importFile:
                    Section("Contact File") {
                        Button("Choose File") {
                            showingImporter = true
                        }
                        .hoverLift()
                        if let importedFileName {
                            Text("Selected: \(importedFileName)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        SecureField("Password", text: $sharePassword)
                        Button("Import Selected File") {
                            Task {
                                guard let data = importedFileData else {
                                    model.lastError = "No file selected."
                                    return
                                }
                                guard !sharePassword.isEmpty else {
                                    model.lastError = "Password required to import."
                                    return
                                }
                                await model.addContact(shareData: data, password: sharePassword)
                                dismiss()
                            }
                        }
                        .disabled(importedFileData == nil)
                        .hoverLift()
                    }
                case .insecure:
                    insecurePairingView
                }
            }
            .navigationTitle("Add Contact")
            .scrollContentBackground(.hidden)
            .glassBackgroundIfNeeded()
            #if os(macOS)
            .formStyle(.grouped)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .hoverLift()
                }
            }
            .onAppear {
                insecureSettings = model.state.insecurePairing
            }
            .onChange(of: insecureSettings) { _, newValue in
                Task { await model.updateInsecurePairing(newValue) }
            }
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: [.piccpContactShare, .data]
            ) { result in
                switch result {
                case .success(let url):
                    Task {
                        do {
                            let scoped = url.startAccessingSecurityScopedResource()
                            defer {
                                if scoped {
                                    url.stopAccessingSecurityScopedResource()
                                }
                            }
                            let data = try Data(contentsOf: url)
                            importedFileData = data
                            importedFileName = url.lastPathComponent
                        } catch {
                            model.lastError = "Failed to read contact file: \(error.localizedDescription)"
                        }
                    }
                case .failure(let error):
                    model.lastError = "Import failed: \(error.localizedDescription)"
                }
            }
            .sheet(isPresented: $showingScanner) {
                NavigationStack {
                    QRCodeScannerView(onScan: { scanned in
                        let result = qrCollector.consume(scanned)
                        switch result {
                        case .single(let value):
                            code = value
                            qrProgress = ""
                            showingScanner = false
                            Task {
                                await model.addContact(code: value)
                                dismiss()
                            }
                        case .partial(_, let received, let total):
                            qrProgress = "Scanned \(received) / \(total) frames"
                        case .complete(let value):
                            code = value
                            qrProgress = ""
                            showingScanner = false
                            Task {
                                await model.addContact(code: value)
                                dismiss()
                            }
                        case .invalid:
                            qrProgress = "Invalid QR sequence."
                        }
                    }, onError: { message in
                        showingScanner = false
                        model.lastError = message
                    }, allowsMultiple: true)
                    .padding()
                    .navigationTitle("Scan QR")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { showingScanner = false }
                                .hoverLift()
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var insecurePairingView: some View {
        let formattedDate: (Date?) -> String = { date in
            date?.formatted(date: .abbreviated, time: .shortened) ?? "Never"
        }

        Section("Insecure Pairing") {
            Toggle("Enable insecure pairing", isOn: $insecureSettings.isEnabled)
            Toggle("I understand pairing can be intercepted", isOn: $insecureSettings.acknowledgeInterceptRisk)
                .disabled(!insecureSettings.isEnabled)
            Toggle("Allow inbound pairing requests", isOn: $insecureSettings.allowInboundRequests)
                .disabled(!insecureSettings.isEnabled || !insecureSettings.acknowledgeInterceptRisk)
            Text("Only enable this if you accept that pairing metadata is sent in clear.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("Pairing Channel") {
            Picker("Method", selection: Binding(
                get: { insecureSettings.method ?? .relay },
                set: { newValue in
                    insecureSettings.method = newValue
                }
            )) {
                ForEach(InsecurePairingMethod.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .disabled(!insecureSettings.isReady)

            if insecureSettings.method == .bluetooth {
                Text("Bluetooth discovery is coming soon.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if insecureSettings.method == .localNetwork {
                Text("Local pairing uses your current relay. Set it to a LAN relay to discover peers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        if insecureSettings.isReady {
            Section("Status") {
                VStack(alignment: .leading, spacing: 6) {
                    let relay = model.insecureLastRelay ?? model.state.relay
                    Text("Relay: \(relay.host):\(relay.port)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Announced: \(formattedDate(model.insecureLastAnnounceAt))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("Last discovery: \(formattedDate(model.insecureLastListAt))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("Peers found: \(model.insecureLastPeerCount)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if model.state.insecurePairing.allowInboundRequests {
                        Text("Requests fetched: \(formattedDate(model.insecureLastRequestFetchAt))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("Requests pending: \(model.insecureLastRequestCount)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text("Self-test: \(formattedDate(model.insecureLastSelfTestAt))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    let result = model.insecureLastSelfTestResult ?? "Not run"
                    let isFailure = result != "OK" && result != "Not run"
                    Text("Self-test result: \(result)")
                        .font(.caption2)
                        .foregroundStyle(isFailure ? .orange : .secondary)
                    if let step = model.insecureSelfTestStep {
                        Text("Self-test step: \(step)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let error = model.insecureLastError {
                        Text("Last error: \(error)")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    Text("Your fingerprint: \(model.state.identity.fingerprint)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .contextMenu {
                    Button("Run Self Test") {
                        FeedbackGenerator.light()
                        Task { await model.runInsecurePairingSelfTest() }
                    }
                }
            }
            Section("Discovery") {
                HStack {
                    Button("Announce") {
                        FeedbackGenerator.light()
                        Task { await model.announceInsecurePairing() }
                    }
                    .glassButton()
                    .hoverLift()
                    Button("Refresh List") {
                        FeedbackGenerator.light()
                        Task { await model.refreshInsecurePairing() }
                    }
                    .glassButton()
                    .hoverLift()
                }
            }

            Section("Discovered Peers") {
                if model.insecureAnnouncements.isEmpty {
                    Text("No peers found")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.insecureAnnouncements) { announcement in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(announcement.offer.displayName)
                            .font(.headline)
                        Text("Relay: \(announcement.offer.relay.host):\(announcement.offer.relay.port)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Send Pairing Request") {
                            Task { await model.sendPairRequest(to: announcement) }
                        }
                        .glassButton(prominent: true)
                        .hoverLift()
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("Incoming Requests") {
                if model.insecureRequests.isEmpty {
                    Text("No incoming requests")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.insecureRequests) { request in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(request.from.displayName)
                            .font(.headline)
                        Text("Relay: \(request.from.relay.host):\(request.from.relay.port)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Accept") {
                                Task { await model.acceptPairRequest(request) }
                            }
                            .glassButton(prominent: true)
                            .hoverLift()
                            Button("Dismiss") {
                                model.dismissPairRequest(request)
                            }
                            .glassButton()
                            .hoverLift()
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        } else {
            Section {
                Text("Complete the acknowledgements to enable discovery.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private enum PairingMethod: String, CaseIterable, Identifiable {
    case scanQR
    case pasteCode
    case importFile
    case insecure

    var id: String { rawValue }

    var title: String {
        switch self {
        case .scanQR:
            return "Scan QR"
        case .pasteCode:
            return "Paste Code"
        case .importFile:
            return "Import File"
        case .insecure:
            return "Insecure"
        }
    }
}

private struct FullScreenQRView: View {
    let frames: [String]
    let code: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if frames.count > 1 {
                    AnimatedQRCodeView(frames: frames, size: 320, interval: 0.8)
                    Text("Animated QR (scan frames in order)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    QRCodeView(text: code, size: 320)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.02))
            .navigationTitle("Full Screen QR")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .hoverLift()
                }
            }
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var model: ClientViewModel
    @State private var selectedTheme: ThemePalette = .glacier
    @State private var privacySettings = PrivacySettings()
    @State private var appLockSettings = AppLockSettings()
    @State private var storageMode: StorageProtectionMode = .keychain
    @State private var pendingStorageMode: StorageProtectionMode?
    @State private var showStorageWarning = false
    @State private var pinSetupKind: PinSetupKind?

    var body: some View {
        #if os(macOS)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PaneHeader(title: "Settings")
                GroupBox("Appearance") {
                    appearanceFields
                }
                GroupBox("Storage Protection") {
                    storageFields
                }
                GroupBox("Privacy") {
                    privacyFields
                }
                GroupBox("App Lock") {
                    appLockFields
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .navigationTitle("Settings")
        .groupBoxStyle(GlassGroupBoxStyle())
        .background(setupAppearance)
        #else
        Form {
            appearanceSection
            storageSection
            privacySection
            appLockSection
        }
        .navigationTitle("Settings")
        .scrollContentBackground(.hidden)
        .glassBackgroundIfNeeded()
        .background(setupAppearance)
        #endif
    }

    private var setupAppearance: some View {
        Color.clear
            .onAppear {
                selectedTheme = model.state.appearance.theme
                privacySettings = model.state.privacy
                appLockSettings = model.state.appLock
                storageMode = model.storageProtectionMode
            }
            .onChange(of: selectedTheme) { _, newValue in
                Task { await model.updateTheme(newValue) }
            }
            .onChange(of: storageMode) { _, newValue in
                if newValue == .deviceOnly, model.storageProtectionMode == .keychain {
                    pendingStorageMode = newValue
                    storageMode = model.storageProtectionMode
                    showStorageWarning = true
                } else {
                    Task { await model.updateStorageProtectionMode(newValue) }
                }
            }
            .onChange(of: privacySettings) { _, newValue in
                Task { await model.updatePrivacy(newValue) }
            }
            .onChange(of: appLockSettings.mode) { _, _ in
                Task { await model.updateAppLock(appLockSettings) }
            }
            .onChange(of: appLockSettings.sessionTimeoutMinutes) { _, _ in
                Task { await model.updateAppLock(appLockSettings) }
            }
            .onChange(of: model.state.appLock) { _, newValue in
                appLockSettings = newValue
            }
            .onChange(of: model.storageProtectionMode) { _, newValue in
                storageMode = newValue
            }
            .alert("Switch to Device Only?", isPresented: $showStorageWarning) {
                Button("Switch", role: .destructive) {
                    if let pendingStorageMode {
                        Task { await model.updateStorageProtectionMode(pendingStorageMode) }
                    }
                    pendingStorageMode = nil
                }
                Button("Cancel", role: .cancel) {
                    pendingStorageMode = nil
                }
            } message: {
                Text("Device-only storage disables Keychain encryption for local data and attachments. You can switch back later in Settings.")
            }
            .sheet(item: $pinSetupKind) { kind in
                PinSetupView(
                    title: kind.title,
                    subtitle: kind.subtitle,
                    onComplete: { pin in
                        let success: Bool
                        switch kind {
                        case .unlock:
                            success = await model.setAppLockPin(pin)
                        case .burnIdentity:
                            success = await model.setActionPin(pin, action: .burnIdentity)
                        case .clearChats:
                            success = await model.setActionPin(pin, action: .clearChats)
                        }
                        if success {
                            appLockSettings = model.state.appLock
                            pinSetupKind = nil
                        }
                        return success
                    },
                    onCancel: {
                        pinSetupKind = nil
                    }
                )
            }
    }

    @ViewBuilder
    private var appearanceSection: some View {
        Section("Appearance") {
            appearanceFields
        }
    }

    @ViewBuilder
    private var privacySection: some View {
        Section("Privacy") {
            privacyFields
        }
    }

    @ViewBuilder
    private var storageSection: some View {
        Section("Storage Protection") {
            storageFields
        }
    }

    @ViewBuilder
    private var appLockSection: some View {
        Section("App Lock") {
            appLockFields
        }
    }

    @ViewBuilder
    private var appearanceFields: some View {
        let columns = [GridItem(.adaptive(minimum: 140), spacing: 12)]
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(ThemePalette.allCases) { palette in
                    ThemeSwatch(palette: palette, isSelected: palette == selectedTheme) {
                        selectedTheme = palette
                    }
                }
            }
            Text("Applies instantly and syncs across all chat views.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var privacyFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Secure typing", isOn: $privacySettings.secureTypingEnabled)
                .accessibilityIdentifier("secure-typing-toggle")
            Text("Uses secure input where supported to reduce keylogging and OS-level text capture. Some third-party keyboards may ignore this.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Use in-app camera capture", isOn: $privacySettings.useSecureCameraCapture)
            Text("Captures images inside Lattice without saving to Photos. This adds a camera button in chats. The OS camera stack can still access raw frames.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("If disabled, the camera button will use the system camera which may store photos in your library.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var storageFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Type", selection: $storageMode) {
                ForEach(StorageProtectionMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.menu)
            Text(storageMode.descriptionText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Changing this re-encrypts local state and attachments. Leave the app open until it finishes.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let status = model.storageProtectionStatus {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var appLockFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Unlock method", selection: $appLockSettings.mode) {
                ForEach(AppLockMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.menu)
            Text("Locks the app when switching tabs or after a timeout. Biometrics do not allow password fallback.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Session timeout", selection: $appLockSettings.sessionTimeoutMinutes) {
                Text("Immediate").tag(0)
                Text("1 minute").tag(1)
                Text("5 minutes").tag(5)
                Text("15 minutes").tag(15)
                Text("30 minutes").tag(30)
                Text("60 minutes").tag(60)
            }
            .pickerStyle(.menu)

            if appLockSettings.mode == .biometricsAndPin || appLockSettings.mode == .pinOnly {
                if appLockSettings.isPinConfigured {
                    Text("PIN set. Enter a new PIN to update.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("PIN required to activate this mode.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("PINs are 6 digits and numbers only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(appLockSettings.isPinConfigured ? "Update PIN" : "Set PIN") {
                    pinSetupKind = .unlock
                }
                .glassButton(prominent: true)
                .hoverLift()
                pinActionsFields
            }
        }
    }

    private var pinActionsFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pin Actions")
                .font(.headline)
            Text("Optional action PINs can trigger emergency actions without unlocking the app.")
                .font(.caption)
                .foregroundStyle(.secondary)

            pinActionSection(
                title: "Burn Identity PIN",
                isConfigured: model.state.appLock.burnPinHash != nil,
                action: .burnIdentity,
                kind: .burnIdentity
            )

            pinActionSection(
                title: "Clear Chats PIN",
                isConfigured: model.state.appLock.clearChatsPinHash != nil,
                action: .clearChats,
                kind: .clearChats
            )
        }
        .padding(.top, 6)
    }

    private func pinActionSection(
        title: String,
        isConfigured: Bool,
        action: AppLockPinAction,
        kind: PinSetupKind
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(isConfigured ? "PIN set." : "No PIN set.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button(isConfigured ? "Update" : "Set") {
                    pinSetupKind = kind
                }
                .glassButton(prominent: true, compact: true)
                Button("Clear") {
                    Task { await model.clearActionPin(action) }
                }
                .glassButton(compact: true)
            }
        }
    }
}

private struct IdentityManagementView: View {
    @ObservedObject var model: ClientViewModel
    @EnvironmentObject private var screenProtection: ScreenProtectionMonitor
    @State private var destination: IdentityDestination?
    @State private var newIdentityName = ""
    @State private var newIdentityRelayId: UUID?

    var body: some View {
        Group {
            if screenProtection.isSensitiveHidden {
                SensitiveContentPlaceholder(
                    title: "Identity Management Hidden",
                    message: "Screen capture or an external display is active. Identity details are hidden to protect your OPSEC."
                )
            } else {
                destinationContent
            }
        }
        .navigationTitle("Identity Management")
        .onAppear {
            if newIdentityRelayId == nil {
                newIdentityRelayId = model.state.relayServers.first?.id
            }
        }
    }

    private enum IdentityDestination: Hashable {
        case audit
        case profile(UUID)
    }

    @ViewBuilder
    private var destinationContent: some View {
        switch destination {
        case .audit:
            IdentityAuditView(model: model) {
                destination = nil
            }
        case .profile(let profileId):
            IdentityDetailView(model: model, profileId: profileId) {
                destination = nil
            }
        case .none:
            identityContent
        }
    }

    @ViewBuilder
    private var identityContent: some View {
        #if os(macOS)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PaneHeader(title: "Identity Management", subtitle: "Manage key continuity and full resets")
                GroupBox("Identity Book") {
                    identityBookSection
                }
                GroupBox("Continuity Audit") {
                    continuityAuditLink
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .privacySensitive()
        .groupBoxStyle(GlassGroupBoxStyle())
        .glassBackgroundIfNeeded()
        #else
        Form {
            Section("Identity Book") {
                identityBookSection
            }
            Section("Continuity Audit") {
                continuityAuditLink
            }
        }
        .privacySensitive()
        .scrollContentBackground(.hidden)
        .glassBackgroundIfNeeded()
        #endif
    }

    private var identityBookSection: some View {
        let ordered = model.state.identityProfiles.sorted { lhs, rhs in
            if lhs.isArchived != rhs.isArchived {
                return !lhs.isArchived
            }
            if lhs.id == model.state.activeIdentityId {
                return true
            }
            if rhs.id == model.state.activeIdentityId {
                return false
            }
            return lhs.createdAt > rhs.createdAt
        }

        return VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(ordered.enumerated()), id: \.element.id) { index, profile in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(profile.identity.displayName)
                                .font(.headline)
                            Text(shortFingerprint(profile.identity.fingerprint))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if profile.id == model.state.activeIdentityId {
                            Text("Active")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Color.white.opacity(0.15)))
                        } else if profile.isArchived {
                            Text("Archived")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Color.white.opacity(0.12)))
                        }
                        syncBadge(for: profile)
                    }
                    if model.state.relayServers.isEmpty {
                        Text("Add a relay to set a home relay for this identity.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Home Relay", selection: relaySelectionBinding(for: profile)) {
                            ForEach(model.state.relayServers) { server in
                                Text(server.displayName).tag(Optional(server.id))
                            }
                        }
                        .disabled(profile.isArchived)
                        #if os(macOS)
                        .pickerStyle(.menu)
                        #endif
                    }
                }
                .cardButtonStyle()
                .onTapGesture {
                    destination = .profile(profile.id)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Add Identity")
                    .font(.subheadline.weight(.semibold))
                Text("Inactive identities remain encrypted at rest per your storage protection choice.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Display name", text: $newIdentityName)
                if !model.state.relayServers.isEmpty {
                    Picker("Home Relay", selection: $newIdentityRelayId) {
                        ForEach(model.state.relayServers) { server in
                            Text(server.displayName).tag(Optional(server.id))
                        }
                    }
                    #if os(macOS)
                    .pickerStyle(.menu)
                    #endif
                }
                Button("Create Identity") {
                    Task {
                        await model.addIdentityProfile(displayName: newIdentityName, relayId: newIdentityRelayId)
                        newIdentityName = ""
                    }
                }
                .glassButton(prominent: true)
                .hoverLift()
            }
        }
    }

    @ViewBuilder
    private func syncBadge(for profile: IdentityProfile) -> some View {
        if !profile.isArchived, let status = model.profileSyncStatus[profile.id] {
            let badge = syncBadgeData(for: status)
            if let badge {
                #if os(macOS)
                Text(badge.text)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .foregroundStyle(badge.color)
                    .background(Capsule().fill(badge.color.opacity(0.18)))
                    .help(badge.help)
                #else
                Text(badge.text)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .foregroundStyle(badge.color)
                    .background(Capsule().fill(badge.color.opacity(0.18)))
                #endif
            }
        }
    }

    private func syncBadgeData(for status: ProfileSyncState) -> (text: String, color: Color, help: String)? {
        switch status {
        case .idle:
            return nil
        case .syncing:
            return ("Syncing", .blue, "")
        case .success(let date):
            let relative = Self.syncFormatter.localizedString(for: date, relativeTo: Date())
            return ("Synced \(relative)", .green, "")
        case .error(_, let message):
            return ("Sync Error", .red, message)
        }
    }

    private static let syncFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    private var continuityAuditLink: some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: 8) {
            Text("Review rotation history, trust assertions, and identity continuity events.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(continuityEventCount) events recorded for the active identity.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button("Open Continuity Audit") {
                destination = .audit
            }
            .glassButton(prominent: true, compact: true)
            .hoverLift()
        }
        #else
        VStack(alignment: .leading, spacing: 8) {
            Button {
                destination = .audit
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Continuity Audit")
                        .font(.headline)
                    Text("\(continuityEventCount) events recorded for the active identity.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        #endif
    }

    private func relaySelectionBinding(for profile: IdentityProfile) -> Binding<UUID?> {
        Binding(
            get: {
                model.state.identityProfile(id: profile.id)?.selectedRelayId ?? model.state.relayServers.first?.id
            },
            set: { newValue in
                Task { await model.updateIdentityRelay(profileId: profile.id, relayId: newValue) }
            }
        )
    }

    private var continuityEventCount: Int {
        model.state.identityProfile(id: model.state.activeIdentityId)?.continuityEvents.count ?? 0
    }
}

private struct IdentityAuditView: View {
    @ObservedObject var model: ClientViewModel
    @EnvironmentObject private var screenProtection: ScreenProtectionMonitor
    let onBack: () -> Void
    @State private var showingPurgeConfirm = false

    var body: some View {
        Group {
            if screenProtection.isSensitiveHidden {
                SensitiveContentPlaceholder(
                    title: "Continuity Audit Hidden",
                    message: "Screen capture or an external display is active. Audit details are hidden to protect your OPSEC."
                )
            } else {
                auditContent
            }
        }
        .navigationTitle("Continuity Audit")
        .confirmationDialog(
            "Purge continuity audit?",
            isPresented: $showingPurgeConfirm,
            titleVisibility: .visible
        ) {
            Button("Purge Audit", role: .destructive) {
                Task { await model.purgeContinuityAudit() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes continuity history for the active identity only.")
        }
        .privacySensitive()
    }

    @ViewBuilder
    private var auditContent: some View {
        #if os(macOS)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                backButton
                PaneHeader(title: "Continuity Audit", subtitle: "Review trust, rotation, and burn events")
                GroupBox("Audit Trail") {
                    continuityAuditSection
                }
                GroupBox("Purge Audit") {
                    purgeSection
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .groupBoxStyle(GlassGroupBoxStyle())
        .glassBackgroundIfNeeded()
        #else
        Form {
            Section {
                backButton
            }
            Section("Audit Trail") {
                continuityAuditSection
            }
            Section("Purge Audit") {
                purgeSection
            }
        }
        .scrollContentBackground(.hidden)
        .glassBackgroundIfNeeded()
        #endif
    }

    private var backButton: some View {
        #if os(macOS)
        return HStack {
            Button {
                onBack()
            } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .glassButton(compact: true)
            .hoverLift()
            Spacer()
        }
        #else
        return Button("Back to Identity Management") {
            onBack()
        }
        #endif
    }

    private var purgeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Clear the local continuity history for the active identity.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Purge Continuity Audit") {
                showingPurgeConfirm = true
            }
            .glassButton(prominent: true, compact: true)
            .hoverLift()
            .disabled(continuityEvents.isEmpty)
        }
    }

    private var continuityAuditSection: some View {
        let events = continuityEvents
        let lastVerified = events
            .filter { $0.kind == .trustAsserted }
            .max(by: { $0.timestamp < $1.timestamp })
        let rotationEvents = events.filter {
            $0.kind == .identityCreated || $0.kind == .identityRotated || $0.kind == .identityBurned
        }

        return VStack(alignment: .leading, spacing: 12) {
            if let lastVerified {
                Text("Last verified continuity: \(lastVerified.contactDisplayName ?? "Contact") · \(formatEventDate(lastVerified.timestamp))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Last verified continuity: Not yet verified.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider()
            Text("Rotation & Burn History")
                .font(.subheadline.weight(.semibold))
            if rotationEvents.isEmpty {
                Text("No rotations or burns recorded yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rotationEvents.prefix(5)) { event in
                    continuityRow(event)
                }
            }
            Divider()
            Text("Continuity Audit Trail")
                .font(.subheadline.weight(.semibold))
            if events.isEmpty {
                Text("No continuity events recorded yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(events.prefix(20)) { event in
                    continuityRow(event)
                }
            }
        }
    }

    private var continuityEvents: [ContinuityEvent] {
        let events = model.state.identityProfile(id: model.state.activeIdentityId)?.continuityEvents ?? []
        return events.sorted(by: { $0.timestamp > $1.timestamp })
    }

    @ViewBuilder
    private func continuityRow(_ event: ContinuityEvent) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(eventTitle(for: event))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(formatEventDate(event.timestamp))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let contactName = event.contactDisplayName {
                Text(contactName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let fingerprintLine = eventFingerprintLine(for: event) {
                Text(fingerprintLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let note = event.note, !note.isEmpty {
                Text("Note: \(note)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func eventTitle(for event: ContinuityEvent) -> String {
        switch event.kind {
        case .identityCreated:
            return "Identity created"
        case .identityRotated:
            return "Identity rotated"
        case .identityBurned:
            return "Identity burned"
        case .contactAdded:
            return "Contact added"
        case .contactRemoved:
            return "Contact removed"
        case .contactRotationReceived:
            return "Contact rotated keys"
        case .contactResetReceived:
            return "Contact reset identity"
        case .trustAsserted:
            return "Trust verified"
        case .trustRevoked:
            return "Trust revoked"
        }
    }

    private func eventFingerprintLine(for event: ContinuityEvent) -> String? {
        if let oldFingerprint = event.oldFingerprint, let newFingerprint = event.newFingerprint {
            if oldFingerprint == newFingerprint {
                return "Fingerprint: \(shortFingerprint(oldFingerprint))"
            }
            return "Fingerprint: \(shortFingerprint(oldFingerprint)) → \(shortFingerprint(newFingerprint))"
        }
        if let newFingerprint = event.newFingerprint {
            return "Fingerprint: \(shortFingerprint(newFingerprint))"
        }
        if let oldFingerprint = event.oldFingerprint {
            return "Fingerprint: \(shortFingerprint(oldFingerprint))"
        }
        return nil
    }

    private func formatEventDate(_ date: Date) -> String {
        Self.continuityFormatter.string(from: date)
    }

    private static let continuityFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

private struct IdentityDetailView: View {
    @ObservedObject var model: ClientViewModel
    @EnvironmentObject private var screenProtection: ScreenProtectionMonitor
    let profileId: UUID
    let onBack: () -> Void

    @State private var displayName = ""
    @State private var confirmBurn = false
    @State private var showingBurnIdentity = false
    @State private var showingArchiveConfirm = false
    @State private var showingDeleteConfirm = false

    var body: some View {
        Group {
            if screenProtection.isSensitiveHidden {
                SensitiveContentPlaceholder(
                    title: "Identity Hidden",
                    message: "Screen capture or an external display is active. Identity details are hidden to protect your OPSEC."
                )
            } else {
                detailContent
            }
        }
        .navigationTitle("Profile Management")
        .onAppear {
            if let profile = profile {
                displayName = profile.identity.displayName
            }
        }
        .onChange(of: profile?.identity.displayName) { _, newValue in
            if let newValue {
                displayName = newValue
            }
        }
        .sheet(isPresented: $showingBurnIdentity) {
            IdentityBurnView(model: model)
        }
        .confirmationDialog("Archive identity?", isPresented: $showingArchiveConfirm, titleVisibility: .visible) {
            Button("Archive", role: .destructive) {
                if let profile {
                    Task { await model.archiveIdentityProfile(profileId: profile.id) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Archived identities stop syncing and remain encrypted at rest.")
        }
        .confirmationDialog("Delete identity?", isPresented: $showingDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let profile {
                    Task { await model.deleteIdentityProfile(profileId: profile.id) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the identity, inbox, contacts, and local attachments.")
        }
        .privacySensitive()
    }

    private var profile: IdentityProfile? {
        model.state.identityProfile(id: profileId)
    }

    private var isActive: Bool {
        profileId == model.state.activeIdentityId
    }

    @ViewBuilder
    private var detailContent: some View {
        #if os(macOS)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                backButton
                PaneHeader(title: profile?.identity.displayName ?? "Identity")
                if !isActive {
                    activationNotice
                }
                GroupBox("Profile Management") {
                    profileManagementSection
                }
                GroupBox("Burn Identity") {
                    burnSection
                }
                if !isActive {
                    GroupBox("Delete Identity") {
                        deleteSection
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .groupBoxStyle(GlassGroupBoxStyle())
        .glassBackgroundIfNeeded()
        #else
        Form {
            Section {
                backButton
            }
            if !isActive {
                Section("Activation Required") {
                    activationNotice
                }
            }
            Section("Profile Management") {
                profileManagementSection
            }
            Section("Burn Identity") {
                burnSection
            }
            if !isActive {
                Section("Delete Identity") {
                    deleteSection
                }
            }
        }
        .scrollContentBackground(.hidden)
        .glassBackgroundIfNeeded()
        #endif
    }

    private var backButton: some View {
        #if os(macOS)
        return HStack {
            Button {
                onBack()
            } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .glassButton(compact: true)
            .hoverLift()
            Spacer()
        }
        #else
        return Button("Back to Identity Management") {
            onBack()
        }
        #endif
    }

    private var activationNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Activate this identity to rotate keys or perform a burn.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Set Active Identity") {
                Task { await model.setActiveIdentity(profileId) }
            }
            .glassButton(compact: true)
            .hoverLift()
        }
    }

    private var identityFields: some View {
        let fingerprint = profile?.identity.fingerprint ?? "—"
        let inboxId = profile?.inboxId ?? "—"

        return VStack(alignment: .leading, spacing: 10) {
            TextField("Display name", text: $displayName)
                .disabled(!isActive)
            HStack {
                Text("Fingerprint")
                Spacer()
                Text(fingerprint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            HStack {
                Text("Inbox")
                Spacer()
                Text(inboxId)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            Button("Save Identity") {
                Task {
                    await model.updateDisplayName(displayName)
                    model.lastInfo = "Identity updated."
                }
            }
            .glassButton(prominent: true)
            .hoverLift()
            .disabled(!isActive)
        }
    }

    private var profileManagementSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            identityFields
            Divider()
                .opacity(0.4)
            VStack(alignment: .leading, spacing: 8) {
                Text("Active Status")
                    .font(.subheadline.weight(.semibold))
                if isActive {
                    Text("This identity is active and used for messaging.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if profile?.isArchived == true {
                    Text("Restore this identity before setting it as active.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Switch to this identity to use it for new sessions and messages.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Set Active Identity") {
                        Task { await model.setActiveIdentity(profileId) }
                    }
                    .glassButton(prominent: true, compact: true)
                    .hoverLift()
                }
            }
            Divider()
                .opacity(0.4)
            VStack(alignment: .leading, spacing: 8) {
                Text("Rotate Keys")
                    .font(.subheadline.weight(.semibold))
                Text("Generate new identity keys while keeping your inbox and contact relationships.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Contacts receive a signed rotation message so they can verify it is still you.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Rotate Keys") {
                    Task { await model.rotateIdentity() }
                }
                .glassButton(prominent: true)
                .hoverLift()
                .disabled(!isActive)
            }
            Divider()
                .opacity(0.4)
            VStack(alignment: .leading, spacing: 8) {
                Text("Archive")
                    .font(.subheadline.weight(.semibold))
                if isActive {
                    Text("Activate a different identity to archive this one.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if profile?.isArchived == true {
                    Text("Archived identities stay encrypted at rest and stop syncing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Restore Identity") {
                        if let profile {
                            Task { await model.restoreIdentityProfile(profileId: profile.id) }
                        }
                    }
                    .glassButton(compact: true)
                    .hoverLift()
                } else {
                    Text("Archive this identity to pause syncing while keeping data encrypted.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Archive Identity") {
                        showingArchiveConfirm = true
                    }
                    .glassButton(compact: true)
                    .hoverLift()
                }
            }
        }
    }

    private var burnSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Create a brand-new identity and inbox. Only contacts marked in Contact Book will be notified.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Everyone else is permanently dropped and can no longer reach you.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Update the carry-over list ahead of time to avoid hurried decisions.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("I understand this is a full reset and cannot be undone.", isOn: $confirmBurn)
                .disabled(!isActive)
            Button("Burn Identity") {
                showingBurnIdentity = true
            }
            .glassButton(prominent: true)
            .hoverLift()
            .disabled(!confirmBurn || !isActive)
        }
    }

    private var deleteSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Permanently remove this identity, inbox, contacts, and local attachments.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("This action cannot be undone.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Delete Identity") {
                showingDeleteConfirm = true
            }
            .glassButton(prominent: true)
            .hoverLift()
        }
    }
}

private func shortFingerprint(_ fingerprint: String) -> String {
    let trimmed = fingerprint.replacingOccurrences(of: "\n", with: "")
    if trimmed.count <= 16 {
        return trimmed
    }
    let prefix = trimmed.prefix(8)
    let suffix = trimmed.suffix(6)
    return "\(prefix)…\(suffix)"
}

private struct RelaysView: View {
    @ObservedObject var model: ClientViewModel
    @EnvironmentObject private var screenProtection: ScreenProtectionMonitor
    @State private var selectedRelayId: UUID?
    @State private var newSourceName = ""
    @State private var newSourceURL = ""
    @State private var relayEditorMode: RelayEditorMode?

    var body: some View {
        Group {
            if screenProtection.isSensitiveHidden {
                SensitiveContentPlaceholder(
                    title: "Relays Hidden",
                    message: "Screen capture or an external display is active. Relay details are hidden to protect your OPSEC."
                )
            } else {
                relaysContent
            }
        }
        .navigationTitle("Relays")
        .onChange(of: screenProtection.isSensitiveHidden) { _, newValue in
            if newValue {
                relayEditorMode = nil
            }
        }
    }

    @ViewBuilder
    private var relaysContent: some View {
        #if os(macOS)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PaneHeader(title: "Relays")
                GroupBox("Preferred Relay") {
                    preferredRelayFields
                }
                GroupBox("Relay Servers") {
                    relayServersFields
                }
                GroupBox("Master Server Sources") {
                    masterSourcesFields
                }
                GroupBox("Add Master Source") {
                    addMasterSourceFields
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .privacySensitive()
        .groupBoxStyle(GlassGroupBoxStyle())
        .background(setupRelays)
        #else
        Form {
            preferredRelaySection
            relayServersSection
            masterSourcesSection
            addMasterSourceSection
        }
        .privacySensitive()
        .scrollContentBackground(.hidden)
        .glassBackgroundIfNeeded()
        .background(setupRelays)
        #endif
    }

    private var setupRelays: some View {
        Color.clear
            .onAppear {
                selectedRelayId = model.state.selectedRelayId
            }
            .sheet(item: $relayEditorMode) { mode in
                RelayEditorView(title: mode.title, initial: mode.record) { name, host, port, note in
                    Task {
                        switch mode {
                        case .add:
                            await model.addRelayServer(name: name, host: host, port: port, note: note)
                        case .edit(let record):
                            await model.updateRelayServer(id: record.id, name: name, host: host, port: port, note: note)
                        }
                    }
                }
            }
    }

    @ViewBuilder
    private var preferredRelaySection: some View {
        Section("Preferred Relay") {
            preferredRelayFields
        }
    }

    @ViewBuilder
    private var relayServersSection: some View {
        Section("Relay Servers") {
            relayServersFields
        }
    }

    @ViewBuilder
    private var masterSourcesSection: some View {
        Section(
            header: Text("Master Server Sources"),
            footer: Text("Formats: JSON array, JSON {servers:[...]}, or text lines host:port,name,region,tags,website,note,kind,federationMode,federationName,federationDescription,temporalBucketSeconds,operatorNote,softwareVersion. Use | or ; to separate tags.")
        ) {
            masterSourcesFields
        }
    }

    @ViewBuilder
    private var addMasterSourceSection: some View {
        Section("Add Master Source") {
            addMasterSourceFields
        }
    }

    @ViewBuilder
    private var preferredRelayFields: some View {
        if model.state.relayServers.isEmpty {
            Text("No relay servers yet")
                .foregroundStyle(.secondary)
        } else {
            Picker("Server", selection: selectedRelayBinding) {
                ForEach(model.state.relayServers) { server in
                    Text(server.displayName).tag(Optional(server.id))
                }
            }
            Button("Test Connection") {
                Task { await model.testSelectedRelay() }
            }
            .glassButton()
            .hoverLift()
        }
    }

    @ViewBuilder
    private var relayServersFields: some View {
        ForEach(model.state.relayServers) { server in
            RelayServerRow(
                server: server,
                isPreferred: server.id == model.state.selectedRelayId
            ) {
                relayEditorMode = .edit(server)
            } onRefreshInfo: {
                Task { await model.fetchRelayInfo(id: server.id) }
            } onRemove: {
                Task { await model.removeRelayServer(id: server.id) }
            }
        }

        Button("Add Relay Server") {
            relayEditorMode = .add
        }
        .hoverLift()
    }

    @ViewBuilder
    private var masterSourcesFields: some View {
        if model.state.masterServerSources.isEmpty {
            Text("No master sources configured")
                .foregroundStyle(.secondary)
        }
        ForEach(model.state.masterServerSources) { source in
            masterSourceRow(source)
        }
        if !model.state.masterServerSources.isEmpty {
            Button("Fetch All Sources") {
                Task { await model.fetchMasterSources() }
            }
            .hoverLift()
        }
        #if os(macOS)
        Text("Formats: JSON array, JSON {servers:[...]}, or text lines host:port,name,region,tags,website,note,kind,federationMode,federationName,federationDescription,temporalBucketSeconds,operatorNote,softwareVersion. Use | or ; to separate tags.")
            .font(.caption2)
            .foregroundStyle(.secondary)
        #endif
    }

    @ViewBuilder
    private var addMasterSourceFields: some View {
        TextField("Name", text: $newSourceName)
        #if os(iOS)
        TextField("URL", text: $newSourceURL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #else
        TextField("URL", text: $newSourceURL)
        #endif
        Button("Add Source") {
            Task {
                await model.addMasterSource(name: newSourceName, url: newSourceURL)
                newSourceName = ""
                newSourceURL = ""
            }
        }
        .disabled(newSourceName.isEmpty || newSourceURL.isEmpty)
        .hoverLift()
    }

    private var selectedRelayBinding: Binding<UUID?> {
        Binding(
            get: { selectedRelayId ?? model.state.selectedRelayId },
            set: { newValue in
                selectedRelayId = newValue
                if let id = newValue {
                    Task { await model.selectRelayServer(id: id) }
                }
            }
        )
    }

    @ViewBuilder
    private func masterSourceRow(_ source: MasterServerSource) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(source.name)
                Spacer()
                Toggle("Enabled", isOn: Binding(
                    get: { source.isEnabled },
                    set: { isEnabled in
                        Task { await model.setMasterSourceEnabled(id: source.id, isEnabled: isEnabled) }
                    }
                ))
                .labelsHidden()
            }
            Text(source.url)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack(spacing: 12) {
                Button("Refresh") {
                    Task { await model.fetchMasterSource(source) }
                }
                .glassButton()
                Button("Remove") {
                    Task { await model.removeMasterSource(id: source.id) }
                }
                .glassButton()
            }
            .hoverLift()
        }
        .padding(.vertical, 4)
    }
}

private struct ContactBookView: View {
    @ObservedObject var model: ClientViewModel
    @EnvironmentObject private var screenProtection: ScreenProtectionMonitor
    let onOpen: (UUID) -> Void
    let onAdd: () -> Void
    @State private var trustPrompt: TrustPrompt?

    var body: some View {
        Group {
            if screenProtection.isSensitiveHidden {
                SensitiveContentPlaceholder(
                    title: "Contact Book Hidden",
                    message: "Screen capture or an external display is active. Contact details are hidden to protect your OPSEC."
                )
            } else {
                contactList
            }
        }
        .navigationTitle("Contact Book")
        .sheet(item: $trustPrompt) { prompt in
            TrustAssertionSheet(prompt: prompt) { note in
                Task {
                    switch prompt.action {
                    case .verified:
                        await model.assertContactTrust(contactId: prompt.contact.id, note: note)
                    case .revoked:
                        await model.revokeContactTrust(contactId: prompt.contact.id, note: note)
                    }
                }
            }
        }
    }

    private var contactList: some View {
        List {
            #if os(macOS)
            PaneHeader(title: "Contact Book")
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            #endif
            Section {
                HStack {
                    Button {
                        onAdd()
                    } label: {
                        Label("Add Contact", systemImage: "person.badge.plus")
                    }
                    .glassButton()
                    .hoverLift()
                    Spacer()
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            if model.state.contacts.isEmpty {
                Text("No contacts yet")
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            ForEach(model.state.contacts) { contact in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(contact.displayName)
                            .font(.headline)
                        Spacer()
                        if let unread = model.state.conversation(for: contact.id)?.unreadCount, unread > 0 {
                            UnreadBadge(count: unread)
                        }
                        Button("Open") { onOpen(contact.id) }
                            .glassButton()
                            .hoverLift()
                        Button("Delete") {
                            Task { await model.removeContact(id: contact.id) }
                        }
                        .glassButton()
                        .hoverLift()
                    }
                    Text("Inbox: \(contact.inboxId)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Relay: \(contact.relay.host):\(contact.relay.port)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Fingerprint: \(contact.fingerprint)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    trustSection(for: contact)
                    Toggle("Receive new identity after burn", isOn: identityResetBinding(for: contact))
                    Text("When you burn your identity, only contacts with this enabled are notified and kept.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.5),
                                    Color.white.opacity(0.08)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.8
                        )
                )
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .contextMenu {
                    Button("Remove Contact", role: .destructive) {
                        Task { await model.removeContact(id: contact.id) }
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        Task { await model.removeContact(id: contact.id) }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .privacySensitive()
        .scrollContentBackground(.hidden)
        .listRowBackground(Color.clear)
        .glassBackgroundIfNeeded()
        #if os(macOS)
        .listStyle(.inset)
        #else
        .listStyle(.plain)
        #endif
    }

    private func identityResetBinding(for contact: Contact) -> Binding<Bool> {
        Binding(
            get: { contact.allowIdentityReset },
            set: { newValue in
                Task { await model.updateContactIdentityReset(contactId: contact.id, allow: newValue) }
            }
        )
    }

    @ViewBuilder
    private func trustSection(for contact: Contact) -> some View {
        let status = trustStatusText(for: contact)
        let detail = trustDetailText(for: contact)
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Trust: \(status)")
                    .font(.caption)
                    .foregroundStyle(trustStatusColor(for: contact))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let lastVerified = contact.lastVerifiedAssertion {
                    Text("Last verified: \(formatTrustDate(lastVerified.timestamp))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Last verified: Never")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Button(trustActionLabel(for: contact)) {
                    trustPrompt = TrustPrompt(contact: contact, action: .verified)
                }
                .glassButton(compact: true)
                .hoverLift()
                Button("Revoke") {
                    trustPrompt = TrustPrompt(contact: contact, action: .revoked)
                }
                .glassButton(compact: true)
                .hoverLift()
            }
        }
    }

    private func trustStatusText(for contact: Contact) -> String {
        guard let assertion = contact.lastTrustAssertionForCurrentFingerprint() else {
            return "Unverified"
        }
        switch assertion.kind {
        case .verified:
            return "Verified"
        case .revoked:
            return "Revoked"
        }
    }

    private func trustStatusColor(for contact: Contact) -> Color {
        guard let assertion = contact.lastTrustAssertionForCurrentFingerprint() else {
            return .secondary
        }
        switch assertion.kind {
        case .verified:
            return .green
        case .revoked:
            return .orange
        }
    }

    private func trustDetailText(for contact: Contact) -> String {
        guard let assertion = contact.lastTrustAssertionForCurrentFingerprint() else {
            return "No verification recorded for current keys."
        }
        let label = assertion.kind == .verified ? "Verified" : "Revoked"
        return "\(label) \(formatTrustDate(assertion.timestamp))"
    }

    private func trustActionLabel(for contact: Contact) -> String {
        contact.isTrusted ? "Re-verify" : "Verify"
    }

    private func formatTrustDate(_ date: Date) -> String {
        Self.trustFormatter.string(from: date)
    }

    private static let trustFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

private struct TrustPrompt: Identifiable {
    let id = UUID()
    let contact: Contact
    let action: ContactTrustKind
}

private struct TrustAssertionSheet: View {
    let prompt: TrustPrompt
    let onConfirm: (String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var note: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title2.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("Optional note", text: $note, axis: .vertical)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .glassButton(compact: true)
                Spacer()
                Button(actionLabel) {
                    let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
                    onConfirm(trimmed.isEmpty ? nil : trimmed)
                    dismiss()
                }
                .glassButton(prominent: true, compact: true)
            }
        }
        .padding(20)
        .frame(maxWidth: 420)
    }

    private var title: String {
        switch prompt.action {
        case .verified:
            return "Verify Contact"
        case .revoked:
            return "Revoke Trust"
        }
    }

    private var actionLabel: String {
        switch prompt.action {
        case .verified:
            return "Verify"
        case .revoked:
            return "Revoke"
        }
    }

    private var message: String {
        switch prompt.action {
        case .verified:
            return "Confirm you have verified \(prompt.contact.displayName)'s current fingerprint."
        case .revoked:
            return "Mark \(prompt.contact.displayName)'s current fingerprint as untrusted."
        }
    }
}

private struct RelayServerRow: View {
    let server: RelayServerRecord
    let isPreferred: Bool
    let onEdit: () -> Void
    let onRefreshInfo: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(server.displayName)
                if isPreferred {
                    Text("Preferred")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Info") { onRefreshInfo() }
                    .glassButton(compact: true)
                    .hoverLift()
                Button("Edit") { onEdit() }
                    .glassButton(compact: true)
                    .hoverLift()
            }
            Text("\(server.endpoint.host):\(server.endpoint.port)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let region = server.region, !region.isEmpty {
                Text("Region: \(region)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let tags = server.tags, !tags.isEmpty {
                Text("Tags: \(tags.joined(separator: ", "))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let website = server.website, !website.isEmpty {
                Text(website)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let note = server.note, !note.isEmpty {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            relayInfoSection
        }
        .contextMenu {
            Button("Edit") { onEdit() }
            Button("Refresh Info") { onRefreshInfo() }
            Button("Remove", role: .destructive) { onRemove() }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) { onRemove() } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private var relayInfoSection: some View {
        if let info = server.advertisedInfo {
            Text("Relay kind: \(relayKindLabel(info.kind))")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("Federation: \(federationLabel(info.federation))")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("Temporal bucket: \(formatBucket(info.temporalBucketSeconds))")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let relayName = info.relayName, !relayName.isEmpty {
                Text("Relay name: \(relayName)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let operatorNote = info.operatorNote, !operatorNote.isEmpty {
                Text(operatorNote)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let software = info.softwareVersion, !software.isEmpty {
                Text("Software: \(software)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let fetchedAt = server.lastInfoFetchedAt {
                Text("Info updated \(formatInfoDate(fetchedAt))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("Relay info not reported yet.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func federationLabel(_ federation: FederationDescriptor) -> String {
        switch federation.mode {
        case .solo:
            return "Solo"
        case .curated:
            if let name = federation.name, !name.isEmpty {
                return "Curated (\(name))"
            }
            return "Curated"
        case .open:
            if let name = federation.name, !name.isEmpty {
                return "Open (\(name))"
            }
            return "Open"
        }
    }

    private func relayKindLabel(_ kind: RelayKind) -> String {
        switch kind {
        case .standard:
            return "Standard"
        case .discovery:
            return "Discovery"
        case .bridge:
            return "Bridge"
        case .archive:
            return "Archive"
        case .privateRelay:
            return "Private"
        }
    }

    private func formatBucket(_ seconds: Int) -> String {
        if seconds <= 0 {
            return "Off"
        }
        if seconds < 60 {
            return "\(seconds)s"
        }
        if seconds % 60 == 0 {
            return "\(seconds / 60)m"
        }
        return String(format: "%.1fm", Double(seconds) / 60.0)
    }

    private func formatInfoDate(_ date: Date) -> String {
        Self.infoFormatter.string(from: date)
    }

    private static let infoFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}

private enum RelayEditorMode: Identifiable {
    case add
    case edit(RelayServerRecord)

    var id: String {
        switch self {
        case .add:
            return "add"
        case .edit(let record):
            return record.id.uuidString
        }
    }

    var title: String {
        switch self {
        case .add:
            return "Add Relay Server"
        case .edit:
            return "Edit Relay Server"
        }
    }

    var record: RelayServerRecord? {
        switch self {
        case .add:
            return nil
        case .edit(let record):
            return record
        }
    }
}

private struct ThemeSwatch: View {
    let palette: ThemePalette
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        let style = ThemeStyle(palette: palette)
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                style.backgroundTint.opacity(0.6),
                                style.glowPrimary.opacity(0.35),
                                style.glowSecondary.opacity(0.25)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(height: 54)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.white.opacity(0.2), lineWidth: 0.8)
                    )
                Text(palette.displayName)
                    .font(.caption)
                    .foregroundStyle(.primary)
            }
            .padding(10)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isSelected ? style.accent.opacity(0.6) : Color.white.opacity(0.08), lineWidth: 1.2)
            )
        }
        .buttonStyle(.plain)
    }
}

#if os(macOS)
private struct GlassGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            configuration.label
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(.primary)
            configuration.content
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.5),
                            Color.white.opacity(0.08)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )
        )
    }
}
#endif

private struct HoverLiftModifier: ViewModifier {
    let cornerRadius: CGFloat
    @State private var hovering = false

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .scaleEffect(hovering ? 1.02 : 1.0)
            .shadow(
                color: Color.white.opacity(hovering ? 0.25 : 0),
                radius: hovering ? 10 : 0,
                x: 0,
                y: hovering ? 4 : 0
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(hovering ? 0.3 : 0), lineWidth: 0.8)
            )
            .animation(.easeOut(duration: 0.15), value: hovering)
            .onHover { hovering = $0 }
        #else
        content
        #endif
    }
}

private struct GlowCardModifier: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(hovering ? 0.28 : 0.18), lineWidth: 0.8)
                    .shadow(
                        color: Color.white.opacity(hovering ? 0.24 : 0.14),
                        radius: hovering ? 16 : 10,
                        x: 0,
                        y: hovering ? 6 : 3
                    )
            )
            .animation(.easeOut(duration: 0.2), value: hovering)
            .onHover { hovering = $0 }
        #else
        content
        #endif
    }
}

private extension View {
    func hoverLift(cornerRadius: CGFloat = 8) -> some View {
        modifier(HoverLiftModifier(cornerRadius: cornerRadius))
    }
}

private extension View {
    func cardButtonStyle() -> some View {
        #if os(macOS)
        return self
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .modifier(GlowCardModifier())
        #else
        return self
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
                    .shadow(color: Color.white.opacity(0.14), radius: 7, x: 0, y: 2)
            )
        #endif
    }
}

private extension View {
    @ViewBuilder
    func clearNavigationContainerBackground() -> some View {
        #if os(iOS)
        if #available(iOS 17.0, *) {
            containerBackground(.clear, for: .navigationSplitView)
        } else {
            self
        }
        #else
        self
        #endif
    }
}

private extension View {
    @ViewBuilder
    func glassBackgroundIfNeeded() -> some View {
        #if os(iOS)
        self.background(GlassBackground())
        #else
        self
        #endif
    }
}

private extension View {
    @ViewBuilder
    func hideWindowToolbarIfNeeded() -> some View {
        #if os(macOS)
        if #available(macOS 13.0, *) {
            toolbar(.hidden, for: .windowToolbar)
        } else {
            self
        }
        #else
        self
        #endif
    }
}

#if os(iOS)
private struct HostingBackgroundClearer: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> ClearController {
        ClearController()
    }

    func updateUIViewController(_ uiViewController: ClearController, context: Context) {}

    final class ClearController: UIViewController {
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            clearBackgrounds()
        }

        private func clearBackgrounds() {
            view.backgroundColor = .clear
            var current = view.superview
            while let next = current?.superview {
                current?.backgroundColor = .clear
                current = next
            }
            current?.backgroundColor = .clear
            view.window?.backgroundColor = .clear
            view.window?.rootViewController?.view.backgroundColor = .clear
        }
    }
}
#endif

private enum Clipboard {
    static func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        #endif
    }
}

private enum FeedbackGenerator {
    static func light() {
        #if os(iOS)
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred()
        #endif
    }
}
