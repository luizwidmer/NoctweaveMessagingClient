import NoctweaveCore

enum ClientLockPresentation {
    /// The waiting PIN accepts duress input. Once authentication starts, only the
    /// real PIN step may appear, after all of its configured predecessors pass.
    static func showsPIN(mode: AppLockMode, completedFactors: Set<AppLockFactor>,
                         keyPromptVisible: Bool, authenticationInFlight: Bool) -> Bool {
        guard mode != .off, !keyPromptVisible, !authenticationInFlight else { return false }
        if mode.canAttempt(.pin, completedFactors: completedFactors) { return true }
        return completedFactors.isEmpty
    }
}
