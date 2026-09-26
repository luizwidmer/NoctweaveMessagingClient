import Darwin
import Foundation
import Security

enum ClientUnlockRetryError: Error {
    case unavailable
    case cooldown
}

protocol ClientUnlockRetryPersistence {
    func read() throws -> Data?
    func write(_ data: Data) throws
    func delete() throws
}

/// An attempt is saved before checking either an ordinary or a duress password.
/// A process crash therefore cannot grant another batch of guesses.
@MainActor
final class ClientUnlockRetryLedger {
    private struct Record: Codable {
        var version = 1
        var failedAttempts = 0
        var retryAfter: Date?

        func validate() throws {
            guard version == 1, (0..<5).contains(failedAttempts),
                  retryAfter.map({ $0.timeIntervalSince1970.isFinite }) != false else {
                throw ClientUnlockRetryError.unavailable
            }
        }
    }

    private let persistence: any ClientUnlockRetryPersistence
    private let lockURL: URL

    init(persistence: any ClientUnlockRetryPersistence, lockURL: URL) {
        self.persistence = persistence
        self.lockURL = lockURL
    }

    func reserveAttempt(at now: Date = Date()) throws {
        try withExclusiveLock {
            var record: Record
            if let encoded = try persistence.read() {
                guard encoded.count <= 256 else { throw ClientUnlockRetryError.unavailable }
                record = try JSONDecoder().decode(Record.self, from: encoded)
                try record.validate()
            } else {
                record = Record()
            }
            if let deadline = record.retryAfter, now < deadline {
                throw ClientUnlockRetryError.cooldown
            }
            record.retryAfter = nil
            record.failedAttempts += 1
            if record.failedAttempts == 5 {
                record.failedAttempts = 0
                record.retryAfter = now.addingTimeInterval(30)
            }
            let encoded = try JSONEncoder().encode(record)
            try persistence.write(encoded)
        }
    }

    func reset() throws {
        try withExclusiveLock { try persistence.delete() }
    }

    /// Erasure has already retired the old credentials. A Keychain failure
    /// must not strand a committed wipe or decoy transition; if the old retry
    /// record remains, subsequent PIN attempts still read it or fail closed.
    func discardAfterLocalTransition() {
        try? withExclusiveLock { try persistence.delete() }
    }

    /// macOS can launch two copies of the app. Serialize each Keychain
    /// read-modify-write across processes, and reject attempts if another
    /// process holds the lock. The file contains no credentials or counters.
    private func withExclusiveLock<T>(_ body: () throws -> T) throws -> T {
        try SecureRegularFileIO.ensurePrivateDirectory(at: lockURL.deletingLastPathComponent())
        let descriptor: Int32 = lockURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        }
        guard descriptor >= 0 else { throw ClientUnlockRetryError.unavailable }
        defer { _ = close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              status.st_uid == geteuid(), status.st_nlink == 1,
              (status.st_mode & mode_t(0o077)) == 0,
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw ClientUnlockRetryError.unavailable
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }
}

/// This device's Keychain keeps the retry deadline across app launches. The
/// account follows the encrypted state scope so development storage cannot
/// advance or erase the production retry record.
struct KeychainClientUnlockRetryPersistence: ClientUnlockRetryPersistence {
    let scope: String

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "org.noctweave.client") + ".unlock-retry.v1",
         kSecAttrAccount as String: scope,
         kSecAttrSynchronizable as String: false]
    }

    func read() throws -> Data? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, data.count <= 256 else {
            throw ClientUnlockRetryError.unavailable
        }
        return data
    }

    func write(_ data: Data) throws {
        guard !data.isEmpty, data.count <= 256 else { throw ClientUnlockRetryError.unavailable }
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw ClientUnlockRetryError.unavailable }
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else {
            throw ClientUnlockRetryError.unavailable
        }
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ClientUnlockRetryError.unavailable
        }
    }
}

#if DEBUG
/// UI tests use only their disposable storage directory, never the app's
/// production Keychain record. SecureRegularFileIO makes each update durable.
struct FileClientUnlockRetryPersistence: ClientUnlockRetryPersistence {
    let url: URL

    func read() throws -> Data? {
        do {
            return try SecureRegularFileIO.read(from: url, maximumBytes: 256, requirePrivateOwner: true)
        } catch SecureRegularFileIOError.notFound {
            return nil
        }
    }

    func write(_ data: Data) throws {
        try SecureRegularFileIO.writePrivate(data, to: url, maximumBytes: 256)
    }

    func delete() throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            return
        }
    }
}
#endif
