import NoctweaveCore

@main
enum ClientLockPresentationTests {
    static func main() {
        let cases: [(String, AppLockMode, Set<AppLockFactor>, Bool, Bool, Bool)] = [
            ("unprotected", .off, [], false, false, false),
            ("PIN only", .pinOnly, [], false, false, true),
            ("waiting for hidden key", .securityKeyAndPin, [], false, false, true),
            ("key introduced", .securityKeyAndPin, [], true, false, false),
            ("key authentication", .securityKeyAndPin, [], true, true, false),
            ("key retry", .securityKeyAndPin, [], true, false, false),
            ("key accepted, PIN due", .securityKeyAndPin, [.securityKey], false, false, true),
            ("all checks, waiting", .biometricsPinAndSecurityKey, [], false, false, true),
            ("all checks, key introduced", .biometricsPinAndSecurityKey, [], true, false, false),
            ("between key and biometrics", .biometricsPinAndSecurityKey, [.securityKey], false, false, false),
            ("biometrics after key", .biometricsPinAndSecurityKey, [.securityKey], false, true, false),
            ("PIN after key and biometrics", .biometricsPinAndSecurityKey, [.securityKey, .biometrics], false, false, true),
            ("biometrics alone cannot advance", .biometricsPinAndSecurityKey, [.biometrics], false, false, false),
            ("key only finished", .securityKey, [.securityKey], false, false, false),
            ("biometrics waiting", .biometricsAndPin, [], false, false, true),
            ("biometrics active", .biometricsAndPin, [], false, true, false),
            ("PIN after biometrics", .biometricsAndPin, [.biometrics], false, false, true),
            ("biometrics only finished", .biometrics, [.biometrics], false, false, false),
            ("no configured PIN after both", .biometricsAndSecurityKey, [.securityKey, .biometrics], false, false, false)
        ]
        for (name, mode, completed, keyPrompt, authenticating, expected) in cases {
            precondition(ClientLockPresentation.showsPIN(mode: mode, completedFactors: completed,
                keyPromptVisible: keyPrompt, authenticationInFlight: authenticating) == expected, name)
        }
        print("Passed \(cases.count) unlock presentation checks.")
    }
}
