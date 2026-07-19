import CryptoKit
import Combine
import Foundation
import LocalAuthentication
import NoctweaveCore

enum ClientBootState: Equatable {
    case loading
    case ready
    case failed(String)
}

private enum NoctweaveClientError: Error, LocalizedError {
    case invalidPairingLink
    case invalidGroupIdentifier
    case pendingAdmissionMissing
    case pairingExpired
    case relayRejected(String)
    case missingPairingFrame(UInt64)
    case unavailable

    var errorDescription: String? {
        switch self {
        case .invalidPairingLink:
            return "The one-use pairing invitation is invalid."
        case .invalidGroupIdentifier:
            return "The group identifier must be a UUID."
        case .pendingAdmissionMissing:
            return "The saved one-use group admission is unavailable."
        case .pairingExpired:
            return "The one-use pairing invitation expired. Start a fresh exchange."
        case .relayRejected(let message):
            return message
        case .missingPairingFrame(let sequence):
            return "The pairing exchange is missing transport frame \(sequence)."
        case .unavailable:
            return "The encrypted client state is not ready."
        }
    }
}

private struct NoctweavePairingLinkV1: Codable {
    static let prefix = "noctweave-pair-v1:"
    static let maximumCharacters = 96 * 1_024

    let version: Int
    let relay: RelayEndpoint
    let invitation: ContactPairingInvitationV2

    init(relay: RelayEndpoint, invitation: ContactPairingInvitationV2) {
        version = 1
        self.relay = relay
        self.invitation = invitation
    }

    func encoded() throws -> String {
        let data = try NoctweaveCoder.encode(self, sortedKeys: true)
        let value = Self.prefix + data.base64EncodedString()
        guard value.count <= Self.maximumCharacters else {
            throw NoctweaveClientError.invalidPairingLink
        }
        return value
    }

    static func decode(_ value: String) throws -> NoctweavePairingLinkV1 {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.hasPrefix(prefix),
              normalized.count <= maximumCharacters,
              let data = Data(base64Encoded: String(normalized.dropFirst(prefix.count))) else {
            throw NoctweaveClientError.invalidPairingLink
        }
        let decoded = try NoctweaveCoder.decode(NoctweavePairingLinkV1.self, from: data)
        guard decoded.version == 1,
              decoded.relay.isStructurallyValid,
              decoded.invitation.isStructurallyValid else {
            throw NoctweaveClientError.invalidPairingLink
        }
        return decoded
    }
}

@MainActor
final class ClientViewModel: ObservableObject {
    @Published private(set) var bootState: ClientBootState = .loading
    @Published private(set) var state: ClientState?
    @Published var selectedRelationshipID: UUID?
    @Published var selectedGroupID: UUID?
    @Published var draftMessage = ""
    @Published var groupDraftMessage = ""
    @Published private(set) var isWorking = false
    @Published private(set) var statusMessage = "Opening encrypted local state…"
    @Published private(set) var lastError: String?

    @Published private(set) var isPairing = false
    @Published private(set) var pairingLink: String?
    @Published private(set) var pairingStatus = ""

    @Published private(set) var groupExchangeLink: String?
    @Published private(set) var groupExchangeStatus = ""
    @Published private(set) var groupMaintenanceStatus: [UUID: String] = [:]

    @Published private(set) var isLocked = false
    @Published private(set) var biometricStepPassed = false
    @Published private(set) var lockError: String?

    private let stateStore: ClientStateStore
    private var client: HeadlessMessagingClient?
    private var pairingTask: Task<Void, Never>?
    private var failedPINAttempts = 0
    private var pinLockedUntil: Date?

    init() {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("NoctweaveClient", isDirectory: true)
        let isUITest = ProcessInfo.processInfo.arguments.contains("UI_TESTING")
        let stateURL = isUITest
            ? FileManager.default.temporaryDirectory
                .appendingPathComponent("NoctweaveCleanV1UITests", isDirectory: true)
                .appendingPathComponent("client-state-v1.nwstate")
            : support.appendingPathComponent("client-state-v1.nwstate")
        if isUITest {
            try? FileManager.default.removeItem(at: stateURL.deletingLastPathComponent())
            stateStore = ClientStateStore(
                fileURL: stateURL,
                protection: .encrypted,
                rollbackAnchorStore: VolatileClientStateRollbackAnchorStore()
            )
        } else {
            stateStore = ClientStateStore(fileURL: stateURL)
        }
        Task { await open() }
    }

