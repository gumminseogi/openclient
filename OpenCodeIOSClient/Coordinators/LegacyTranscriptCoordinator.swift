import Foundation

/// Legacy servers expose a newest-message limit, not a revision/delta endpoint.
/// Disk previews are provisional. An interrupted canonical window needs a full
/// inventory before its older entries can be considered current again.
@MainActor
enum LegacyTranscriptCoordinator {
    static func needsCompleteInventory(
        window: LegacyTranscriptWindow?, streamIsOpen: Bool, continuityEpoch: UInt
    ) -> Bool {
        guard let window, window.origin == .canonical else { return false }
        return !streamIsOpen || window.continuityEpoch != continuityEpoch
    }

    static func read(
        connection: BackendConnection, session: OpenCodeSession, completeInventory: Bool
    ) async throws -> BackendTranscriptPage {
        let scope = BackendScope(projectID: session.projectID, directory: session.directory,
                                 workspaceID: session.workspaceID)
        let page = try await connection.chat.transcript(sessionID: session.id, scope: scope,
            cursor: nil, limit: completeInventory ? Int.max : OpenCodeCachedChatPreview.messageLimit)
        guard completeInventory else { return page }

        // Official 1.x returns the entire inventory when limit is omitted. Keep
        // cursor-bearing compatible servers correct rather than assuming that.
        var messages = page.messages
        var cursor = page.olderCursor
        var seen: Set<String> = []
        while let next = cursor {
            try Task.checkCancellation()
            guard !connection.isClosed, seen.insert(next).inserted else {
                throw OpenCodeAPIError.invalidResponse
            }
            let older = try await connection.chat.transcript(sessionID: session.id, scope: scope,
                cursor: next, limit: OpenCodeCachedChatPreview.messageLimit)
            messages = ChatStore.mergingCanonicalMessagePage(older.messages, into: messages)
            cursor = older.olderCursor
        }
        return BackendTranscriptPage(messages: messages, olderCursor: nil)
    }

    static func mergingNewestPage(
        _ page: [OpenCodeMessageEnvelope], into existing: [OpenCodeMessageEnvelope],
        replacesExisting: Bool
    ) -> [OpenCodeMessageEnvelope] {
        guard !replacesExisting else { return page }
        let pageIDs = Set(page.map(\.id))
        // Replace only a covered newest suffix. A limited page cannot prove that
        // an absent older message was deleted.
        let anchor = existing.firstIndex { pageIDs.contains($0.id) }
        let older = anchor.map { Array(existing[..<$0]) } ?? existing
        return ChatStore.mergingCanonicalMessagePage(page, into: older)
    }
}
