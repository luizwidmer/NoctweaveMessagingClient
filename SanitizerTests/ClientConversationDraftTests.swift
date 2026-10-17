import Foundation

/// Model-level regression: the script compiles the app's actual selection
/// properties and send methods against this deferred client. No UI, relay,
/// Keychain, biometric, or device interaction is involved.
@MainActor
final class DeferredDraftSendClient {
    struct GroupResult {
        enum Disposition: String { case queued }
        let complete = false
        let disposition = Disposition.queued
    }

    var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    func sendText(_ text: String, relationshipID: UUID) async throws {
        started = true
        await withCheckedContinuation { continuation = $0 }
    }

    func sendGroupText(groupID: UUID, text: String) async throws -> GroupResult {
        try await sendText(text, relationshipID: groupID)
        return GroupResult()
    }

    func finish() {
        continuation?.resume()
        continuation = nil
    }
}

@main
struct ClientConversationDraftTests {
    enum Failure: Error { case assertion(String) }

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure.assertion(message) }
    }

    @MainActor
    static func main() async throws {
        let model = ClientConversationDraftModel()
        let first = UUID(), second = UUID()
        model.selectedRelationshipID = first
        model.draftMessage = "Private text for the first contact"
        model.selectedRelationshipID = second
        try require(model.draftMessage.isEmpty, "A contact draft appeared in another contact's composer")
        model.draftMessage = "Keep while refreshing this contact"
        model.selectedRelationshipID = second
        try require(model.draftMessage == "Keep while refreshing this contact", "Reselecting the same contact cleared its draft")
        model.selectedRelationshipID = nil
        try require(model.draftMessage.isEmpty, "A deselected contact retained its composer plaintext")

        model.selectedGroupID = first
        model.groupDraftMessage = "Private text for the first group"
        model.selectedGroupID = second
        try require(model.groupDraftMessage.isEmpty, "A group draft appeared in another group's composer")
        model.groupDraftMessage = "Keep while refreshing this group"
        model.selectedGroupID = second
        try require(model.groupDraftMessage == "Keep while refreshing this group", "Reselecting the same group cleared its draft")
        model.selectedGroupID = nil
        try require(model.groupDraftMessage.isEmpty, "A deselected group retained its composer plaintext")

        for group in [false, true] {
            for change in ["same selection", "new selection", "edited draft"] {
                let sender = ClientConversationDraftModel()
                if group {
                    sender.selectedGroupID = first
                    sender.groupDraftMessage = "sent text"
                    sender.sendGroupDraft()
                } else {
                    sender.selectedRelationshipID = first
                    sender.draftMessage = "sent text"
                    sender.sendDraft()
                }
                while !sender.client.started { await Task.yield() }
                if change == "new selection" {
                    if group { sender.selectedGroupID = second; sender.groupDraftMessage = "sent text" }
                    else { sender.selectedRelationshipID = second; sender.draftMessage = "sent text" }
                } else if change == "edited draft" {
                    if group { sender.groupDraftMessage = "new text" }
                    else { sender.draftMessage = "new text" }
                }
                sender.client.finish()
                await sender.operation?.value
                let expected = change == "new selection" ? "sent text" : change == "edited draft" ? "new text" : ""
                let actual = group ? sender.groupDraftMessage : sender.draftMessage
                try require(actual == expected, "Send completion changed the wrong draft (group=\(group), \(change))")
            }
        }
        print("Passed 12 model-level conversation draft checks: selection changes, same-context preservation, and deferred send completion.")
    }
}
