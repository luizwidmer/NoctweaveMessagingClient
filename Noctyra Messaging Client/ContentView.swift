import SwiftUI
import NoctweaveCore
import UniformTypeIdentifiers
import ImageIO
import Darwin
import StoreKit
import Combine
import AVFoundation
#if os(iOS)
import UIKit
import PhotosUI
#elseif os(macOS)
import AppKit
import Carbon.HIToolbox
#endif

#if os(iOS)
private func dismissActiveTextInput() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}
#endif

private enum SidebarItem: Hashable {
    case contact(UUID)
    case group(UUID)
    case contactBook
    case myCode
    case relays
    case identityManagement
    case settings
}

#if os(iOS)
private enum IOSMainTab: String, Hashable {
    case chats
    case contacts
    case myCode
    case relays
    case identity
    case settings

    static func initialFromLaunchArguments() -> IOSMainTab {
        let args = ProcessInfo.processInfo.arguments
        if let raw = args.first(where: { $0.hasPrefix("START_TAB=") })?.split(separator: "=", maxSplits: 1).last {
            switch raw.lowercased() {
            case "chats":
                return .chats
            case "contacts":
                return .contacts
            case "mycode", "my_code", "code":
                return .myCode
            case "relays":
                return .relays
            case "identity":
                return .identity
            case "settings":
                return .settings
            default:
                break
            }
        }
        return .chats
    }
}
#endif

