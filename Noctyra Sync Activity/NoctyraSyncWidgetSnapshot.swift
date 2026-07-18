import Foundation

struct NoctyraSyncWidgetSnapshot: Codable, Hashable {
    var updatedAt: Date
    var isFetching: Bool
    var lastAttemptAt: Date?
    var lastSuccessAt: Date?
    var fetchedPacketCount: Int
    var stagedPacketCount: Int
    var routeCount: Int
    var status: String

    static let empty = NoctyraSyncWidgetSnapshot(
        updatedAt: Date(timeIntervalSince1970: 0),
        isFetching: false,
        lastAttemptAt: nil,
        lastSuccessAt: nil,
        fetchedPacketCount: 0,
        stagedPacketCount: 0,
        routeCount: 0,
        status: "No sync yet"
    )
}