    var activePersona: PersonaProfileV1? {
        guard let state else { return nil }
        return state.personas.first { $0.id == state.activePersonaID }
    }

    var relationships: [PairwiseRelationshipV2] {
        activePersona?.relationships.sorted {
            let lhsDate = $0.events.last?.createdAt ?? $0.createdAt
            let rhsDate = $1.events.last?.createdAt ?? $1.createdAt
            if lhsDate == rhsDate { return $0.id.uuidString < $1.id.uuidString }
            return lhsDate > rhsDate
        } ?? []
    }

    var groups: [GroupRuntimeRecord] {
        activePersona?.groupRuntimes.sorted {
            $0.groupId.uuidString < $1.groupId.uuidString
        } ?? []
    }

    var pendingGroupAdmissions: [PendingGroupAdmissionV2] {
        activePersona?.pendingGroupAdmissions.sorted {
            if $0.createdAt == $1.createdAt { return $0.id.uuidString < $1.id.uuidString }
            return $0.createdAt < $1.createdAt
        } ?? []
    }

    var selectedRelationship: PairwiseRelationshipV2? {
        guard let selectedRelationshipID else { return nil }
        return relationships.first { $0.id == selectedRelationshipID }
    }

    var selectedGroup: GroupRuntimeRecord? {
        guard let selectedGroupID else { return nil }
        return groups.first { $0.groupId == selectedGroupID }
    }