struct ContentView: View {
    @StateObject private var model = ClientViewModel()
    @StateObject private var screenProtection = ScreenProtectionMonitor()
    @State private var selection: SidebarItem?
    @State private var showingAddContact = ProcessInfo.processInfo.arguments.contains("SHOW_ADD_CONTACT")
    @State private var showingCreateGroup = ProcessInfo.processInfo.arguments.contains("SHOW_CREATE_GROUP")
#if os(iOS)
    @SceneStorage("noctyra.ios.mainTab") private var iosTabRaw: String = IOSMainTab.initialFromLaunchArguments().rawValue
#endif
    #if os(macOS)
    @StateObject private var windowController = AppWindowController()
    @State private var sidebarWidth: CGFloat = 292
    @State private var isResizerHovering = false
    #endif
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
            if shouldShowMainContent {
                rootContainer
                    .clearNavigationContainerBackground()
                    .hideWindowToolbarIfNeeded()
                    .applyIf(!ProcessInfo.processInfo.arguments.contains("UI_TESTING")) { view in
                        view.secureContainerIfAvailable()
                    }
                #if os(iOS)
                HostingBackgroundClearer()
                    .frame(width: 0, height: 0)
                #else
                EmptyView()
                #endif
            }
            if showIntro {
                IntroOverlay(opacity: introOpacity, scale: introScale)
                    .allowsHitTesting(false)
            }
            if model.requiresOnboarding {
                FirstRunSetupView(model: model)
            }
            if model.isLocked && model.isReady && !model.requiresOnboarding {
                AppLockView(model: model)
            }
            if model.requiresStorageChoice && !model.requiresOnboarding {
                StorageChoiceView { mode in
                    model.selectStorageProtection(mode)
                }
            }
            if shouldShowStartupPrivacyShield {
                StartupPrivacyShield()
            }
            if let status = model.storageProtectionStatus {
                StorageStatusToast(message: status)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        #if os(macOS)
        // Capture the NSWindow for custom window controls.
        .overlay {
            WindowCaptureView(controller: windowController)
                .frame(width: 0, height: 0)
        }
        // Custom traffic lights: floating controls, no titlebar.
        .overlay(alignment: .topLeading) {
            NoctyraTrafficLights()
                .padding(.leading, 14)
                .padding(.top, 12)
        }
        #endif
        .preferredColorScheme(themeStyle.preferredColorScheme)
        .environment(\.appTheme, themeStyle)
        .tint(themeStyle.accent)
        .environmentObject(screenProtection)
        #if os(macOS)
        .environmentObject(windowController)
        #endif
        .sheet(isPresented: $showingAddContact) {
            AddContactView(model: model)
                .noctyraSheetPresentation()
        }
        .sheet(isPresented: $showingCreateGroup) {
            CreateGroupView(model: model)
                .noctyraSheetPresentation()
        }
        #if os(macOS)
        .onChange(of: model.state.privacy.hideSensitiveWhenUnfocused) { _, newValue in
            screenProtection.setHideWhenUnfocusedEnabled(newValue)
        }
        .onChange(of: model.state.privacy.macBlockWindowCapture) { _, newValue in
            windowController.setBlockWindowCapture(newValue)
        }
        .onChange(of: windowController.isAppActive) { _, _ in
            screenProtection.setAppInFocus(windowController.isAppActive)
        }
        .onChange(of: windowController.isWindowKey) { _, _ in
            screenProtection.setAppInFocus(windowController.isAppActive)
        }
        #endif
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
            #if os(macOS)
            screenProtection.setHideWhenUnfocusedEnabled(model.state.privacy.hideSensitiveWhenUnfocused)
            screenProtection.setAppInFocus(windowController.isAppActive)
            windowController.setBlockWindowCapture(model.state.privacy.macBlockWindowCapture)
            #endif
        }
        .onChange(of: scenePhase) { _, newValue in
            model.handleScenePhaseChange(newValue)
            if newValue == .active {
                screenProtection.refresh()
            }
        }
        #if os(macOS)
        // Ensure our background extends into the titlebar region so the traffic lights appear to float.
        .ignoresSafeArea(.container, edges: .top)
        #endif
    }

    private var shouldShowMainContent: Bool {
        model.isReady
            && !model.requiresStorageChoice
            && !model.requiresOnboarding
            && !model.isLocked
    }

    private var shouldShowStartupPrivacyShield: Bool {
        !model.isReady && !model.requiresStorageChoice && !model.requiresOnboarding
    }

    @ViewBuilder
    private var rootContainer: some View {
        #if os(macOS)
        HStack(spacing: 0) {
            macSidebarView
                .frame(minWidth: 240, idealWidth: sidebarWidth, maxWidth: 420)
                .layoutPriority(1)

            sidebarResizer

            detailView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        #else
        GeometryReader { proxy in
            let size = proxy.size
            let stableSize = IOSControlMetrics.stableScreenSize(fallback: size)
            let useSideRail = IOSControlMetrics.prefersSideRail(for: stableSize)

            Group {
                if useSideRail {
                    HStack(spacing: 0) {
                        IOSSideRail(selectedTab: iosTabSelection, availableHeight: size.height) { tab in
                            iosTabSelection.wrappedValue = tab
                        }
                        Rectangle()
                            .fill(Color.white.opacity(0.06))
                            .frame(width: 0.5)
                            .ignoresSafeArea(.container, edges: .vertical)
                        iosMainContent
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    // Custom iOS bottom bar to avoid TabView's "More" behavior and keep 6 tabs stable.
                    VStack(spacing: 0) {
                        iosMainContent
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        IOSBottomBar(selectedTab: iosTabSelection) { tab in
                            iosTabSelection.wrappedValue = tab
                        }
                    }
                }
            }
            .frame(width: size.width, height: size.height)
        }
        #endif
    }

#if os(iOS)
    private var iosTabSelection: Binding<IOSMainTab> {
        Binding(
            get: { IOSMainTab(rawValue: iosTabRaw) ?? IOSMainTab.initialFromLaunchArguments() },
            set: { iosTabRaw = $0.rawValue }
        )
    }

    @ViewBuilder
    private var iosMainContent: some View {
        switch iosTabSelection.wrappedValue {
        case .chats:
            NavigationStack {
                ChatsListView(model: model) {
                    showingAddContact = true
                } onAddGroup: {
                    showingCreateGroup = true
                }
            }
        case .contacts:
            NavigationStack {
                ContactBookTabView(model: model) {
                    showingAddContact = true
                }
            }
        case .myCode:
            NavigationStack {
                MyCodeView(model: model)
            }
            .hideSheetNavigationBar()
        case .relays:
            NavigationStack {
                RelaysView(model: model)
            }
            .hideSheetNavigationBar()
        case .identity:
            NavigationStack {
                IdentityManagementView(model: model)
            }
            .hideSheetNavigationBar()
        case .settings:
            NavigationStack {
                SettingsView(model: model)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }
#endif

    #if os(macOS)
    private var sidebarResizer: some View {
        ZStack {
            Rectangle()
                .fill(Color.white.opacity(isResizerHovering ? 0.12 : 0.06))
                .frame(width: 1)
                .animation(.easeInOut(duration: 0.18), value: isResizerHovering)

            Color.clear
                .frame(width: 8)
                .contentShape(Rectangle())
                .onHover { hovering in
                    isResizerHovering = hovering
                    if hovering {
                        NSCursor.resizeLeftRight.push()
                    } else {
                        NSCursor.pop()
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let newWidth = sidebarWidth + value.translation.width
                            sidebarWidth = min(420, max(240, newWidth))
                        }
                )
        }
        .frame(maxHeight: .infinity)
        .background(Color.clear)
    }
    #endif

    private var sidebarView: some View {
        #if os(macOS)
        macSidebarView
        #else
        iosSidebarView
        #endif
    }

    private var iosSidebarView: some View {
        List(selection: $selection) {
            SidebarHeader()
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

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
                                Image(systemName: "person.circle")
                                    .foregroundStyle(.secondary)
                                Text(contact.displayName)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .layoutPriority(1)
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

            Section("Groups") {
                if screenProtection.isSensitiveHidden {
                    Label("Groups hidden while capture is active", systemImage: "eye.slash")
                        .foregroundStyle(.secondary)
                } else {
                    Button {
                        showingCreateGroup = true
                    } label: {
                        Label("Create Group", systemImage: "plus.circle")
                    }
                    if model.state.groups.isEmpty {
                        Text("No groups yet")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.state.groups) { group in
                        NavigationLink(value: SidebarItem.group(group.id)) {
                            HStack {
                                Image(systemName: "person.3.fill")
                                    .foregroundStyle(.secondary)
                                Text(group.title)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .layoutPriority(1)
                                Spacer()
                                if unreadCount(for: group) > 0 {
                                    UnreadBadge(count: unreadCount(for: group))
                                }
                            }
                        }
                        .accessibilityIdentifier("group-\(group.id.uuidString)")
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
        .scrollContentBackground(.hidden)
        .listRowBackground(Color.clear)
        .glassBackgroundIfNeeded()
        .navigationTitle("")
        .privacySensitive()
    }

    #if os(macOS)
    private var macSidebarView: some View {
        List(selection: $selection) {
            // Reserve space for the floating custom traffic lights.
            Color.clear
                .frame(height: 32)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            SidebarHeader()
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            Section("Contacts") {
                if screenProtection.isSensitiveHidden {
                    Label("Contacts hidden while capture is active", systemImage: "eye.slash")
                        .foregroundStyle(.secondary)
                } else {
                    if model.state.contacts.isEmpty {
                        Text("No contacts yet")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                            .padding(.vertical, 6)
                    }
                    ForEach(model.state.contacts) { contact in
                        MacSidebarRow(
                            title: contact.displayName,
                            subtitle: "Secure chat",
                            systemImage: "person.circle",
                            unreadCount: unreadCount(for: contact),
                            isSelected: selection == .contact(contact.id)
                        )
                        .tag(SidebarItem.contact(contact.id))
                        .contextMenu {
                            Button("Remove Contact", role: .destructive) {
                                Task { await model.removeContact(id: contact.id) }
                            }
                        }
                        .accessibilityIdentifier("contact-\(contact.id.uuidString)")
                    }
                }
            }

            Section("Groups") {
                if screenProtection.isSensitiveHidden {
                    Label("Groups hidden while capture is active", systemImage: "eye.slash")
                        .foregroundStyle(.secondary)
                } else {
                    Button {
                        showingCreateGroup = true
                    } label: {
                        MacSidebarRow(
                            title: "Create Group",
                            subtitle: "Start a private group",
                            systemImage: "plus.circle",
                            isAction: true,
                            isSelected: false
                        )
                    }
                    .buttonStyle(.plain)
                    if model.state.groups.isEmpty {
                        Text("No groups yet")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                            .padding(.vertical, 6)
                    }
                    ForEach(model.state.groups) { group in
                        MacSidebarRow(
                            title: group.title,
                            subtitle: group.isPendingInvitation ? "Group invitation" : "\(group.resolvedMemberCount) members",
                            systemImage: group.isPendingInvitation ? "envelope.badge" : "person.3.fill",
                            unreadCount: unreadCount(for: group),
                            isSelected: selection == .group(group.id)
                        )
                        .tag(SidebarItem.group(group.id))
                        .accessibilityIdentifier("group-\(group.id.uuidString)")
                    }
                }
            }

            Section("Tools") {
                MacSidebarRow(title: "Contact Book", systemImage: "book.closed", isSelected: selection == .contactBook)
                    .tag(SidebarItem.contactBook)
                MacSidebarRow(title: "My Code", systemImage: "qrcode", isSelected: selection == .myCode)
                    .tag(SidebarItem.myCode)
                MacSidebarRow(title: "Relays", systemImage: "antenna.radiowaves.left.and.right", isSelected: selection == .relays)
                    .tag(SidebarItem.relays)
                MacSidebarRow(title: "Identity Management", systemImage: "person.badge.shield.checkmark", isSelected: selection == .identityManagement)
                    .tag(SidebarItem.identityManagement)
                MacSidebarRow(title: "Settings", systemImage: "gearshape", isSelected: selection == .settings)
                    .tag(SidebarItem.settings)
                    .accessibilityIdentifier("sidebar-settings")
            }
        }
        .scrollContentBackground(.hidden)
        .listSectionSeparator(.hidden)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .listStyle(.sidebar)
        // No sidebar material on macOS: keep the titlebar region clean and consistent with the app background.
        .background(Color.clear)
        .privacySensitive()
    }
    #endif

    @ViewBuilder
    private var detailView: some View {
        switch selection {
        case .contact(let contactId):
            if let contact = model.state.contacts.first(where: { $0.id == contactId }) {
                ConversationView(model: model, contact: contact)
            } else {
                PlaceholderView(title: "Select a contact")
            }
        case .group(let groupId):
            if let group = model.state.group(for: groupId) {
                GroupConversationView(model: model, group: group)
            } else {
                PlaceholderView(title: "Select a group")
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

    private func unreadCount(for group: GroupConversation) -> Int {
        model.state.group(for: group.id)?.unreadCount ?? 0
    }

}

private struct IntroOverlay: View {
    let opacity: Double
    let scale: CGFloat

    var body: some View {
        VStack {
            WelcomeContent(title: "Welcome to Noctyra", subtitle: "Post-quantum chat", imageSize: 300)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .opacity(opacity)
        .scaleEffect(scale)
    }
}

private struct StartupPrivacyShield: View {
    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()
            ProgressView()
                .controlSize(.small)
                .tint(.white.opacity(0.72))
        }
        .transition(.opacity)
    }
}

private struct SidebarHeader: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image("Rhombus")
                .resizable()
                .scaledToFit()
                .frame(width: 26, height: 26)
                .shadow(color: theme.accent.opacity(0.25), radius: 8, x: 0, y: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text("Noctyra")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                Text("Post-quantum chat")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.black.opacity(isDark ? 0.16 : 0.05))
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                theme.accent.opacity(isDark ? 0.14 : 0.08),
                                theme.glowSecondary.opacity(isDark ? 0.08 : 0.04),
                                Color.clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .opacity(isDark ? 0.65 : 0.45)
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(isDark ? 0.20 : 0.32),
                            theme.accent.opacity(isDark ? 0.14 : 0.12),
                            Color.white.opacity(isDark ? 0.06 : 0.08)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )
        )
        .shadow(color: theme.accent.opacity(isDark ? 0.14 : 0.08), radius: 10, x: 0, y: 4)
        .padding(.vertical, 6)
    }
}

#if os(macOS)
private struct MacSidebarRow: View {
    let title: String
    var subtitle: String? = nil
    let systemImage: String
    var unreadCount: Int = 0
    var isAction: Bool = false
    let isSelected: Bool

    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false

    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isSelected || isAction ? theme.accent : .secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13.5, weight: isSelected ? .semibold : .medium, design: .rounded))
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let subtitle, !subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if unreadCount > 0 {
                UnreadBadge(count: unreadCount)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, subtitle == nil ? 8 : 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
                .opacity(isSelected ? 1 : (hovering ? 0.54 : 0))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(theme.accent.opacity(isSelected ? (isDark ? 0.18 : 0.12) : (hovering ? 0.08 : 0)))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(
                            Color.white.opacity(isSelected ? (isDark ? 0.24 : 0.34) : (hovering ? 0.16 : 0)),
                            lineWidth: 0.8
                        )
                )
        }
        .shadow(color: theme.accent.opacity(isSelected ? 0.14 : 0), radius: 9, x: 0, y: 4)
        .animation(.easeOut(duration: 0.16), value: isSelected)
        .animation(.easeOut(duration: 0.16), value: hovering)
        .onHover { hovering = $0 }
    }
}
#endif

#if os(iOS)
private struct IOSBottomBar: View {
    let selectedTab: Binding<IOSMainTab>
    let onSelect: (IOSMainTab) -> Void
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    private var tabs: [(IOSMainTab, String, String)] {
        [
            (.chats, "Chats", "message"),
            (.contacts, "Contacts", "book.closed"),
            (.myCode, "Code", "qrcode"),
            (.relays, "Relays", "antenna.radiowaves.left.and.right"),
            (.identity, "Identity", "person.badge.shield.checkmark"),
            (.settings, "Settings", "gearshape")
        ]
    }

    private var isDark: Bool { colorScheme == .dark }
    private var tabSpacing: CGFloat { IOSControlMetrics.isPad ? 8 : 4 }
    private var barPadding: CGFloat { IOSControlMetrics.isPad ? 8 : 6 }

    var body: some View {
        HStack(spacing: tabSpacing) {
            ForEach(tabs, id: \.0.rawValue) { tab, title, icon in
                Button {
                    guard selectedTab.wrappedValue != tab else { return }
                    onSelect(tab)
                    FeedbackGenerator.light()
                } label: {
                    VStack(spacing: IOSControlMetrics.tabItemSpacing) {
                        Image(systemName: icon)
                            .font(.system(size: IOSControlMetrics.tabIconSize, weight: .semibold))
                            .frame(height: IOSControlMetrics.tabIconFrameHeight)
                        Text(title)
                            .font(.system(size: IOSControlMetrics.tabTextSize, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, IOSControlMetrics.tabItemVerticalPadding)
                    .foregroundStyle(selectedTab.wrappedValue == tab ? theme.accent : Color.secondary)
                    .background(
                        Capsule(style: .continuous)
                            .fill(selectedTab.wrappedValue == tab ? theme.accent.opacity(isDark ? 0.16 : 0.11) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("tab-\(tab.rawValue)")
            }
        }
        .padding(barPadding)
        .background(
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule(style: .continuous)
                        .fill(Color.black.opacity(isDark ? 0.20 : 0.055))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.white.opacity(isDark ? 0.14 : 0.22), lineWidth: 0.7)
                )
                .shadow(color: theme.accent.opacity(isDark ? 0.08 : 0.05), radius: 7, x: 0, y: 2)
        )
        .padding(.horizontal, IOSControlMetrics.tabBarHorizontalPadding)
        .padding(.top, IOSControlMetrics.isPad ? 8 : 4)
        .padding(.bottom, IOSControlMetrics.tabBarBottomPadding)
    }
}

private struct IOSSideRail: View {
    let selectedTab: Binding<IOSMainTab>
    let availableHeight: CGFloat
    let onSelect: (IOSMainTab) -> Void
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    private var isDark: Bool { colorScheme == .dark }
    private var compactHeight: Bool { availableHeight < 760 }
    private var logoSize: CGFloat { compactHeight ? 28 : 42 }
    private var itemSpacing: CGFloat { compactHeight ? 6 : 10 }
    private var itemVerticalPadding: CGFloat { compactHeight ? 8 : 12 }
    private var labelSize: CGFloat { compactHeight ? 13 : 14 }
    private var iconSize: CGFloat { compactHeight ? 16 : 17 }
    private var railWidth: CGFloat { compactHeight ? 160 : 176 }

    private var tabs: [(IOSMainTab, String, String)] {
        [
            (.chats, "Chats", "message"),
            (.contacts, "Contacts", "book.closed"),
            (.myCode, "Code", "qrcode"),
            (.relays, "Relays", "antenna.radiowaves.left.and.right"),
            (.identity, "Identity", "person.badge.shield.checkmark"),
            (.settings, "Settings", "gearshape")
        ]
    }

    var body: some View {
        VStack(spacing: itemSpacing) {
            Image("Rhombus")
                .resizable()
                .scaledToFit()
                .frame(width: logoSize, height: logoSize)
                .padding(.bottom, compactHeight ? 2 : 8)

            ForEach(tabs, id: \.0.rawValue) { tab, title, icon in
                Button {
                    guard selectedTab.wrappedValue != tab else { return }
                    onSelect(tab)
                    FeedbackGenerator.light()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: icon)
                            .font(.system(size: iconSize, weight: .semibold))
                            .frame(width: 22)
                        Text(title)
                            .font(.system(size: labelSize, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(selectedTab.wrappedValue == tab ? theme.accent : Color.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, itemVerticalPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(selectedTab.wrappedValue == tab ? theme.accent.opacity(isDark ? 0.18 : 0.12) : Color.clear)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("tab-\(tab.rawValue)")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, compactHeight ? 10 : 12)
        .padding(.top, compactHeight ? 16 : 24)
        .padding(.bottom, compactHeight ? 10 : 16)
        .frame(width: railWidth)
        .frame(maxHeight: .infinity)
        .background(
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(
                    Rectangle()
                        .fill(Color.black.opacity(isDark ? 0.20 : 0.06))
                )
                .overlay(
                    LinearGradient(
                        colors: [
                            theme.accent.opacity(isDark ? 0.08 : 0.05),
                            Color.clear
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .ignoresSafeArea(.container, edges: .vertical)
        )
    }
}

private struct ChatsListView: View {
    private enum ChatSortMode: String, CaseIterable, Identifiable {
        case unread
        case recent
        case name

        var id: String { rawValue }

        var title: String {
            switch self {
            case .unread:
                return "Unread First"
            case .recent:
                return "Recent First"
            case .name:
                return "Name"
            }
        }

        var icon: String {
            switch self {
            case .unread:
                return "bubble.left.and.bubble.right"
            case .recent:
                return "clock.arrow.circlepath"
            case .name:
                return "textformat.abc"
            }
        }
    }

    @ObservedObject var model: ClientViewModel
    let onAddContact: () -> Void
    let onAddGroup: () -> Void
    @EnvironmentObject private var screenProtection: ScreenProtectionMonitor
    @State private var searchText = ""
    @AppStorage("noctyra.chat.sortMode.v1") private var sortModeRaw = ChatSortMode.unread.rawValue
    @AppStorage("noctyra.chat.pinnedContacts.v1") private var pinnedContactsRaw = ""
    @AppStorage("noctyra.chat.pinnedGroups.v1") private var pinnedGroupsRaw = ""
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            NoctyraTopBar(
                title: "Chats",
                subtitle: "Post-quantum chat",
                trailing: AnyView(
                    HStack(spacing: 8) {
                        Menu {
                            Section("Sort") {
                                ForEach(ChatSortMode.allCases) { mode in
                                    Button {
                                        sortModeRaw = mode.rawValue
                                    } label: {
                                        if sortMode == mode {
                                            Label(mode.title, systemImage: "checkmark")
                                        } else {
                                            Label(mode.title, systemImage: mode.icon)
                                        }
                                    }
                                }
                            }
                            Section {
                                Button("Clear All Pins", role: .destructive) {
                                    clearAllPins()
                                }
                                .disabled(pinnedContactIds.isEmpty && pinnedGroupIds.isEmpty)
                            }
                        } label: {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .accessibilityLabel("Sort and Pin Options")
                        .glassCircleButton(diameter: 34)
                        .hoverLift()
                        Menu {
                            Button {
                                onAddContact()
                                FeedbackGenerator.light()
                            } label: {
                                Label("New Contact", systemImage: "person.badge.plus")
                            }
                            Button {
                                onAddGroup()
                                FeedbackGenerator.light()
                            } label: {
                                Label("New Group", systemImage: "person.3.fill")
                            }
                        } label: {
                            Image(systemName: "square.and.pencil")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .accessibilityLabel("New Chat")
                        .glassCircleButton(prominent: true, diameter: 34)
                        .hoverLift()
                    }
                )
            )
            InlineSearchField(text: $searchText, prompt: "Search chats")
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 6)

            if screenProtection.isSensitiveHidden {
                SensitiveContentPlaceholder(
                    title: "Chats Hidden",
                    message: "Screen capture or an external display is active. Chat list is hidden to protect your operational security."
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        chatSectionHeader(
                            title: "Groups",
                            symbol: "person.3.fill",
                            count: filteredGroups.count
                        )
                        if filteredGroups.isEmpty {
                            chatEmptyState(
                                hasActiveSearch ? "No matching groups" : "No groups yet",
                                symbol: "person.3"
                            )
                        } else {
                            VStack(spacing: 8) {
                                ForEach(filteredGroups) { group in
                                    NavigationLink {
                                        if let refreshed = model.state.group(for: group.id) {
                                            GroupConversationView(model: model, group: refreshed)
                                        } else {
                                            PlaceholderView(title: "Group not found")
                                        }
                                    } label: {
                                        chatRow(
                                            symbol: "person.3.fill",
                                            title: group.title,
                                            preview: groupPreview(for: group),
                                            timestamp: lastGroupTimestamp(for: group),
                                            unreadCount: model.state.group(for: group.id)?.unreadCount ?? 0,
                                            isPinned: isPinnedGroup(group.id)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("group-chat-\(group.id.uuidString)")
                                    .contextMenu {
                                        Button(isPinnedGroup(group.id) ? "Unpin Group" : "Pin Group") {
                                            togglePinnedGroup(group.id)
                                        }
                                    }
                                }
                            }
                        }

                        chatSectionHeader(
                            title: "Contacts",
                            symbol: "person.2.fill",
                            count: filteredContacts.count
                        )
                        if filteredContacts.isEmpty {
                            chatEmptyState(
                                hasActiveSearch ? "No matching contacts" : "No contacts yet",
                                symbol: "person.crop.circle.badge.plus"
                            )
                        } else {
                            VStack(spacing: 8) {
                                ForEach(filteredContacts) { contact in
                                    NavigationLink {
                                        ConversationView(model: model, contact: contact)
                                    } label: {
                                        chatRow(
                                            symbol: "person.fill",
                                            title: contact.displayName,
                                            preview: contactPreview(for: contact),
                                            timestamp: lastContactTimestamp(for: contact),
                                            unreadCount: model.state.conversation(for: contact.id)?.unreadCount ?? 0,
                                            isPinned: isPinnedContact(contact.id)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("chat-\(contact.id.uuidString)")
                                    .contextMenu {
                                        Button(isPinnedContact(contact.id) ? "Unpin Contact" : "Pin Contact") {
                                            togglePinnedContact(contact.id)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }
                .privacySensitive()
            }
        }
        .glassBackgroundIfNeeded()
        .toolbar(.hidden, for: .navigationBar)
    }

    private var hasActiveSearch: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func chatSectionHeader(title: String, symbol: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption.weight(.bold))
                .textCase(.uppercase)
                .tracking(0.7)
            Spacer()
            Text("\(count)")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.ultraThinMaterial, in: Capsule())
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }

    private func chatEmptyState(_ title: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
                .background(.ultraThinMaterial, in: Circle())
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .uniformGlassCard(cornerRadius: 16, padding: 12, minHeight: 58)
    }

    private func chatRow(
        symbol: String,
        title: String,
        preview: String,
        timestamp: Date?,
        unreadCount: Int,
        isPinned: Bool
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(unreadCount > 0 ? Color.accentColor : Color.secondary)
                .frame(width: 36, height: 36)
                .background(
                    Circle()
                        .fill(unreadCount > 0 ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.08))
                )
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.body.weight(unreadCount > 0 ? .semibold : .medium))
                        .lineLimit(1)
                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                if let timestamp {
                    Text(Self.chatTimeFormatter.string(from: timestamp))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if unreadCount > 0 {
                    UnreadBadge(count: unreadCount)
                } else {
                    EmptyView()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(minHeight: 62)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.black.opacity(colorScheme == .dark ? 0.12 : 0.045))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    theme.accent.opacity(unreadCount > 0 ? 0.11 : 0.045),
                                    Color.clear
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(colorScheme == .dark ? 0.10 : 0.16), lineWidth: 0.7)
        )
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var sortMode: ChatSortMode {
        ChatSortMode(rawValue: sortModeRaw) ?? .unread
    }

    private var pinnedContactIds: Set<UUID> {
        Self.decodePinnedIDs(from: pinnedContactsRaw)
    }

    private var pinnedGroupIds: Set<UUID> {
        Self.decodePinnedIDs(from: pinnedGroupsRaw)
    }

    private var filteredGroups: [GroupConversation] {
        let filtered = model.state.groups.filter { group in
            guard hasActiveSearch else { return true }
            let haystack = "\(group.title) \(groupPreview(for: group))".lowercased()
            return haystack.contains(normalizedSearchText)
        }
        return filtered.sorted(by: compareGroups(_:_:))
    }

    private var filteredContacts: [Contact] {
        let filtered = model.state.contacts.filter { contact in
            guard hasActiveSearch else { return true }
            let haystack = "\(contact.displayName) \(contactPreview(for: contact))".lowercased()
            return haystack.contains(normalizedSearchText)
        }
        return filtered.sorted(by: compareContacts(_:_:))
    }

    private func compareGroups(_ lhs: GroupConversation, _ rhs: GroupConversation) -> Bool {
        let lhsPinned = isPinnedGroup(lhs.id)
        let rhsPinned = isPinnedGroup(rhs.id)
        if lhsPinned != rhsPinned {
            return lhsPinned
        }
        let lhsUnread = model.state.group(for: lhs.id)?.unreadCount ?? lhs.unreadCount
        let rhsUnread = model.state.group(for: rhs.id)?.unreadCount ?? rhs.unreadCount
        let lhsDate = lastGroupTimestamp(for: lhs) ?? lhs.createdAt
        let rhsDate = lastGroupTimestamp(for: rhs) ?? rhs.createdAt
        switch sortMode {
        case .unread:
            if lhsUnread != rhsUnread {
                return lhsUnread > rhsUnread
            }
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }
        case .recent:
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }
            if lhsUnread != rhsUnread {
                return lhsUnread > rhsUnread
            }
        case .name:
            let nameOrder = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }
        }
        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }

    private func compareContacts(_ lhs: Contact, _ rhs: Contact) -> Bool {
        let lhsPinned = isPinnedContact(lhs.id)
        let rhsPinned = isPinnedContact(rhs.id)
        if lhsPinned != rhsPinned {
            return lhsPinned
        }
        let lhsUnread = model.state.conversation(for: lhs.id)?.unreadCount ?? 0
        let rhsUnread = model.state.conversation(for: rhs.id)?.unreadCount ?? 0
        let lhsDate = lastContactTimestamp(for: lhs) ?? .distantPast
        let rhsDate = lastContactTimestamp(for: rhs) ?? .distantPast
        switch sortMode {
        case .unread:
            if lhsUnread != rhsUnread {
                return lhsUnread > rhsUnread
            }
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }
        case .recent:
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }
            if lhsUnread != rhsUnread {
                return lhsUnread > rhsUnread
            }
        case .name:
            let nameOrder = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }
        }
        return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
    }

    private func isPinnedContact(_ id: UUID) -> Bool {
        pinnedContactIds.contains(id)
    }

    private func isPinnedGroup(_ id: UUID) -> Bool {
        pinnedGroupIds.contains(id)
    }

    private func togglePinnedContact(_ id: UUID) {
        var ids = pinnedContactIds
        if ids.contains(id) {
            ids.remove(id)
        } else {
            ids.insert(id)
        }
        pinnedContactsRaw = Self.encodePinnedIDs(ids)
        FeedbackGenerator.light()
    }

    private func togglePinnedGroup(_ id: UUID) {
        var ids = pinnedGroupIds
        if ids.contains(id) {
            ids.remove(id)
        } else {
            ids.insert(id)
        }
        pinnedGroupsRaw = Self.encodePinnedIDs(ids)
        FeedbackGenerator.light()
    }

    private func clearAllPins() {
        pinnedContactsRaw = ""
        pinnedGroupsRaw = ""
        FeedbackGenerator.light()
    }

    private func lastGroupTimestamp(for group: GroupConversation) -> Date? {
        model.latestGroupMessage(groupId: group.id)?.timestamp
    }

    private func lastContactTimestamp(for contact: Contact) -> Date? {
        model.latestDirectMessage(contactId: contact.id)?.timestamp
    }

    private func groupPreview(for group: GroupConversation) -> String {
        previewText(for: model.latestGroupMessage(groupId: group.id))
    }

    private func contactPreview(for contact: Contact) -> String {
        previewText(for: model.latestDirectMessage(contactId: contact.id))
    }

    private func previewText(for message: NoctweaveCore.Message?) -> String {
        guard let message else { return "No messages yet" }
        if message.isMismatch {
            return "Delivery sync pending"
        }
        if message.attachment != nil {
            return message.direction == .sent ? "Attachment sent" : "Attachment received"
        }
        return message.direction == .sent ? "Message sent" : "Message received"
    }

    private static let chatTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private static func decodePinnedIDs(from raw: String) -> Set<UUID> {
        Set(
            raw.split(separator: ",")
                .compactMap { UUID(uuidString: String($0)) }
        )
    }

    private static func encodePinnedIDs(_ ids: Set<UUID>) -> String {
        ids
            .map(\.uuidString)
            .sorted()
            .joined(separator: ",")
    }
}

private struct ContactBookTabView: View {
    @ObservedObject var model: ClientViewModel
    let onAddContact: () -> Void

    private struct Route: Identifiable, Hashable {
        let id: UUID
    }

    @State private var route: Route?

    var body: some View {
        ContactBookView(model: model) { contactId in
            route = Route(id: contactId)
        } onAdd: {
            onAddContact()
        }
        .navigationDestination(item: $route) { route in
            if let contact = model.state.contacts.first(where: { $0.id == route.id }) {
                ConversationView(model: model, contact: contact)
            } else {
                PlaceholderView(title: "Contact not found")
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}
#endif

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

private struct EmptyConversationState: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .padding(.horizontal, 32)
    }
}

private struct ChatWallpaper: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    private var isDark: Bool {
        colorScheme == .dark
    }

    var body: some View {
        GeometryReader { proxy in
            #if os(iOS)
            let renderSize = IOSControlMetrics.stableScreenSize(fallback: proxy.size)
            #else
            let renderSize = proxy.size
            #endif
            ZStack {
                LinearGradient(
                    colors: [
                        Color.black.opacity(isDark ? 0.18 : 0.03),
                        theme.backgroundTint.opacity(isDark ? 0.36 : 0.18),
                        theme.glowSecondary.opacity(isDark ? 0.14 : 0.08)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                Image(assetName(for: renderSize))
                    .resizable()
                    .scaledToFill()
                    .frame(width: renderSize.width, height: renderSize.height)
                    .clipped()
                    .opacity(isDark ? 0.30 : 0.24)
                    .blendMode(isDark ? .plusLighter : .normal)

                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.black.opacity(isDark ? 0.04 : 0.00),
                                Color.black.opacity(isDark ? 0.18 : 0.04)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
            .frame(width: renderSize.width, height: renderSize.height)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .allowsHitTesting(false)
    }

    private func assetName(for size: CGSize) -> String {
        let usesTabletArtwork = size.width >= 700 || size.width > size.height
        switch (usesTabletArtwork, isDark) {
        case (true, true):
            return "ChatDoodlesTabletDark"
        case (true, false):
            return "ChatDoodlesTablet"
        case (false, true):
            return "ChatDoodlesPhoneDark"
        case (false, false):
            return "ChatDoodlesPhone"
        }
    }
}

#if os(iOS)
private struct ChatTopBar: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let title: String
    let status: String
    var trailing: AnyView? = nil
    var onBack: (() -> Void)? = nil

    private var isDark: Bool { colorScheme == .dark }
    private var isRegularWidth: Bool { horizontalSizeClass == .regular }
    private var isPad: Bool { IOSControlMetrics.isPad }
    private var buttonDiameter: CGFloat { isPad ? IOSControlMetrics.circleButtonDiameter : (isRegularWidth ? 58 : 34) }
    private var titleSize: CGFloat { isPad ? 27 : (isRegularWidth ? 28 : 18) }
    private var statusSize: CGFloat { isPad ? 15 : (isRegularWidth ? 17 : 12) }
    private var horizontalPadding: CGFloat { isPad ? 22 : (isRegularWidth ? 24 : 12) }
    private var verticalPadding: CGFloat { isPad ? 12 : (isRegularWidth ? 14 : 8) }
    private var barMinHeight: CGFloat { isPad ? 76 : (isRegularWidth ? 84 : 52) }

    var body: some View {
        HStack(spacing: isRegularWidth ? 12 : 9) {
            Button {
                onBack?()
                dismiss()
                FeedbackGenerator.light()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: isPad ? IOSControlMetrics.circleIconSize : (isRegularWidth ? 24 : 15), weight: .semibold))
            }
            .accessibilityLabel("Back")
            .glassCircleButton(diameter: buttonDiameter)
            .hoverLift()

            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: titleSize, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .layoutPriority(1)

                if !status.isEmpty {
                    Circle()
                        .fill(Color.secondary.opacity(0.55))
                        .frame(width: isPad ? 7 : (isRegularWidth ? 5 : 3.5), height: isPad ? 7 : (isRegularWidth ? 5 : 3.5))
                        .accessibilityHidden(true)
                    Text(status)
                        .font(.system(size: statusSize, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .layoutPriority(0)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            if let trailing {
                trailing
            }
        }
        .frame(maxWidth: .infinity, minHeight: barMinHeight, alignment: .center)
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    theme.accent.opacity(isDark ? 0.075 : 0.045),
                                    theme.glowSecondary.opacity(isDark ? 0.045 : 0.025),
                                    Color.clear
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Color.white.opacity(isDark ? 0.055 : 0.10))
                        .frame(height: 0.5)
                }
                .allowsHitTesting(false)
                .ignoresSafeArea(.container, edges: [.top, .leading, .trailing])
        }
        .shadow(color: theme.accent.opacity(isDark ? 0.055 : 0.035), radius: 8, x: 0, y: 3)
    }
}
#endif

private struct InlineSearchField: View {
    @Binding var text: String
    let prompt: String
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .searchInputBehavior()
                .textFieldStyle(.plain)
                .background(Color.clear)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            Capsule(style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(isDark ? 0.10 : 0.75),
                            Color.white.opacity(isDark ? 0.05 : 0.58)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    theme.accent.opacity(isDark ? 0.14 : 0.10),
                                    theme.glowSecondary.opacity(isDark ? 0.07 : 0.04),
                                    Color.clear
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.white.opacity(isDark ? 0.22 : 0.28), lineWidth: 0.8)
        )
        .clipShape(Capsule(style: .continuous))
        .compositingGroup()
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
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    private var isDark: Bool { colorScheme == .dark }

    @ViewBuilder
    var body: some View {
        #if os(macOS)
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.black.opacity(isDark ? 0.20 : 0.08))
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                theme.accent.opacity(isDark ? 0.18 : 0.12),
                                theme.glowSecondary.opacity(isDark ? 0.10 : 0.06),
                                Color.white.opacity(isDark ? 0.03 : 0.06)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .blendMode(.plusLighter)
                    .opacity(isDark ? 0.75 : 0.55)
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(isDark ? 0.26 : 0.42),
                            theme.accent.opacity(isDark ? 0.20 : 0.16),
                            Color.white.opacity(isDark ? 0.08 : 0.10)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.9
                )
        )
        // Align with the sidebar header baseline (which is pushed down to clear the floating window controls).
        .padding(.top, 32)
        .padding(.bottom, 6)
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
    @State private var showingVoiceRecorder = false
    @EnvironmentObject private var screenProtection: ScreenProtectionMonitor
    #if os(iOS)
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showingSecureCamera = false
    @State private var showingInsecureCamera = false
    @State private var showCameraChoiceAlert = false
    @AppStorage("lattice.secureCameraPromptShown.v1") private var secureCameraPromptShown = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #else
    @State private var showingAttachmentImporter = false
    #endif
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
    @FocusState private var isComposerFocused: Bool
    #endif

    private var isDark: Bool {
        colorScheme == .dark
    }

    var body: some View {
        let messages = model.directMessagesForDisplay(contactId: contact.id)
        let isSensitiveHidden = screenProtection.isSensitiveHidden
        let isRevealed = revealMessages && !isSensitiveHidden
        VStack(spacing: 0) {
            #if os(iOS)
            ChatTopBar(
                title: isSensitiveHidden ? "Secure Chat" : contact.displayName,
                status: isSensitiveHidden ? "Capture active" : "Secure chat",
                trailing: AnyView(
                    HStack(spacing: chatHeaderSpacing) {
                        Button {
                            showingClearChatConfirm = true
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: chatHeaderIconSize, weight: .semibold))
                        }
                        .accessibilityLabel("Clear Chat")
                        .glassCircleButton(diameter: chatHeaderButtonDiameter)
                        .hoverLift()
                        RevealToggleButton(
                            isRevealed: $revealMessages,
                            isDisabled: isSensitiveHidden,
                            diameter: chatHeaderButtonDiameter,
                            iconSize: chatHeaderIconSize
                        )
                    }
                ),
                onBack: {
                    Task { await deactivateConversation(contact.id) }
                }
            )
            #else
            HStack(alignment: .center) {
                ZStack {
                    Circle()
                        .fill(theme.accent.opacity(isSensitiveHidden ? 0.12 : 0.18))
                    Image(systemName: isSensitiveHidden ? "eye.slash.fill" : "lock.shield.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.accent)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 2) {
                    if isSensitiveHidden {
                        Text("Secure chat hidden")
                            .font(.system(size: 18, weight: .semibold, design: .rounded))
                        Text("Screen capture is active")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(contact.displayName)
                            .font(.system(size: 18, weight: .semibold, design: .rounded))
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
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.black.opacity(isDark ? 0.18 : 0.07))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        theme.accent.opacity(isDark ? 0.14 : 0.09),
                                        theme.glowSecondary.opacity(isDark ? 0.08 : 0.05),
                                        Color.clear
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.white.opacity(isDark ? 0.22 : 0.34), lineWidth: 0.8)
                    )
            )
            .shadow(color: theme.accent.opacity(isDark ? 0.10 : 0.06), radius: 12, x: 0, y: 5)
            .padding(.horizontal, 18)
            .padding(.top, 42)
            .padding(.bottom, 10)
            #endif
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        if messages.isEmpty {
                            EmptyConversationState(title: "No messages yet", subtitle: "Send a message to start this secure chat.")
                        } else {
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
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
                }
                .onAppear {
                    scrollToBottom(messages, proxy: proxy, animated: false)
                }
                .onChange(of: messages.count) { _, _ in
                    scrollToBottom(messages, proxy: proxy, animated: true)
                }
                #if os(iOS)
                .contentShape(Rectangle())
                .simultaneousGesture(
                    TapGesture().onEnded {
                        dismissActiveTextInput()
                    }
                )
                #endif
            }

            HStack(spacing: 8) {
                #if os(iOS)
                Button {
                    handleCameraButtonTap()
                } label: {
                    Image(systemName: "camera")
                        .font(.system(size: IOSControlMetrics.circleIconSize, weight: .semibold))
                }
                .accessibilityLabel("Capture Photo")
                .accessibilityHint("Enable in Settings > Privacy to capture within Noctyra.")
                .glassCircleButton(diameter: IOSControlMetrics.circleButtonDiameter)
                .hoverLift()
                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    Image(systemName: "paperclip")
                        .font(.system(size: IOSControlMetrics.circleIconSize, weight: .semibold))
                }
                .accessibilityLabel("Attach Image")
                .glassCircleButton(diameter: IOSControlMetrics.circleButtonDiameter)
                .hoverLift()
                Button {
                    showingVoiceRecorder = true
                } label: {
                    Image(systemName: "mic")
                        .font(.system(size: IOSControlMetrics.circleIconSize, weight: .semibold))
                }
                .accessibilityLabel("Record Voice Message")
                .glassCircleButton(diameter: IOSControlMetrics.circleButtonDiameter)
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
                Button {
                    showingVoiceRecorder = true
                } label: {
                    Image(systemName: "mic")
                        .font(.system(size: 14, weight: .semibold))
                }
                .accessibilityLabel("Record Voice Message")
                .glassCircleButton(diameter: 34)
                .hoverLift()
                #endif
                #if os(iOS)
                MessageInputField(
                    text: $messageText,
                    secureTypingEnabled: model.state.privacy.secureTypingEnabled,
                    secureTypingKeyboard: model.state.privacy.secureTypingKeyboard
                ) {
                    sendMessage()
                }
                #else
                TextField("Message", text: $messageText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .submitLabel(.send)
                    .padding(.vertical, 7)
                    .padding(.horizontal, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.black.opacity(isDark ? 0.16 : 0.05))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(Color.white.opacity(isDark ? 0.14 : 0.24), lineWidth: 0.7)
                            )
                    )
                    .focused($isComposerFocused)
                    .onSubmit {
                        sendMessage()
                    }
                #endif
                Button {
                    sendMessage()
                } label: {
                    Image(systemName: "paperplane.fill")
                        #if os(iOS)
                        .font(.system(size: IOSControlMetrics.prominentCircleIconSize, weight: .semibold))
                        #else
                        .font(.system(size: 15, weight: .semibold))
                        #endif
                }
                .accessibilityLabel("Send")
                #if os(iOS)
                .glassCircleButton(prominent: true, diameter: IOSControlMetrics.circleButtonDiameter)
                #else
                .glassCircleButton(prominent: true, diameter: 34)
                #endif
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
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.black.opacity(isDark ? 0.16 : 0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.white.opacity(isDark ? 0.18 : 0.30), lineWidth: 0.8)
                    )
            )
            #endif
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
        }
        .background {
            ChatWallpaper()
                .ignoresSafeArea()
        }
        .glassBackgroundIfNeeded()
        .privacySensitive()
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .sheet(isPresented: $showingVoiceRecorder) {
            VoiceRecorderSheetView(
                onRecorded: { data, fileName, mimeType in
                    Task {
                        await model.sendAttachment(
                            data: data,
                            fileName: fileName,
                            mimeType: mimeType,
                            to: contact.id
                        )
                    }
                    showingVoiceRecorder = false
                },
                onError: { message in
                    model.lastError = message
                    showingVoiceRecorder = false
                },
                onCancel: {
                    showingVoiceRecorder = false
                }
            )
            .noctyraSheetPresentation()
        }
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
        .confirmationDialog("Clear chat?", isPresented: $showingClearChatConfirm) {
            Button("Clear Chat", role: .destructive) {
                Task { await model.clearConversation(contactId: contact.id) }
            }
        } message: {
            Text("This removes messages from this device only and does not affect encryption or your contact.")
        }
        .task(id: contact.id) {
            await activateConversation(contact.id)
        }
        .onChange(of: contact.id) { oldValue, _ in
            Task { await deactivateConversation(oldValue) }
        }
        .onAppear {
            revealMessages = false
            screenProtection.refresh()
            #if os(macOS)
            updateSecureInput()
            #endif
        }
        .onDisappear {
            #if os(iOS)
            revealMessages = false
            #else
            if model.activeContactId == contact.id {
                model.activeContactId = nil
            }
            Task { await deactivateConversation(contact.id) }
            revealMessages = false
            SecureEventInputController.shared.setEnabled(false)
            #endif
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                Task { await model.closeConversation(contactId: contact.id) }
                revealMessages = false
                #if os(macOS)
                SecureEventInputController.shared.setEnabled(false)
                #endif
            } else if newPhase == .active {
                Task { await activateConversation(contact.id) }
            }
        }
        .onChange(of: screenProtection.isSensitiveHidden) { _, newValue in
            if newValue {
                model.purgeAttachmentDecryptionMemory(contactId: contact.id)
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

    #if os(iOS)
    private var isRegularWidth: Bool {
        horizontalSizeClass == .regular
    }

    private var chatHeaderButtonDiameter: CGFloat {
        IOSControlMetrics.isPad ? IOSControlMetrics.circleButtonDiameter : (isRegularWidth ? 58 : 32)
    }

    private var chatHeaderIconSize: CGFloat {
        IOSControlMetrics.isPad ? IOSControlMetrics.circleIconSize : (isRegularWidth ? 22 : 14)
    }

    private var chatHeaderSpacing: CGFloat {
        IOSControlMetrics.isPad ? 16 : (isRegularWidth ? 14 : 8)
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
            let data = try readBoundedFile(url, maxBytes: 32 * 1024 * 1024)
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

    private func scrollToBottom(_ messages: [NoctweaveCore.Message], proxy: ScrollViewProxy, animated: Bool) {
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

    private func activateConversation(_ contactId: UUID) async {
        model.activeContactId = contactId
        model.activeGroupId = nil
        await model.openConversation(contactId: contactId)
        await model.markConversationRead(contactId: contactId)
    }

    private func deactivateConversation(_ contactId: UUID) async {
        await model.closeConversation(contactId: contactId)
        if model.activeContactId == contactId {
            model.activeContactId = nil
        }
    }
}

private struct GroupConversationView: View {
    @ObservedObject var model: ClientViewModel
    let group: GroupConversation
    @State private var messageText = ""
    @State private var revealMessages = false
    @State private var showingClearChatConfirm = false
    @State private var showingGroupDetails = false
    @State private var showingVoiceRecorder = false
    @EnvironmentObject private var screenProtection: ScreenProtectionMonitor
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showingSecureCamera = false
    @State private var showingInsecureCamera = false
    @State private var showCameraChoiceAlert = false
    @AppStorage("lattice.secureCameraPromptShown.v1") private var secureCameraPromptShown = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #else
    @State private var showingAttachmentImporter = false
    #endif
    #if os(macOS)
    @FocusState private var isComposerFocused: Bool
    #endif

    private var resolvedGroup: GroupConversation? {
        model.state.group(for: group.id)
    }

    private var groupTitle: String {
        resolvedGroup?.title ?? group.title
    }

    private var groupMessages: [NoctweaveCore.Message] {
        model.groupMessagesForDisplay(groupId: group.id)
    }

    private var memberCount: Int {
        resolvedGroup?.resolvedMemberCount ?? group.resolvedMemberCount
    }

    private var currentGroup: GroupConversation {
        resolvedGroup ?? group
    }

    private var isGroupUnavailable: Bool {
        resolvedGroup == nil
    }

    private var isPendingInvitation: Bool {
        currentGroup.isPendingInvitation
    }

    private var groupStatusText: String {
        if isPendingInvitation {
            return "Invitation pending"
        }
        return "\(memberCount) members"
    }

    private var groupInviterName: String {
        guard let creator = currentGroup.createdByFingerprint else {
            return "a group member"
        }
        if let contact = model.state.contacts.first(where: { $0.fingerprint == creator }) {
            return contact.displayName
        }
        if let member = currentGroup.memberProfiles.first(where: { $0.fingerprint == creator }),
           let name = member.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return name
        }
        return "Group Member \(creator.prefix(8))"
    }

    private var isDark: Bool {
        colorScheme == .dark
    }

    var body: some View {
        let isSensitiveHidden = screenProtection.isSensitiveHidden
        let isRevealed = revealMessages && !isSensitiveHidden
        VStack(spacing: 0) {
            #if os(iOS)
            ChatTopBar(
                title: isSensitiveHidden ? "Secure Group" : groupTitle,
                status: isSensitiveHidden ? "Capture active" : groupStatusText,
                trailing: AnyView(
                    HStack(spacing: chatHeaderSpacing) {
                        if !isPendingInvitation {
                            Button {
                                showingGroupDetails = true
                            } label: {
                                Image(systemName: "slider.horizontal.3")
                                    .font(.system(size: chatHeaderIconSize, weight: .semibold))
                            }
                            .accessibilityLabel("Group Settings")
                            .glassCircleButton(diameter: chatHeaderButtonDiameter)
                            .hoverLift()
                            Button {
                                showingClearChatConfirm = true
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: chatHeaderIconSize, weight: .semibold))
                            }
                            .accessibilityLabel("Clear Group Chat")
                            .glassCircleButton(diameter: chatHeaderButtonDiameter)
                            .hoverLift()
                            RevealToggleButton(
                                isRevealed: $revealMessages,
                                isDisabled: isSensitiveHidden,
                                diameter: chatHeaderButtonDiameter,
                                iconSize: chatHeaderIconSize
                            )
                        }
                    }
                ),
                onBack: {
                    Task { await deactivateGroup(group.id) }
                }
            )
            #else
            HStack(alignment: .center) {
                ZStack {
                    Circle()
                        .fill(theme.accent.opacity(isSensitiveHidden ? 0.12 : 0.18))
                    Image(systemName: isSensitiveHidden ? "eye.slash.fill" : "person.3.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.accent)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 2) {
                    if isSensitiveHidden {
                        Text("Secure group hidden")
                            .font(.system(size: 18, weight: .semibold, design: .rounded))
                        Text("Screen capture is active")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(groupTitle)
                            .font(.system(size: 18, weight: .semibold, design: .rounded))
                        Text(groupStatusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if !isPendingInvitation {
                    Button {
                        showingGroupDetails = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .accessibilityLabel("Group Settings")
                    .glassCircleButton(diameter: 30)
                    .hoverLift()
                    Button {
                        showingClearChatConfirm = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .accessibilityLabel("Clear Group Chat")
                    .glassCircleButton(diameter: 30)
                    .hoverLift()
                    RevealToggleButton(isRevealed: $revealMessages, isDisabled: isSensitiveHidden)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.black.opacity(isDark ? 0.18 : 0.07))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        theme.accent.opacity(isDark ? 0.14 : 0.09),
                                        theme.glowSecondary.opacity(isDark ? 0.08 : 0.05),
                                        Color.clear
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.white.opacity(isDark ? 0.22 : 0.34), lineWidth: 0.8)
                    )
            )
            .shadow(color: theme.accent.opacity(isDark ? 0.10 : 0.06), radius: 12, x: 0, y: 5)
            .padding(.horizontal, 18)
            .padding(.top, 42)
            .padding(.bottom, 10)
            #endif

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        if isPendingInvitation {
                            GroupInvitationPanel(
                                title: groupTitle,
                                inviterName: groupInviterName,
                                onAccept: {
                                    Task { await model.acceptGroupInvitation(id: group.id) }
                                },
                                onDecline: {
                                    Task { await model.declineGroupInvitation(id: group.id) }
                                }
                            )
                            .padding(.horizontal, 2)
                            .padding(.vertical, 8)
                        } else if groupMessages.isEmpty {
                            EmptyConversationState(title: "No messages yet", subtitle: "Messages sent here are shared with this group.")
                        } else {
                            ForEach(groupMessages) { message in
                                MessageRow(model: model, message: message, isRevealed: isRevealed, onRetry: nil)
                                    .id(message.id)
                                    .contextMenu {
                                        Button("Delete Message", role: .destructive) {
                                            Task { await model.deleteGroupMessage(groupId: group.id, messageId: message.id) }
                                        }
                                    }
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
                }
                .onAppear {
                    scrollToBottom(groupMessages, proxy: proxy, animated: false)
                }
                .onChange(of: groupMessages.count) { _, _ in
                    scrollToBottom(groupMessages, proxy: proxy, animated: true)
                }
                #if os(iOS)
                .contentShape(Rectangle())
                .simultaneousGesture(
                    TapGesture().onEnded {
                        dismissActiveTextInput()
                    }
                )
                #endif
            }

            if !isPendingInvitation {
                HStack(spacing: 8) {
                #if os(iOS)
                Button {
                    handleCameraButtonTap()
                } label: {
                    Image(systemName: "camera")
                        .font(.system(size: IOSControlMetrics.circleIconSize, weight: .semibold))
                }
                .accessibilityLabel("Capture Group Photo")
                .glassCircleButton(diameter: IOSControlMetrics.circleButtonDiameter)
                .hoverLift()
                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    Image(systemName: "paperclip")
                        .font(.system(size: IOSControlMetrics.circleIconSize, weight: .semibold))
                }
                .accessibilityLabel("Attach Group Image")
                .glassCircleButton(diameter: IOSControlMetrics.circleButtonDiameter)
                .hoverLift()
                Button {
                    showingVoiceRecorder = true
                } label: {
                    Image(systemName: "mic")
                        .font(.system(size: IOSControlMetrics.circleIconSize, weight: .semibold))
                }
                .accessibilityLabel("Record Group Voice Message")
                .glassCircleButton(diameter: IOSControlMetrics.circleButtonDiameter)
                .hoverLift()
                MessageInputField(
                    text: $messageText,
                    secureTypingEnabled: model.state.privacy.secureTypingEnabled,
                    secureTypingKeyboard: model.state.privacy.secureTypingKeyboard
                ) {
                    sendMessage()
                }
                #else
                Button {
                    showingAttachmentImporter = true
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 14, weight: .semibold))
                }
                .accessibilityLabel("Attach Group Image")
                .glassCircleButton(diameter: 34)
                .hoverLift()
                Button {
                    showingVoiceRecorder = true
                } label: {
                    Image(systemName: "mic")
                        .font(.system(size: 14, weight: .semibold))
                }
                .accessibilityLabel("Record Group Voice Message")
                .glassCircleButton(diameter: 34)
                .hoverLift()
                TextField("Message", text: $messageText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .submitLabel(.send)
                    .padding(.vertical, 7)
                    .padding(.horizontal, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.black.opacity(isDark ? 0.16 : 0.05))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(Color.white.opacity(isDark ? 0.14 : 0.24), lineWidth: 0.7)
                            )
                    )
                    .focused($isComposerFocused)
                    .onSubmit {
                        sendMessage()
                    }
                #endif
                Button {
                    sendMessage()
                } label: {
                    Image(systemName: "paperplane.fill")
                        #if os(iOS)
                        .font(.system(size: IOSControlMetrics.prominentCircleIconSize, weight: .semibold))
                        #else
                        .font(.system(size: 15, weight: .semibold))
                        #endif
                }
                .accessibilityLabel("Send Group Message")
                #if os(iOS)
                .glassCircleButton(prominent: true, diameter: IOSControlMetrics.circleButtonDiameter)
                #else
                .glassCircleButton(prominent: true, diameter: 34)
                #endif
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
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.black.opacity(isDark ? 0.16 : 0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.white.opacity(isDark ? 0.18 : 0.30), lineWidth: 0.8)
                    )
            )
            #endif
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            }
        }
        .background {
            ChatWallpaper()
                .ignoresSafeArea()
        }
        .glassBackgroundIfNeeded()
        .privacySensitive()
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .sheet(isPresented: $showingGroupDetails) {
            GroupDetailsView(model: model, groupId: group.id) {
                closeGroupView()
            }
                .noctyraSheetPresentation()
        }
        .sheet(isPresented: $showingVoiceRecorder) {
            VoiceRecorderSheetView(
                onRecorded: { data, fileName, mimeType in
                    Task {
                        await model.sendGroupAttachment(
                            data: data,
                            fileName: fileName,
                            mimeType: mimeType,
                            to: group.id
                        )
                    }
                    showingVoiceRecorder = false
                },
                onError: { message in
                    model.lastError = message
                    showingVoiceRecorder = false
                },
                onCancel: {
                    showingVoiceRecorder = false
                }
            )
            .noctyraSheetPresentation()
        }
        #if os(iOS)
        .onChange(of: selectedPhoto) { _, newItem in
            guard let newItem else { return }
            Task { await handlePickedPhoto(newItem) }
        }
        .sheet(isPresented: $showingSecureCamera) {
            SecureCameraCaptureView(
                onCapture: { data in
                    Task {
                        await model.sendGroupAttachment(
                            data: data,
                            fileName: "camera.jpg",
                            mimeType: "image/jpeg",
                            to: group.id
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
                        await model.sendGroupAttachment(
                            data: data,
                            fileName: "camera.jpg",
                            mimeType: "image/jpeg",
                            to: group.id
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
        .confirmationDialog("Clear group chat?", isPresented: $showingClearChatConfirm) {
            Button("Clear Chat", role: .destructive) {
                Task { await model.clearGroupConversation(groupId: group.id) }
            }
        } message: {
            Text("This removes local group messages from this device only.")
        }
        .task(id: group.id) {
            await activateGroup(group.id)
        }
        .onChange(of: group.id) { oldValue, _ in
            Task { await deactivateGroup(oldValue) }
        }
        .onChange(of: isGroupUnavailable) { _, unavailable in
            if unavailable {
                closeGroupView()
            }
        }
        .onAppear {
            revealMessages = false
            screenProtection.refresh()
        }
        .onDisappear {
            #if os(iOS)
            revealMessages = false
            #else
            if model.activeGroupId == group.id {
                model.activeGroupId = nil
            }
            Task { await deactivateGroup(group.id) }
            revealMessages = false
            #endif
        }
        .onChange(of: screenProtection.isSensitiveHidden) { _, newValue in
            if newValue {
                model.purgeAttachmentDecryptionMemory(groupId: group.id)
                revealMessages = false
            }
        }
        .onChange(of: scenePhase) { _, newValue in
            if newValue == .background {
                Task { await model.closeGroupConversation(groupId: group.id) }
                revealMessages = false
            } else if newValue == .active {
                Task { await activateGroup(group.id) }
            }
        }
    }

    #if os(iOS)
    private var isRegularWidth: Bool {
        horizontalSizeClass == .regular
    }

    private var chatHeaderButtonDiameter: CGFloat {
        IOSControlMetrics.isPad ? IOSControlMetrics.circleButtonDiameter : (isRegularWidth ? 58 : 32)
    }

    private var chatHeaderIconSize: CGFloat {
        IOSControlMetrics.isPad ? IOSControlMetrics.circleIconSize : (isRegularWidth ? 22 : 14)
    }

    private var chatHeaderSpacing: CGFloat {
        IOSControlMetrics.isPad ? 16 : (isRegularWidth ? 14 : 8)
    }
    #endif

    private func sendMessage() {
        let trimmed = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task { await model.sendGroupMessage(text: trimmed, to: group.id) }
        messageText = ""
    }

    private func closeGroupView() {
        if model.activeGroupId == group.id {
            model.activeGroupId = nil
        }
        Task { await deactivateGroup(group.id) }
        #if os(iOS)
        dismiss()
        #endif
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
            await model.sendGroupAttachment(data: data, fileName: nil, mimeType: mimeType, to: group.id)
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
            let data = try readBoundedFile(url, maxBytes: 32 * 1024 * 1024)
            let fileName = url.lastPathComponent
            let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "image/jpeg"
            await model.sendGroupAttachment(data: data, fileName: fileName, mimeType: mimeType, to: group.id)
        } catch {
            await MainActor.run {
                model.lastError = "Failed to read attachment: \(error.localizedDescription)"
            }
        }
    }
    #endif

    private func scrollToBottom(_ messages: [NoctweaveCore.Message], proxy: ScrollViewProxy, animated: Bool) {
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

    private func activateGroup(_ groupId: UUID) async {
        model.activeContactId = nil
        model.activeGroupId = groupId
        await model.openGroupConversation(groupId: groupId)
        await model.markGroupRead(groupId: groupId)
    }

    private func deactivateGroup(_ groupId: UUID) async {
        await model.closeGroupConversation(groupId: groupId)
        if model.activeGroupId == groupId {
            model.activeGroupId = nil
        }
    }
}

private struct GroupInvitationPanel: View {
    let title: String
    let inviterName: String
    let onAccept: () -> Void
    let onDecline: () -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "envelope.badge.shield.half.filled")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .frame(width: 40, height: 40)
                    .background(theme.accent.opacity(0.14), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text("Group Invitation")
                        .font(.headline)
                    Text("\(inviterName) invited you to \(title). Accepting creates a group-only identity for this conversation.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                Button("Decline", action: onDecline)
                    .glassButton(compact: true)
                    .hoverLift()
                Button(action: onAccept) {
                    Label("Accept", systemImage: "checkmark")
                }
                .glassButton(prominent: true, compact: true)
                .hoverLift()
            }
        }
        .uniformGlassCard(cornerRadius: 18, padding: 14)
    }
}

struct SheetHero: View {
    let icon: String
    let title: String
    let subtitle: String

    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(theme.accent)
                .frame(width: 44, height: 44)
                .background(theme.accent.opacity(0.15), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .uniformGlassCard(cornerRadius: 20, padding: 16)
    }
}

struct SheetActionBar<Trailing: View>: View {
    let closeLabel: String
    let onClose: () -> Void
    @ViewBuilder let trailing: () -> Trailing

    init(
        closeLabel: String = "Close",
        onClose: @escaping () -> Void,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.closeLabel = closeLabel
        self.onClose = onClose
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
            }
            .accessibilityLabel(closeLabel)
            .glassCircleButton(diameter: 34)
            .hoverLift()

            Spacer()
            trailing()
        }
    }
}

extension SheetActionBar where Trailing == EmptyView {
    init(closeLabel: String = "Close", onClose: @escaping () -> Void) {
        self.init(closeLabel: closeLabel, onClose: onClose) {
            EmptyView()
        }
    }
}

struct SheetSection<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    let icon: String
    var role: ButtonRole? = nil
    @ViewBuilder let content: () -> Content

    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(role == .destructive ? Color.red : theme.accent)
                    .frame(width: 28, height: 28)
                    .background(
                        (role == .destructive ? Color.red : theme.accent).opacity(0.12),
                        in: Circle()
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }

            content()
        }
        .uniformGlassCard(cornerRadius: 18, padding: 14)
    }
}

