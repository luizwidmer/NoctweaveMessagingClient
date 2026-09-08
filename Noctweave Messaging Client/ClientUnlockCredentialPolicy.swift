import Foundation
import NoctweaveCore

/// App credentials follow the host's input convention. The physical security
/// key's own PIN remains an independent authenticator on every platform.
enum ClientUnlockCredentialPolicy {
    #if os(macOS)
    static let usesPassword = true
    static let name = "Password"
    static let rules = "Use 6–128 characters."
    static let creationTitle = "Create a password"
    static let icon = "textformat.abc"
    #else
    static let usesPassword = false
    static let name = "PIN"
    static let rules = "Use exactly six digits."
    static let creationTitle = "Create a six-digit PIN"
    static let icon = "number.square.fill"
    #endif

    static func isNumericPIN(_ value: String) -> Bool {
        value.utf8.count == 6 && value.utf8.allSatisfy { (48...57).contains($0) }
    }
    static func isValidNewCredential(_ value: String) -> Bool {
        usesPassword ? AppLockDuressPassword.isValid(value) : isNumericPIN(value)
    }
    static func makeRecord(_ value: String) throws -> AppLockPINRecordV2 {
        usesPassword ? try AppLockPasswordV1.makeRecord(password: value) : try AppLockPINV2.makeRecord(pin: value)
    }
    static func usesPINForDuressReplacement(_ value: String) -> Bool {
        // New mobile duress codes are always numeric. Keep pre-existing legacy
        // nonnumeric codes usable rather than failing a destructive action or
        // replacing its credential with one the owner never chose.
        !usesPassword && isNumericPIN(value)
    }
}

extension AppLockMode {
    var clientDisplayName: String {
        guard ClientUnlockCredentialPolicy.usesPassword else { return displayName }
        return displayName.replacingOccurrences(of: "PIN Only", with: "Password")
            .replacingOccurrences(of: "PIN", with: "Password")
    }
}
