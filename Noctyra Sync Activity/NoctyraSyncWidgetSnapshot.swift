import Foundation

struct NoctyraSyncWidgetSnapshot: Codable, Hashable {
    var updatedAt: Date
    var isFetching: Bool
    var lastAttemptAt: Date?
    var lastSuccessAt: Date?
    var fetchedEnvelopeCount: Int
    var stagedEnvelopeCount: Int
    var profileCount: Int
    var status: String

    static let empty = NoctyraSyncWidgetSnapshot(
        updatedAt: Date(timeIntervalSince1970: 0),
        isFetching: false,
        lastAttemptAt: nil,
        lastSuccessAt: nil,
        fetchedEnvelopeCount: 0,
        stagedEnvelopeCount: 0,
        profileCount: 0,
        status: "No sync yet"
    )
}