struct SheetEmptyState: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
}

private struct SheetContactSelectionRow: View {
    let contact: Contact
    let isSelected: Bool
    var isEnabled: Bool = true
    let action: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: "person.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isSelected ? theme.accent : Color.secondary)
                    .frame(width: 34, height: 34)
                    .background(
                        (isSelected ? theme.accent : Color.secondary).opacity(0.12),
                        in: Circle()
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(contact.displayName)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(contact.fingerprint)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(isSelected ? theme.accent : Color.secondary.opacity(0.65))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(isSelected ? theme.accent.opacity(0.10) : Color.primary.opacity(0.035))
                    .overlay(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .stroke(
                                isSelected ? theme.accent.opacity(0.40) : Color.white.opacity(0.08),
                                lineWidth: 0.8
                            )
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.62)
    }
}

private struct SheetGroupMemberRow: View {
    let member: RelayGroupMemberProfile
    let isSelf: Bool
    let isCreator: Bool
    let isDirectContact: Bool
    let canPair: Bool
    let canPromoteDirectly: Bool
    let canKick: Bool
    let onPair: () -> Void
    let onKick: () -> Void

    @Environment(\.appTheme) private var theme

    private var displayName: String {
        let trimmed = member.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            return trimmed
        }
        return "Group Member \(member.fingerprint.prefix(8))"
    }

    private var statusText: String {
        if isSelf { return "You" }
        if isCreator { return "Creator" }
        if isDirectContact { return "Contact" }
        return "Group identity"
    }

    private var pairLabel: String {
        canPromoteDirectly ? "Add Contact" : "Request Pair"
    }

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: isCreator ? "crown.fill" : "person.crop.circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isCreator ? Color.yellow : theme.accent)
                .frame(width: 34, height: 34)
                .background((isCreator ? Color.yellow : theme.accent).opacity(0.13), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(displayName)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(statusText)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(theme.accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(theme.accent.opacity(0.12), in: Capsule())
                }
                Text(member.fingerprint)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            if canPair || canKick {
                VStack(alignment: .trailing, spacing: 6) {
                    if canPair {
                        Button(action: onPair) {
                            Label(pairLabel, systemImage: canPromoteDirectly ? "person.badge.plus" : "point.3.connected.trianglepath.dotted")
                                .labelStyle(.titleAndIcon)
                                .font(.caption.weight(.semibold))
                        }
                        .glassButton(compact: true)
                        .hoverLift()
                    }

                    if canKick {
                        Button(role: .destructive, action: onKick) {
                            Label("Remove", systemImage: "person.crop.circle.badge.minus")
                                .labelStyle(.titleAndIcon)
                                .font(.caption.weight(.semibold))
                        }
                        .glassButton(compact: true)
                        .hoverLift()
                    }
                }
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.primary.opacity(0.035))
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 0.8)
                )
        )
    }
}

private struct GroupDetailsView: View {
    @ObservedObject var model: ClientViewModel
    let groupId: UUID
    var onGroupRemoved: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var isSaving = false
    @State private var showingLeaveConfirm = false
    @State private var showingKickConfirm = false
    @State private var memberToKick: RelayGroupMemberProfile?
    @State private var actingMemberFingerprint: String?
    private var canEditRelayGroup: Bool {
        guard let group else { return false }
        return model.canEditRelayGroup(group)
    }
    private var isRelayGroupCreator: Bool {
        guard let group else { return false }
        return model.isRelayGroupCreator(group)
    }
    private var leaveButtonLabel: String {
        isRelayGroupCreator ? "Extinguish Group" : "Leave Group"
    }
    private var leaveDialogTitle: String {
        isRelayGroupCreator ? "Extinguish this group?" : "Leave this group?"
    }
    private var leaveDialogMessage: String {
        if isRelayGroupCreator {
            return "As creator, leaving will extinguish this relay-backed group for all members."
        }
        return "You will stop receiving messages for this group on this device."
    }

    private var group: GroupConversation? {
        model.state.group(for: groupId)
    }

    private var groupMemberProfiles: [RelayGroupMemberProfile] {
        group?.memberProfiles ?? []
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SheetActionBar(onClose: { dismiss() }) {
                        Button {
                            save()
                        } label: {
                            Label(isSaving ? "Saving…" : "Save", systemImage: "checkmark")
                        }
                        .glassButton(prominent: true, compact: true)
                        .disabled(!canSave || isSaving || group == nil || !canEditRelayGroup)
                    }

                    SheetHero(
                        icon: "person.3.fill",
                        title: "Group Settings",
                        subtitle: canEditRelayGroup
                            ? "Rename the group and manage scoped members."
                            : "Review group membership and relay policy."
                    )

                    if group == nil {
                        SheetEmptyState(
                            icon: "person.3.sequence.fill",
                            title: "Group unavailable",
                            message: "This group no longer exists for the active identity."
                        )
                    } else {
                        SheetSection(title: "Group Name", icon: "textformat") {
                        TextField("Group name", text: $title)
                            .disabled(!canEditRelayGroup)
                            .noctyraInputField()
                        }

                        SheetSection(
                            title: "Your Role",
                            icon: isRelayGroupCreator ? "crown.fill" : "person.fill"
                        ) {
                            Label(
                                isRelayGroupCreator ? "Creator" : "Member",
                                systemImage: isRelayGroupCreator ? "crown.fill" : "person.fill"
                            )
                            .font(.headline)
                            .foregroundStyle(.primary)

                            Text(
                                isRelayGroupCreator
                                    ? "You can update membership, rename the group, and extinguish this relay-backed group for everyone."
                                    : "You can read group details and leave this group. Only the creator can update membership or extinguish it."
                            )
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        }

                        SheetSection(
                            title: "Members",
                            subtitle: "\(group?.resolvedMemberCount ?? groupMemberProfiles.count) in group",
                            icon: "person.2.fill"
                        ) {
                            if groupMemberProfiles.isEmpty {
                                SheetEmptyState(
                                    icon: "person.2.slash",
                                    title: "No member profiles",
                                    message: "The relay has not reported group-scoped member profiles yet."
                                )
                            } else {
                                LazyVStack(spacing: 8) {
                                    ForEach(groupMemberProfiles, id: \.fingerprint) { member in
                                        SheetGroupMemberRow(
                                            member: member,
                                            isSelf: isSelf(member.fingerprint),
                                            isCreator: member.fingerprint == group?.createdByFingerprint,
                                            isDirectContact: model.groupMemberIsDirectContact(member),
                                            canPair: canPair(member),
                                            canPromoteDirectly: model.canPromoteGroupMember(member),
                                            canKick: canKick(member),
                                            onPair: {
                                                pair(member)
                                            },
                                            onKick: {
                                                memberToKick = member
                                                showingKickConfirm = true
                                            }
                                        )
                                    }
                                }
                            }
                        }

                        SheetSection(title: "How Changes Sync", icon: "arrow.triangle.2.circlepath") {
                            Text(
                                group?.relayInboxId != nil
                                    ? "Changes are synced to the relay group registry through group-scoped identities. Messages remain end-to-end encrypted for each member."
                                    : "Changes affect this identity profile on this device. Messages remain end-to-end encrypted for each member."
                            )
                            .font(.callout)
                            .foregroundStyle(.secondary)

                            if !canEditRelayGroup {
                                Label(
                                    "Only the group creator can edit relay-backed groups.",
                                    systemImage: "lock.fill"
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }

                        SheetSection(
                            title: isRelayGroupCreator ? "Extinguish Group" : "Leave Group",
                            icon: "rectangle.portrait.and.arrow.right",
                            role: .destructive
                        ) {
                            Text(
                                isRelayGroupCreator
                                    ? "Leaving as creator permanently extinguishes this relay-backed group for every member."
                                    : "You will stop receiving messages for this group on this identity."
                            )
                            .font(.callout)
                            .foregroundStyle(.secondary)

                            Button(leaveButtonLabel, role: .destructive) {
                                showingLeaveConfirm = true
                            }
                            .glassButton(prominent: true)
                            .disabled(isSaving)
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
            .noctyraSheetBackground()
            .hideSheetNavigationBar()
        }
        .noctyraSheetPresentation()
        .onAppear {
            loadCurrentValues()
        }
        .onChange(of: group?.id) { _, _ in
            loadCurrentValues()
        }
        .confirmationDialog(leaveDialogTitle, isPresented: $showingLeaveConfirm) {
            Button(leaveButtonLabel, role: .destructive) {
                leave()
            }
        } message: {
            Text(leaveDialogMessage)
        }
        .confirmationDialog("Remove this member?", isPresented: $showingKickConfirm) {
            Button("Remove Member", role: .destructive) {
                if let memberToKick {
                    kick(memberToKick)
                }
            }
            .disabled(memberToKick.map { actingMemberFingerprint == $0.fingerprint } ?? false)
        } message: {
            if let memberToKick {
                Text("This removes \(displayName(for: memberToKick)) from the relay group.")
            }
        }
    }

    private var canSave: Bool {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty,
              let group else {
            return false
        }
        return canEditRelayGroup && trimmedTitle != group.title
    }

    private func loadCurrentValues() {
        guard let group else { return }
        title = group.title
    }

    private func save() {
        guard canSave else { return }
        isSaving = true
        Task {
            await model.renameGroup(id: groupId, title: title)
            await MainActor.run {
                isSaving = false
                if model.state.group(for: groupId) != nil {
                    dismiss()
                }
            }
        }
    }

    private func leave() {
        isSaving = true
        dismiss()
        Task {
            await model.leaveGroup(id: groupId)
            await MainActor.run {
                isSaving = false
                onGroupRemoved()
            }
        }
    }

    private func isSelf(_ fingerprint: String) -> Bool {
        fingerprint == model.state.identity.fingerprint || group?.scopedIdentity?.fingerprint == fingerprint
    }

    private func canKick(_ member: RelayGroupMemberProfile) -> Bool {
        canEditRelayGroup
            && !isSelf(member.fingerprint)
            && member.fingerprint != group?.createdByFingerprint
            && actingMemberFingerprint == nil
    }

    private func canPair(_ member: RelayGroupMemberProfile) -> Bool {
        !isSelf(member.fingerprint)
            && !model.groupMemberIsDirectContact(member)
            && actingMemberFingerprint == nil
    }

    private func pair(_ member: RelayGroupMemberProfile) {
        actingMemberFingerprint = member.fingerprint
        Task {
            await model.pairWithGroupMember(groupId: groupId, fingerprint: member.fingerprint)
            await MainActor.run {
                actingMemberFingerprint = nil
            }
        }
    }

    private func kick(_ member: RelayGroupMemberProfile) {
        isSaving = true
        actingMemberFingerprint = member.fingerprint
        Task {
            await model.kickGroupMember(groupId: groupId, fingerprint: member.fingerprint)
            await MainActor.run {
                isSaving = false
                actingMemberFingerprint = nil
                memberToKick = nil
            }
        }
    }

    private func displayName(for member: RelayGroupMemberProfile) -> String {
        let trimmed = member.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            return trimmed
        }
        return "Group Member \(member.fingerprint.prefix(8))"
    }
}

private struct MessageRow: View {
    @ObservedObject var model: ClientViewModel
    let message: NoctweaveCore.Message
    let isRevealed: Bool
    let onRetry: (() -> Void)?
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

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
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var bubble: some View {
        if message.attachment == nil {
            ViewThatFits(in: .horizontal) {
                bubbleChrome {
                    bubbleContent
                }
                .fixedSize(horizontal: true, vertical: false)

                bubbleChrome {
                    bubbleContent
                }
                .frame(maxWidth: bubbleMaxWidth, alignment: .leading)
            }
        } else {
            bubbleChrome {
                bubbleContent
            }
            .frame(maxWidth: bubbleMaxWidth, alignment: .leading)
        }
    }

    private var bubbleContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let sender = message.senderDisplayName, message.direction == .received {
                Text(sender)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
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
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func bubbleChrome<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(message.direction == .sent ? bubbleTint.opacity(colorScheme == .dark ? 0.28 : 0.22) : Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.055))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .opacity(message.direction == .sent ? 0.30 : 0.42)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    bubbleTint.opacity(message.direction == .sent ? 0.14 : 0.055),
                                    Color.clear
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(
                            Color.white.opacity(colorScheme == .dark ? 0.11 : 0.18),
                            lineWidth: 0.7
                        )
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: bubbleTint.opacity(message.direction == .sent ? 0.12 : 0.055), radius: 5, x: 0, y: 2)
    }

    private var bubbleMaxWidth: CGFloat {
        #if os(iOS)
        return 330
        #else
        return 560
        #endif
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
            if isImageAttachment {
                attachmentPreview
            } else if isAudioAttachment {
                AudioAttachmentPlayer(
                    model: model,
                    attachment: attachment,
                    isRevealed: isRevealed
                )
            } else {
                unsupportedPreview
            }
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

    private var normalizedMimeType: String {
        attachment.descriptor.mimeType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var isImageAttachment: Bool {
        normalizedMimeType.hasPrefix("image/")
    }

    private var isAudioAttachment: Bool {
        normalizedMimeType.hasPrefix("audio/")
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

    private var unsupportedPreview: some View {
        HStack(spacing: 8) {
            Image(systemName: "paperclip")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Attachment")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
    }

    private var previewSize: CGFloat {
        #if os(macOS)
        return 220
        #else
        return 180
        #endif
    }

    private var maxPreviewDimension: CGFloat { 4096 }
    private var maxPreviewPixels: Int { 16_000_000 }

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
            var data = await model.loadAttachmentData(fileName: fileName)
            await MainActor.run {
                defer { isLoading = false }
                guard var decrypted = data else {
                    didFail = true
                    return
                }
                let rendered = makeImage(from: decrypted)
                decrypted.secureWipe()
                data = nil
                guard let image = rendered else {
                    didFail = true
                    return
                }
                self.image = image
            }
        }
    }

    private func makeImage(from data: Data) -> Image? {
        guard isPreviewImageWithinLimits(data) else { return nil }
        #if os(iOS)
        guard let uiImage = UIImage(data: data) else { return nil }
        return Image(uiImage: uiImage)
        #else
        guard let nsImage = NSImage(data: data) else { return nil }
        return Image(nsImage: nsImage)
        #endif
    }

    private func isPreviewImageWithinLimits(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let widthValue = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let heightValue = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            return false
        }
        let width = widthValue.intValue
        let height = heightValue.intValue
        guard width > 0, height > 0 else { return false }
        guard CGFloat(width) <= maxPreviewDimension, CGFloat(height) <= maxPreviewDimension else {
            return false
        }
        let pixels = width * height
        return pixels > 0 && pixels <= maxPreviewPixels
    }
}

private struct AudioAttachmentPlayer: View {
    @ObservedObject var model: ClientViewModel
    let attachment: AttachmentInfo
    let isRevealed: Bool

    @State private var player: AVAudioPlayer?
    @State private var isLoading = false
    @State private var didFail = false
    @State private var isPlaying = false
    @State private var currentTime: TimeInterval = 0
    @State private var duration: TimeInterval = 0
    @State private var progressTimer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    togglePlayback()
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                }
                .glassCircleButton(diameter: 30)
                .hoverLift()
                .disabled(!isRevealed || isLoading)

