import Foundation

#if canImport(AppIntents)
import AppIntents

@available(iOS 16.0, macOS 13.0, *)
struct NoctyraCiphertextPrefetchIntent: AppIntent {
    static var title: LocalizedStringResource = "Fetch Noctyra Ciphertext"
    static var description = IntentDescription("Fetches encrypted relay envelopes without decrypting message content or acknowledging delivery.")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = await CiphertextPrefetchRunner.runDefault()
        await NoctyraSyncDashboardController.refreshWidgetFromStore(fetchedEnvelopeCount: result.fetchedEnvelopeCount)
        return .result(dialog: "Noctyra ciphertext sync finished. Open Noctyra to review sync status.")
    }
}
#endif
