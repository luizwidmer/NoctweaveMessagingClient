import Darwin
import Foundation

@main
enum ClientUnlockRetryLedgerTests {
    @MainActor
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoctweaveRetryLedgerTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = FileClientUnlockRetryPersistence(
            url: directory.appendingPathComponent("retry.json"))
        let lockURL = directory.appendingPathComponent("retry.lock")
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        for _ in 0..<5 {
            try ClientUnlockRetryLedger(persistence: persistence, lockURL: lockURL).reserveAttempt(at: start)
        }
        do {
            try ClientUnlockRetryLedger(persistence: persistence, lockURL: lockURL)
                .reserveAttempt(at: start.addingTimeInterval(29))
            fatalError("A relaunch cleared the cooldown")
        } catch ClientUnlockRetryError.cooldown {
            // A newly constructed ledger still reads the saved cooldown.
        }
        try ClientUnlockRetryLedger(persistence: persistence, lockURL: lockURL)
            .reserveAttempt(at: start.addingTimeInterval(30))

        try ClientUnlockRetryLedger(persistence: persistence, lockURL: lockURL).reset()
        try ClientUnlockRetryLedger(persistence: persistence, lockURL: lockURL).reserveAttempt(at: start)

        let competingDescriptor = open(lockURL.path, O_RDWR)
        precondition(competingDescriptor >= 0)
        defer { _ = close(competingDescriptor) }
        precondition(flock(competingDescriptor, LOCK_EX | LOCK_NB) == 0)
        do {
            try ClientUnlockRetryLedger(persistence: persistence, lockURL: lockURL).reserveAttempt(at: start)
            fatalError("A separate descriptor bypassed the retry lock")
        } catch ClientUnlockRetryError.unavailable {}
        _ = flock(competingDescriptor, LOCK_UN)

        try persistence.write(Data("invalid".utf8))
        do {
            try ClientUnlockRetryLedger(persistence: persistence, lockURL: lockURL).reserveAttempt(at: start)
            fatalError("Invalid durable state must fail closed")
        } catch {
            // Decode failure must not be treated as a fresh attempt ledger.
        }

        let unavailable = ClientUnlockRetryLedger(persistence: UnavailablePersistence(), lockURL: lockURL)
        unavailable.discardAfterLocalTransition()
        do {
            try unavailable.reserveAttempt(at: start)
            fatalError("Keychain failure after erasure must not permit a fresh guess")
        } catch ClientUnlockRetryError.unavailable {
            // Erasure proceeds, but a later unlock still fails closed.
        }
        print("Client unlock retry persistence checks passed.")
    }
}

private struct UnavailablePersistence: ClientUnlockRetryPersistence {
    func read() throws -> Data? { throw ClientUnlockRetryError.unavailable }
    func write(_ data: Data) throws { throw ClientUnlockRetryError.unavailable }
    func delete() throws { throw ClientUnlockRetryError.unavailable }
}