                VStack(alignment: .leading, spacing: 3) {
                    Text(statusLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isRevealed ? .primary : .secondary)
                    Text(timeLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            progressBar
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 0.7)
                )
        )
        .onDisappear {
            stopPlayback()
        }
        .onChange(of: isRevealed) { _, newValue in
            if !newValue {
                stopPlayback()
            }
        }
    }

    private var statusLabel: String {
        if !isRevealed {
            return "Hidden voice message"
        }
        if isLoading {
            return "Loading voice message..."
        }
        if didFail {
            return "Voice message unavailable"
        }
        return isPlaying ? "Playing voice message" : "Voice message"
    }

    private var timeLabel: String {
        if duration <= 0 {
            return "00:00"
        }
        return "\(formatDuration(currentTime)) / \(formatDuration(duration))"
    }

    private var progressBar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.10))
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.40))
                    .frame(width: geometry.size.width * progress)
            }
        }
        .frame(height: 6)
    }

    private var progress: CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(min(max(currentTime / duration, 0), 1))
    }

    private func togglePlayback() {
        guard isRevealed else { return }
        if isPlaying {
            stopPlayback()
            return
        }
        Task {
            if player == nil {
                await loadPlayer()
            }
            guard let player else {
                didFail = true
                return
            }
            if player.currentTime >= player.duration {
                player.currentTime = 0
            }
            if player.play() {
                duration = player.duration
                isPlaying = true
                startProgressTimer()
            } else {
                didFail = true
            }
        }
    }

    private func loadPlayer() async {
        guard !isLoading else { return }
        guard let fileName = attachment.localFileName else {
            didFail = true
            return
        }
        isLoading = true
        var data = await model.loadAttachmentData(fileName: fileName)
        defer {
            isLoading = false
            data?.secureWipe()
            data = nil
        }
        guard let data else {
            didFail = true
            return
        }
        do {
            let candidate = try AVAudioPlayer(data: data)
            candidate.prepareToPlay()
            player = candidate
            duration = candidate.duration
            currentTime = 0
            didFail = false
        } catch {
            didFail = true
        }
    }

    private func stopPlayback() {
        if let player, player.isPlaying {
            player.stop()
        }
        player?.currentTime = 0
        currentTime = 0
        isPlaying = false
        stopProgressTimer()
    }

    private func startProgressTimer() {
        stopProgressTimer()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            guard let player else {
                stopProgressTimer()
                isPlaying = false
                return
            }
            currentTime = player.currentTime
            duration = player.duration
            if !player.isPlaying {
                isPlaying = false
                stopProgressTimer()
                if currentTime >= duration {
                    currentTime = duration
                }
            }
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func formatDuration(_ value: TimeInterval) -> String {
        let seconds = max(0, Int(value.rounded()))
        let minutes = seconds / 60
        let remainder = seconds % 60
        return String(format: "%02d:%02d", minutes, remainder)
    }
}

private extension Data {
    mutating func secureWipe() {
        guard !isEmpty else { return }
        let byteCount = count
        withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            _ = memset_s(baseAddress, byteCount, 0, byteCount)
        }
        removeAll(keepingCapacity: false)
    }
}

private struct RevealToggleButton: View {
    @Binding var isRevealed: Bool
    var isDisabled: Bool = false
    var diameter: CGFloat = 32
    var iconSize: CGFloat = 14

    var body: some View {
        Button {
            isRevealed.toggle()
        } label: {
            Image(systemName: isRevealed ? "eye" : "eye.slash")
                .font(.system(size: iconSize, weight: .semibold))
        }
        .accessibilityLabel(isRevealed ? "Hide Messages" : "Reveal Messages")
        .accessibilityIdentifier("reveal-toggle")
        .glassCircleButton(diameter: diameter)
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
    let secureTypingKeyboard: SecureTypingKeyboard
    let onSubmit: () -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        ZStack(alignment: .leading) {
            if text.isEmpty {
                Text("Message")
                    .font(.system(size: IOSControlMetrics.isPad ? 24 : 17, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .padding(.leading, IOSControlMetrics.isPad ? 16 : 8)
            }
            UIKitMessageInput(
                text: $text,
                secureTypingEnabled: secureTypingEnabled,
                secureTypingKeyboard: secureTypingKeyboard,
                onSubmit: onSubmit
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .padding(.horizontal, IOSControlMetrics.isPad ? 8 : 2)
        }
        .frame(height: IOSControlMetrics.composerHeight)
        .background(Color.clear)
        .overlay(
            RoundedRectangle(cornerRadius: IOSControlMetrics.isPad ? 16 : 12, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 0.8)
        )
    }
}

private struct UIKitMessageInput: UIViewRepresentable {
    @Binding var text: String
    let secureTypingEnabled: Bool
    let secureTypingKeyboard: SecureTypingKeyboard
    let onSubmit: () -> Void

    func makeUIView(context: Context) -> UITextView {
        let view = CenteredTextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.isOpaque = false
        view.textColor = .label
        view.font = IOSControlMetrics.isPad
            ? UIFont.systemFont(ofSize: 24, weight: .regular)
            : UIFont.preferredFont(forTextStyle: .body)
        view.isScrollEnabled = true
        view.textContainerInset = .zero
        view.textContainer.maximumNumberOfLines = 2
        view.textContainer.lineBreakMode = .byTruncatingTail
        view.textContainer.lineFragmentPadding = 0
        view.returnKeyType = .send
        view.keyboardDismissMode = .interactive
        applyPrivacyTraits(to: view)
        context.coordinator.configureKeyboard(
            for: view,
            secureTypingEnabled: secureTypingEnabled,
            secureTypingKeyboard: secureTypingKeyboard
        )
        view.text = text
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.parent = self
        if uiView.text != text {
            uiView.text = text
        }
        uiView.font = IOSControlMetrics.isPad
            ? UIFont.systemFont(ofSize: 24, weight: .regular)
            : UIFont.preferredFont(forTextStyle: .body)
        applyPrivacyTraits(to: uiView)
        context.coordinator.configureKeyboard(
            for: uiView,
            secureTypingEnabled: secureTypingEnabled,
            secureTypingKeyboard: secureTypingKeyboard
        )
        uiView.setNeedsLayout()
    }

    private func applyPrivacyTraits(to view: UITextView) {
        view.isSecureTextEntry = secureTypingEnabled && secureTypingKeyboard == .apple
        view.autocorrectionType = secureTypingEnabled ? .no : .default
        view.spellCheckingType = secureTypingEnabled ? .no : .default
        view.autocapitalizationType = secureTypingEnabled ? .none : .sentences
        view.smartQuotesType = secureTypingEnabled ? .no : .default
        view.smartDashesType = secureTypingEnabled ? .no : .default
        view.textContentType = secureTypingEnabled ? .none : nil
        view.passwordRules = nil
        view.inputAssistantItem.leadingBarButtonGroups = []
        view.inputAssistantItem.trailingBarButtonGroups = []
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        fileprivate var parent: UIKitMessageInput
        private var secureKeyboard: SecureComposerKeyboard?

        init(_ parent: UIKitMessageInput) {
            self.parent = parent
        }

        func configureKeyboard(
            for textView: UITextView,
            secureTypingEnabled: Bool,
            secureTypingKeyboard: SecureTypingKeyboard
        ) {
            if secureTypingEnabled && secureTypingKeyboard == .noctyra {
                let keyboard = secureKeyboard ?? SecureComposerKeyboard()
                keyboard.textView = textView
                keyboard.onSend = { [weak self, weak textView] in
                    guard let self, let textView else { return }
                    self.parent.text = textView.text
                    let trimmed = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        self.parent.onSubmit()
                    }
                }
                secureKeyboard = keyboard
                if textView.inputView !== keyboard {
                    textView.inputView = keyboard
                    textView.reloadInputViews()
                }
            } else if textView.inputView != nil {
                textView.inputView = nil
                textView.reloadInputViews()
            }
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

private final class SecureComposerKeyboard: UIInputView {
    weak var textView: UITextView?
    var onSend: (() -> Void)?

    private enum KeyboardMode {
        case letters
        case numbers
        case symbols
    }

    private struct Key {
        enum Action {
            case input(String)
            case shift
            case delete
            case mode(KeyboardMode)
            case space
            case send
        }

        let title: String?
        let imageName: String?
        let action: Action
        let weight: CGFloat
        let isAccent: Bool

        init(
            _ title: String,
            action: Action? = nil,
            weight: CGFloat = 1,
            isAccent: Bool = false
        ) {
            self.title = title
            self.imageName = nil
            self.action = action ?? .input(title)
            self.weight = weight
            self.isAccent = isAccent
        }

        init(
            imageName: String,
            action: Action,
            weight: CGFloat = 1,
            isAccent: Bool = false
        ) {
            self.title = nil
            self.imageName = imageName
            self.action = action
            self.weight = weight
            self.isAccent = isAccent
        }
    }

    private let rootStack = UIStackView()
    private var letterButtons: [UIButton] = []
    private var modeButtons: [UIButton] = []
    private var isShifted = false
    private var isCapsLocked = false
    private var mode: KeyboardMode = .letters
    private var lastShiftTap: Date?
    private var deleteRepeatTimer: Timer?
    private var alternatePressTimer: Timer?
    private var suppressNextTouchUp = false
    private weak var keyPreviewView: UIView?
    private weak var alternatePickerView: UIView?
    private var heightConstraint: NSLayoutConstraint?

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 304), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        backgroundColor = UIColor.systemBackground.withAlphaComponent(0.96)
        translatesAutoresizingMaskIntoConstraints = false

        rootStack.axis = .vertical
        rootStack.spacing = 7
        rootStack.alignment = .fill
        rootStack.distribution = .fillEqually
        rootStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(rootStack)
        let heightConstraint = heightAnchor.constraint(equalToConstant: preferredKeyboardHeight)
        self.heightConstraint = heightConstraint
        NSLayoutConstraint.activate([
            heightConstraint,
            rootStack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            rootStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            rootStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            rootStack.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -8)
        ])

        render()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let targetHeight = preferredKeyboardHeight
        if heightConstraint?.constant != targetHeight {
            heightConstraint?.constant = targetHeight
            invalidateIntrinsicContentSize()
        }
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: preferredKeyboardHeight)
    }

    private func render() {
        letterButtons.removeAll()
        modeButtons.removeAll()
        rootStack.arrangedSubviews.forEach { view in
            rootStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for row in rows(for: mode) {
            addRow(row, to: rootStack)
        }

        refreshLetterCase()
        refreshModeButtons()
    }

    private var preferredKeyboardHeight: CGFloat {
        traitCollection.userInterfaceIdiom == .pad ? 346 : 304
    }

    private func rows(for mode: KeyboardMode) -> [[Key]] {
        switch mode {
        case .letters:
            return [
                ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"].map { Key($0) },
                ["a", "s", "d", "f", "g", "h", "j", "k", "l"].map { Key($0) },
                [
                    Key(imageName: shiftImageName, action: .shift, weight: 1.35),
                    Key("z"), Key("x"), Key("c"), Key("v"), Key("b"), Key("n"), Key("m"),
                    Key(imageName: "delete.left", action: .delete, weight: 1.35)
                ],
                [
                    Key("123", action: .mode(.numbers), weight: 1.35),
                    Key(",", weight: 0.85),
                    Key("space", action: .space, weight: 4.8),
                    Key(".", weight: 0.85),
                    Key(imageName: "paperplane.fill", action: .send, weight: 1.35, isAccent: true)
                ]
            ]
        case .numbers:
            return [
                ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"].map { Key($0) },
                ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""].map { Key($0) },
                [
                    Key("#+=", action: .mode(.symbols), weight: 1.35),
                    Key("."), Key(","), Key("?"), Key("!"), Key("'"),
                    Key(imageName: "delete.left", action: .delete, weight: 1.35)
                ],
                [
                    Key("ABC", action: .mode(.letters), weight: 1.35),
                    Key("space", action: .space, weight: 5.6),
                    Key(imageName: "paperplane.fill", action: .send, weight: 1.35, isAccent: true)
                ]
            ]
        case .symbols:
            return [
                ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="].map { Key($0) },
                ["_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•"].map { Key($0) },
                [
                    Key("123", action: .mode(.numbers), weight: 1.35),
                    Key("."), Key(","), Key("?"), Key("!"), Key("'"),
                    Key(imageName: "delete.left", action: .delete, weight: 1.35)
                ],
                [
                    Key("ABC", action: .mode(.letters), weight: 1.35),
                    Key("space", action: .space, weight: 5.6),
                    Key(imageName: "paperplane.fill", action: .send, weight: 1.35, isAccent: true)
                ]
            ]
        }
    }

    private var shiftImageName: String {
        isCapsLocked ? "shift.fill" : "shift"
    }

    private func addRow(_ keys: [Key], to stack: UIStackView) {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = traitCollection.userInterfaceIdiom == .pad ? 8 : 5
        row.alignment = .fill
        row.distribution = .fill
        let totalWeight = keys.reduce(CGFloat.zero) { $0 + $1.weight }
        let totalSpacing = row.spacing * CGFloat(max(keys.count - 1, 0))

        for key in keys {
            let button = makeButton(for: key)
            row.addArrangedSubview(button)
            let width = button.widthAnchor.constraint(
                equalTo: row.widthAnchor,
                multiplier: key.weight / totalWeight,
                constant: -(totalSpacing * key.weight / totalWeight)
            )
            width.priority = .required
            width.isActive = true
        }

        stack.addArrangedSubview(row)
    }

    private func makeButton(for key: Key) -> UIButton {
        var configuration = UIButton.Configuration.filled()
        configuration.baseForegroundColor = key.isAccent ? .white : .label
        configuration.baseBackgroundColor = backgroundColor(for: key)
        configuration.cornerStyle = .medium
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6)

        let button = UIButton(configuration: configuration)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: traitCollection.userInterfaceIdiom == .pad ? 48 : 40).isActive = true
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.accessibilityLabel = accessibilityLabel(for: key)

        if let imageName = key.imageName {
            button.setImage(UIImage(systemName: imageName), for: .normal)
            button.imageView?.contentMode = .scaleAspectFit
        } else if let title = key.title {
            button.setTitle(title, for: .normal)
            button.titleLabel?.adjustsFontSizeToFitWidth = true
            button.titleLabel?.minimumScaleFactor = 0.7
            button.titleLabel?.font = font(for: key)
        }

        if case .input(let value) = key.action,
           value.count == 1,
           value.rangeOfCharacter(from: .letters) != nil {
            letterButtons.append(button)
        }

        if case .mode = key.action {
            modeButtons.append(button)
        }

        button.addAction(UIAction { [weak self, weak button] _ in
            guard let self, let button else { return }
            self.pressFeedback(on: button, key: key)
        }, for: .touchDown)
        button.addAction(UIAction { [weak self, weak button] _ in
            guard let self else { return }
            if case .delete = key.action {
                self.stopDeleteRepeat()
            } else if self.suppressNextTouchUp {
                self.suppressNextTouchUp = false
            } else {
                self.handle(key.action)
            }
            self.releaseFeedback(on: button)
        }, for: .touchUpInside)
        button.addAction(UIAction { [weak self, weak button] _ in
            self?.releaseFeedback(on: button)
        }, for: [.touchCancel, .touchUpOutside, .touchDragExit])

        return button
    }

    private func backgroundColor(for key: Key) -> UIColor {
        if key.isAccent {
            return UIColor.tintColor.withAlphaComponent(0.92)
        }
        switch key.action {
        case .shift, .delete, .mode:
            return UIColor.tertiarySystemFill
        case .space:
            return UIColor.secondarySystemBackground
        case .input, .send:
            return UIColor.secondarySystemBackground
        }
    }

    private func font(for key: Key) -> UIFont {
        switch key.action {
        case .mode, .space:
            return .systemFont(ofSize: 15, weight: .semibold)
        default:
            return .systemFont(ofSize: 20, weight: .regular)
        }
    }

    private func accessibilityLabel(for key: Key) -> String {
        switch key.action {
        case .shift:
            return isCapsLocked ? "Caps lock" : "Shift"
        case .delete:
            return "Delete"
        case .space:
            return "Space"
        case .send:
            return "Send"
        case .mode(let mode):
            switch mode {
            case .letters: return "Letters"
            case .numbers: return "Numbers"
            case .symbols: return "Symbols"
            }
        case .input(let value):
            return value
        }
    }

    private func handle(_ action: Key.Action) {
        guard let textView else { return }
        switch action {
        case .shift:
            handleShift()
        case .delete:
            deleteBackward()
        case .mode(let newMode):
            mode = newMode
            if mode != .letters {
                isShifted = false
                isCapsLocked = false
            }
            render()
        case .space:
            textView.insertText(" ")
            notifyChanged(textView)
        case .send:
            onSend?()
        case .input(let value):
            insertInput(value)
        }
    }

    private func insertInput(_ value: String) {
        guard let textView else { return }
        let inserted = shouldCapitalize(value) ? value.uppercased() : value
        textView.insertText(inserted)
        notifyChanged(textView)
        if isShifted && !isCapsLocked {
            isShifted = false
            lastShiftTap = nil
            refreshLetterCase()
            refreshModeButtons()
        }
    }

    private func deleteBackward() {
        guard let textView else { return }
        textView.deleteBackward()
        notifyChanged(textView)
    }

    private func handleShift() {
        let now = Date()
        if let lastShiftTap, now.timeIntervalSince(lastShiftTap) < 0.35 {
            isCapsLocked.toggle()
            isShifted = isCapsLocked
        } else if isCapsLocked {
            isCapsLocked = false
            isShifted = false
        } else {
            isShifted.toggle()
        }
        lastShiftTap = now
        render()
    }

    private func shouldCapitalize(_ value: String) -> Bool {
        isShifted && value.rangeOfCharacter(from: .letters) != nil
    }

    private func refreshLetterCase() {
        for button in letterButtons {
            guard let title = button.title(for: .normal) else { continue }
            button.setTitle(isShifted ? title.uppercased() : title.lowercased(), for: .normal)
        }
    }

    private func refreshModeButtons() {
        for button in modeButtons {
            guard let label = button.title(for: .normal) else { continue }
            let isCurrent: Bool
            switch (label, mode) {
            case ("ABC", .letters), ("123", .numbers), ("#+=", .symbols):
                isCurrent = true
            default:
                isCurrent = false
            }
            button.configuration?.baseBackgroundColor = isCurrent
                ? UIColor.tintColor.withAlphaComponent(0.22)
                : UIColor.tertiarySystemFill
        }
    }

    private func pressFeedback(on button: UIButton, key: Key) {
        dismissAlternatePicker()
        suppressNextTouchUp = false
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        showKeyPreview(for: key, from: button)
        if case .delete = key.action {
            deleteBackward()
            startDeleteRepeat()
        } else {
            startAlternatePickerTimer(for: key, from: button)
        }
        UIView.animate(withDuration: 0.06, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            button.transform = CGAffineTransform(scaleX: 0.94, y: 0.94)
            button.alpha = 0.82
        }
    }

    private func releaseFeedback(on button: UIButton?) {
        stopDeleteRepeat()
        stopAlternatePickerTimer()
        dismissKeyPreview()
        UIView.animate(withDuration: 0.14, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            button?.transform = .identity
            button?.alpha = 1
        }
    }

    private func startDeleteRepeat() {
        stopDeleteRepeat()
        deleteRepeatTimer = Timer.scheduledTimer(withTimeInterval: 0.42, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.deleteRepeatTimer = Timer.scheduledTimer(withTimeInterval: 0.065, repeats: true) { [weak self] _ in
                self?.deleteBackward()
            }
        }
    }

    private func stopDeleteRepeat() {
        deleteRepeatTimer?.invalidate()
        deleteRepeatTimer = nil
    }

    private func startAlternatePickerTimer(for key: Key, from button: UIButton) {
        stopAlternatePickerTimer()
        guard case .input(let value) = key.action, !alternates(for: value).isEmpty else { return }
        alternatePressTimer = Timer.scheduledTimer(withTimeInterval: 0.38, repeats: false) { [weak self, weak button] _ in
            guard let self, let button else { return }
            self.suppressNextTouchUp = true
            self.dismissKeyPreview()
            self.showAlternatePicker(for: value, from: button)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }

    private func stopAlternatePickerTimer() {
        alternatePressTimer?.invalidate()
        alternatePressTimer = nil
    }

    private func alternates(for value: String) -> [String] {
        switch value.lowercased() {
        case "a": return ["á", "à", "â", "ä", "ã", "å", "ā", "æ"]
        case "c": return ["ç", "ć", "č"]
        case "e": return ["é", "è", "ê", "ë", "ē", "ė", "ę"]
        case "i": return ["í", "ì", "î", "ï", "ī", "į"]
        case "l": return ["ł"]
        case "n": return ["ñ", "ń"]
        case "o": return ["ó", "ò", "ô", "ö", "õ", "ø", "ō", "œ"]
        case "s": return ["ś", "š", "ß"]
        case "u": return ["ú", "ù", "û", "ü", "ū"]
        case "y": return ["ý", "ÿ"]
        case "z": return ["ž", "ź", "ż"]
        case ".": return ["…"]
        case "?": return ["¿"]
        case "!": return ["¡"]
        case "-": return ["–", "—"]
        case "\"": return ["“", "”", "„"]
        case "'": return ["‘", "’"]
        case "/": return ["\\"]
        default: return []
        }
    }

    private func showAlternatePicker(for value: String, from button: UIButton) {
        let alternates = alternates(for: value)
        guard !alternates.isEmpty else { return }
        dismissAlternatePicker()

        let container = UIView()
        container.backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.98)
        container.layer.cornerRadius = 16
        container.layer.cornerCurve = .continuous
        container.layer.shadowColor = UIColor.black.cgColor
        container.layer.shadowOpacity = 0.2
        container.layer.shadowRadius = 14
        container.layer.shadowOffset = CGSize(width: 0, height: 6)
        container.accessibilityLabel = "Alternate characters"

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 4
        stack.alignment = .fill
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false

        let presentedAlternates = alternates.map { shouldCapitalize($0) ? $0.uppercased() : $0 }
        for alternate in presentedAlternates {
            var configuration = UIButton.Configuration.plain()
            configuration.baseForegroundColor = .label
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)

            let alternateButton = UIButton(configuration: configuration)
            alternateButton.setTitle(alternate, for: .normal)
            alternateButton.titleLabel?.font = .systemFont(ofSize: 23, weight: .medium)
            alternateButton.accessibilityLabel = "Insert \(alternate)"
            alternateButton.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                self.insertInput(alternate)
                self.suppressNextTouchUp = false
                self.dismissAlternatePicker()
            }, for: .touchUpInside)
            stack.addArrangedSubview(alternateButton)
        }

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6)
        ])

        let buttonFrame = button.convert(button.bounds, to: self)
        let buttonWidth: CGFloat = 36
        let width = min(bounds.width - 8, CGFloat(presentedAlternates.count) * buttonWidth + 12)
        let height: CGFloat = 52
        let x = min(max(buttonFrame.midX - width / 2, 4), max(bounds.width - width - 4, 4))
        let y = max(buttonFrame.minY - height - 8, 4)
        container.frame = CGRect(x: x, y: y, width: width, height: height)
        container.alpha = 0
        container.transform = CGAffineTransform(translationX: 0, y: 6)

        addSubview(container)
        alternatePickerView = container
        UIView.animate(withDuration: 0.12, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            container.alpha = 1
            container.transform = .identity
        }
    }

    private func dismissAlternatePicker() {
        guard let picker = alternatePickerView else { return }
        alternatePickerView = nil
        UIView.animate(withDuration: 0.1, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            picker.alpha = 0
            picker.transform = CGAffineTransform(translationX: 0, y: 4)
        } completion: { _ in
            picker.removeFromSuperview()
        }
    }

    private func showKeyPreview(for key: Key, from button: UIButton) {
        guard let title = previewTitle(for: key) else { return }
        dismissKeyPreview()

        let preview = UILabel()
        preview.text = title
        preview.textAlignment = .center
        preview.font = title.containsEmoji
            ? .systemFont(ofSize: 30, weight: .regular)
            : .systemFont(ofSize: 28, weight: .medium)
        preview.textColor = .label
        preview.backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.98)
        preview.layer.cornerRadius = 12
        preview.layer.cornerCurve = .continuous
        preview.layer.masksToBounds = false
        preview.layer.shadowColor = UIColor.black.cgColor
        preview.layer.shadowOpacity = 0.18
        preview.layer.shadowRadius = 10
        preview.layer.shadowOffset = CGSize(width: 0, height: 4)
        preview.alpha = 0

        let buttonFrame = button.convert(button.bounds, to: self)
        let width = max(46, buttonFrame.width + 16)
        let height: CGFloat = 54
        let x = min(max(buttonFrame.midX - width / 2, 4), max(bounds.width - width - 4, 4))
        let y = max(buttonFrame.minY - height - 8, 4)
        preview.frame = CGRect(x: x, y: y, width: width, height: height)

        addSubview(preview)
        keyPreviewView = preview
        UIView.animate(withDuration: 0.08, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            preview.alpha = 1
            preview.transform = CGAffineTransform(translationX: 0, y: -2)
        }
    }

    private func previewTitle(for key: Key) -> String? {
        switch key.action {
        case .input(let value):
            if value == " " { return nil }
            return shouldCapitalize(value) ? value.uppercased() : value
        default:
            return nil
        }
    }

    private func dismissKeyPreview() {
        guard let preview = keyPreviewView else { return }
        keyPreviewView = nil
        UIView.animate(withDuration: 0.08, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            preview.alpha = 0
            preview.transform = CGAffineTransform(translationX: 0, y: 4)
        } completion: { _ in
            preview.removeFromSuperview()
        }
    }

    private func notifyChanged(_ textView: UITextView) {
        textView.delegate?.textViewDidChange?(textView)
    }
}

