import Darwin
import Foundation

enum SecureRegularFileIOError: Error {
    case notFound
    case inaccessible
    case notRegular
    case tooLarge
    case changedDuringRead
    case unsafeDirectory
}

/// File-descriptor I/O for untrusted imports and private app state. The final
/// component is never followed, reads are bounded, and private writes replace
/// their destination atomically from inside a verified mode-0700 directory.
enum SecureRegularFileIO {
    static func read(
        from url: URL,
        maximumBytes: Int,
        allowEmpty: Bool = false,
        requirePrivateOwner: Bool = false
    ) throws -> Data {
        let descriptor: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else {
            throw errno == ENOENT ? SecureRegularFileIOError.notFound : .inaccessible
        }
        defer { _ = close(descriptor) }
        let before = try validate(
            descriptor,
            maximumBytes: maximumBytes,
            allowEmpty: allowEmpty,
            requirePrivateOwner: requirePrivateOwner
        )

        var data = Data()
        data.reserveCapacity(Int(before.st_size))
        var buffer = [UInt8](repeating: 0, count: min(64 * 1_024, maximumBytes + 1))
        while true {
            let remaining = maximumBytes + 1 - data.count
            guard remaining > 0 else { throw SecureRegularFileIOError.tooLarge }
            let requested = min(buffer.count, remaining)
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return Darwin.read(descriptor, base, requested)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw SecureRegularFileIOError.inaccessible }
            if count == 0 { break }
            data.append(contentsOf: buffer[0..<count])
            guard data.count <= maximumBytes else { throw SecureRegularFileIOError.tooLarge }
        }

        var after = stat()
        guard fstat(descriptor, &after) == 0,
              sameFileAndVersion(before, after),
              data.count == Int(after.st_size),
              allowEmpty || !data.isEmpty else {
            throw SecureRegularFileIOError.changedDuringRead
        }
        return data
    }

    static func privateRegularFileExists(at url: URL, maximumBytes: Int) -> Bool {
        do {
            let data = try read(
                from: url,
                maximumBytes: maximumBytes,
                requirePrivateOwner: true
            )
            return !data.isEmpty
        } catch {
            return false
        }
    }

    static func ensurePrivateDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let descriptor: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { throw SecureRegularFileIOError.unsafeDirectory }
        defer { _ = close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_uid == geteuid(),
              (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              fchmod(descriptor, mode_t(0o700)) == 0 else {
            throw SecureRegularFileIOError.unsafeDirectory
        }
    }

    static func writePrivate(
        _ data: Data,
        to fileURL: URL,
        maximumBytes: Int,
        excludedFromBackup: Bool = true
    ) throws {
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw SecureRegularFileIOError.tooLarge
        }
        let directoryURL = fileURL.deletingLastPathComponent()
        try ensurePrivateDirectory(at: directoryURL)
        let directory: Int32 = directoryURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard directory >= 0 else { throw SecureRegularFileIOError.unsafeDirectory }
        defer { _ = close(directory) }

        let name = fileURL.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw SecureRegularFileIOError.inaccessible
        }
        let temporaryName = ".\(name).\(UUID().uuidString.lowercased()).tmp"
        let descriptor = temporaryName.withCString { temporary in
            openat(
                directory,
                temporary,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else { throw SecureRegularFileIOError.inaccessible }
        var descriptorIsOpen = true
        var temporaryExists = true
        defer {
            if descriptorIsOpen { _ = close(descriptor) }
            if temporaryExists {
                temporaryName.withCString { _ = unlinkat(directory, $0, 0) }
            }
        }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw SecureRegularFileIOError.inaccessible
        }
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < raw.count {
                let result = Darwin.write(
                    descriptor,
                    base.advanced(by: written),
                    raw.count - written
                )
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { throw SecureRegularFileIOError.inaccessible }
                written += result
            }
        }
        guard fsync(descriptor) == 0, close(descriptor) == 0 else {
            descriptorIsOpen = false
            throw SecureRegularFileIOError.inaccessible
        }
        descriptorIsOpen = false
        let result = temporaryName.withCString { temporary in
            name.withCString { destination in
                renameat(directory, temporary, directory, destination)
            }
        }
        guard result == 0, fsync(directory) == 0 else {
            throw SecureRegularFileIOError.inaccessible
        }
        temporaryExists = false

        do {
            #if os(iOS)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: fileURL.path
            )
            #endif
            if excludedFromBackup {
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                var mutableURL = fileURL
                try mutableURL.setResourceValues(values)
            }
        } catch {
            fileURL.withUnsafeFileSystemRepresentation { path in
                if let path { _ = unlink(path) }
            }
            throw SecureRegularFileIOError.inaccessible
        }
    }

    private static func validate(
        _ descriptor: Int32,
        maximumBytes: Int,
        allowEmpty: Bool,
        requirePrivateOwner: Bool
    ) throws -> stat {
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              status.st_size >= 0 else {
            throw SecureRegularFileIOError.notRegular
        }
        guard UInt64(status.st_size) <= UInt64(maximumBytes) else {
            throw SecureRegularFileIOError.tooLarge
        }
        guard allowEmpty || status.st_size > 0 else {
            throw SecureRegularFileIOError.notRegular
        }
        if requirePrivateOwner {
            guard status.st_uid == geteuid(),
                  (status.st_mode & mode_t(0o077)) == 0 else {
                throw SecureRegularFileIOError.notRegular
            }
        }
        return status
    }

    private static func sameFileAndVersion(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
    }
}
