import Foundation

@main
struct ClientGroupRefreshTests {
    enum Failure: Error { case assertion(String), unavailable }

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure.assertion(message) }
    }

    @MainActor
    static func main() async throws {
        var calls: [String] = []
        var pages = 0
        let result = await ClientGroupRefresh.run {
            calls.append("maintain")
            return false
        } sync: {
            calls.append("sync")
            pages += 1
            return (pages, pages < 2)
        }
        try require(calls == ["maintain", "sync", "sync"], "Refresh did not receive all queued inbound pages")
        try require(result.receivedEventCount == 3 && !result.hasMore, "Incorrect inbound refresh result")
        try require(result.maintenanceError == nil && result.syncError == nil, "Successful refresh reported an error")

        var inboundCalls = 0
        let partial = await ClientGroupRefresh.run {
            throw Failure.unavailable
        } sync: {
            inboundCalls += 1
            return (2, false)
        }
        try require(inboundCalls == 1 && partial.receivedEventCount == 2, "Outbound maintenance failure prevented inbound synchronization")
        try require(partial.maintenanceError != nil && partial.syncError == nil, "Partial availability was lost")

        var boundedCalls = 0
        let bounded = await ClientGroupRefresh.run { true } sync: {
            boundedCalls += 1
            return (1, true)
        }
        try require(boundedCalls == 8 && bounded.receivedEventCount == 8 && bounded.hasMore, "Refresh did not enforce its bounded page budget")
        try require(bounded.requiresFollowUp, "Queued outbound status was lost")

        var failureCalls = 0
        let failed = await ClientGroupRefresh.run { false } sync: {
            failureCalls += 1
            throw Failure.unavailable
        }
        try require(failureCalls == 1 && failed.syncError != nil, "Inbound failure was retried indefinitely or hidden")

        var cancelledCalls = 0
        let cancelled = Task { @MainActor in
            await ClientGroupRefresh.run {
                cancelledCalls += 1
                return false
            } sync: {
                cancelledCalls += 1
                return (0, false)
            }
        }
        cancelled.cancel()
        let cancelledResult = await cancelled.value
        try require(cancelledCalls == 0 && cancelledResult.syncError is CancellationError,
                    "Cancelled refresh contacted the relay")
        print("Passed group refresh checks: inbound pages, partial availability, page bounds, errors, and cancellation.")
    }
}