private extension String {
    var containsEmoji: Bool {
        unicodeScalars.contains { scalar in
            scalar.properties.isEmojiPresentation || scalar.value > 0x238C && scalar.properties.isEmoji
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }

    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
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

private struct StableCapsuleBadge: View {
    let text: String
    let icon: String?
    let color: Color

    var body: some View {
        Group {
            if let icon {
                Label(text, systemImage: icon)
            } else {
                Text(text)
            }
        }
        .font(.caption2.weight(.semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.72)
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .frame(minHeight: 24)
        .background(Capsule().fill(color.opacity(0.18)))
        .fixedSize(horizontal: true, vertical: true)
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
    @State private var isPreparingCode = false

    var body: some View {
        Group {
            #if os(iOS)
            VStack(spacing: 0) {
                NoctyraTopBar(title: "My Code", subtitle: "Export, AirDrop, or scan")
                Group {
                    if screenProtection.isSensitiveHidden {
                        SensitiveContentPlaceholder(
                            title: "My Code Hidden",
                            message: "Screen capture or an external display is active. Your contact code is hidden to protect your operational security."
                        )
                    } else {
                        codeContent
                    }
                }
            }
            #else
            Group {
                if screenProtection.isSensitiveHidden {
                    SensitiveContentPlaceholder(
                        title: "My Code Hidden",
                        message: "Screen capture or an external display is active. Your contact code is hidden to protect your operational security."
                    )
                } else {
                    codeContent
                }
            }
            #endif
        }
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

                VStack(alignment: .leading, spacing: 10) {
                    Label("Password-Protected Share", systemImage: "lock.doc.fill")
                        .font(.headline)
                    Text("Set a password, then export a file or send it through AirDrop. The recipient imports the same protected payload.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    SecureField("Password", text: $sharePassword)
                        .noctyraInputField()
                    #if os(iOS)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) {
                            exportFileButton
                            shareAirDropButton
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            exportFileButton
                            shareAirDropButton
                        }
                    }
                    #else
                    HStack {
                        exportFileButton
                        shareAirDropButton
                    }
                    #endif
                    Text("Use Import File on the other device to accept an AirDrop share.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .uniformGlassCard(cornerRadius: 18, padding: 16)

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("Scan to Pair", systemImage: "qrcode")
                            .font(.headline)
                        Spacer()
                        #if os(iOS)
                        fullScreenQRButton
                        #else
                        Button {
                            showingFullScreenQR = true
                        } label: {
                            Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
                        }
                        .glassButton(compact: true)
                        .hoverLift()
                        #endif
                    }

                    if isPreparingCode {
                        VStack(spacing: 12) {
                            ProgressView()
                                .controlSize(.large)
                            Text("Preparing protected contact code…")
                                .font(.subheadline.weight(.semibold))
                            Text("Post-quantum keys are large. This may take a moment.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 220)
                    } else {
                        #if os(iOS)
                        ViewThatFits(in: .horizontal) {
                            qrBlock(size: 220)
                            qrBlock(size: 200)
                            qrBlock(size: 180)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        #else
                        ViewThatFits(in: .horizontal) {
                            qrBlock(size: 260)
                            qrBlock(size: 230)
                            qrBlock(size: 200)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        #endif
                    }
                }
                .uniformGlassCard(cornerRadius: 18, padding: 16)

                VStack(alignment: .leading, spacing: 10) {
                    Label("Contact Code", systemImage: "text.alignleft")
                        .font(.headline)
                    if showingCode {
                        TextEditor(text: $code)
                            .font(.callout.monospaced())
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 150)
                            .padding(8)
                            .background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Contact code hidden")
                                .font(.callout.weight(.semibold))
                            Text("You can copy it without revealing the full post-quantum payload.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 10)
                    }

                    #if os(iOS)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) {
                            revealCodeButton
                            copyCodeButton
                            refreshCodeButton
                        }
                        HStack(spacing: 10) {
                            revealCodeButton
                            copyCodeButton
                            Menu {
                                Button("Refresh") { refreshCode() }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .font(.system(size: 16, weight: .semibold))
                            }
                            .glassCircleButton(diameter: 36)
                        }
                    }
                    #else
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
                    }
                    #endif

                    Text("Refresh rebuilds the code from your current identity and relay. It does not rotate keys.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .uniformGlassCard(cornerRadius: 18, padding: 16)
            }
            #if os(iOS)
            .padding(.horizontal, 16)
            #else
            .padding(.horizontal, 20)
            #endif
            .padding(.bottom, 20)
            .adaptiveReadableContent(maxWidth: 880)
        }
        .glassBackgroundIfNeeded()
        .privacySensitive()
        .onAppear {
            refreshCode()
            showingCode = false
        }
        .fileExporter(
            isPresented: $showingExporter,
            document: exportDocument,
            contentType: .noctweaveContactShare,
            defaultFilename: "noctweave-contact"
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
                .noctyraSheetPresentation()
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
        guard !isPreparingCode else { return }
        isPreparingCode = true
        Task {
            let generatedCode = await model.contactOfferCode()
            await MainActor.run {
                code = generatedCode
                qrFrames = QRCodeTransfer.encodeFrames(generatedCode, maxChunkSize: 360)
                isPreparingCode = false
            }
        }
    }

    @ViewBuilder
    private func qrBlock(size: CGFloat) -> some View {
        VStack(spacing: 8) {
            if qrFrames.count > 1 {
                AnimatedQRCodeView(frames: qrFrames, size: size, interval: 0.45)
                Text("Animated contact code · \(qrFrames.count) frames")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text("Use Full Screen QR for the fastest scan.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                QRCodeView(text: code, size: size)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
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

    private var exportFileButton: some View {
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
    }

    private var shareAirDropButton: some View {
        Button("Share via AirDrop") {
            Task {
                await prepareAirDropShare()
            }
        }
        .glassButton()
        .disabled(sharePassword.isEmpty)
        .hoverLift()
    }

    #if os(iOS)
    private var revealCodeButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                showingCode.toggle()
            }
        } label: {
            Image(systemName: showingCode ? "eye.slash" : "eye")
                .font(.system(size: 15, weight: .semibold))
        }
        .accessibilityLabel(showingCode ? "Hide code" : "Reveal code")
        .glassCircleButton(diameter: 36)
        .hoverLift()
    }

    private var copyCodeButton: some View {
        Button {
            Clipboard.copy(code)
            model.lastInfo = "Copied contact code."
        } label: {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 15, weight: .semibold))
        }
        .accessibilityLabel("Copy code")
        .glassCircleButton(diameter: 36)
        .hoverLift()
    }

    private var refreshCodeButton: some View {
        Button {
            refreshCode()
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 15, weight: .semibold))
        }
        .accessibilityLabel("Refresh code")
        .glassCircleButton(diameter: 36)
        .hoverLift()
    }

    private var fullScreenQRButton: some View {
        Button {
            showingFullScreenQR = true
        } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 15, weight: .semibold))
        }
        .accessibilityLabel("Full screen QR")
        .glassCircleButton(diameter: 36)
        .hoverLift()
    }
    #endif

    private func writeShareFile(data: Data) throws -> URL {
        let filename = "noctweave-contact-\(UUID().uuidString).noctweave"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try data.write(to: url, options: [.atomic])
        return url
    }
}

private struct CreateGroupView: View {
    @ObservedObject var model: ClientViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var selectedMembers = Set<UUID>()
    @State private var memberSearchText = ""
    @State private var isCreating = false
    private var selectedRelayInfo: RelayInfo? {
        guard let selectedRelayId = model.state.selectedRelayId else { return nil }
        return model.state.relayServers.first(where: { $0.id == selectedRelayId })?.advertisedInfo
    }

    private var isRelayGroupCreationDisabled: Bool {
        selectedRelayInfo?.groupCreationMode == .disabled
    }

    private var relayGroupCreationLabel: String {
        if selectedRelayInfo?.groupCreationMode == .disabled {
            return "Disabled"
        }
        return "Allowed"
    }

    private var relayDisplayName: String {
        if let relayName = selectedRelayInfo?.relayName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !relayName.isEmpty {
            return relayName
        }
        return "\(model.state.relay.host):\(model.state.relay.port)"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SheetActionBar(closeLabel: "Cancel", onClose: { dismiss() }) {
                        Button {
                            create()
                        } label: {
                            Label(isCreating ? "Creating…" : "Create", systemImage: "plus")
                        }
                        .glassButton(prominent: true, compact: true)
                        .disabled(!canCreate || isCreating || isRelayGroupCreationDisabled)
                    }

                    SheetHero(
                        icon: "person.3.fill",
                        title: "Create Group",
                        subtitle: "Choose a name and at least two members."
                    )

                    SheetSection(title: "Group Name", icon: "textformat") {
                    TextField("e.g. Ops Team", text: $title)
                        .noctyraInputField()
                    }

                    SheetSection(
                        title: "Members",
                        subtitle: "\(selectedMembers.count) selected",
                        icon: "person.2.fill"
                    ) {
                        InlineSearchField(text: $memberSearchText, prompt: "Search members")

                        if model.state.contacts.isEmpty {
                            SheetEmptyState(
                                icon: "person.crop.circle.badge.plus",
                                title: "Add contacts first",
                                message: "Groups require at least two existing contacts."
                            )
                        } else if filteredContacts.isEmpty {
                            SheetEmptyState(
                                icon: "magnifyingglass",
                                title: "No matching contacts",
                                message: "Try another name or fingerprint."
                            )
                        } else {
                            LazyVStack(spacing: 8) {
                                ForEach(filteredContacts) { contact in
                                    SheetContactSelectionRow(
                                        contact: contact,
                                        isSelected: selectedMembers.contains(contact.id)
                                    ) {
                                        toggle(contact.id)
                                    }
                                }
                            }
                        }
                    }

                    SheetSection(title: "Delivery Model", icon: "lock.shield.fill") {
                        Text("Each group message is delivered as an independently encrypted envelope to every selected member.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    if let relayInfo = selectedRelayInfo {
                        SheetSection(title: "Relay Policy", icon: "antenna.radiowaves.left.and.right") {
                            sheetMetadataRow("Relay", relayDisplayName)
                            sheetMetadataRow("Group creation", relayGroupCreationLabel)

                            if relayInfo.federation.mode == .curated {
                                if relayInfo.curatedStrictPolicyEnabled == true {
                                    sheetMetadataRow("Federation", "Strict curated")
                                }
                                if let quorum = relayInfo.curatedCoordinatorQuorum {
                                    sheetMetadataRow("Coordinator quorum", "\(quorum)")
                                }
                                if let requireSigned = relayInfo.curatedRequireSignedDirectory {
                                    Label(
                                        requireSigned ? "Signed directory required" : "Unsigned directory accepted",
                                        systemImage: requireSigned ? "checkmark.shield.fill" : "exclamationmark.triangle.fill"
                                    )
                                    .font(.caption)
                                    .foregroundStyle(requireSigned ? Color.secondary : Color.orange)
                                }
                            }

                            if relayInfo.groupCreationMode == .disabled {
                                Label(
                                    "Choose another relay or ask the operator to enable group creation.",
                                    systemImage: "exclamationmark.triangle.fill"
                                )
                                .font(.caption)
                                .foregroundStyle(.orange)
                            }
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
            .noctyraSheetBackground()
            .hideSheetNavigationBar()
        }
        .noctyraSheetPresentation()
    }

    private func toggle(_ contactId: UUID) {
        if selectedMembers.contains(contactId) {
            selectedMembers.remove(contactId)
        } else {
            selectedMembers.insert(contactId)
        }
        FeedbackGenerator.light()
    }

    private func sheetMetadataRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption)
                .multilineTextAlignment(.trailing)
        }
    }

    private var canCreate: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && selectedMembers.count >= 2
    }

    private var filteredContacts: [Contact] {
        let sorted = model.state.contacts.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        let query = memberSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return sorted }
        return sorted.filter { contact in
            let haystack = "\(contact.displayName) \(contact.fingerprint)".lowercased()
            return haystack.contains(query)
        }
    }

    private func create() {
        guard canCreate else { return }
        guard !isRelayGroupCreationDisabled else {
            model.lastError = "Group creation is disabled on the selected relay."
            return
        }
        isCreating = true
        let priorCount = model.state.groups.count
        Task {
            await model.createGroup(title: title, memberContactIds: Array(selectedMembers))
            await MainActor.run {
                isCreating = false
                if model.state.groups.count > priorCount {
                    dismiss()
                }
            }
        }
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
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SheetActionBar(closeLabel: "Cancel", onClose: { dismiss() })

                    SheetHero(
                        icon: "person.crop.circle.badge.plus",
                        title: "Add Contact",
                        subtitle: pairingMethodSubtitle
                    )

                    SheetSection(title: "Pairing Method", icon: "point.3.connected.trianglepath.dotted") {
                        #if os(iOS)
                        ChipSegmentedControl(
                            selection: $method,
                            options: PairingMethod.allCases,
                            title: { $0.title },
                            minItemWidth: 112
                        )
                        #else
                        Picker("Method", selection: $method) {
                            ForEach(PairingMethod.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                        #endif
                    }

                    pairingMethodContent
                }
                .padding(16)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
            .noctyraSheetBackground()
            .hideSheetNavigationBar()
            .onAppear {
                insecureSettings = model.state.insecurePairing
            }
            .onChange(of: method) { _, newValue in
                if newValue == .federation {
                    Task { await model.refreshFederationPairing() }
                }
            }
            .onChange(of: insecureSettings) { _, newValue in
                Task { await model.updateInsecurePairing(newValue) }
            }
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: [.noctweaveContactShare, .data]
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
                            let data = try readBoundedFile(url, maxBytes: 1 * 1024 * 1024)
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
                    VStack(spacing: 0) {
                        SheetActionBar {
                            showingScanner = false
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)

                        VStack(spacing: 14) {
                            SheetHero(
                                icon: "qrcode.viewfinder",
                                title: "Scan Contact Code",
                                subtitle: "Hold the other device steady while animated frames are collected."
                            )

                            SheetSection(
                                title: "Camera",
                                subtitle: qrProgress.isEmpty ? "Align the QR code inside the guide." : qrProgress,
                                icon: "camera.fill"
                            ) {
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
                                        qrProgress = "Scanned \(received) of \(total) frames"
                                    case .complete(let value):
                                        code = value
                                        qrProgress = ""
                                        showingScanner = false
                                        Task {
                                            await model.addContact(code: value)
                                            dismiss()
                                        }
                                    case .invalid:
                                        qrProgress = "That frame is not part of a valid contact code."
                                    }
                                }, onError: { message in
                                    showingScanner = false
                                    model.lastError = message
                                }, allowsMultiple: true)
                            }
                        }
                        .frame(maxWidth: 680)
                        .padding(16)
                        .frame(maxWidth: .infinity)
                        Spacer(minLength: 0)
                    }
                    .noctyraSheetBackground()
                    .hideSheetNavigationBar()
                }
                .noctyraSheetPresentation()
            }
        }
        .noctyraSheetPresentation()
    }

    @ViewBuilder
    private var pairingMethodContent: some View {
        switch method {
        case .scanQR:
            SheetSection(title: "Scan Animated QR", icon: "qrcode.viewfinder") {
                Text("Point this device at the other person’s contact QR. Multi-frame codes are collected automatically.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button {
                    showingScanner = true
                } label: {
                    Label("Open QR Scanner", systemImage: "camera.viewfinder")
                }
                .glassButton(prominent: true)
                .hoverLift()
                if !qrProgress.isEmpty {
                    Label(qrProgress, systemImage: "circle.dotted")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .pasteCode:
            SheetSection(title: "Paste Contact Code", icon: "doc.on.clipboard") {
                Text("Paste the complete contact payload exactly as received.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TextEditor(text: $code)
                    .font(.caption.monospaced())
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 150)
                    .noctyraInputField()
                Button {
                    Task {
                        await model.addContact(code: code)
                        dismiss()
                    }
                } label: {
                    Label("Add Contact", systemImage: "person.badge.plus")
                }
                .glassButton(prominent: true)
                .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .hoverLift()
            }
        case .importFile:
            SheetSection(title: "Protected Contact File", icon: "doc.badge.key") {
                Text("Choose a Noctyra contact file and enter the password shared by its sender.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Button {
                    showingImporter = true
                } label: {
                    Label(
                        importedFileData == nil ? "Choose Contact File" : "Choose Another File",
                        systemImage: "folder"
                    )
                }
                .glassButton()
                .hoverLift()

                if let importedFileName {
                    Label(importedFileName, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                SecureField("File password", text: $sharePassword)
                    .noctyraInputField()

                Button {
                    importSelectedFile()
                } label: {
                    Label("Import Contact", systemImage: "square.and.arrow.down")
                }
                .glassButton(prominent: true)
                .disabled(importedFileData == nil || sharePassword.isEmpty)
                .hoverLift()
            }
        case .insecure:
            relayPairingContent
        case .federation:
            federationPairingContent
        }
    }

    @ViewBuilder
    private var relayPairingContent: some View {
        let formattedDate: (Date?) -> String = { date in
            date?.formatted(date: .abbreviated, time: .shortened) ?? "Never"
        }

        SheetSection(title: "Pairing via Relay", icon: "antenna.radiowaves.left.and.right") {
            Toggle("Enable pairing via relay", isOn: $insecureSettings.isEnabled)
            Toggle("I understand relay pairing leaks metadata", isOn: $insecureSettings.acknowledgeInterceptRisk)
                .disabled(!insecureSettings.isEnabled)
            Toggle("Allow incoming relay pair requests", isOn: $insecureSettings.allowInboundRequests)
                .disabled(!insecureSettings.isEnabled || !insecureSettings.acknowledgeInterceptRisk)
            Text("Relay pairing exposes timing, relay endpoint, and participant fingerprints. Encryption protects message content, but the relay cannot prove a discovered identity belongs to the person you expect. Compare the safety code over a separate trusted channel before marking the contact verified.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }

        if insecureSettings.isReady {
            SheetSection(
                title: "Discovery Status",
                subtitle: "\(model.insecureLastPeerCount) peer\(model.insecureLastPeerCount == 1 ? "" : "s") found",
                icon: "dot.radiowaves.left.and.right"
            ) {
                let relay = model.insecureLastRelay ?? model.state.relay
                pairingStatusRow("Relay", "\(relay.host):\(relay.port)")
                pairingStatusRow("Announced", formattedDate(model.insecureLastAnnounceAt))
                pairingStatusRow("Last discovery", formattedDate(model.insecureLastListAt))
                if model.state.insecurePairing.allowInboundRequests {
                    pairingStatusRow("Pending requests", "\(model.insecureLastRequestCount)")
                }
                if let error = model.insecureLastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        announceButton
                        refreshListButton
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        announceButton
                        refreshListButton
                    }
                }
                .contextMenu {
                    Button("Run Self Test") {
                        FeedbackGenerator.light()
                        Task { await model.runInsecurePairingSelfTest() }
                    }
                }
            }

            SheetSection(title: "Discovered Peers", icon: "person.2.wave.2") {
                if model.insecureAnnouncements.isEmpty {
                    SheetEmptyState(
                        icon: "dot.radiowaves.left.and.right",
                        title: "No peers found",
                        message: "Ask the other person to enable relay pairing, then refresh."
                    )
                }
                ForEach(model.insecureAnnouncements) { announcement in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(announcement.offer.displayName)
                                .font(.headline)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        Text("Relay: \(announcement.offer.relay.host):\(announcement.offer.relay.port)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("Safety code: \(pairingSafetyNumber(for: announcement.offer.fingerprint))")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Button("Send Pairing Request") {
                            Task { await model.sendPairRequest(to: announcement) }
                        }
                        .glassButton(prominent: true)
                        .hoverLift()
                    }
                    .padding(12)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
                }
            }

            SheetSection(title: "Incoming Requests", icon: "tray.and.arrow.down.fill") {
                if model.insecureRequests.isEmpty {
                    SheetEmptyState(
                        icon: "tray",
                        title: "No incoming requests",
                        message: "Requests from discovered peers will appear here."
                    )
                }
                ForEach(model.insecureRequests) { request in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(request.from.displayName)
                            .font(.headline)
                        Text("Relay: \(request.from.relay.host):\(request.from.relay.port)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("Safety code: \(pairingSafetyNumber(for: request.from.fingerprint))")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        #if os(iOS)
                        ViewThatFits(in: .horizontal) {
                            HStack {
                                acceptRequestButton(request)
                                dismissRequestButton(request)
                            }
                            VStack(alignment: .leading, spacing: 10) {
                                acceptRequestButton(request)
                                dismissRequestButton(request)
                            }
                        }
                        #else
                        HStack {
                            acceptRequestButton(request)
                            dismissRequestButton(request)
                        }
                        #endif
                    }
                    .padding(12)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
                }
            }
        } else {
            SheetSection(title: "Discovery Locked", icon: "lock.fill") {
                Text("Enable relay pairing and acknowledge its metadata exposure to begin discovery.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var pairingMethodSubtitle: String {
        switch method {
        case .scanQR: return "Scan a contact code directly from another device."
        case .pasteCode: return "Paste a complete contact payload."
        case .importFile: return "Open a password-protected contact file."
        case .insecure: return "Discover peers through your configured relay."
        case .federation: return "Discover peers across compatible relays in your federation."
        }
    }

    @ViewBuilder
    private var federationPairingContent: some View {
        let formattedDate: (Date?) -> String = { date in
            date?.formatted(date: .abbreviated, time: .shortened) ?? "Never"
        }

        SheetSection(title: "Pair over Federation", icon: "point.3.connected.trianglepath.dotted") {
            Toggle("Enable federation pairing", isOn: $insecureSettings.isEnabled)
            Toggle("I understand federation pairing leaks metadata", isOn: $insecureSettings.acknowledgeInterceptRisk)
                .disabled(!insecureSettings.isEnabled)
            Toggle("Allow incoming federation pair requests", isOn: $insecureSettings.allowInboundRequests)
                .disabled(!insecureSettings.isEnabled || !insecureSettings.acknowledgeInterceptRisk)
            Text("Federation pairing announces this identity to compatible relays in the current federation and checks those relays for peers. Message contents remain protected, but relays may observe timing, participating relays, and identity fingerprints. Compare the safety code over a trusted side channel before marking a contact verified.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }

        if insecureSettings.isReady {
            SheetSection(
                title: "Federation Discovery",
                subtitle: "\(model.federationPairingRelayCount) relay\(model.federationPairingRelayCount == 1 ? "" : "s") scanned",
                icon: "network"
            ) {
                pairingStatusRow("Last refresh", formattedDate(model.federationPairingLastRefreshAt))
                pairingStatusRow("Peers found", "\(model.federationPairingAnnouncements.count)")
                pairingStatusRow("Incoming requests", "\(model.federationPairingRequests.count)")
                if let error = model.federationPairingLastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Button {
                    FeedbackGenerator.light()
                    Task { await model.refreshFederationPairing() }
                } label: {
                    Label("Refresh Federation", systemImage: "arrow.triangle.2.circlepath")
                }
                .glassButton(prominent: true)
                .hoverLift()
            }

            SheetSection(title: "Federation Peers", icon: "person.2.wave.2") {
                if model.federationPairingAnnouncements.isEmpty {
                    SheetEmptyState(
                        icon: "network",
                        title: "No federation peers found",
                        message: "Ask the other person to enable Pair over Federation, then refresh."
                    )
                }
                ForEach(model.federationPairingAnnouncements) { announcement in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(announcement.offer.displayName)
                                .font(.headline)
                            Spacer()
                            Text(announcement.offer.relay.host)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Text("Relay: \(announcement.offer.relay.host):\(announcement.offer.relay.port)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("Safety code: \(pairingSafetyNumber(for: announcement.offer.fingerprint))")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Button("Send Federation Pair Request") {
                            Task { await model.sendFederationPairRequest(to: announcement) }
                        }
                        .glassButton(prominent: true)
                        .hoverLift()
                    }
                    .padding(12)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
                }
            }

            SheetSection(title: "Incoming Federation Requests", icon: "tray.and.arrow.down.fill") {
                if model.federationPairingRequests.isEmpty {
                    SheetEmptyState(
                        icon: "tray",
                        title: "No incoming requests",
                        message: "Requests sent through federation relays will appear here."
                    )
                }
                ForEach(model.federationPairingRequests) { request in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(request.from.displayName)
                            .font(.headline)
                        Text("Reply relay: \(request.from.relay.host):\(request.from.relay.port)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("Safety code: \(pairingSafetyNumber(for: request.from.fingerprint))")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        ViewThatFits(in: .horizontal) {
                            HStack {
                                acceptRequestButton(request)
                                dismissRequestButton(request)
                            }
                            VStack(alignment: .leading, spacing: 10) {
                                acceptRequestButton(request)
                                dismissRequestButton(request)
                            }
                        }
                    }
                    .padding(12)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
                }
            }
        } else {
            SheetSection(title: "Federation Discovery Locked", icon: "lock.fill") {
                Text("Enable federation pairing and acknowledge its metadata exposure to scan compatible relays.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func importSelectedFile() {
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

    private func pairingStatusRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }

    private var announceButton: some View {
        Button("Announce") {
            FeedbackGenerator.light()
            Task { await model.announceInsecurePairing() }
        }
        .glassButton()
        .hoverLift()
    }

    private var refreshListButton: some View {
        Button("Refresh List") {
            FeedbackGenerator.light()
            Task { await model.refreshInsecurePairing() }
        }
        .glassButton()
        .hoverLift()
    }

    private func acceptRequestButton(_ request: PairingRequest) -> some View {
        Button("Accept") {
            Task { await model.acceptPairRequest(request) }
        }
        .glassButton(prominent: true)
        .hoverLift()
    }

    private func dismissRequestButton(_ request: PairingRequest) -> some View {
        Button("Dismiss") {
            model.dismissPairRequest(request)
        }
        .glassButton()
        .hoverLift()
    }

    private func pairingSafetyNumber(for remoteFingerprint: String) -> String {
        ContactSafetyNumber.make(
            localFingerprint: model.state.identity.fingerprint,
            remoteFingerprint: remoteFingerprint
        )
    }
}

private enum PairingMethod: String, CaseIterable, Identifiable {
    case scanQR
    case pasteCode
    case importFile
    case insecure
    case federation

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
            return "Relay Pairing"
        case .federation:
            return "Federation"
        }
    }
}

private struct FullScreenQRView: View {
    let frames: [String]
    let code: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SheetActionBar {
                    dismiss()
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)

                GeometryReader { proxy in
                    // Keep within the smallest iPhone widths (avoid horizontal overflow on 320pt devices).
                    let size = max(220, min(360, proxy.size.width - 48))
                    VStack(spacing: 16) {
                        if frames.count > 1 {
                            AnimatedQRCodeView(frames: frames, size: size, interval: 0.8)
                            Text("Animated QR · scan frames in order")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        } else {
                            QRCodeView(text: code, size: size)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .noctyraSheetBackground()
            .hideSheetNavigationBar()
        }
    }
}

private struct NoctyraMenuCard<TitleAccessory: View, TrailingAccessory: View>: View {
    let title: String
    let subtitle: String
    let symbol: String
    var accent: Color?
    @ViewBuilder var titleAccessory: () -> TitleAccessory
    @ViewBuilder var trailingAccessory: () -> TrailingAccessory

    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    #if os(macOS)
    @State private var hovering = false
    #endif

    private var cardAccent: Color {
        accent ?? theme.accent
    }

    private var isDark: Bool {
        colorScheme == .dark
    }

    var body: some View {
        HStack(spacing: 13) {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        cardAccent.opacity(isDark ? 0.22 : 0.16),
                                        theme.glowSecondary.opacity(isDark ? 0.16 : 0.08)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(isDark ? 0.22 : 0.38), lineWidth: 0.8)
                    )
                    .frame(width: 34, height: 34)

                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(cardAccent)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    titleAccessory()
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailingAccessory()

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(cardAccent.opacity(0.86))
                .frame(width: 26, height: 26)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(isDark ? 0.16 : 0.30), lineWidth: 0.7)
                )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .uniformGlassCard(cornerRadius: 15, minHeight: 72)
        #if os(macOS)
        .shadow(color: theme.accent.opacity(hovering ? 0.18 : 0.06), radius: hovering ? 14 : 7, x: 0, y: hovering ? 7 : 3)
        .scaleEffect(hovering ? 1.006 : 1.0)
        .animation(.easeOut(duration: 0.16), value: hovering)
        .onHover { hovering = $0 }
        #endif
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
    @State private var showingLegalDocuments = false
    @State private var showingAppSecuritySetup = false
    @State private var actionPlanEditorRequest: ActionPlanEditorRequest?
    @State private var pendingActionPlanConfig: ActionPlanCommitConfig?
    @State private var securityReauthRequest: SecurityReauthRequest?
    @State private var lockScreenMessageDraft = ""
    @State private var showPinActions = false
    @State private var showingDonateSheet = false
    #if os(iOS)
    @SceneStorage("noctyra.settings.destination") private var settingsDestinationRaw: String = ""
    #else
    @State private var settingsDestinationRaw: String = ""
    #endif

    private enum SettingsDestination: String, CaseIterable, Identifiable {
        case appearance
        case privacy
        case appLock
        case storage
        case legal
        case donate

        var id: String { rawValue }

        var title: String {
            switch self {
            case .appearance:
                return "Appearance"
            case .privacy:
                return "Privacy"
            case .appLock:
                return "App Lock"
            case .storage:
                return "Storage"
            case .legal:
                return "Legal"
            case .donate:
                return "Donate"
            }
        }

        var subtitle: String {
            switch self {
            case .appearance:
                return "Theme and visual style"
            case .privacy:
                return "Typing, camera, and capture safeguards"
            case .appLock:
                return "Biometrics, PIN, and timeout controls"
            case .storage:
                return "Encryption and local data protection"
            case .legal:
                return "Policies and terms"
            case .donate:
                return "Support ongoing development"
            }
        }

        var symbol: String {
            switch self {
            case .appearance:
                return "paintpalette"
            case .privacy:
                return "lock.shield"
            case .appLock:
                return "key.viewfinder"
            case .storage:
                return "externaldrive.fill"
            case .legal:
                return "doc.text"
            case .donate:
                return "heart.fill"
            }
        }
    }

    private enum SecurityReauthRequest: Identifiable {
        case sessionTimeout(Int)
        case lockMethod
        case pinUpdate(PinSetupKind)

        var id: String {
            switch self {
            case .sessionTimeout(let minutes):
                return "session-\(minutes)"
            case .lockMethod:
                return "lock-method"
            case .pinUpdate(let kind):
                return "pin-\(kind.rawValue)"
            }
        }

        var title: String {
            switch self {
            case .sessionTimeout:
                return "Confirm Session Timeout Change"
            case .lockMethod:
                return "Confirm Unlock Method Change"
            case .pinUpdate:
                return "Confirm PIN Update"
            }
        }

        var subtitle: String {
            switch self {
            case .sessionTimeout:
                return "Re-authenticate to change the session timeout."
            case .lockMethod:
                return "Re-authenticate to change the app unlock method."
            case .pinUpdate:
                return "Re-authenticate before updating security PINs."
            }
        }

        var biometricReason: String {
            switch self {
            case .sessionTimeout:
                return "Authorize session timeout change"
            case .lockMethod:
                return "Authorize unlock method change"
            case .pinUpdate:
                return "Authorize PIN update"
            }
        }
    }

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if settingsDestination != nil {
                    Button {
                        settingsDestination = nil
                        FeedbackGenerator.light()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .accessibilityLabel("Back")
                    .glassCircleButton(diameter: 32)
                    .hoverLift()
                }
                PaneHeader(
                    title: settingsDestination?.title ?? "Settings",
                    subtitle: settingsDestination?.subtitle ?? "Appearance, privacy, and protection"
                )
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 6)
            Group {
                if let destination = settingsDestination {
                    settingsDetail(for: destination)
                } else {
                    settingsMenuCards
                }
            }
            .glassBackgroundIfNeeded()
            .background(setupAppearance)
        }
        .sheet(isPresented: $showingLegalDocuments) {
            ClientLegalDocumentsView()
                .noctyraSheetPresentation()
        }
        .sheet(isPresented: $showingDonateSheet) {
            ClientDonationSheetView()
                .noctyraSheetPresentation()
        }
        .sheet(item: $actionPlanEditorRequest) { request in
            ActionPinPlanEditorView(model: model, initialPlan: request.plan) { config in
                pendingActionPlanConfig = config
                actionPlanEditorRequest = nil
                beginSecurityReauth(for: .pinUpdate(.actionPlan))
            } onCancel: {
                actionPlanEditorRequest = nil
            }
            .noctyraSheetPresentation()
        }
        #else
        VStack(spacing: 0) {
            NoctyraTopBar(
                title: settingsDestination?.title ?? "Settings",
                subtitle: settingsDestination?.subtitle ?? "Appearance, privacy, and protection",
                leading: settingsDestination == nil
                    ? nil
                    : AnyView(
                        Button {
                            settingsDestination = nil
                            FeedbackGenerator.light()
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .accessibilityLabel("Back")
                        .glassCircleButton(diameter: 32)
                        .hoverLift()
                    )
            )
            Group {
                if let destination = settingsDestination {
                    settingsDetail(for: destination)
                } else {
                    settingsMenuCards
                }
            }
            .glassBackgroundIfNeeded()
            .background(setupAppearance)
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    guard settingsDestination != nil else { return }
                    guard value.translation.width > 80 else { return }
                    guard abs(value.translation.height) < 90 else { return }
                    settingsDestination = nil
                    FeedbackGenerator.light()
                }
        )
        .sheet(isPresented: $showingLegalDocuments) {
            ClientLegalDocumentsView()
                .noctyraSheetPresentation()
        }
        .sheet(isPresented: $showingDonateSheet) {
            ClientDonationSheetView()
                .noctyraSheetPresentation()
        }
        .sheet(item: $actionPlanEditorRequest) { request in
            ActionPinPlanEditorView(model: model, initialPlan: request.plan) { config in
                pendingActionPlanConfig = config
                actionPlanEditorRequest = nil
                beginSecurityReauth(for: .pinUpdate(.actionPlan))
            } onCancel: {
                actionPlanEditorRequest = nil
            }
            .noctyraSheetPresentation()
        }
        #endif
    }

    private var settingsDestination: SettingsDestination? {
        get { SettingsDestination(rawValue: settingsDestinationRaw) }
        nonmutating set { settingsDestinationRaw = newValue?.rawValue ?? "" }
    }

    private struct SettingsDestinationCard: View {
        let destination: SettingsDestination

        var body: some View {
            NoctyraMenuCard(
                title: destination.title,
                subtitle: destination.subtitle,
                symbol: destination.symbol,
                accent: nil
            ) {
                EmptyView()
            } trailingAccessory: {
                EmptyView()
            }
        }
    }

    private func settingsDetail(for destination: SettingsDestination) -> some View {
        ScrollView {
            VStack(spacing: 14) {
                SheetSection(
                    title: destination.title,
                    subtitle: destination.subtitle,
                    icon: destination.symbol
                ) {
                    settingsFields(for: destination)
                }
            }
            .frame(maxWidth: 760)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func settingsFields(for destination: SettingsDestination) -> some View {
        switch destination {
        case .appearance:
            appearanceFields
        case .privacy:
            privacyFields
        case .appLock:
            appLockFields
        case .storage:
            storageFields
        case .legal:
            legalFields
        case .donate:
            donateFields
        }
    }

    private var settingsMenuCards: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(SettingsDestination.allCases) { destination in
                    Button {
                        settingsDestination = destination
                        FeedbackGenerator.light()
                    } label: {
                        SettingsDestinationCard(destination: destination)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings-destination-\(destination.rawValue)")
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 20)
            .adaptiveReadableContent(maxWidth: 820)
        }
    }

    private var setupAppearance: some View {
        Color.clear
            .onAppear {
                selectedTheme = model.state.appearance.theme
                privacySettings = model.state.privacy
                appLockSettings = model.state.appLock
                lockScreenMessageDraft = model.state.appLock.lockScreenMessage
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
            .onChange(of: model.state.appLock) { _, newValue in
                appLockSettings = newValue
                lockScreenMessageDraft = newValue.lockScreenMessage
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
            .sheet(isPresented: $showingAppSecuritySetup) {
                AppSecurityUnlockSetupSheet(
                    model: model,
                    currentSettings: appLockSettings
                ) { updated in
                    appLockSettings = updated
                    Task { await model.updateAppLock(updated, lockAfterUpdate: false) }
                }
                .noctyraSheetPresentation()
            }
            .platformPinPresentation(item: $pinSetupKind) { kind in
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
                        case .actionPlan:
                            guard let pending = pendingActionPlanConfig else {
                                success = false
                                model.lastError = "Missing action plan configuration."
                                break
                            }
                            success = await model.setActionPlanPin(
                                pin: pin,
                                planId: pending.planId,
                                label: pending.label,
                                operations: pending.operations
                            )
                        }
                        if success {
                            appLockSettings = model.state.appLock
                            pinSetupKind = nil
                            pendingActionPlanConfig = nil
                            actionPlanEditorRequest = nil
                        }
                        return success
                    },
                    onCancel: {
                        pinSetupKind = nil
                        pendingActionPlanConfig = nil
                    }
                )
            }
            .platformPinPresentation(item: $securityReauthRequest) { request in
                SecurityReauthView(
                    model: model,
                    title: request.title,
                    subtitle: request.subtitle,
                    biometricReason: request.biometricReason
                ) {
                    securityReauthRequest = nil
                    DispatchQueue.main.async {
                        completeSecurityReauth(request)
                    }
                } onCancel: {
                    if case .pinUpdate(.actionPlan) = request {
                        pendingActionPlanConfig = nil
                    }
                    securityReauthRequest = nil
                }
            }
    }

    @ViewBuilder
    private var appearanceFields: some View {
        #if os(iOS)
        // iPhone portrait can be very narrow (including multi-column layouts). Keep swatches flexible.
        let columns = [GridItem(.adaptive(minimum: 112), spacing: 12)]
        #else
        let columns = [GridItem(.adaptive(minimum: 140), spacing: 12)]
        #endif
        let palettes = [ThemePalette.noir] + ThemePalette.allCases.filter { $0 != .noir }
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(palettes) { palette in
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
            #if os(iOS)
            Picker("Secure typing keyboard", selection: $privacySettings.secureTypingKeyboard) {
                ForEach(SecureTypingKeyboard.allCases) { keyboard in
                    Text(keyboard.displayName).tag(keyboard)
                }
            }
            .pickerStyle(.segmented)
            .disabled(!privacySettings.secureTypingEnabled)
            Text(privacySettings.secureTypingKeyboard == .noctyra
                 ? "Noctyra's keyboard avoids the iOS Passwords shortcut by staying outside Apple's password-field path."
                 : "Apple's keyboard keeps native secure text entry. iOS may still show the Passwords shortcut.")
                .font(.caption)
                .foregroundStyle(.secondary)
            #endif
            Toggle("Use in-app camera capture", isOn: $privacySettings.useSecureCameraCapture)
            Text("Captures images inside Noctyra without saving to Photos. This adds a camera button in chats. The OS camera stack can still access raw frames.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("If disabled, the camera button will use the system camera which may store photos in your library.")
                .font(.caption)
                .foregroundStyle(.secondary)
            #if os(macOS)
            Divider().opacity(0.35)
            Toggle("Hide sensitive content when unfocused", isOn: $privacySettings.hideSensitiveWhenUnfocused)
            Text("When Noctyra loses focus, chats, contact details, identities, and relays are hidden until the window is active again.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Block window capture (best effort)", isOn: $privacySettings.macBlockWindowCapture)
            Text("Asks macOS to prevent other processes from capturing this window via standard WindowServer APIs. This does not stop a physical camera.")
                .font(.caption)
                .foregroundStyle(.secondary)
            #endif
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
            VStack(alignment: .leading, spacing: 8) {
                Text("Unlock Method")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Image(systemName: unlockIcon(for: appLockSettings.mode))
                        .font(.system(size: 16, weight: .semibold))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(appLockSettings.mode.displayName)
                            .font(.subheadline.weight(.semibold))
                        Text(unlockDescription(for: appLockSettings.mode))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .uniformGlassCard(cornerRadius: 14, minHeight: 64)
                if !model.biometricsAvailable {
                    Text("Biometrics are unavailable on this device. Use PIN-based unlock.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Choose App Unlock Method") {
                    beginSecurityReauth(for: .lockMethod)
                }
                .glassButton(prominent: true)
                .hoverLift()
            }

            Text("Locks the app when switching tabs or after a timeout. Biometrics require biometric match and do not accept device passcode unlock.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("Lock Screen Message")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("Optional custom message shown on the lock screen.", text: $lockScreenMessageDraft, axis: .vertical)
                    .lineLimit(2...3)
                    .noctyraInputField()
                    .onChange(of: lockScreenMessageDraft) { _, newValue in
                        let capped = String(newValue.prefix(140))
                        if capped != newValue {
                            lockScreenMessageDraft = capped
                        }
                    }
                Text("Optional. Up to 140 characters.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button("Save Lock Message") {
                    appLockSettings.lockScreenMessage = lockScreenMessageDraft
                    Task { await model.updateAppLock(appLockSettings, lockAfterUpdate: false) }
                }
                .glassButton()
                .hoverLift()
                .disabled(lockScreenMessageDraft == appLockSettings.lockScreenMessage)
            }

            Picker(
                "Session timeout",
                selection: Binding(
                    get: { appLockSettings.sessionTimeoutMinutes },
                    set: { newValue in
                        guard newValue != appLockSettings.sessionTimeoutMinutes else { return }
                        beginSecurityReauth(for: .sessionTimeout(newValue))
                    }
                )
            ) {
                Text("Immediate").tag(0)
                Text("1 minute").tag(1)
                Text("5 minutes").tag(5)
                Text("15 minutes").tag(15)
                Text("30 minutes").tag(30)
                Text("60 minutes").tag(60)
            }
            .pickerStyle(.menu)

            if modeRequiresPin(appLockSettings.mode) {
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
                    beginSecurityReauth(for: .pinUpdate(.unlock))
                }
                .glassButton(prominent: true)
                .hoverLift()
                DisclosureGroup(isExpanded: $showPinActions) {
                    pinActionsFields
                } label: {
                    Label("Advanced: PIN Actions", systemImage: "bolt.shield")
                        .font(.subheadline.weight(.semibold))
                }
                .padding(.top, 2)
            }
        }
    }

    private func beginSecurityReauth(for request: SecurityReauthRequest) {
        securityReauthRequest = request
    }

    private func completeSecurityReauth(_ request: SecurityReauthRequest) {
        switch request {
        case .sessionTimeout(let minutes):
            appLockSettings.sessionTimeoutMinutes = minutes
            Task { await model.updateAppLock(appLockSettings, lockAfterUpdate: false) }
        case .lockMethod:
            showingAppSecuritySetup = true
        case .pinUpdate(let kind):
            pinSetupKind = kind
        }
    }

    private func modeRequiresPin(_ mode: AppLockMode) -> Bool {
        mode == .pinOnly || mode == .biometricsAndPin
    }

    private func unlockIcon(for mode: AppLockMode) -> String {
        switch mode {
        case .off:
            return "lock.open"
        case .biometrics:
            return "faceid"
        case .pinOnly:
            return "number.square"
        case .biometricsAndPin:
            return "lock.shield"
        }
    }

    private func unlockDescription(for mode: AppLockMode) -> String {
        switch mode {
        case .off:
            return "No app lock is enforced."
        case .biometrics:
            return "Biometrics only."
        case .pinOnly:
            return "PIN only."
        case .biometricsAndPin:
            return "Biometrics plus PIN."
        }
    }

    private var legalFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Review the Privacy Policy and Terms of Use accepted during onboarding.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("View Privacy Policy and Terms") {
                showingLegalDocuments = true
            }
            .glassButton()
            .hoverLift()
        }
    }

    private var donateFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Noctyra is independently developed. Donations fund maintenance, audits, and relay tooling.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                showingDonateSheet = true
            } label: {
                Label("Donate to Noctyra", systemImage: "heart.fill")
            }
            .glassButton(prominent: true)
            .hoverLift()
        }
    }

    private var pinActionsFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PIN Actions")
                .font(.headline)
            Text("Action plans let one PIN run multiple operations. After execution, that PIN becomes the unlock PIN.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if model.state.appLock.actionPlans.isEmpty {
                Text("No action plans configured.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.state.appLock.actionPlans.sorted(by: { $0.createdAt > $1.createdAt })) { plan in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(plan.label)
                            .font(.subheadline.weight(.semibold))
                        Text(plan.operations.map { $0.kind.displayName }.joined(separator: " • "))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        HStack {
                            Button("Edit") {
                                actionPlanEditorRequest = ActionPlanEditorRequest(plan: plan)
                            }
                            .glassButton(compact: true)
                            Button("Delete") {
                                Task { await model.removeActionPlan(planId: plan.id) }
                            }
                            .glassButton(compact: true)
                        }
                    }
                    .uniformGlassCard(cornerRadius: 12, minHeight: 92)
                }
            }
            Button("Add Action Plan") {
                actionPlanEditorRequest = ActionPlanEditorRequest(plan: nil)
            }
            .glassButton(prominent: true)
            .hoverLift()
        }
        .padding(.top, 6)
    }
}

