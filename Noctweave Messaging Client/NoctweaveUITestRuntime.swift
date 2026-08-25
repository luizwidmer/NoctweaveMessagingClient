import Foundation

/// Centralizes every process-argument test override behind a compile-time
/// DEBUG boundary. Release builds always use production storage and privacy
/// behavior, even when launched with UI-test-looking arguments.
enum NoctweaveUITestRuntime {
    enum Option {
        case readyState
        case productFixture
        case resetState
        case plaintextState
        case secureRendering
    }

    static var isEnabled: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("UI_TESTING")
        #else
        false
        #endif
    }

    static func contains(_ option: Option) -> Bool {
        #if DEBUG
        isEnabled && ProcessInfo.processInfo.arguments.contains(argumentName(for: option))
        #else
        false
        #endif
    }

    static func value(after option: Option) -> String? {
        #if DEBUG
        guard isEnabled else { return nil }
        let arguments = ProcessInfo.processInfo.arguments
        guard let optionIndex = arguments.firstIndex(of: argumentName(for: option)),
              arguments.indices.contains(optionIndex + 1) else {
            return nil
        }
        return arguments[optionIndex + 1]
        #else
        nil
        #endif
    }

    #if DEBUG
    private static func argumentName(for option: Option) -> String {
        switch option {
        case .readyState:
            "UI_TESTING_READY_STATE"
        case .productFixture:
            "UI_TESTING_PRODUCT_FIXTURE"
        case .resetState:
            "UI_TESTING_RESET_STATE"
        case .plaintextState:
            "UI_TESTING_PLAINTEXT_STATE"
        case .secureRendering:
            "SECURE_RENDERING_TEST"
        }
    }
    #endif
}
