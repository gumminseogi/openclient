import Foundation

@MainActor
enum SessionInteractionHydrationCoordinator {
    static func hydrate(session: OpenCodeSession, model: AppViewModel) async -> Bool {
        guard model.connectionStore.apiProfile == .v2 else { return true }
        guard let connection = try? model.requireBackendConnection(),
              let client = try? connection.requireOpenCodeClient(for: .interactions) else { return false }
        let registry = model.directoryStoreRegistry
        let owner = registry.ownerStore(forSessionID: session.id) ?? registry.activeStore
        guard let key = registry.key(for: owner) else { return false }
        let generation = registry.generation
        let lifecycle = registry.v2LifecycleRevision(sessionID: session.id)
        // A reply/creation during a snapshot invalidates that category. Retry from
        // a fresh revision so unrelated pending requests are not lost forever.
        for _ in 0..<3 {
            let permissionsRevision = owner.permissionRevision
            let questionsRevision = owner.questionRevision
            do {
                try Task.checkCancellation()
                async let permissions = client.listV2SessionPermissions(sessionID: session.id)
                async let forms = client.listV2SessionForms(sessionID: session.id)
                let loaded = try await (permissions, forms)
                guard !Task.isCancelled, model.isCurrentBackendConnection(connection),
                      registry.generation == generation, registry.contains(owner, forKey: key),
                      registry.v2LifecycleRevision(sessionID: session.id) == lifecycle,
                      !registry.isV2SessionDeleted(session.id) else { return false }
                let applied = owner.applyV2SessionInteractions(sessionID: session.id, permissions: loaded.0, forms: loaded.1,
                    permissionRevisionAtRequestStart: permissionsRevision, questionRevisionAtRequestStart: questionsRevision)
                model.liveActivityFacade.reducerDidCommit(sessionIDs: [session.id])
                if model.directoryStore === owner, model.selectedSession?.id == session.id {
                    model.sessionInteractionStore.applySelectedSession(sessionID: session.id,
                        sessions: owner.sessions, syncState: owner.syncState)
                }
                if applied { return true }
            } catch {
                model.appendDebugLog("v2 interaction hydration failed: \(error.localizedDescription)")
                return false
            }
        }
        return false
    }
}