private let clientDonationProductIDs: [String] = [
    "com.luizwidmer.noctyra.donate.small",
    "com.luizwidmer.noctyra.donate.medium",
    "com.luizwidmer.noctyra.donate.large"
]

@MainActor
private final class ClientDonationStore: ObservableObject {
    @Published var products: [Product] = []
    @Published var isLoading = false
    @Published var statusMessage: String?

    func loadProducts() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await Product.products(for: clientDonationProductIDs)
            products = loaded.sorted { $0.price < $1.price }
            if loaded.isEmpty {
                statusMessage = "No donation products were found. Add the product IDs in App Store Connect or a StoreKit config file."
            } else {
                statusMessage = nil
            }
        } catch {
            statusMessage = "Unable to load donation products: \(error.localizedDescription)"
        }
    }

    func donate(_ product: Product) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    await transaction.finish()
                    statusMessage = "Thanks for supporting Noctyra."
                case .unverified(_, let error):
                    statusMessage = "Purchase could not be verified: \(error.localizedDescription)"
                }
            case .pending:
                statusMessage = "Purchase is pending approval."
            case .userCancelled:
                statusMessage = "Purchase cancelled."
            @unknown default:
                statusMessage = "Purchase failed. Try again."
            }
        } catch {
            statusMessage = "Purchase failed: \(error.localizedDescription)"
        }
    }
}

private struct ClientDonationSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = ClientDonationStore()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SheetActionBar {
                    dismiss()
                } trailing: {
                    Button {
                        Task { await store.loadProducts() }
                    } label: {
                        Label("Reload", systemImage: "arrow.clockwise")
                    }
                    .glassButton(compact: true)
                    .disabled(store.isLoading)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)

                ScrollView {
                    VStack(spacing: 14) {
                        SheetHero(
                            icon: "heart.fill",
                            title: "Support Noctyra",
                            subtitle: "Fund continued maintenance, audits, and privacy-focused development."
                        )

                        SheetSection(
                            title: "Donation Options",
                            subtitle: "One-time in-app purchases processed by Apple.",
                            icon: "giftcard.fill"
                        ) {
                            if store.isLoading && store.products.isEmpty {
                                HStack(spacing: 10) {
                                    ProgressView()
                                    Text("Loading donation options…")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 18)
                            } else if store.products.isEmpty {
                                SheetEmptyState(
                                    icon: "shippingbox",
                                    title: "No options available",
                                    message: "Donation products are not currently available from the App Store."
                                )
                            } else {
                        LazyVStack(spacing: 10) {
                            ForEach(store.products, id: \.id) { product in
                                Button {
                                    Task { await store.donate(product) }
                                } label: {
                                            HStack(spacing: 12) {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(product.displayName)
                                                        .font(.subheadline.weight(.semibold))
                                            Text(product.description)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                        }
                                        Spacer()
                                        Text(product.displayPrice)
                                                    .font(.subheadline.weight(.semibold))
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                            .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                        .uniformGlassCard(cornerRadius: 13, minHeight: 64)
                                .disabled(store.isLoading)
                            }
                        }
                    }
                        }

                if let status = store.statusMessage {
                            Label(status, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .uniformGlassCard(cornerRadius: 13)
                        }
                    }
                    .frame(maxWidth: 680)
                    .padding(16)
                    .frame(maxWidth: .infinity)
                }
            }
            .noctyraSheetBackground()
            .hideSheetNavigationBar()
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 420)
        #endif
        .task {
            await store.loadProducts()
        }
    }
}

private struct SecurityReauthView: View {
    @ObservedObject var model: ClientViewModel
    let title: String
    let subtitle: String
    let biometricReason: String
    let onSuccess: () -> Void
    let onCancel: () -> Void

    @State private var pin = ""
    @State private var errorMessage: String?
    @State private var biometricPassed = false
    @State private var isVerifyingBiometrics = false

    private var mode: AppLockMode {
        model.state.appLock.mode
    }

    private var requiresBiometrics: Bool {
        guard model.biometricsAvailable else {
            return false
        }
        switch mode {
        case .biometrics, .biometricsAndPin:
            return true
        case .pinOnly:
            return false
        case .off:
            return false
        }
    }

    private var requiresPin: Bool {
        switch mode {
        case .pinOnly, .biometricsAndPin:
            return model.state.appLock.isPinConfigured
        case .off:
            return model.state.appLock.isPinConfigured
        case .biometrics:
            return false
        }
    }

    private var biometricSatisfied: Bool {
        !requiresBiometrics || biometricPassed
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.black,
                    Color.black.opacity(0.92),
                    Color.black.opacity(0.86)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 18) {
                HStack {
                    Button("Cancel", action: onCancel)
                        .glassButton(compact: true)
                    Spacer()
                }
                .padding(.horizontal, 16)

                Spacer()

                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.white)
                Text(title)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.72))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)

                if requiresBiometrics && !biometricPassed {
                    Button(isVerifyingBiometrics ? "Verifying..." : "Verify Biometrics") {
                        verifyBiometrics()
                    }
                    .glassButton(prominent: true)
                    .disabled(isVerifyingBiometrics)
                }

                if requiresPin && biometricSatisfied {
                    PinDotsRow(total: 6, filled: pin.count)
                        .padding(.top, 4)
                    NumericPinPad(pin: $pin, maxLength: 6) { _ in
                        verifyPin()
                    }
                } else if biometricSatisfied && !requiresPin {
                    Button("Continue") {
                        onSuccess()
                    }
                    .glassButton(prominent: true)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red.opacity(0.9))
                        .multilineTextAlignment(.center)
                }

                Spacer()
            }
            .padding(.vertical, 24)
        }
        .onAppear {
            errorMessage = nil
            pin = ""
            if !requiresPin && !requiresBiometrics {
                onSuccess()
            }
        }
    }

    private func verifyBiometrics() {
        isVerifyingBiometrics = true
        errorMessage = nil
        Task {
            let success = await model.performBiometricUnlock(reason: biometricReason)
            await MainActor.run {
                isVerifyingBiometrics = false
                if success {
                    biometricPassed = true
                    if !requiresPin {
                        onSuccess()
                    }
                } else {
                    errorMessage = "Biometric verification failed. Ensure Face ID/Touch ID is enrolled and enabled for Noctyra in Settings."
                }
            }
        }
    }

    private func verifyPin() {
        let lockout = model.appLockPinLockoutRemainingSeconds()
        if lockout > 0 {
            pin = ""
            errorMessage = "Too many attempts. Try again in \(lockout)s."
            return
        }
        guard pin.count == 6 else {
            errorMessage = "Enter your 6-digit unlock PIN."
            return
        }
        if model.verifyAppLockPin(pin) {
            errorMessage = nil
            onSuccess()
        } else {
            pin = ""
            let lockout = model.appLockPinLockoutRemainingSeconds()
            if lockout > 0 {
                errorMessage = "Too many attempts. Try again in \(lockout)s."
            } else {
                errorMessage = "Invalid unlock PIN."
            }
        }
    }
}

private struct AppSecurityUnlockSetupSheet: View {
    @ObservedObject var model: ClientViewModel
    let currentSettings: AppLockSettings
    let onApply: (AppLockSettings) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme
    @State private var selectedMode: AppLockMode
    @State private var biometricVerified: Bool
    @State private var isVerifyingBiometrics = false
    @State private var verificationError: String?
    @State private var showingPinSetup = false

    init(
        model: ClientViewModel,
        currentSettings: AppLockSettings,
        onApply: @escaping (AppLockSettings) -> Void
    ) {
        self.model = model
        self.currentSettings = currentSettings
        self.onApply = onApply
        let defaultMode: AppLockMode = model.biometricsAvailable ? .biometrics : .pinOnly
        var initialMode: AppLockMode = currentSettings.mode == .off ? defaultMode : currentSettings.mode
        if !model.biometricsAvailable, initialMode == .biometrics {
            initialMode = currentSettings.isPinConfigured ? .pinOnly : .off
        }
        if !model.biometricsAvailable, initialMode == .biometricsAndPin {
            initialMode = currentSettings.isPinConfigured ? .pinOnly : .off
        }
        let wasBiometricModeAlreadyConfigured = (currentSettings.mode == .biometrics || currentSettings.mode == .biometricsAndPin)
        _selectedMode = State(initialValue: initialMode)
        _biometricVerified = State(initialValue: wasBiometricModeAlreadyConfigured && currentSettings.mode == initialMode)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SheetActionBar(closeLabel: "Cancel") {
                    dismiss()
                } trailing: {
                    Button("Apply") {
                        var updated = model.state.appLock
                        updated.mode = selectedMode
                        onApply(updated)
                        dismiss()
                    }
                    .glassButton(prominent: true, compact: true)
                    .disabled(!canApply)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        SheetHero(
                            icon: "lock.shield.fill",
                            title: "App Security Unlock",
                            subtitle: "Choose how Noctyra verifies access after the app locks."
                        )

                        SheetSection(
                            title: "Unlock Method",
                            subtitle: "Changes are saved only after every required setup step succeeds.",
                            icon: "key.fill"
                        ) {
                            VStack(spacing: 10) {
                                if !model.biometricsAvailable {
                                    Label(
                                        "Biometrics are unavailable on this device. PIN-based unlock remains available.",
                                        systemImage: "touchid"
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }

                                ForEach(selectableModes) { mode in
                                    Button {
                                        withAnimation(.easeInOut(duration: 0.18)) {
                                            selectMode(mode)
                                        }
                                    } label: {
                                        HStack(spacing: 12) {
                                            Image(systemName: icon(for: mode))
                                                .font(.system(size: 18, weight: .semibold))
                                                .frame(width: 26)
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(mode.displayName)
                                                    .font(.headline)
                                                Text(description(for: mode))
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                    .multilineTextAlignment(.leading)
                                            }
                                            Spacer()
                                            Image(systemName: selectedMode == mode ? "checkmark.circle.fill" : "circle")
                                                .font(.system(size: 18, weight: .semibold))
                                                .foregroundStyle(selectedMode == mode ? theme.accent : Color.secondary)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .uniformGlassCard(cornerRadius: 16, minHeight: 76)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                                            .stroke(
                                                selectedMode == mode ? theme.accent.opacity(0.75) : Color.white.opacity(0.12),
                                                lineWidth: selectedMode == mode ? 1.4 : 1
                                            )
                                    )
                                }
                            }
                        }

                        if requiresBiometrics(selectedMode) {
                            SheetSection(
                                title: "Biometric Setup",
                                subtitle: biometricVerified ? "Biometrics verified." : "Verification is required before this mode can be enabled.",
                                icon: "touchid"
                            ) {
                                Button(isVerifyingBiometrics ? "Verifying…" : (biometricVerified ? "Re-verify Biometrics" : "Verify Biometrics")) {
                                    verifyBiometrics()
                                }
                                .glassButton(prominent: !biometricVerified)
                                .disabled(isVerifyingBiometrics)
                                .hoverLift()
                            }
                        }

                        if requiresPin(selectedMode) {
                            SheetSection(
                                title: "PIN Setup",
                                subtitle: model.state.appLock.isPinConfigured ? "A six-digit PIN is configured." : "Set a six-digit PIN to continue.",
                                icon: "number.square.fill"
                            ) {
                                Button(model.state.appLock.isPinConfigured ? "Update PIN" : "Set PIN") {
                                    showingPinSetup = true
                                }
                                .glassButton(prominent: !model.state.appLock.isPinConfigured)
                                .hoverLift()
                            }
                        }

                        if let verificationError {
                            Label(verificationError, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .uniformGlassCard(cornerRadius: 13)
                        }
                    }
                    .frame(maxWidth: 700)
                    .padding(16)
                    .frame(maxWidth: .infinity)
                }
            }
            .noctyraSheetBackground()
            .hideSheetNavigationBar()
        }
        .platformPinPresentation(isPresented: $showingPinSetup) {
            PinSetupView(
                title: PinSetupKind.unlock.title,
                subtitle: PinSetupKind.unlock.subtitle,
                onComplete: { pin in
                    let success = await model.setAppLockPin(pin)
                    if success {
                        verificationError = nil
                        showingPinSetup = false
                    }
                    return success
                },
                onCancel: {
                    showingPinSetup = false
                }
            )
        }
        .onAppear {
            guard model.biometricsAvailable, requiresBiometrics(selectedMode), !biometricVerified else { return }
            verifyBiometrics()
        }
    }

    private var canApply: Bool {
        if requiresBiometrics(selectedMode), !biometricVerified {
            return false
        }
        if requiresPin(selectedMode), !model.state.appLock.isPinConfigured {
            return false
        }
        return true
    }

    private func selectMode(_ mode: AppLockMode) {
        if !model.biometricsAvailable, requiresBiometrics(mode) {
            return
        }
        selectedMode = mode
        verificationError = nil
        if requiresBiometrics(mode) {
            let previouslyConfiguredForBiometrics = requiresBiometrics(currentSettings.mode) && currentSettings.mode == mode
            biometricVerified = previouslyConfiguredForBiometrics
            if !biometricVerified {
                verifyBiometrics()
            }
        } else {
            biometricVerified = true
        }
    }

    private func verifyBiometrics() {
        isVerifyingBiometrics = true
        verificationError = nil
        Task {
            let success = await model.performBiometricUnlock(reason: "Authorize unlock method change")
            await MainActor.run {
                isVerifyingBiometrics = false
                if success {
                    biometricVerified = true
                } else {
                    verificationError = "Biometric verification failed. Ensure Face ID/Touch ID is enrolled and enabled for Noctyra in Settings."
                }
            }
        }
    }

    private func requiresBiometrics(_ mode: AppLockMode) -> Bool {
        mode == .biometrics || mode == .biometricsAndPin
    }

    private func requiresPin(_ mode: AppLockMode) -> Bool {
        mode == .pinOnly || mode == .biometricsAndPin
    }

    private func icon(for mode: AppLockMode) -> String {
        switch mode {
        case .off:
            return "lock.open"
        case .biometrics:
            return "faceid"
        case .pinOnly:
            return "number.square"
        case .biometricsAndPin:
            return "lock.shield"
        }
    }

    private func description(for mode: AppLockMode) -> String {
        switch mode {
        case .off:
            return "Disable app unlock checks."
        case .biometrics:
            return "Unlock only with biometrics."
        case .pinOnly:
            return "Unlock only with your PIN."
        case .biometricsAndPin:
            return "Require biometrics first, then PIN."
        }
    }

    private var selectableModes: [AppLockMode] {
        if model.biometricsAvailable {
            return [.biometrics, .pinOnly, .biometricsAndPin]
        }
        return [.pinOnly]
    }
}

