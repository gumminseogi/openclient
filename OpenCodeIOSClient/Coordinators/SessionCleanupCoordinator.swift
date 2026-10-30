import Foundation

@MainActor
final class SessionCleanupCoordinator {
    let store = SessionCleanupStore()
    private let connection: BackendConnection
    private let isCurrent: () -> Bool
    private let delete: (OpenCodeSession) async -> Bool

    init(connection: BackendConnection, isCurrent: @escaping () -> Bool,
         delete: @escaping (OpenCodeSession) async -> Bool) {
        self.connection = connection
        self.isCurrent = isCurrent
        self.delete = delete
    }

    private func checkConnection() throws {
        try Task.checkCancellation()
        guard isCurrent(), !connection.isClosed else { throw BackendError.disconnected }
    }

    private func inventory() async throws -> ([OpenCodeProject], [SessionCleanupStore.Candidate]) {
        try checkConnection()
        guard let activity = connection.sessionActivity else { throw BackendError.invalidScope }
        let projects = try await connection.projects.projectsSnapshot().projects
        let isV2 = connection.openCodeCompatibility?.profile == .v2
        var scopes = Set<BackendScope>()
        for project in projects {
            if isV2 { scopes.insert(.init(projectID: project.id)) }
            else {
                scopes.insert(.init(projectID: project.id, directory: project.id == "global" ? nil : project.worktree))
                for sandbox in project.sandboxes ?? [] {
                    scopes.insert(.init(projectID: project.id, directory: sandbox))
                }
            }
        }
        var sessions: [String: OpenCodeSession] = [:]
        var statuses: [String: String] = [:]
        for scope in scopes {
            var cursor: String?
            var seen = Set<String>()
            repeat {
                try checkConnection()
                let page = try await connection.sessions.sessions(scope: scope, cursor: cursor,
                    limit: isV2 ? 100 : Int.max, roots: false)
                for session in page.sessions { sessions[session.id] = session }
                cursor = page.nextCursor
                if let cursor, !seen.insert(cursor).inserted { throw OpenCodeV2TransportError.invalidTimelineRecord }
            } while cursor != nil
            statuses.merge(try await activity.sessionStatuses(scope: scope), uniquingKeysWith: { _, new in new })
        }
        try checkConnection()
        return (projects, SessionCleanupStore.candidates(sessions: Array(sessions.values), statuses: statuses))
    }

    func load() async {
        guard !store.isLoading, !store.isDeleting else { return }
        store.isLoading = true
        store.error = nil
        defer { store.isLoading = false }
        do {
            let (projects, candidates) = try await inventory()
            store.projects = projects
            store.candidates = candidates
        } catch is CancellationError { }
        catch { store.error = error.localizedDescription }
    }

    func deleteCandidates(_ targets: [SessionCleanupStore.Candidate]) async {
        guard !store.isDeleting, !targets.isEmpty else { return }
        store.isDeleting = true
        store.error = nil
        store.progress = 0
        store.total = targets.count
        store.failures = [:]
        defer { store.isDeleting = false }
        do {
            var incomplete = false
            for target in targets {
                try checkConnection()
                do {
                    // Re-read the entire conversation immediately before each delete,
                    // including children created while a long batch was in progress.
                    guard let current = try await currentConversation(target.session),
                          current.lastActivity == target.lastActivity,
                          current.memberIDs == target.memberIDs,
                          current.session.projectID == target.session.projectID else {
                        store.failures[target.id] = String(localized: "Chat activity changed. Review it again before deleting.")
                        store.progress += 1
                        incomplete = true
                        continue
                    }
                    try checkConnection()
                    if await delete(current.session) { store.remove(target.id) }
                    else {
                        incomplete = true
                        store.failures[target.id] = String(localized: "Could not delete this chat. Try again.")
                    }
                } catch is CancellationError { throw CancellationError() }
                catch {
                    incomplete = true
                    store.failures[target.id] = error.localizedDescription
                }
                store.progress += 1
            }
            if incomplete { store.error = String(localized: "Some chats were skipped or could not be deleted. Refresh to review them again.") }
        } catch is CancellationError { }
        catch { store.error = error.localizedDescription }
    }

    private func currentConversation(_ root: OpenCodeSession) async throws -> SessionCleanupStore.Candidate? {
        guard let activity = connection.sessionActivity else { throw BackendError.invalidScope }
        func scope(_ session: OpenCodeSession) -> BackendScope {
            .init(projectID: session.projectID, directory: session.directory, workspaceID: session.workspaceID)
        }
        var sessions = [try await connection.sessions.session(id: root.id, scope: scope(root))]
        var seenIDs: Set<String> = [root.id]
        var index = 0
        while index < sessions.count {
            let parent = sessions[index]
            var cursor: String?
            var seenCursors = Set<String>()
            repeat {
                try checkConnection()
                let childScope = connection.openCodeCompatibility?.profile == .v2
                    ? BackendScope(projectID: parent.projectID) : scope(parent)
                let page = try await connection.sessions.childSessions(parentID: parent.id, scope: childScope, cursor: cursor)
                for child in page.sessions where seenIDs.insert(child.id).inserted { sessions.append(child) }
                cursor = page.nextCursor
                if let cursor, !seenCursors.insert(cursor).inserted { throw OpenCodeV2TransportError.invalidTimelineRecord }
            } while cursor != nil
            index += 1
        }
        var statuses: [String: String] = [:]
        for scope in Set(sessions.map(scope)) {
            try checkConnection()
            statuses.merge(try await activity.sessionStatuses(scope: scope), uniquingKeysWith: { _, new in new })
        }
        try checkConnection()
        return SessionCleanupStore.candidates(sessions: sessions, statuses: statuses).first { $0.id == root.id }
    }

    func loadTranscript(_ session: OpenCodeSession, older: Bool = false) async {
        var transcript = store.transcripts[session.id] ?? .init()
        guard !transcript.isLoading, older || !transcript.loaded else { return }
        if older && transcript.olderCursor == nil { return }
        transcript.isLoading = true
        transcript.error = nil
        store.transcripts[session.id] = transcript
        do {
            try checkConnection()
            let page = try await connection.chat.transcript(sessionID: session.id,
                scope: .init(projectID: session.projectID, directory: session.directory, workspaceID: session.workspaceID),
                cursor: older ? transcript.olderCursor : nil, limit: 50)
            try checkConnection()
            let existing = Set(transcript.messages.map(\.id))
            transcript.messages = page.messages.filter { !existing.contains($0.id) } + transcript.messages
            transcript.olderCursor = page.olderCursor
            transcript.loaded = true
        } catch is CancellationError { }
        catch { transcript.error = error.localizedDescription }
        transcript.isLoading = false
        store.transcripts[session.id] = transcript
    }
}
