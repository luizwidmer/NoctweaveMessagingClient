import Foundation
import Security

@main
enum ClientGroupNameStoreTests {
    @MainActor
    static func main() throws {
        let scope = UUID().uuidString
        let suite = "NoctweaveGroupNameTests." + scope
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = ClientGroupNameStore(stateURL: URL(fileURLWithPath: "/tmp/" + scope),
            scope: scope, service: suite + ".keychain", defaults: defaults)
        defer {
            try? store.delete()
            defaults.removePersistentDomain(forName: suite)
        }
        let canary = "private-name-" + scope
        try store.save([scope: canary])
        let reopened = try store.load()
        precondition(reopened[scope] == canary)
        precondition(defaults.object(forKey: "noctweave.groupNames") == nil)
        precondition(!defaults.dictionaryRepresentation().values.contains { "\($0)".contains(canary) })

        defaults.set("{\"old\":\"developer data\"}", forKey: "noctweave.groupNames")
        do { _ = try store.load(); fatalError("Legacy plaintext was ignored") }
        catch ClientGroupNameStoreError.legacyNamesPresent {}
        do { try store.save([:]); fatalError("Legacy plaintext was silently replaced") }
        catch ClientGroupNameStoreError.legacyNamesPresent {}
        precondition(defaults.string(forKey: "noctweave.groupNames") != nil)
        defaults.removeObject(forKey: "noctweave.groupNames")

        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: store.service, kSecAttrAccount as String: store.account,
            kSecAttrSynchronizable as String: false]
        precondition(SecItemUpdate(query as CFDictionary,
            [kSecValueData as String: Data("damaged".utf8)] as CFDictionary) == errSecSuccess)
        do { _ = try store.load(); fatalError("Corrupt Keychain record was accepted") }
        catch ClientGroupNameStoreError.invalidRecord {}
        print("Client group-name Keychain checks passed.")
    }
}
