import CryptoKit
import Foundation
@_spi(Testing) import NoctweaveCore

/// Each action has a separately scoped, rollback-anchored staging store. A
/// committed staging state is the durable intent to finish replacement; it is
/// checked before the ordinary state is opened, including after a crash.
@MainActor
struct ClientStorageSession {
    let stateURL: URL
    let attachmentsURL: URL
    let scope: String
    let usesFixtureKeys: Bool
    let usesPlaintextFixture: Bool
    var clearsSupportDirectory = false

    var groupNameStore: ClientGroupNameStore {
        ClientGroupNameStore(stateURL: stateURL, scope: scope)
    }

    func stateStore(action: AppLockDuressAction? = nil) -> ClientStateStore {
        let url = action.map { stateURL.deletingLastPathComponent().appendingPathComponent("replacement-\($0.rawValue).nwstate") } ?? stateURL
        let identifier = scope + (action.map { ".replacement.\($0.rawValue)" } ?? "")
        if usesPlaintextFixture { return ClientStateStore(fileURL: url, protection: .insecurePlaintextForTesting) }
        #if DEBUG
        if usesFixtureKeys {
            return ClientStateStore(fileURL: url, encryptionKey: SymmetricKey(data: Data(repeating: 0x4E, count: 32)),
                rollbackAnchorStore: UITestFileRollbackAnchorStore(fileURL: action == nil
                    ? url.deletingLastPathComponent().appendingPathComponent("rollback-anchor-v1.json")
                    : url.appendingPathExtension("anchor")), storageScopeIdentifier: identifier)
        }
        #endif
        return ClientStateStore(fileURL: url, storageScopeIdentifier: identifier, keyProvider: SecureStorageKeyProvider())
    }

    func attachments(action: AppLockDuressAction? = nil) -> ClientAttachmentStore {
        ClientAttachmentStore(directory: action.map { attachmentsURL.appendingPathExtension("replacement-\($0.rawValue)") } ?? attachmentsURL,
            storageScopeIdentifier: scope + (action.map { ".replacement.\($0.rawValue)" } ?? ""),
            encryptionKey: usesFixtureKeys ? SymmetricKey(data: Data(repeating: 0x41, count: 32)) : nil,
            keyProvider: SecureStorageKeyProvider())
    }
}

/// Explicit full reset has its own durable intent, independent of duress plans.
/// It is reconciled before any saved session or replacement vault is opened.
@MainActor
struct ClientFullReset {
    let storage: ClientStorageSession
    private var markerURL: URL { storage.stateURL.appendingPathExtension("purge-pending-v1") }
    var isPending: Bool { FileManager.default.fileExists(atPath: markerURL.path) }

    func begin() throws {
        try FileManager.default.createDirectory(at: markerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SecureRegularFileIO.writePrivate(Data(), to: markerURL, maximumBytes: 0, allowEmpty: true)
    }

    func complete(clearSideEffects: () throws -> Void) async throws {
        var failure: Error?
        for action in [Optional<AppLockDuressAction>.none] + AppLockDuressAction.allCases.map({ Optional($0) }) {
            let store = storage.stateStore(action: action)
            do {
                if storage.usesPlaintextFixture { try await store.eraseAllLocalState() }
                else { try await store.destroyLocalEncryptionMaterial(preservingCiphertext: false) }
            } catch { failure = error }
            let attachments = storage.attachments(action: action)
            do { try attachments.destroyEncryptionMaterial() } catch { failure = error }
            do { try attachments.finishKeyDestruction(preservingCiphertext: false) } catch { failure = error }
        }
        if storage.clearsSupportDirectory {
            do {
                for file in try FileManager.default.contentsOfDirectory(at: storage.stateURL.deletingLastPathComponent(), includingPropertiesForKeys: nil)
                    where file.standardizedFileURL != markerURL.standardizedFileURL {
                    try FileManager.default.removeItem(at: file)
                }
            } catch { failure = error }
        }
        do { try clearSideEffects() } catch { failure = error }
        if let failure { throw failure }
        if isPending { try FileManager.default.removeItem(at: markerURL) }
    }
}

@MainActor
final class ClientDuressTransition {
    private let storage: ClientStorageSession
    // An authenticated manifest shares the separately encrypted staging vault.
    // Its UUID is reserved only inside that vault, never in the active store.
    private static let manifestID = UUID(uuidString: "368B6654-E7CD-4C83-959C-23287180B13F")!
    private struct Manifest: Codable {
        let attachmentIDs: Set<UUID>
        let groupNames: [String: String]
    }
    init(storage: ClientStorageSession) { self.storage = storage }

