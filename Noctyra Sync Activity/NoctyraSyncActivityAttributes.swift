import Foundation
import ActivityKit

@available(iOS 16.2, *)
struct NoctyraSyncActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var isFetching: Bool
        var lastAttemptAt: Date?
        var lastSuccessAt: Date?
        var fetchedEnvelopeCount: Int
        var stagedEnvelopeCount: Int
        var profileCount: Int
        var status: String
    }

    var dashboardName: String
}
