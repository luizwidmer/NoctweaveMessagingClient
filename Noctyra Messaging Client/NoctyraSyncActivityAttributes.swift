import Foundation

#if os(iOS)
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

        static let idle = ContentState(
            isFetching: false,
            lastAttemptAt: nil,
            lastSuccessAt: nil,
            fetchedEnvelopeCount: 0,
            stagedEnvelopeCount: 0,
            profileCount: 0,
            status: "No sync yet"
        )
    }

    var dashboardName: String
}
#endif