    func pending() async throws -> (AppLockDuressAction, ClientState)? {
        guard !storage.usesPlaintextFixture else { return nil }
        var found: (AppLockDuressAction, ClientState)?
        for action in AppLockDuressAction.allCases {
            let journal = storage.stateStore(action: action)
            if let state = try await journal.load() {
                guard found == nil, state.appLock.mode == .pinOnly,
                      state.appLock.duressPlans.isEmpty,
                      state.appLock.pinHash.map({ AppLockPasswordV1.isRecord($0) || AppLockPINV2.isRecord($0) }) == true else {
                    throw ClientStateStoreError.storageUnavailable
                }
                found = (action, state)
            }
        }
        return found
    }

    func clearInactiveStaging() async throws {
        guard !storage.usesPlaintextFixture else { return }
        for action in AppLockDuressAction.allCases {
            let journal = storage.stateStore(action: action)
            guard try await journal.load() == nil else { continue }
            // Inactive journals can have leftovers after a crash before intent
            // commit or after finalization. They must not retain an older decoy.
            let attachments = storage.attachments(action: action)
            try attachments.eraseAllLocalAttachments()
            try attachments.destroyEncryptionMaterial()
            try await journal.eraseAllLocalState()
            try await journal.destroyLocalEncryptionMaterial(preservingCiphertext: false)
        }
    }

    func stage(_ replacement: ClientState, action: AppLockDuressAction,
               sourceAttachments: ClientAttachmentStore, groupNames: [String: String]) async throws {
        guard !storage.usesPlaintextFixture, try await pending() == nil else {
            throw ClientStateStoreError.storageUnavailable
        }
        try await clearInactiveStaging()
        let staged = storage.attachments(action: action)
        try staged.eraseAllLocalAttachments()
        var copied = Set<UUID>()
        guard !replacement.referencedLocalAttachmentIDs.contains(Self.manifestID) else { throw ClientStateStoreError.storageUnavailable }
        for id in replacement.referencedLocalAttachmentIDs {
            guard let name = sourceAttachments.existingFileName(attachmentId: id) else { continue }
            var data = try sourceAttachments.loadSanitizedAttachment(fileName: name)
            defer { data.resetBytes(in: data.startIndex..<data.endIndex) }
            _ = try staged.saveSanitizedAttachment(data, attachmentId: id)
            copied.insert(id)
        }
        let groupIDs = Set(replacement.personas.flatMap { $0.groupRuntimes.map { $0.groupId.uuidString.lowercased() } })
        let manifest = Manifest(attachmentIDs: copied, groupNames: groupNames.filter { groupIDs.contains($0.key) })
        _ = try staged.saveSanitizedAttachment(try JSONEncoder().encode(manifest), attachmentId: Self.manifestID)
        // Save last: nothing destructive happens until all retained material and
        // the replacement password are durably encrypted and authenticated.
        try await storage.stateStore(action: action).save(replacement, replacing: nil)
    }

