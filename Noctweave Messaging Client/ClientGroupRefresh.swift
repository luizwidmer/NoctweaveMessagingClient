import Foundation

/// A manual refresh must receive messages as well as maintain outbound routes.
/// Keep those steps independent so an outbound failure does not hide an inbox
/// that is still reachable. The bound matches ordinary foreground sync.
@MainActor
enum ClientGroupRefresh {
    struct Result {
        var requiresFollowUp = false
        var receivedEventCount = 0
        var hasMore = false
        var maintenanceError: Error?
        var syncError: Error?
    }

    static func run(
        maintain: () async throws -> Bool,
        sync: () async throws -> (receivedEventCount: Int, hasMore: Bool)
    ) async -> Result {
        var result = Result()
        do {
            try Task.checkCancellation()
            result.requiresFollowUp = try await maintain()
        } catch {
            result.maintenanceError = error
        }
        for _ in 0..<8 {
            do {
                try Task.checkCancellation()
                let page = try await sync()
                result.receivedEventCount += page.receivedEventCount
                result.hasMore = page.hasMore
                if !page.hasMore { break }
            } catch {
                result.syncError = error
                break
            }
        }
        return result
    }
}