private struct IdentityManagementView: View {
    @ObservedObject var model: ClientViewModel
    @EnvironmentObject private var screenProtection: ScreenProtectionMonitor
    @Environment(\.appTheme) private var theme
    @State private var destination: IdentityDestination?
    @State private var newIdentityName = ""
    @State private var newIdentityRelayId: UUID?
    @State private var identitySearchText = ""
    @State private var showingCreateIdentity = false

    var body: some View {
        Group {
            #if os(iOS)
            VStack(spacing: 0) {
                NoctyraTopBar(
                    title: identityTopBarTitle,
                    subtitle: identityTopBarSubtitle,
                    leading: destination == nil
                        ? nil
                        : AnyView(
                            Button {
                                destination = nil
                                FeedbackGenerator.light()
                            } label: {
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 14, weight: .semibold))
                            }
                            .accessibilityLabel("Back")
                            .glassCircleButton(diameter: 34)
                            .hoverLift()
                        )
                )
                Group {
                    if screenProtection.isSensitiveHidden {
                        SensitiveContentPlaceholder(
                            title: "Identity Management Hidden",
                            message: "Screen capture or an external display is active. Identity details are hidden to protect your operational security."
                        )
                    } else {
                        destinationContent
                    }
                }
            }
            #else
            Group {
                if screenProtection.isSensitiveHidden {
                    SensitiveContentPlaceholder(
                    title: "Identity Management Hidden",
                    message: "Screen capture or an external display is active. Identity details are hidden to protect your operational security."
                )
                } else {
                    destinationContent
                }
            }
            #endif
        }
        .onAppear {
            if newIdentityRelayId == nil {
                newIdentityRelayId = model.state.relayServers.first?.id
            }
        }
        .sheet(isPresented: $showingCreateIdentity) {
            createIdentitySheet
                .noctyraSheetPresentation()
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    guard destination != nil else { return }
                    guard value.translation.width > 80 else { return }
                    guard abs(value.translation.height) < 90 else { return }
                    destination = nil
                    FeedbackGenerator.light()
                }
        )
    }

    private enum IdentityDestination: Hashable {
        case audit
        case profile(UUID)
    }

    private var identityTopBarTitle: String {
        switch destination {
        case .audit:
            return "Continuity Audit"
        case .profile:
            return "Profile Management"
        case .none:
            return "Identity Management"
        }
    }

    private var identityTopBarSubtitle: String {
        switch destination {
        case .audit:
            return "Trust, rotation, and burn history"
        case .profile(let profileId):
            if let profile = model.state.identityProfile(id: profileId) {
                return profile.identity.displayName
            }
            return "Identity details and lifecycle controls"
        case .none:
            return "Profiles, continuity, and burns"
        }
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
                identityOverviewCard
                identityBookSection
                continuityAuditLink
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .privacySensitive()
        .glassBackgroundIfNeeded()
        #else
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                identityOverviewCard

                identityBookSection

                continuityAuditLink
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 24)
            .adaptiveReadableContent(maxWidth: 860)
        }
        .privacySensitive()
        .glassBackgroundIfNeeded()
        #endif
    }

    private var identityOverviewCard: some View {
        let total = model.state.identityProfiles.count
        let archived = model.state.identityProfiles.filter(\.isArchived).count
        let activeName = model.state.identityProfile(id: model.state.activeIdentityId)?.identity.displayName ?? "None"

        return ViewThatFits(in: .horizontal) {
            identityOverviewRow(activeName: activeName, total: total, archived: archived)
            identityOverviewStack(activeName: activeName, total: total, archived: archived)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .uniformGlassCard(cornerRadius: 16, minHeight: 96)
    }

    private func identityOverviewRow(activeName: String, total: Int, archived: Int) -> some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 44, height: 44)
                Image(systemName: "person.badge.key.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Active Identity")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(activeName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 8) {
                    identityMetricBadge(title: "Profiles", value: "\(total)")
                    identityMetricBadge(title: "Archived", value: "\(archived)")
                    identityMetricBadge(title: "Audit", value: "\(continuityEventCount)")
                }
            }

            Spacer(minLength: 8)

            Button {
                showingCreateIdentity = true
            } label: {
                Label("New", systemImage: "plus")
            }
            .glassButton(prominent: true, compact: true)
            .hoverLift()
            .disabled(model.state.relayServers.isEmpty)
            #if os(macOS)
            .help(model.state.relayServers.isEmpty ? "Add a relay before creating another identity." : "Create a new identity")
            #endif
        }
    }

    private func identityOverviewStack(activeName: String, total: Int, archived: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: 40, height: 40)
                    Image(systemName: "person.badge.key.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Active Identity")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(activeName)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 8)

                Button {
                    showingCreateIdentity = true
                } label: {
                    Label("New", systemImage: "plus")
                }
                .glassButton(prominent: true, compact: true)
                .hoverLift()
                .disabled(model.state.relayServers.isEmpty)
            }

            HStack(spacing: 8) {
                identityMetricBadge(title: "Profiles", value: "\(total)")
                identityMetricBadge(title: "Archived", value: "\(archived)")
                identityMetricBadge(title: "Audit", value: "\(continuityEventCount)")
            }
        }
    }

    private var createIdentitySheet: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SheetHero(
                    icon: "person.crop.circle.badge.plus",
                    title: "Create Identity",
                    subtitle: "Create an independent inbox with its own home relay."
                )
                addIdentityCard
            }
            .padding(20)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .glassBackgroundIfNeeded()
    }

    private func identityMetricBadge(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.subheadline.weight(.semibold))
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
        let query = identitySearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = ordered.filter { profile in
            guard !query.isEmpty else { return true }
            let haystack = [
                profile.identity.displayName,
                profile.identity.fingerprint,
                profile.inboxId,
                currentRelayName(for: profile)
            ]
            .joined(separator: " ")
            .lowercased()
            return haystack.contains(query)
        }

        return VStack(alignment: .leading, spacing: 12) {
            Text("Identity Book")
                .font(.headline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            InlineSearchField(text: $identitySearchText, prompt: "Search identities")
            if filtered.isEmpty {
                Text("No matching identities.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(filtered) { profile in
                identityProfileCard(profile)
            }
        }
    }

    private func identityProfileCard(_ profile: IdentityProfile) -> some View {
        Button {
            destination = .profile(profile.id)
        } label: {
            NoctyraMenuCard(
                title: profile.identity.displayName,
                subtitle: "\(shortFingerprint(profile.identity.fingerprint)) • \(currentRelayName(for: profile))",
                symbol: profile.isArchived ? "archivebox.fill" : "person.text.rectangle.fill",
                accent: identityAccent(for: profile)
            ) {
                identityStatusBadge(for: profile)
            } trailingAccessory: {
                syncBadge(for: profile)
            }
        }
        .buttonStyle(.plain)
    }

    private func identityAccent(for profile: IdentityProfile) -> Color {
        profile.isArchived ? .secondary : theme.accent
    }

    @ViewBuilder
    private func identityStatusBadge(for profile: IdentityProfile) -> some View {
        if profile.id == model.state.activeIdentityId {
            Text("Active")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.white.opacity(0.15)))
        } else if profile.isArchived {
            Text("Archived")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.white.opacity(0.12)))
        }
    }

    private var addIdentityCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("New Identity", systemImage: "person.crop.circle.badge.plus")
                .font(.headline)
            Text("Creates a separate identity, inbox, and relay assignment. Existing identities remain encrypted and continue syncing.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Display name", text: $newIdentityName)
                .noctyraInputField()
            if !model.state.relayServers.isEmpty {
                HStack(spacing: 10) {
                    Label("Home Relay", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("Home Relay", selection: $newIdentityRelayId) {
                        ForEach(model.state.relayServers) { server in
                            Text(server.displayName).tag(Optional(server.id))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
            } else {
                Label("Add a relay before creating another identity.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button {
                    Task {
                        await model.addIdentityProfile(displayName: newIdentityName, relayId: newIdentityRelayId)
                        newIdentityName = ""
                        showingCreateIdentity = false
                    }
                } label: {
                    Label("Create Identity", systemImage: "plus")
                }
                .glassButton(prominent: true)
                .hoverLift()
                .disabled(
                    newIdentityName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || model.state.relayServers.isEmpty
                )
            }
        }
        .uniformGlassCard(cornerRadius: 16, padding: 16)
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
        Button {
            destination = .audit
        } label: {
            NoctyraMenuCard(
                title: "Continuity Audit",
                subtitle: "\(continuityEventCount) events recorded for the active identity.",
                symbol: "checkmark.shield",
                accent: nil
            ) {
                EmptyView()
            } trailingAccessory: {
                EmptyView()
            }
        }
        .buttonStyle(.plain)
    }

    private func currentRelayName(for profile: IdentityProfile) -> String {
        guard
            let relayId = model.state.identityProfile(id: profile.id)?.selectedRelayId,
            let relay = model.state.relayServers.first(where: { $0.id == relayId })
        else {
            return "Select Relay"
        }
        return relay.displayName
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
                    message: "Screen capture or an external display is active. Audit details are hidden to protect your operational security."
                )
            } else {
                auditContent
            }
        }
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
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                backButton
                #if os(macOS)
                PaneHeader(title: "Continuity Audit", subtitle: "Review trust, rotation, and burn events")
                #else
                SheetHero(
                    icon: "checkmark.shield.fill",
                    title: "Continuity Audit",
                    subtitle: "Review trust, rotation, and burn events."
                )
                #endif
                SheetSection(title: "Audit Trail", icon: "list.bullet.rectangle") {
                    continuityAuditSection
                }
                SheetSection(title: "Purge Audit", icon: "trash", role: .destructive) {
                    purgeSection
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 20)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .glassBackgroundIfNeeded()
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 4)
        #else
        return HStack {
            Button {
                onBack()
            } label: {
                Label("Identity Management", systemImage: "chevron.left")
            }
            .glassButton(compact: true)
            .hoverLift()
            Spacer()
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
                    message: "Screen capture or an external display is active. Identity details are hidden to protect your operational security."
                )
            } else {
                detailContent
            }
        }
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
                .noctyraSheetPresentation()
        }
        .onChange(of: showingBurnIdentity) { _, isPresented in
            if !isPresented {
                confirmBurn = false
            }
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
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                backButton
                #if os(macOS)
                PaneHeader(title: profile?.identity.displayName ?? "Identity")
                #else
                SheetHero(
                    icon: "person.text.rectangle.fill",
                    title: profile?.identity.displayName ?? "Identity",
                    subtitle: isActive ? "Active identity profile" : "Encrypted inactive identity"
                )
                #endif
                if !isActive {
                    SheetSection(title: "Activation Required", icon: "bolt.fill") {
                        activationNotice
                    }
                }
                SheetSection(title: "Profile Management", icon: "person.crop.rectangle") {
                    profileManagementSection
                }
                SheetSection(title: "Burn Identity", icon: "flame.fill", role: .destructive) {
                    burnSection
                }
                if !isActive {
                    SheetSection(title: "Delete Identity", icon: "trash.fill", role: .destructive) {
                        deleteSection
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 20)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .glassBackgroundIfNeeded()
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 4)
        #else
        return HStack {
            Button {
                onBack()
            } label: {
                Label("Identity Management", systemImage: "chevron.left")
            }
            .glassButton(compact: true)
            .hoverLift()
            Spacer()
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
                .noctyraInputField()
                .disabled(!isActive)
            identityCodeRow(title: "Fingerprint", value: fingerprint)
            identityCodeRow(title: "Inbox", value: inboxId)
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

    private func identityCodeRow(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var profileManagementSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            identityFields
            Divider()
                .opacity(0.4)
            homeRelaySection
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

    private var homeRelaySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Home Relay")
                .font(.subheadline.weight(.semibold))
            Text("This identity syncs and receives messages through its selected relay.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if model.state.relayServers.isEmpty {
                Label("No relays configured.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Menu(selectedRelayName) {
                    if let profile {
                        ForEach(model.state.relayServers) { server in
                            Button(server.displayName) {
                                Task {
                                    await model.updateIdentityRelay(profileId: profile.id, relayId: server.id)
                                }
                            }
                        }
                    }
                }
                .disabled(profile?.isArchived == true)
                .glassButton(compact: true)
                .hoverLift()
            }
        }
    }

    private var selectedRelayName: String {
        guard
            let relayId = profile?.selectedRelayId,
            let relay = model.state.relayServers.first(where: { $0.id == relayId })
        else {
            return "Select Relay"
        }
        return relay.displayName
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
    @State private var newSourceName = ""
    @State private var newSourceURL = ""
    @State private var relayEditorMode: RelayEditorMode? =
        ProcessInfo.processInfo.arguments.contains("SHOW_RELAY_EDITOR") ? .add : nil
    @State private var relaySearchText = ""
    @State private var showRelayDiagnostics = false
    @State private var showMasterSourceFormatHelp = false
    @State private var relayDestination: RelayDestination?

    private enum RelayDestination: String, CaseIterable, Identifiable {
        case relays
        case sources

        var id: String { rawValue }

        var title: String {
            switch self {
            case .relays:
                return "Relays"
            case .sources:
                return "Master Sources"
            }
        }

        var symbol: String {
            switch self {
            case .relays:
                return "antenna.radiowaves.left.and.right"
            case .sources:
                return "list.bullet.rectangle"
            }
        }
    }

    var body: some View {
        Group {
            #if os(iOS)
            VStack(spacing: 0) {
                NoctyraTopBar(
                    title: relayTopBarTitle,
                    subtitle: relayTopBarSubtitle,
                    leading: relayDestination == nil
                        ? nil
                        : AnyView(
                            Button {
                                relayDestination = nil
                                FeedbackGenerator.light()
                            } label: {
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 14, weight: .semibold))
                            }
                            .accessibilityLabel("Back")
                            .glassCircleButton(diameter: 34)
                            .hoverLift()
                        )
                )
                Group {
                    if screenProtection.isSensitiveHidden {
                        SensitiveContentPlaceholder(
                            title: "Relays Hidden",
                            message: "Screen capture or an external display is active. Relay details are hidden to protect your operational security."
                        )
                    } else {
                        relaysContent
                    }
                }
            }
            #else
            Group {
                if screenProtection.isSensitiveHidden {
                    SensitiveContentPlaceholder(
                        title: "Relays Hidden",
                        message: "Screen capture or an external display is active. Relay details are hidden to protect your operational security."
                    )
                } else {
                    relaysContent
                }
            }
            #endif
        }
        .onChange(of: screenProtection.isSensitiveHidden) { _, newValue in
            if newValue {
                relayEditorMode = nil
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    guard relayDestination != nil else { return }
                    guard value.translation.width > 80 else { return }
                    guard abs(value.translation.height) < 90 else { return }
                    relayDestination = nil
                    FeedbackGenerator.light()
                }
        )
    }

    private var relayTopBarTitle: String {
        relayDestination?.title ?? "Relays"
    }

    private var relayTopBarSubtitle: String {
        relayDestination == nil ? "Relay list and master sources" : relaySubtitle(for: relayDestination!)
    }

    private func relaySubtitle(for destination: RelayDestination) -> String {
        switch destination {
        case .relays:
            return "\(model.state.relayServers.count) configured relay\(model.state.relayServers.count == 1 ? "" : "s") + diagnostics"
        case .sources:
            let enabled = model.state.masterServerSources.filter(\.isEnabled).count
            return "\(enabled) enabled source\(enabled == 1 ? "" : "s")"
        }
    }

    @ViewBuilder
    private var relaysContent: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if relayDestination != nil {
                    Button {
                        relayDestination = nil
                        FeedbackGenerator.light()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .accessibilityLabel("Back")
                    .glassCircleButton(diameter: 32)
                    .hoverLift()
                }
                PaneHeader(title: relayTopBarTitle, subtitle: relayTopBarSubtitle)
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 6)
            Group {
                if let destination = relayDestination {
                    relayDetail(for: destination)
                } else {
                    relayMenuCards
                }
            }
        }
        .privacySensitive()
        .glassBackgroundIfNeeded()
        .background(setupRelays)
        #else
        Group {
            if let destination = relayDestination {
                relayDetail(for: destination)
            } else {
                relayMenuCards
            }
        }
        .privacySensitive()
        .glassBackgroundIfNeeded()
        .background(setupRelays)
        #endif
    }

    private func relayDetail(for destination: RelayDestination) -> some View {
        ScrollView {
            VStack(spacing: 14) {
                SheetSection(
                    title: destination.title,
                    subtitle: relaySubtitle(for: destination),
                    icon: destination == .relays ? "network" : "list.bullet.rectangle.portrait"
                ) {
                    relaySectionContent(for: destination)
                }
            }
            .frame(maxWidth: 820)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
    }

    private var setupRelays: some View {
        Color.clear
            .onAppear {
                if model.state.selectedRelayId == nil, let first = model.state.relayServers.first {
                    Task { await model.selectRelayServer(id: first.id) }
                }
            }
            .sheet(item: $relayEditorMode) { mode in
                RelayEditorView(title: mode.title, initial: mode.record) { name, endpoint, note, relayPassword in
                    Task {
                        switch mode {
                        case .add:
                            await model.addRelayServer(
                                name: name,
                                endpoint: endpoint,
                                note: note,
                                relayPassword: relayPassword
                            )
                        case .edit(let record):
                            await model.updateRelayServer(
                                id: record.id,
                                name: name,
                                endpoint: endpoint,
                                note: note,
                                relayPassword: relayPassword
                            )
                        }
                    }
                }
                .noctyraSheetPresentation()
            }
            .sheet(isPresented: $showMasterSourceFormatHelp) {
                MasterSourceFormatHelpView()
                    .noctyraSheetPresentation()
            }
    }

    @ViewBuilder
    private func relaySectionContent(for destination: RelayDestination) -> some View {
        switch destination {
        case .relays:
            VStack(alignment: .leading, spacing: 12) {
                relayServersFields
                Divider().opacity(0.35)
                relayDiagnosticsFields
            }
        case .sources:
            VStack(alignment: .leading, spacing: 12) {
                masterSourcesFields
                Divider().opacity(0.35)
                Text("Add Master Source")
                    .font(.subheadline.weight(.semibold))
                addMasterSourceFields
            }
        }
    }

    private struct RelayDestinationCard: View {
        let destination: RelayDestination
        let subtitle: String

        @Environment(\.appTheme) private var theme
        @Environment(\.colorScheme) private var colorScheme
        #if os(macOS)
        @State private var hovering = false
        #endif

        private var isDark: Bool {
            colorScheme == .dark
        }

        var body: some View {
            HStack(spacing: 13) {
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .overlay(
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            theme.accent.opacity(isDark ? 0.22 : 0.16),
                                            theme.glowSecondary.opacity(isDark ? 0.16 : 0.08)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                        )
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(isDark ? 0.22 : 0.38), lineWidth: 0.8)
                        )
                        .frame(width: 34, height: 34)

                    Image(systemName: destination.symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.accent)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(destination.title)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(theme.accent.opacity(0.86))
                    .frame(width: 26, height: 26)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(isDark ? 0.16 : 0.30), lineWidth: 0.7)
                    )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            .uniformGlassCard(cornerRadius: 15, minHeight: 72)
            #if os(macOS)
            .shadow(color: theme.accent.opacity(hovering ? 0.18 : 0.06), radius: hovering ? 14 : 7, x: 0, y: hovering ? 7 : 3)
            .scaleEffect(hovering ? 1.006 : 1.0)
            .animation(.easeOut(duration: 0.16), value: hovering)
            .onHover { hovering = $0 }
            #endif
        }
    }

    private var relayMenuCards: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(RelayDestination.allCases) { destination in
                    Button {
                        relayDestination = destination
                        FeedbackGenerator.light()
                    } label: {
                        RelayDestinationCard(destination: destination, subtitle: relaySubtitle(for: destination))
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 20)
            .adaptiveReadableContent(maxWidth: 820)
        }
    }

    @ViewBuilder
    private var relayServersFields: some View {
        InlineSearchField(text: $relaySearchText, prompt: "Search relays")
        if filteredRelayServers.isEmpty {
            Text(hasRelaySearch ? "No matching relays" : "No relays yet")
                .foregroundStyle(.secondary)
        }
        ForEach(filteredRelayServers) { server in
            RelayServerRow(
                server: server,
                isPreferred: server.id == model.state.selectedRelayId,
                health: model.relayHealth[server.id]
            ) {
                relayEditorMode = .edit(server)
            } onRefreshInfo: {
                Task { await model.fetchRelayInfo(id: server.id) }
            } onRemove: {
                Task { await model.removeRelayServer(id: server.id) }
            }
        }

        Button("Add Relay") {
            relayEditorMode = .add
        }
        .glassButton(prominent: true, compact: true)
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
        Button("Format Help") {
            showMasterSourceFormatHelp = true
        }
        .glassButton(compact: true)
        .hoverLift()
    }

    @ViewBuilder
    private var relayDiagnosticsFields: some View {
        DisclosureGroup(isExpanded: $showRelayDiagnostics) {
            VStack(alignment: .leading, spacing: 8) {
                if let selectedRelay = model.state.relayServers.first(where: { $0.id == model.state.selectedRelayId }) {
                    Text("Selected: \(selectedRelay.displayName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(endpointDisplayString(selectedRelay.endpoint))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else {
                    Text("No relay selected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Button("Test Connection") {
                        Task { await model.testSelectedRelay() }
                    }
                    .glassButton(compact: true)
                    if !model.state.relayServers.isEmpty {
                        Button("Refresh All Relay Info") {
                            refreshAllRelayInfo()
                        }
                        .glassButton(compact: true)
                    }
                }
            }
            .padding(.top, 4)
        } label: {
            Label("Advanced Relay Tools", systemImage: "stethoscope")
                .font(.subheadline.weight(.semibold))
        }
    }

    private func endpointDisplayString(_ endpoint: RelayEndpoint) -> String {
        let scheme: String = {
            switch endpoint.transport {
            case .tcp:
                return endpoint.useTLS ? "tls" : "tcp"
            case .http:
                return endpoint.useTLS ? "https" : "http"
            case .websocket:
                return endpoint.useTLS ? "wss" : "ws"
            }
        }()
        let host = endpoint.host.contains(":") ? "[\(endpoint.host)]" : endpoint.host
        let includePort: Bool = {
            switch endpoint.transport {
            case .http, .websocket:
                let defaultPort: UInt16 = endpoint.useTLS ? 443 : 80
                return endpoint.port != defaultPort
            case .tcp:
                return true
            }
        }()
        if includePort {
            return "\(scheme)://\(host):\(endpoint.port)"
        }
        return "\(scheme)://\(host)"
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

    private var hasRelaySearch: Bool {
        !relaySearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var normalizedRelaySearch: String {
        relaySearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var filteredRelayServers: [RelayServerRecord] {
        let sorted = model.state.relayServers.sorted { lhs, rhs in
            let lhsPreferred = lhs.id == model.state.selectedRelayId
            let rhsPreferred = rhs.id == model.state.selectedRelayId
            if lhsPreferred != rhsPreferred {
                return lhsPreferred
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
        guard hasRelaySearch else { return sorted }
        return sorted.filter { server in
            let info = server.advertisedInfo
            let haystackParts: [String] = [
                server.displayName,
                server.endpoint.host,
                "\(server.endpoint.port)",
                server.region ?? "",
                server.tags?.joined(separator: " ") ?? "",
                server.website ?? "",
                server.note ?? "",
                info?.relayName ?? "",
                info?.operatorNote ?? "",
                info?.softwareVersion ?? "",
                info?.federation.name ?? "",
                info?.federation.description ?? ""
            ]
            let haystack = haystackParts.joined(separator: " ").lowercased()
            return haystack.contains(normalizedRelaySearch)
        }
    }

    private func refreshAllRelayInfo() {
        let relayIds = model.state.relayServers.map(\.id)
        Task {
            for relayId in relayIds {
                await model.fetchRelayInfo(id: relayId)
            }
        }
    }

    @ViewBuilder
    private func masterSourceRow(_ source: MasterServerSource) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(source.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
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
                .lineLimit(1)
                .truncationMode(.middle)
            #if os(iOS)
            Menu {
                Button("Refresh") { Task { await model.fetchMasterSource(source) } }
                Button("Remove", role: .destructive) { Task { await model.removeMasterSource(id: source.id) } }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 16, weight: .semibold))
            }
            .glassCircleButton(diameter: 34)
            .hoverLift()
            #else
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
            #endif
        }
        .uniformGlassCard(cornerRadius: 12, minHeight: 96)
        .padding(.vertical, 2)
    }
}

private struct MasterSourceFormatHelpView: View {
    @Environment(\.dismiss) private var dismiss

    private let textExample = """
# host:port,name,region,tags,website,note,kind,federationMode,federationName,federationDescription,temporalBucketSeconds,operatorNote,softwareVersion,groupCreationMode,requiresPassword,useTLS,curatedStrictPolicyEnabled,curatedCoordinatorQuorum,curatedRequireSignedDirectory,transport
https://relay.example.org:443,Example Relay,US,privacy|high-uptime,https://relay.example.org,Public relay,standard,curated,Noctyra Federation,Trusted mesh,300,No logs,1.2.0,allowed,false,true,true,2,true,http
wss://relay-b.example.org:443,WS Relay,EU,privacy,https://relay-b.example.org,WebSocket endpoint,bridge,open,OpenMesh,Community open federation,120,,,allowed,false,true,,,websocket
"""

    private let jsonExample = """
{
  "servers": [
    {
      "name": "Example Relay",
      "host": "relay.example.org",
      "port": 443,
      "useTLS": true,
      "transport": "http",
      "relayKind": "standard",
      "federationMode": "curated",
      "federationName": "Noctyra Federation"
    }
  ]
}
"""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SheetActionBar {
                    dismiss()
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        SheetHero(
                            icon: "doc.text.magnifyingglass",
                            title: "Master Source Format",
                            subtitle: "Publish relay directories as JSON or line-based text."
                        )

                        SheetSection(
                            title: "Accepted Formats",
                            subtitle: "URL hosts may use HTTP(S) or WebSocket schemes.",
                            icon: "checklist"
                        ) {
                            Text("Use JSON for structured directories or text lines for compact lists. Unknown optional fields are ignored.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        SheetSection(title: "JSON Example", icon: "curlybraces") {
                            Text(jsonExample)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        SheetSection(title: "Text Example", icon: "text.alignleft") {
                            Text(textExample)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(maxWidth: 760)
                    .padding(16)
                    .frame(maxWidth: .infinity)
                }
            }
            .noctyraSheetBackground()
            .hideSheetNavigationBar()
        }
    }
}

private struct ContactBookView: View {
    private struct DeleteContactPrompt: Identifiable {
        let id: UUID
        let name: String
    }

    @ObservedObject var model: ClientViewModel
    @EnvironmentObject private var screenProtection: ScreenProtectionMonitor
    let onOpen: (UUID) -> Void
    let onAdd: () -> Void
    @State private var trustPrompt: TrustPrompt?
    @State private var deleteContactPrompt: DeleteContactPrompt?
    @State private var searchText = ""

    var body: some View {
        Group {
            #if os(iOS)
            VStack(spacing: 0) {
                NoctyraTopBar(
                    title: "Contact Book",
                    subtitle: "Contacts and trust",
                    trailing: AnyView(
                        Button {
                            onAdd()
                        } label: {
                            Image(systemName: "person.badge.plus")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .accessibilityLabel("Add Contact")
                        .glassCircleButton(prominent: true, diameter: 34)
                        .hoverLift()
                    )
                )
                Group {
                    if screenProtection.isSensitiveHidden {
                        SensitiveContentPlaceholder(
                            title: "Contact Book Hidden",
                            message: "Screen capture or an external display is active. Contact details are hidden to protect your operational security."
                        )
                    } else {
                        iosContactList
                    }
                }
            }
            #else
            if screenProtection.isSensitiveHidden {
                SensitiveContentPlaceholder(
                    title: "Contact Book Hidden",
                    message: "Screen capture or an external display is active. Contact details are hidden to protect your operational security."
                )
            } else {
                contactBookMac
            }
            #endif
        }
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
            .noctyraSheetPresentation()
        }
        .confirmationDialog(
            "Delete contact?",
            isPresented: Binding(
                get: { deleteContactPrompt != nil },
                set: { if !$0 { deleteContactPrompt = nil } }
            )
        ) {
            if let prompt = deleteContactPrompt {
                Button("Delete \(prompt.name)", role: .destructive) {
                    Task { await model.removeContact(id: prompt.id) }
                    deleteContactPrompt = nil
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the contact, local direct chat history, and trust records from this device.")
        }
    }

    #if os(macOS)
    private var contactBookMac: some View {
        VStack(alignment: .leading, spacing: 16) {
            PaneHeader(title: "Contact Book", subtitle: "Contacts and trust")
            List {
                contactListRows
            }
            .scrollContentBackground(.hidden)
            .listSectionSeparator(.hidden)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listStyle(.inset)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
        .privacySensitive()
    }
    #endif

    #if os(iOS)
    private var iosContactList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                InlineSearchField(text: $searchText, prompt: "Search contacts")

                HStack {
                    Label(
                        "\(filteredContacts.count) contact\(filteredContacts.count == 1 ? "" : "s")",
                        systemImage: "person.2.fill"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 4)

                if filteredContacts.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: hasActiveSearch ? "magnifyingglass" : "person.crop.circle.badge.plus")
                            .font(.system(size: 28, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(hasActiveSearch ? "No matching contacts" : "Your contact book is empty")
                            .font(.headline)
                        if !hasActiveSearch {
                            Text("Add a contact using a protected file, animated QR, AirDrop, or relay pairing.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            Button("Add Contact") { onAdd() }
                                .glassButton(prominent: true)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .uniformGlassCard(cornerRadius: 18, padding: 16)
                } else {
                    ForEach(filteredContacts) { contact in
                        contactCard(contact)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 24)
            .adaptiveReadableContent(maxWidth: 860)
        }
        .privacySensitive()
        .glassBackgroundIfNeeded()
    }

    private func contactCard(_ contact: Contact) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "person.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 40, height: 40)
                    .background(Color.accentColor.opacity(0.14), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(contact.displayName)
                        .font(.headline)
                        .lineLimit(1)
                    Text(contact.isTrusted ? "Verified contact" : "Verification pending")
                        .font(.caption)
                        .foregroundStyle(contact.isTrusted ? Color.green : Color.secondary)
                }
                Spacer()
                Button { onOpen(contact.id) } label: {
                    Image(systemName: "bubble.left.fill")
                        .font(.system(size: 14, weight: .semibold))
                }
                .accessibilityLabel("Open Chat")
                .glassCircleButton(prominent: true, diameter: 34)
                Button {
                    deleteContactPrompt = DeleteContactPrompt(id: contact.id, name: contact.displayName)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 14, weight: .semibold))
                }
                .accessibilityLabel("Delete Contact")
                .glassCircleButton(diameter: 34)
            }

            VStack(alignment: .leading, spacing: 5) {
                contactMetadataRow("Relay", value: "\(contact.relay.host):\(contact.relay.port)")
                contactMetadataRow("Inbox", value: contact.inboxId)
                contactMetadataRow("Fingerprint", value: shortFingerprint(contact.fingerprint))
            }

            trustSection(for: contact)

            Toggle(isOn: identityResetBinding(for: contact)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Receive identity after burn")
                        .font(.caption.weight(.semibold))
                    Text("Keep this contact through a full identity reset.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
        }
        .uniformGlassCard(cornerRadius: 18, padding: 14)
        .contextMenu {
            Button("Remove Contact", role: .destructive) {
                deleteContactPrompt = DeleteContactPrompt(id: contact.id, name: contact.displayName)
            }
        }
    }

    private func contactMetadataRow(_ label: String, value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            Text(value)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
    #endif

    private var contactList: some View {
        List {
            contactListRows
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

    @ViewBuilder
    private var contactListRows: some View {
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
            InlineSearchField(text: $searchText, prompt: "Search contacts")
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }

        if filteredContacts.isEmpty {
            Text(hasActiveSearch ? "No matching contacts" : "No contacts yet")
                .foregroundStyle(.secondary)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }

        ForEach(filteredContacts) { contact in
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(contact.displayName)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                    Spacer()
                    #if os(iOS)
                    Button { onOpen(contact.id) } label: {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .glassCircleButton(diameter: 32)
                    .hoverLift()
                    Button {
                        deleteContactPrompt = DeleteContactPrompt(id: contact.id, name: contact.displayName)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .glassCircleButton(diameter: 32)
                    .hoverLift()
                    #else
                    Button("Open") { onOpen(contact.id) }
                        .glassButton()
                        .hoverLift()
                Button("Delete") {
                    deleteContactPrompt = DeleteContactPrompt(id: contact.id, name: contact.displayName)
                }
                .glassButton()
                .hoverLift()
                    #endif
                }
                Text("Inbox: \(contact.inboxId)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Relay: \(contact.relay.host):\(contact.relay.port)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Fingerprint: \(contact.fingerprint)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                trustSection(for: contact)
                Toggle(isOn: identityResetBinding(for: contact)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Receive new identity after burn")
                            .font(.caption.weight(.semibold))
                        Text("Only contacts with this enabled are notified and kept.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .uniformGlassCard(cornerRadius: 12, padding: 0, minHeight: 156)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
            .contextMenu {
                Button("Remove Contact", role: .destructive) {
                    deleteContactPrompt = DeleteContactPrompt(id: contact.id, name: contact.displayName)
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    deleteContactPrompt = DeleteContactPrompt(id: contact.id, name: contact.displayName)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    private var hasActiveSearch: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var filteredContacts: [Contact] {
        let sorted = model.state.contacts.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        guard hasActiveSearch else { return sorted }
        return sorted.filter { contact in
            let haystack = [
                contact.displayName,
                contact.inboxId,
                contact.fingerprint,
                contact.relay.host,
                "\(contact.relay.port)"
            ]
                .joined(separator: " ")
                .lowercased()
            return haystack.contains(normalizedSearchText)
        }
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
                    .lineLimit(2)
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
            #if os(iOS)
            Menu {
                Button(trustActionLabel(for: contact)) {
                    trustPrompt = TrustPrompt(
                        contact: contact,
                        action: .verified,
                        localFingerprint: model.state.identity.fingerprint
                    )
                }
                Button("Revoke", role: .destructive) {
                    trustPrompt = TrustPrompt(
                        contact: contact,
                        action: .revoked,
                        localFingerprint: model.state.identity.fingerprint
                    )
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 16, weight: .semibold))
            }
            .glassCircleButton(diameter: 34)
            .hoverLift()
            #else
            VStack(alignment: .trailing, spacing: 6) {
                Button(trustActionLabel(for: contact)) {
                    trustPrompt = TrustPrompt(
                        contact: contact,
                        action: .verified,
                        localFingerprint: model.state.identity.fingerprint
                    )
                }
                .glassButton(compact: true)
                .hoverLift()
                Button("Revoke") {
                    trustPrompt = TrustPrompt(
                        contact: contact,
                        action: .revoked,
                        localFingerprint: model.state.identity.fingerprint
                    )
                }
                .glassButton(compact: true)
                .hoverLift()
            }
            #endif
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
    let localFingerprint: String
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
            if prompt.action == .verified {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Safety code")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(
                        ContactSafetyNumber.make(
                            localFingerprint: prompt.localFingerprint,
                            remoteFingerprint: prompt.contact.fingerprint
                        )
                    )
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
            TextField("Optional note", text: $note, axis: .vertical)
                .lineLimit(2...4)
                .noctyraInputField()
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
        .frame(maxWidth: 460)
        .uniformGlassCard(cornerRadius: 18, padding: 16)
        .padding(16)
        .noctyraSheetBackground()
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
    let health: RelayHealthSnapshot?
    let onEdit: () -> Void
    let onRefreshInfo: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(server.displayName)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                if isPreferred {
                    Text("Preferred")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                #if os(macOS)
                transportBadge
                relayHealthBadge
                #endif
                Spacer()
                #if os(iOS)
                Menu {
                    Button("Refresh Info") { onRefreshInfo() }
                    Button("Copy Endpoint") { copyEndpoint() }
                    Button("Edit") { onEdit() }
                    Button("Remove", role: .destructive) { onRemove() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 16, weight: .semibold))
                }
                .glassCircleButton(diameter: 34)
                .hoverLift()
                #else
                Button("Info") { onRefreshInfo() }
                    .glassButton(compact: true)
                    .hoverLift()
                Button("Edit") { onEdit() }
                    .glassButton(compact: true)
                    .hoverLift()
                #endif
            }
            #if os(iOS)
            HStack(spacing: 6) {
                transportBadge
                relayHealthBadge
                Spacer(minLength: 0)
            }
            .padding(.top, 4)
            #endif
            Text("\(server.endpoint.host):\(server.endpoint.port)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            relayHealthSummary
            if let region = server.region, !region.isEmpty {
                Text("Region: \(region)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let tags = server.tags, !tags.isEmpty {
                Text("Tags: \(tags.joined(separator: ", "))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let website = server.website, !website.isEmpty {
                Text(website)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let note = server.note, !note.isEmpty {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            relayInfoSection
        }
        .uniformGlassCard(cornerRadius: 12, minHeight: 138)
        .contextMenu {
            Button("Copy Endpoint") { copyEndpoint() }
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
    private var relayHealthBadge: some View {
        if let badge = relayHealthBadgeData {
            let view = StableCapsuleBadge(text: badge.text, icon: badge.icon, color: badge.color)
            #if os(macOS)
            view.help(badge.help)
            #else
            view
            #endif
        }
    }

    @ViewBuilder
    private var relayHealthSummary: some View {
        if let health {
            let checked = Self.relativeFormatter.localizedString(for: health.lastCheckedAt, relativeTo: Date())
            if let latency = health.latencyMs {
                Text("Latency: \(latency) ms · checked \(checked)")
                    .font(.caption2)
                    .foregroundStyle(health.isReachable ? Color.secondary : Color.orange)
            } else {
                Text("Checked \(checked)")
                    .font(.caption2)
                    .foregroundStyle(health.isReachable ? Color.secondary : Color.orange)
            }
            if let failureReason = health.failureReason, !failureReason.isEmpty, !health.isReachable {
                Text("Health issue: \(failureReason)")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        } else {
            Text("Health not checked yet.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var relayHealthBadgeData: (text: String, icon: String, color: Color, help: String)? {
        guard let health else { return nil }
        let isStale = Date().timeIntervalSince(health.lastCheckedAt) > 300
        if health.isReachable {
            if isStale {
                return ("Stale", "clock.badge.exclamationmark", .orange, "Relay responded before, but health data is older than 5 minutes.")
            }
            return ("Healthy", "checkmark.circle.fill", .green, "Relay is reachable.")
        }
        return ("Unreachable", "xmark.octagon.fill", .red, "Relay failed last health check.")
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    @ViewBuilder
    private var transportBadge: some View {
        let badge = transportBadgeData
        let view = StableCapsuleBadge(text: badge.text, icon: badge.icon, color: badge.color)
        #if os(macOS)
        view.help(badge.help)
        #else
        view
        #endif
    }

    private var transportBadgeData: (text: String, icon: String, color: Color, help: String) {
        let configuredTLS = server.endpoint.useTLS
        if let advertisedTLS = server.advertisedInfo?.tlsEnabled {
            if configuredTLS && advertisedTLS {
                return ("TLS On", "lock.shield.fill", .green, "Client and relay are both set to TLS.")
            }
            if configuredTLS && !advertisedTLS {
                return ("TLS Mismatch", "exclamationmark.triangle.fill", .orange, "Client expects TLS, but relay reports TLS disabled.")
            }
            if !configuredTLS && advertisedTLS {
                return ("No TLS", "lock.open.fill", .orange, "Relay supports TLS, but this client entry is using plain transport.")
            }
            return ("No TLS", "lock.open.fill", .secondary, "Client and relay are both using plain transport.")
        }
        if configuredTLS {
            return ("TLS On", "lock.fill", .blue, "Client entry is configured for TLS. Refresh info to verify relay status.")
        }
        return ("No TLS", "lock.open", .secondary, "Client entry is configured for plain transport.")
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
            policyBadgesRow(for: info)
            Text("Temporal bucket: \(formatBucket(info.temporalBucketSeconds))")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let schedule = info.temporalBucketScheduleSeconds, !schedule.isEmpty {
                Text("Multi-buckets: \(formatBucketSchedule(schedule))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let attachmentDefaultTTL = info.attachmentDefaultTTLSeconds {
                let attachmentMaxTTL = info.attachmentMaxTTLSeconds ?? attachmentDefaultTTL
                Text("Attachment retention: default \(formatTTL(attachmentDefaultTTL)), max \(formatTTL(attachmentMaxTTL))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let attachmentStorageBackend = info.attachmentStorageBackend,
               !attachmentStorageBackend.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Attachment storage: \(attachmentStorageBackend.uppercased())")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let wakeSupport = info.wakeSupport {
                Text("Wake policy: \(wakePolicyLabel(wakeSupport))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                Text("Wake policy: local polling defaults")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if info.attachmentsEnabled == false {
                Text("Media policy: text-only")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            if let coordinators = info.federationCoordinatorEndpoints, !coordinators.isEmpty {
                let display = coordinators.prefix(2).map { endpoint in
                    "\(endpoint.host):\(endpoint.port)"
                }.joined(separator: ", ")
                let suffix = coordinators.count > 2 ? " +\(coordinators.count - 2) more" : ""
                Text("Coordinators: \(display)\(suffix)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let relayCount = info.coordinatorReportedRelayCount {
                Text("Coordinator directory: \(relayCount) relays")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let groupMode = info.groupCreationMode {
                Text("Group creation: \(groupCreationLabel(groupMode))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let relayName = info.relayName, !relayName.isEmpty {
                Text("Relay name: \(relayName)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let operatorNote = info.operatorNote, !operatorNote.isEmpty {
                Text(operatorNote)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            if let software = info.softwareVersion, !software.isEmpty {
                Text("Software: \(software)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if info.requiresPassword == true {
                let configured = !(server.relayPassword?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                Text(configured ? "Relay password configured." : "Relay requires password: configure it in Edit.")
                    .font(.caption2)
                    .foregroundStyle(configured ? Color.secondary : Color.orange)
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

    private struct PolicyBadge: Identifiable {
        let id: String
        let text: String
        let icon: String
        let color: Color
        let help: String
    }

    @ViewBuilder
    private func policyBadgesRow(for info: RelayInfo) -> some View {
        let badges = federationPolicyBadges(for: info)
        if !badges.isEmpty {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    ForEach(badges) { badge in
                        policyBadgeView(badge)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(badges) { badge in
                        policyBadgeView(badge)
                    }
                }
            }
            .padding(.top, 2)
        }
    }

    @ViewBuilder
    private func policyBadgeView(_ badge: PolicyBadge) -> some View {
        let view = StableCapsuleBadge(text: badge.text, icon: badge.icon, color: badge.color)
        #if os(macOS)
        view.help(badge.help)
        #else
        view
        #endif
    }

    private func federationPolicyBadges(for info: RelayInfo) -> [PolicyBadge] {
        var badges: [PolicyBadge] = []

        if info.federation.mode == .curated {
            if info.curatedStrictPolicyEnabled == true {
                badges.append(
                    PolicyBadge(
                        id: "curated-strict",
                        text: "Strict Curated",
                        icon: "shield.checkered",
                        color: .green,
                        help: "Curated forwarding requires allowlist + coordinator verification."
                    )
                )
            } else if info.curatedStrictPolicyEnabled == false {
                badges.append(
                    PolicyBadge(
                        id: "curated-soft",
                        text: "Curated",
                        icon: "shield.lefthalf.filled",
                        color: .orange,
                        help: "Curated forwarding is running with strict policy disabled."
                    )
                )
            }
            if let quorum = info.curatedCoordinatorQuorum {
                badges.append(
                    PolicyBadge(
                        id: "curated-quorum-\(quorum)",
                        text: "Quorum \(quorum)",
                        icon: "person.3.fill",
                        color: .blue,
                        help: "Coordinator quorum required for curated forwarding."
                    )
                )
            }
            if let requireSigned = info.curatedRequireSignedDirectory {
                badges.append(
                    PolicyBadge(
                        id: "curated-signed-\(requireSigned ? "on" : "off")",
                        text: requireSigned ? "Signed Dir" : "Unsigned Dir OK",
                        icon: requireSigned ? "checkmark.seal.fill" : "exclamationmark.shield.fill",
                        color: requireSigned ? .mint : .orange,
                        help: requireSigned
                            ? "Relay requires signed coordinator directory snapshots."
                            : "Relay accepts unsigned coordinator directory responses."
                    )
                )
            }
        }

        if info.requiresPassword == true {
            badges.append(
                PolicyBadge(
                    id: "password-required",
                    text: "Password",
                    icon: "key.fill",
                    color: .orange,
                    help: "Relay requires an access password for operational requests."
                )
            )
        }

        return badges
    }

    private func copyEndpoint() {
        Clipboard.copy(endpointClipboardValue)
        FeedbackGenerator.light()
    }

    private var endpointClipboardValue: String {
        let scheme: String
        switch server.endpoint.transport {
        case .tcp:
            scheme = server.endpoint.useTLS ? "tls" : "tcp"
        case .http:
            scheme = server.endpoint.useTLS ? "https" : "http"
        case .websocket:
            scheme = server.endpoint.useTLS ? "wss" : "ws"
        }
        let includePort: Bool = {
            switch server.endpoint.transport {
            case .http, .websocket:
                let defaultPort: UInt16 = server.endpoint.useTLS ? 443 : 80
                return server.endpoint.port != defaultPort
            case .tcp:
                return true
            }
        }()
        if includePort {
            return "\(scheme)://\(server.endpoint.host):\(server.endpoint.port)"
        }
        return "\(scheme)://\(server.endpoint.host)"
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
        case .manual:
            if let name = federation.name, !name.isEmpty {
                return "Manual (\(name))"
            }
            return "Manual"
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
        case .coordinator:
            return "Coordinator"
        }
    }

    private func groupCreationLabel(_ mode: GroupCreationMode) -> String {
        switch mode {
        case .allowed:
            return "Allowed"
        case .disabled:
            return "Disabled"
        }
    }

    private func wakePolicyLabel(_ support: DecentralizedWakeSupport) -> String {
        let interval = "\(formatWakeDuration(support.minPollIntervalSeconds))-\(formatWakeDuration(support.maxPollIntervalSeconds))"
        let jitter = support.jitterPermille == 0
            ? "no jitter"
            : "\(support.jitterPermille / 10)% jitter"
        switch support.mode {
        case .pullOnly:
            return "pull-only, \(interval), \(jitter)"
        case .longPoll:
            let timeout = support.longPollTimeoutSeconds.map(formatWakeDuration) ?? "default timeout"
            return "long-poll, \(interval), timeout \(timeout), \(jitter)"
        }
    }

    private func formatWakeDuration(_ seconds: Int) -> String {
        if seconds < 60 {
            return "\(seconds)s"
        }
        if seconds < 3600 {
            return seconds % 60 == 0
                ? "\(seconds / 60)m"
                : String(format: "%.1fm", Double(seconds) / 60.0)
        }
        return seconds % 3600 == 0
            ? "\(seconds / 3600)h"
            : String(format: "%.1fh", Double(seconds) / 3600.0)
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

    private func formatBucketSchedule(_ schedule: [Int]) -> String {
        let normalized = Array(Set(schedule.filter { $0 > 0 })).sorted()
        if normalized.isEmpty {
            return "Off"
        }
        return normalized.map(formatBucket).joined(separator: ", ")
    }

    private func formatTTL(_ seconds: Int) -> String {
        if seconds < 60 {
            return "\(seconds)s"
        }
        if seconds < 3600 {
            return "\(seconds / 60)m"
        }
        if seconds % 3600 == 0 {
            return "\(seconds / 3600)h"
        }
        return String(format: "%.1fh", Double(seconds) / 3600.0)
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
            return "Add Relay"
        case .edit:
            return "Edit Relay"
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
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        let isDark = colorScheme == .dark
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
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.black.opacity(isDark ? 0.20 : 0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    theme.accent.opacity(isDark ? 0.16 : 0.10),
                                    theme.glowSecondary.opacity(isDark ? 0.10 : 0.06),
                                    Color.clear
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
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
        .shadow(color: theme.accent.opacity(isDark ? 0.12 : 0.08), radius: 10, x: 0, y: 4)
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
            .frame(maxWidth: .infinity, minHeight: 108, alignment: .leading)
            .padding(12)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.ultraThinMaterial)
                    GlassCardBacking(cornerRadius: 16)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .modifier(GlowCardModifier())
        #else
        return self
            .frame(maxWidth: .infinity, minHeight: 108, alignment: .leading)
            .padding(12)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.ultraThinMaterial)
                    GlassCardBacking(cornerRadius: 16)
                }
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

private struct GlassCardBacking: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    let cornerRadius: CGFloat

    var body: some View {
        let isDark = (colorScheme == .dark)
        let opacity: Double = {
            if isDark {
                return theme.basePalette == .noir ? 0.28 : 0.18
            }
            return theme.basePalette == .noir ? 0.12 : 0.06
        }()
        return RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.black.opacity(opacity))
    }
}

private extension View {
    @ViewBuilder
    func searchInputBehavior() -> some View {
        #if os(iOS)
        self
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #else
        self
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
        // Use the secure-friendly wallpaper on iOS so it renders correctly even when the
        // whole UI is hosted inside the secure screenshot-protection container.
        self.background(SecureGlassBackground())
        #else
        self
        #endif
    }
}

private extension View {
    @ViewBuilder
    func paneNavigationTitle(_ title: String) -> some View {
        #if os(iOS)
        navigationTitle(title)
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

#if os(macOS)
private struct WindowTitleHider: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        TitleHiderView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? TitleHiderView)?.apply()
    }

    private final class TitleHiderView: NSView {
        private var observedWindow: NSWindow?
        private var windowObserver: NSObjectProtocol?
        private var titleObservation: NSKeyValueObservation?

        deinit {
            if let windowObserver {
                NotificationCenter.default.removeObserver(windowObserver)
            }
            titleObservation?.invalidate()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if observedWindow !== window {
                if let windowObserver {
                    NotificationCenter.default.removeObserver(windowObserver)
                    self.windowObserver = nil
                }
                titleObservation?.invalidate()
                titleObservation = nil
                observedWindow = window
                if let window {
                    windowObserver = NotificationCenter.default.addObserver(
                        forName: NSWindow.didBecomeKeyNotification,
                        object: window,
                        queue: .main
                    ) { [weak self] _ in
                        self?.apply()
                    }
                    titleObservation = window.observe(\.title, options: [.new]) { w, _ in
                        if w.title.isEmpty == false {
                            w.title = ""
                        }
                    }
                }
            }
            apply()
        }

        func apply() {
            guard let window else { return }
            window.titleVisibility = .hidden
            // Clean titlebar: traffic lights float over the app background with no extra bars.
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = true
            window.tabbingMode = .disallowed
            window.toolbar = nil
            if #available(macOS 11.0, *) {
                window.titlebarSeparatorStyle = .none
            }
            window.isOpaque = false
            window.backgroundColor = .clear
            window.title = ""

            // User preference: completely remove the macOS chrome in the traffic-light area.
            // Hiding the titlebar view eliminates the faint bar/shading that persists even with transparent titlebars.
            if let titlebarView = window.standardWindowButton(.closeButton)?.superview {
                titlebarView.isHidden = true
                titlebarView.alphaValue = 0
            }
            window.standardWindowButton(.closeButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true

            // SwiftUI sometimes re-applies the window title after the view attaches.
            // Re-assert a couple of times to keep the title text from flashing back.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.applyOnce() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.60) { [weak self] in self?.applyOnce() }
        }

        private func applyOnce() {
            guard let window else { return }
            window.titleVisibility = .hidden
            window.title = ""
        }
    }
}
#endif

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
        UIPasteboard.general.setItems(
            [[UTType.plainText.identifier: text]],
            options: [
                .localOnly: true,
                .expirationDate: Date().addingTimeInterval(60)
            ]
        )
        #elseif os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            if pasteboard.string(forType: .string) == text {
                pasteboard.clearContents()
            }
        }
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

private func readBoundedFile(_ url: URL, maxBytes: Int) throws -> Data {
    let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
    guard values.isRegularFile == true,
          let fileSize = values.fileSize,
          fileSize >= 0,
          fileSize <= maxBytes else {
        throw CocoaError(.fileReadTooLarge)
    }
    let data = try Data(contentsOf: url, options: .mappedIfSafe)
    guard data.count <= maxBytes else {
        throw CocoaError(.fileReadTooLarge)
    }
    return data
}