    func complete(_ replacement: ClientState, action: AppLockDuressAction,
                  oldState: ClientStateStore, oldAttachments: ClientAttachmentStore,
                  clearSideEffects: () throws -> Void) async throws {
        let staged = storage.attachments(action: action)
        let manifestName = "\(Self.manifestID.uuidString).bin"
        let manifest = try JSONDecoder().decode(Manifest.self, from: staged.loadSanitizedAttachment(fileName: manifestName))
        guard manifest.attachmentIDs.isSubset(of: replacement.referencedLocalAttachmentIDs) else {
            throw ClientStateStoreError.storageUnavailable
        }
        // Authenticate all retained files before deleting anything. A missing
        // committed file is an error, never silently treated as an absent cache.
        for id in manifest.attachmentIDs {
            var data = try staged.loadSanitizedAttachment(fileName: "\(id.uuidString).bin")
            data.resetBytes(in: data.startIndex..<data.endIndex)
        }
        var failure: Error?
        do { try await oldState.destroyLocalEncryptionMaterial(preservingCiphertext: action.preservesCiphertext) }
        catch { failure = error }
        if action.preservesCiphertext {
            do { try oldAttachments.prepareForKeyDestruction() }
            catch {
                // An unreadable/legacy attachment must be removed if it cannot
                // be authenticated and migrated to the key being destroyed.
                do { try oldAttachments.eraseAllLocalAttachments() } catch { failure = error }
            }
        }
        do { try oldAttachments.destroyEncryptionMaterial() } catch { failure = error }
        do { try oldAttachments.finishKeyDestruction(preservingCiphertext: action.preservesCiphertext) }
        catch { failure = error }
        do { try clearSideEffects() } catch { failure = error }
        if let failure { throw failure }

        let freshAttachments = storage.attachments()
        for id in manifest.attachmentIDs {
            var data = try staged.loadSanitizedAttachment(fileName: "\(id.uuidString).bin")
            defer { data.resetBytes(in: data.startIndex..<data.endIndex) }
            _ = try freshAttachments.saveSanitizedAttachment(data, attachmentId: id)
        }
        let freshState = storage.stateStore()
        try await freshState.save(replacement, replacing: nil)
        if !manifest.groupNames.isEmpty { try storage.groupNameStore.save(manifest.groupNames) }
        // Until this tombstone commits, restart repeats cleanup and installation
        // from the immutable staging state. No messaging session is opened yet.
        let journal = storage.stateStore(action: action)
        try await journal.eraseAllLocalState()
        try await journal.destroyLocalEncryptionMaterial(preservingCiphertext: false)
        try staged.eraseAllLocalAttachments()
        try staged.destroyEncryptionMaterial()
        try await clearInactiveStaging()
    }
}

#if DEBUG
/// UI-test state intentionally survives app-process restarts so simulator and
/// desktop interoperability scenarios can exercise durable recovery. This
/// file-backed anchor is scoped to the disposable UI-test directory and is
/// deleted only with `UI_TESTING_RESET_STATE`; production continues to use
/// the platform rollback-anchor store.
final class UITestFileRollbackAnchorStore:
    ClientStateRollbackAnchorStore, @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func load() throws -> ClientStateRollbackAnchorRecord? {
        lock.lock()
        defer { lock.unlock() }
        return try loadUnlocked()
    }

    func compareAndSwap(
        expected: ClientStateRollbackAnchorRecord?,
        replacement: ClientStateRollbackAnchorRecord
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard try loadUnlocked() == expected else {
            throw ClientStateRollbackAnchorError.compareAndSwapFailed
        }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try SecureRegularFileIO.writePrivate(
            NoctweaveCoder.encode(replacement, sortedKeys: true),
            to: fileURL,
            maximumBytes: 64 * 1_024
        )
    }

    private func loadUnlocked() throws -> ClientStateRollbackAnchorRecord? {
        for attempt in 0..<3 {
            do {
                let data = try SecureRegularFileIO.read(
                    from: fileURL, maximumBytes: 64 * 1_024, requirePrivateOwner: true)
                return try NoctweaveCoder.decode(ClientStateRollbackAnchorRecord.self, from: data)
            } catch SecureRegularFileIOError.notFound {
                return nil
            } catch SecureRegularFileIOError.changedDuringRead where attempt < 2 {
                // Discard unstable bytes, then repeat all descriptor/version checks.
                continue
            }
        }
        throw SecureRegularFileIOError.changedDuringRead
    }
}
#endif