    var selectedEvents: [ConversationEvent] {
        selectedRelationship?.events.sorted {
            if $0.createdAt == $1.createdAt {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.createdAt < $1.createdAt
        } ?? []
    }

    var selectedGroupEvents: [GroupConversationEventV2] {
        selectedGroup?.events ?? []
    }

    var appLockMode: AppLockMode {
        state?.appLock.mode ?? .off
    }

    var appLockMessage: String {
        let value = state?.appLock.lockScreenMessage
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "Your encrypted conversations are locked." : value
    }

    func open() async {
        bootState = .loading
        do {
            let opened = try await HeadlessMessagingClient.open(
                stateStore: stateStore,
                displayName: "Local Persona"
            )
            client = opened
            try await refresh()
            isLocked = appLockMode != .off
            statusMessage = "Encrypted local state is ready."
            bootState = .ready
            if !isLocked { syncAll() }
        } catch {
            let message = describe(error)
            lastError = message
            bootState = .failed(message)
        }
    }

    func refresh() async throws {
        guard let client else { throw NoctweaveClientError.unavailable }
        let snapshot = await client.snapshot()
        state = snapshot
        #if os(iOS)
        try OpaqueRoutePrefetchBridge.update(from: snapshot)
        #endif
        let available = snapshot.personas
            .first { $0.id == snapshot.activePersonaID }?
            .relationships ?? []
        let availableGroups = snapshot.personas
            .first { $0.id == snapshot.activePersonaID }?
            .groupRuntimes ?? []
        if let selectedRelationshipID,
           !available.contains(where: { $0.id == selectedRelationshipID }) {
            self.selectedRelationshipID = nil
        }
        if self.selectedRelationshipID == nil {
            if selectedGroupID == nil {
                self.selectedRelationshipID = available.first?.id
            }
        }
        if let selectedGroupID,
           !availableGroups.contains(where: { $0.groupId == selectedGroupID }) {
            self.selectedGroupID = nil
        }
    }

    func sendDraft() {
        let text = draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let relationshipID = selectedRelationshipID else { return }
        draftMessage = ""
        runOperation(label: "Sending…") { client in
            _ = try await client.sendText(text, relationshipID: relationshipID)
            self.statusMessage = "Message persisted and submitted through opaque routes."
        }
    }

    func sendGroupDraft() {
        let text = groupDraftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let groupID = selectedGroupID else { return }
        groupDraftMessage = ""
        runOperation(label: "Sending group event…") { client in
            let result = try await client.sendGroupText(groupID: groupID, text: text)
            self.statusMessage = result.complete
                ? "Group event persisted and submitted through group-scoped opaque routes."
                : "Group event is durable and queued for route retry (\(result.disposition.rawValue))."
        }
    }

    func createGroup(groupIDText: String, relayText: String) {
        runOperation(label: "Creating group-scoped runtime…") { client in
            guard let groupID = UUID(
                uuidString: groupIDText.trimmingCharacters(in: .whitespacesAndNewlines)
            ) else {
                throw NoctweaveClientError.invalidGroupIdentifier
            }
            let relay = try RelayEndpointParser.parse(relayText)
            let created = try await client.createGroup(groupID: groupID, relay: relay)
            self.selectedRelationshipID = nil
            self.selectedGroupID = created.groupID
            self.statusMessage = "Created group \(created.groupID.uuidString.prefix(8)) with a fresh group-only credential and receive route."
        }
    }

    func syncAll() {
        guard bootState == .ready, !isLocked else { return }
        runOperation(label: "Maintaining routes and synchronizing…") { client in
            var errors: [Error] = []
            do {
                _ = try await client.maintainAllRelationships()
            } catch {
                errors.append(error)
            }

            let persona = await client.activePersona()
            let relationshipIDs = persona.relationships.map(\.id)
            let groupIDs = persona.groupRuntimes.map(\.groupId)
            var received = 0
            for relationshipID in relationshipIDs {
                do {
                    for _ in 0..<8 {
                        let batches = try await client.sync(relationshipID: relationshipID)
                        received += batches.reduce(0) { $0 + $1.receivedEvents.count }
                        if !batches.contains(where: \.hasMore) { break }
                    }
                } catch {
                    errors.append(error)
                }
            }

            for groupID in groupIDs {
                do {
                    let report = try await client.maintainGroup(groupID: groupID)
                    self.groupMaintenanceStatus[groupID] = report.requiresFollowUp
                        ? "Durable group transport still has queued retries."
                        : "Group routes and pending transport are healthy."
                } catch {
                    errors.append(error)
                    self.groupMaintenanceStatus[groupID] = "Maintenance unavailable: \(self.describe(error))"
                }
                do {
                    for _ in 0..<8 {
                        let batches = try await client.syncGroup(groupID: groupID)
                        received += batches.reduce(0) { $0 + $1.receivedEvents.count }
                        if !batches.contains(where: \.hasMore) { break }
                    }
                } catch {
                    errors.append(error)
                }
            }

            if let first = errors.first {
                self.statusMessage = "Sync completed with partial relay availability: \(self.describe(first))"
            } else {
                self.statusMessage = "Sync complete. \(received) new event\(received == 1 ? "" : "s")."
            }
        }
    }

    func maintainRelationships() {
        runOperation(label: "Maintaining relationship routes…") { client in
            let reports = try await client.maintainAllRelationships()
            let followUps = reports.filter(\.requiresFollowUp).count
            self.statusMessage = followUps == 0
                ? "All relationship routes are healthy."
                : "\(followUps) relationship\(followUps == 1 ? "" : "s") need another maintenance pass."
        }
    }

    func maintainAllTransport() {
        runOperation(label: "Maintaining relationship and group routes…") { client in
            var errors: [Error] = []
            let relationshipReports: [HeadlessRelationshipMaintenanceReportV2]
            do {
                relationshipReports = try await client.maintainAllRelationships()
            } catch {
                relationshipReports = []
                errors.append(error)
            }
            let groupIDs = (await client.activePersona()).groupRuntimes.map(\.groupId)
            var groupFollowUps = 0
            for groupID in groupIDs {
                do {
                    let report = try await client.maintainGroup(groupID: groupID)
                    if report.requiresFollowUp { groupFollowUps += 1 }
                    self.groupMaintenanceStatus[groupID] = report.requiresFollowUp
                        ? "Durable group transport still has queued retries."
                        : "Group routes and pending transport are healthy."
                } catch {
                    errors.append(error)
                    self.groupMaintenanceStatus[groupID] = "Maintenance unavailable: \(self.describe(error))"
                }
            }
            let relationshipFollowUps = relationshipReports.filter(\.requiresFollowUp).count
            let totalFollowUps = relationshipFollowUps + groupFollowUps
            if let first = errors.first {
                self.statusMessage = "Maintenance completed with partial relay availability: \(self.describe(first))"
            } else if totalFollowUps == 0 {
                self.statusMessage = "All relationship and group routes are healthy."
            } else {
                self.statusMessage = "\(totalFollowUps) transport scope\(totalFollowUps == 1 ? "" : "s") need another maintenance pass."
            }
        }
    }

    func maintainSelectedGroup() {
        guard let groupID = selectedGroupID else { return }
        runOperation(label: "Maintaining group routes…") { client in
            let report = try await client.maintainGroup(groupID: groupID)
            let value = report.requiresFollowUp
                ? "Durable group transport still has queued retries."
                : "Group routes and pending transport are healthy."
            self.groupMaintenanceStatus[groupID] = value
            self.statusMessage = value
        }
    }

    func prepareGroupJoinRequest(groupIDText: String, relayText: String) {
        groupExchangeLink = nil
        groupExchangeStatus = "Preparing a fresh group-only credential and route…"
        runOperation(label: "Preparing one-use group admission…") { client in
            guard let groupID = UUID(
                uuidString: groupIDText.trimmingCharacters(in: .whitespacesAndNewlines)
            ) else {
                throw NoctweaveClientError.invalidGroupIdentifier
            }
            let relay = try RelayEndpointParser.parse(relayText)
            let bindingDigest = Self.freshGroupInvitationBinding(groupID: groupID)
            let prepared = try await client.prepareGroupAdmission(
                groupID: groupID,
                invitationBindingDigest: bindingDigest,
                relay: relay,
                expiresAt: Date().addingTimeInterval(12 * 60 * 60)
            )
            _ = try await client.resumeGroupAdmissionRoute(admissionID: prepared.admissionID)
            let pending = try Self.pendingAdmission(
                prepared.admissionID,
                in: await client.activePersona()
            )
            let request = try Self.groupAdmissionRequest(from: pending)
            self.groupExchangeLink = try request.encoded()
            self.groupExchangeStatus = "Admission \(prepared.admissionID.uuidString) is saved. Share this one-use request only through an authenticated encrypted channel."
        }
    }

    func resumeGroupJoinRequest(admissionID: UUID) {
        groupExchangeLink = nil
        groupExchangeStatus = "Resuming the exact saved route request…"
        runOperation(label: "Resuming saved group admission…") { client in
            _ = try await client.resumeGroupAdmissionRoute(admissionID: admissionID)
            let pending = try Self.pendingAdmission(
                admissionID,
                in: await client.activePersona()
            )
            self.groupExchangeLink = try Self.groupAdmissionRequest(from: pending).encoded()
            self.groupExchangeStatus = "Resumed saved admission \(admissionID.uuidString)."
        }
    }

    func prepareGroupMemberResponse(requestLink: String) {
        groupExchangeLink = nil
        groupExchangeStatus = "Verifying the admission and preparing a signed group epoch…"
        runOperation(label: "Verifying group admission and preparing epoch…") { client in
            let request = try NoctweaveGroupAdmissionRequestLinkV1.decode(requestLink)
            let prepared = try await client.prepareGroupMemberAddition(
                groupID: request.groupID,
                admission: request.admission,
                initialRouteSet: request.initialRouteSet,
                idempotencyKey: try request.requestDigest
            )
            let response = try NoctweaveGroupAdmissionResponseLinkV1(
                request: request,
                prepared: prepared
            )
            self.groupExchangeLink = try response.encoded()
            do {
                let report = try await client.maintainGroup(groupID: request.groupID)
                self.groupMaintenanceStatus[request.groupID] = report.requiresFollowUp
                    ? "Member epoch is durable; relay publication still needs retry."
                    : "Member epoch and group transport are published."
                self.groupExchangeStatus = report.requiresFollowUp
                    ? "Welcome package is ready. Share it through the same authenticated encrypted channel; run maintenance again for queued relay publication."
                    : "Welcome package is ready. Share it through the same authenticated encrypted channel."
            } catch {
                self.groupMaintenanceStatus[request.groupID] = "Member epoch is durable; maintenance unavailable: \(self.describe(error))"
                self.groupExchangeStatus = "Welcome package is ready; relay publication needs a later maintenance pass."
            }
        }
    }

    func acceptGroupMemberResponse(responseLink: String) {
        groupExchangeLink = nil
        groupExchangeStatus = "Verifying the response against the saved one-use admission…"
        runOperation(label: "Verifying one-use group welcome…") { client in
            let response = try NoctweaveGroupAdmissionResponseLinkV1.decode(responseLink)
            let pending = try Self.pendingAdmission(
                response.admissionID,
                in: await client.activePersona()
            )
            let request = try Self.groupAdmissionRequest(from: pending)
            guard response.matches(request) else {
                throw NoctweaveGroupExchangeLinkError.requestMismatch
            }
            _ = try await client.pinGroupJoinAnchor(
                admissionID: response.admissionID,
                anchor: response.anchor,
                invitationBindingDigest: request.invitationBindingDigest
            )
            for announcement in response.existingMemberRouteAnnouncements {
                _ = try await client.acceptGroupAdmissionRouteAnnouncement(
                    admissionID: response.admissionID,
                    announcement: announcement
                )
            }
            _ = try await client.acceptGroupAdmissionTransition(
                admissionID: response.admissionID,
                transition: response.transition
            )
            let progress = try await client.acceptGroupAdmissionWelcome(
                admissionID: response.admissionID,
                welcome: response.welcome
            )
            guard progress.completed else {
                throw NoctweaveGroupExchangeLinkError.invalidLink
            }
            self.selectedRelationshipID = nil
            self.selectedGroupID = response.groupID
            self.groupExchangeLink = nil
            self.groupExchangeStatus = "The one-use admission was consumed. This group now has an independent group-scoped runtime."
            self.statusMessage = "Joined group \(response.groupID.uuidString.prefix(8))."
        }
    }

    func clearGroupExchangeLink() {
        groupExchangeLink = nil
        groupExchangeStatus = ""
    }

    func burnPersona(replacementName: String = "Local Persona") {
        runOperation(label: "Burning local persona…") { client in
            _ = try await client.burnActivePersona(replacementDisplayName: replacementName)
            self.selectedRelationshipID = nil
            self.statusMessage = "The local persona was burned and replaced without continuity."
        }
    }

    func startOfferingPairing(relayText: String, pseudonym: String) {
        guard !isPairing else { return }
        isPairing = true
        pairingLink = nil
        pairingStatus = "Preparing fresh relationship authority and opaque route…"
        lastError = nil
        pairingTask = Task { [weak self] in
            await self?.runOffererPairing(relayText: relayText, pseudonym: pseudonym)
        }
    }

    func startAcceptingPairing(link: String, pseudonym: String) {
        guard !isPairing else { return }
        isPairing = true
        pairingLink = nil
        pairingStatus = "Opening the one-use encrypted rendezvous…"
        lastError = nil
        pairingTask = Task { [weak self] in
            await self?.runResponderPairing(link: link, pseudonym: pseudonym)
        }
    }

    func cancelPairing() {
        pairingTask?.cancel()
        pairingStatus = "Cancelling and removing the temporary relay lanes…"
    }

    func clearPairingLink() {
        pairingLink = nil
        pairingStatus = ""
    }

    func lockNow() {
        biometricStepPassed = false
        lockError = nil
        isLocked = true
    }

    func lockForBackgroundIfConfigured() {
        if appLockMode != .off { lockNow() }
    }

    func unlockWithBiometrics() async {
        lockError = nil
        if appLockMode == .off {
            isLocked = false
            return
        }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            lockError = "Biometric authentication is unavailable."
            return
        }
        do {
            let accepted = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: "Unlock encrypted Noctweave conversations"
            )
            guard accepted else {
                lockError = "Biometric authentication failed."
                return
            }
            if appLockMode == .biometricsAndPin {
                biometricStepPassed = true
            } else {
                isLocked = false
            }
        } catch {
            lockError = describe(error)
        }
    }

    func unlockWithPIN(_ value: String) {
        guard appLockMode == .pinOnly
                || (appLockMode == .biometricsAndPin && biometricStepPassed) else {
            lockError = "Complete biometric authentication first."
            return
        }
        if let pinLockedUntil, pinLockedUntil > Date() {
            lockError = "PIN entry is temporarily locked."
            return
        }
        guard let settings = state?.appLock,
              let salt = settings.pinSalt,
              let expected = settings.pinHash,
              matchesStructuredPIN(value, salt: salt, expected: expected) else {
            failedPINAttempts += 1
            if failedPINAttempts >= 5 {
                pinLockedUntil = Date().addingTimeInterval(30)
                failedPINAttempts = 0
                lockError = "Too many attempts. PIN entry is locked for 30 seconds."
            } else {
                lockError = "Incorrect PIN."
            }
            return
        }
        failedPINAttempts = 0
        pinLockedUntil = nil
        lockError = nil
        isLocked = false
    }

    func displayText(for event: ConversationEvent) -> String {
        if event.content.type == .text,
           let value = String(data: event.content.payload, encoding: .utf8) {
            return value
        }
        if let fallback = event.content.fallbackText, !fallback.isEmpty {
            return fallback
        }
        return "Unsupported content: \(event.content.type.canonicalName)"
    }

    func displayText(for event: GroupConversationEventV2) -> String {
        if event.content.type == .text,
           let value = String(data: event.content.payload, encoding: .utf8) {
            return value
        }
        if let fallback = event.content.fallbackText, !fallback.isEmpty {
            return fallback
        }
        return "Unsupported group content: \(event.content.type.canonicalName)"
    }

    func isOutgoing(_ event: ConversationEvent) -> Bool {
        event.authorEndpointHandle == selectedRelationship?.localEndpointHandle
    }

    func isOutgoing(_ event: GroupConversationEventV2) -> Bool {
        event.authorCredentialHandle == selectedGroup?.localCredential.credentialHandle
    }

    private static func pendingAdmission(
        _ admissionID: UUID,
        in persona: PersonaProfileV1
    ) throws -> PendingGroupAdmissionV2 {
        guard let pending = persona.pendingGroupAdmissions.first(where: { $0.id == admissionID })
        else {
            throw NoctweaveClientError.pendingAdmissionMissing
        }
        return pending
    }

    private static func groupAdmissionRequest(
        from pending: PendingGroupAdmissionV2
    ) throws -> NoctweaveGroupAdmissionRequestLinkV1 {
        guard let routeSet = pending.advertisedRouteSet else {
            throw NoctweaveClientError.pendingAdmissionMissing
        }
        return try NoctweaveGroupAdmissionRequestLinkV1(
            admissionID: pending.id,
            groupID: pending.groupID,
            invitationBindingDigest: pending.invitationBindingDigest,
            admission: pending.admission,
            initialRouteSet: routeSet
        )
    }

    private static func freshGroupInvitationBinding(groupID: UUID) -> Data {
        var material = Data("org.noctweave.group-invitation-binding/v1\0".utf8)
        material.append(Data(groupID.uuidString.lowercased().utf8))
        SymmetricKey(size: .bits256).withUnsafeBytes { material.append(contentsOf: $0) }
        return Data(SHA256.hash(data: material))
    }

    private func runOperation(
        label: String,
        _ operation: @escaping (HeadlessMessagingClient) async throws -> Void
    ) {
        guard !isWorking else { return }
        isWorking = true
        statusMessage = label
        lastError = nil
        Task {
            defer { isWorking = false }
            do {
                guard let client else { throw NoctweaveClientError.unavailable }
                try await operation(client)
                try await refresh()
            } catch {
                lastError = describe(error)
                statusMessage = "The operation did not complete."
            }
        }
    }

    private func runOffererPairing(relayText: String, pseudonym: String) async {
        var cleanup: (RelayClient, RendezvousRelayAdapterV2)?
        defer {
            isPairing = false
            pairingTask = nil
        }
        do {
            guard let client else { throw NoctweaveClientError.unavailable }
            let endpoint = try RelayEndpointParser.parse(relayText)
            let localPseudonym = try validatedPseudonym(pseudonym)
            let now = Date()
            let pendingParticipant = try await client.prepareContactParticipant(
                relay: endpoint,
                relationshipPseudonym: localPseudonym,
                createdAt: now
            )
            let participant = try await client.activateContactParticipant(pendingParticipant)
            var offer = try await client.makeContactPairingInvitation(
                createdAt: now,
                expiresAt: now.addingTimeInterval(10 * 60)
            )
            let adapter = try RendezvousRelayAdapterV2(offer: offer.invitation.offer)
            let relay = RelayClient(endpoint: endpoint)
            cleanup = (relay, adapter)

            try requireEmpty(
                await relay.send(.registerRendezvousTransportV2(adapter.registrationRequest))
            )
            pairingLink = try NoctweavePairingLinkV1(
                relay: endpoint,
                invitation: offer.invitation
            ).encoded()
            pairingStatus = "Share this one-use invitation privately. Waiting for the responder…"

            let inbound = try await waitForFrames(
                relay: relay,
                adapter: adapter,
                receivingAs: .offerer,
                afterSequence: 0,
                throughSequence: 2,
                deadline: offer.invitation.offer.expiresAt
            )
            let openFrame = try frame(sequence: 1, in: inbound)
            let acceptanceFrame = try frame(sequence: 2, in: inbound)
            guard case .open(let openRequest) = try adapter.open(
                openFrame,
                direction: .responderToOfferer
            ), case .sessionFrame(let acceptance) = try adapter.open(
                acceptanceFrame,
                direction: .responderToOfferer
            ) else {
                throw NoctweaveClientError.invalidPairingLink
            }

            var ledger = RendezvousRedemptionLedgerV2()
            let started = try ContactPairingOffererFlowV2.begin(
                pendingOffer: &offer.pending,
                invitation: offer.invitation,
                participant: participant,
                openRequest: openRequest,
                acceptanceFrame: acceptance,
                ledger: &ledger,
                at: Date()
            )
            var flow = started.flow
            try requireEmpty(await relay.send(.appendRendezvousTransportV2(
                try adapter.sealSessionFrame(started.offerFrame, transportSequence: 1)
            )))
            pairingStatus = "Introductions exchanged. Verifying the relationship transcript…"

            let confirmations = try await waitForFrames(
                relay: relay,
                adapter: adapter,
                receivingAs: .offerer,
                afterSequence: 2,
                throughSequence: 3,
                deadline: offer.invitation.offer.expiresAt
            )
            let confirmationOuter = try frame(sequence: 3, in: confirmations)
            guard case .sessionFrame(let confirmation) = try adapter.open(
                confirmationOuter,
                direction: .responderToOfferer
            ) else {
                throw NoctweaveClientError.invalidPairingLink
            }
            let completion = try flow.receiveConfirmation(confirmation, at: Date())
            let scope = await client.mintActivePersonaScopeToken()
            try await client.addRelationship(
                completion.relationship,
                consent: .accepted,
                personaScope: scope
            )
            try requireEmpty(await relay.send(.appendRendezvousTransportV2(
                try adapter.sealSessionFrame(
                    completion.confirmationFrame,
                    transportSequence: 2
                )
            )))
            await deleteTemporaryLanes(relay: relay, adapter: adapter)
            cleanup = nil
            pairingLink = nil
            pairingStatus = "A fresh unlinkable relationship is ready."
            try await refresh()
        } catch {
            if let cleanup {
                await deleteTemporaryLanes(relay: cleanup.0, adapter: cleanup.1)
            }
            pairingLink = nil
            if error is CancellationError {
                pairingStatus = "Pairing cancelled. Start with a fresh invitation."
            } else {
                lastError = describe(error)
                pairingStatus = "Pairing did not complete. Start with a fresh invitation."
            }
        }
    }

    private func runResponderPairing(link: String, pseudonym: String) async {
        var cleanup: (RelayClient, RendezvousRelayAdapterV2)?
        defer {
            isPairing = false
            pairingTask = nil
        }
        do {
            guard let client else { throw NoctweaveClientError.unavailable }
            let shared = try NoctweavePairingLinkV1.decode(link)
            guard Date() < shared.invitation.offer.expiresAt else {
                throw NoctweaveClientError.pairingExpired
            }
            let localPseudonym = try validatedPseudonym(pseudonym)
            let adapter = try RendezvousRelayAdapterV2(offer: shared.invitation.offer)
            let relay = RelayClient(endpoint: shared.relay)
            cleanup = (relay, adapter)
            try requireEmpty(
                await relay.send(.registerRendezvousTransportV2(adapter.registrationRequest))
            )

            let pendingParticipant = try await client.prepareContactParticipant(
                relay: shared.relay,
                relationshipPseudonym: localPseudonym
            )
            let participant = try await client.activateContactParticipant(pendingParticipant)
            let started = try ContactPairingResponderFlowV2.begin(
                invitation: shared.invitation,
                participant: participant,
                at: Date()
            )
            var flow = started.flow
            try requireEmpty(await relay.send(.appendRendezvousTransportV2(
                try adapter.sealOpen(started.openRequest)
            )))
            try requireEmpty(await relay.send(.appendRendezvousTransportV2(
                try adapter.sealSessionFrame(started.acceptanceFrame, transportSequence: 2)
            )))
            pairingStatus = "Waiting for the offerer’s encrypted relationship introduction…"

            let offers = try await waitForFrames(
                relay: relay,
                adapter: adapter,
                receivingAs: .responder,
                afterSequence: 0,
                throughSequence: 1,
                deadline: shared.invitation.offer.expiresAt
            )
            let offerOuter = try frame(sequence: 1, in: offers)
            guard case .sessionFrame(let contactOffer) = try adapter.open(
                offerOuter,
                direction: .offererToResponder
            ) else {
                throw NoctweaveClientError.invalidPairingLink
            }
            let confirmation = try flow.receiveOffer(contactOffer, at: Date())
            try requireEmpty(await relay.send(.appendRendezvousTransportV2(
                try adapter.sealSessionFrame(confirmation, transportSequence: 3)
            )))
            pairingStatus = "Relationship transcript verified. Waiting for final confirmation…"

            let finals = try await waitForFrames(
                relay: relay,
                adapter: adapter,
                receivingAs: .responder,
                afterSequence: 1,
                throughSequence: 2,
                deadline: shared.invitation.offer.expiresAt
            )
            let finalOuter = try frame(sequence: 2, in: finals)
            guard case .sessionFrame(let finalConfirmation) = try adapter.open(
                finalOuter,
                direction: .offererToResponder
            ) else {
                throw NoctweaveClientError.invalidPairingLink
            }
            let relationship = try flow.receiveConfirmation(finalConfirmation, at: Date())
            let scope = await client.mintActivePersonaScopeToken()
            try await client.addRelationship(
                relationship,
                consent: .accepted,
                personaScope: scope
            )
            await deleteTemporaryLanes(relay: relay, adapter: adapter)
            cleanup = nil
            pairingStatus = "A fresh unlinkable relationship is ready."
            try await refresh()
        } catch {
            if let cleanup {
                await deleteTemporaryLanes(relay: cleanup.0, adapter: cleanup.1)
            }
            if error is CancellationError {
                pairingStatus = "Pairing cancelled. Start with a fresh invitation."
            } else {
                lastError = describe(error)
                pairingStatus = "Pairing did not complete. Start with a fresh invitation."
            }
        }
    }

    private func waitForFrames(
        relay: RelayClient,
        adapter: RendezvousRelayAdapterV2,
        receivingAs role: RendezvousRoleV2,
        afterSequence: UInt64,
        throughSequence: UInt64,
        deadline: Date
    ) async throws -> [RendezvousRelayCiphertextFrameV2] {
        while Date() < deadline {
            try Task.checkCancellation()
            let response = try await relay.send(.syncRendezvousTransportV2(
                adapter.syncRequest(receivingAs: role, afterSequence: afterSequence)
            ))
            guard response.status == .success,
                  case .rendezvousSync(let batch)? = response.successBody else {
                throw NoctweaveClientError.relayRejected(
                    response.error?.message ?? "The relay rejected the pairing sync."
                )
            }
            let frames = batch.frames.sorted { $0.sequence < $1.sequence }
            if frames.contains(where: { $0.sequence == throughSequence }) {
                return frames
            }
            try await Task.sleep(nanoseconds: 350_000_000)
        }
        throw NoctweaveClientError.pairingExpired
    }

    private func frame(
        sequence: UInt64,
        in frames: [RendezvousRelayCiphertextFrameV2]
    ) throws -> RendezvousRelayCiphertextFrameV2 {
        guard let value = frames.first(where: { $0.sequence == sequence }) else {
            throw NoctweaveClientError.missingPairingFrame(sequence)
        }
        return value
    }

    private func requireEmpty(_ response: RelayResponse) throws {
        guard response.status == .success, case .empty? = response.successBody else {
            throw NoctweaveClientError.relayRejected(
                response.error?.message ?? "The relay rejected the pairing request."
            )
        }
    }

    private func deleteTemporaryLanes(
        relay: RelayClient,
        adapter: RendezvousRelayAdapterV2
    ) async {
        for request in adapter.deletionRequests() {
            _ = try? await relay.send(.deleteRendezvousTransportV2(request))
        }
    }

    private func validatedPseudonym(_ value: String) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.utf8.count <= 512 else {
            throw NoctweaveClientError.invalidPairingLink
        }
        return normalized
    }

    private func matchesStructuredPIN(
        _ pin: String,
        salt: Data,
        expected: Data
    ) -> Bool {
        let digits = pin.filter(\.isNumber)
        guard digits.count == 6,
              expected.count == 41,
              expected.prefix(5) == Data("NPIN2".utf8) else {
            return false
        }
        var rounds: UInt32 = 0
        for byte in expected[5..<9] {
            rounds = (rounds << 8) | UInt32(byte)
        }
        guard (10_000...500_000).contains(Int(rounds)) else { return false }
        let key = SymmetricKey(data: Data(digits.utf8))
        var block = Data(HMAC<SHA256>.authenticationCode(for: salt, using: key))
        var digest = block
        if rounds > 1 {
            for _ in 2...rounds {
                block = Data(HMAC<SHA256>.authenticationCode(for: block, using: key))
                for index in digest.indices { digest[index] ^= block[index] }
            }
        }
        let stored = Data(expected.suffix(32))
        guard digest.count == stored.count else { return false }
        var difference: UInt8 = 0
        for index in digest.indices { difference |= digest[index] ^ stored[index] }
        return difference == 0
    }

    private func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           !description.isEmpty {
            return description
        }
        return String(describing: error)
    }
}
