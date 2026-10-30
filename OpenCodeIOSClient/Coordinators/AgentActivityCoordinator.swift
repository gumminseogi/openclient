import Foundation

@MainActor
enum AgentActivityCoordinator {
    static func hydrate(parent: OpenCodeSession, model: AppViewModel, isCurrent: () -> Bool) async throws {
        let connection = try model.requireBackendConnection()
        let registry = model.directoryStoreRegistry
        let generation = registry.generation
        let owner = registry.ownerStore(forSessionID: parent.id) ?? registry.activeStore
        let snapshot = owner.sessions
        let lifecycle = registry.v2LifecycleSnapshot
        func current() -> Bool {
            !Task.isCancelled && model.isCurrentBackendConnection(connection)
                && registry.generation == generation && isCurrent()
                && registry.ownerStore(forSessionID: parent.id) === owner
                && registry.v2LifecycleRevision(sessionID: parent.id) == (lifecycle[parent.id] ?? 0)
        }
        var children: [OpenCodeSession] = []
        var cursor: String?
        var seen = Set<String>()
        repeat {
            let page = try await connection.sessions.childSessions(parentID: parent.id,
                scope: .init(projectID: parent.projectID, directory: parent.directory, workspaceID: parent.workspaceID), cursor: cursor)
            guard current() else { throw CancellationError() }
            children += page.sessions.filter { $0.parentID == parent.id && !$0.isArchived }
            cursor = page.nextCursor
            if let cursor, !seen.insert(cursor).inserted { throw URLError(.badServerResponse) }
        } while cursor != nil

        let protected = Set((snapshot + children).map(\.id).filter {
            registry.isV2SessionDeleted($0) || registry.v2LifecycleRevision(sessionID: $0) != (lifecycle[$0] ?? 0)
        })
        owner.reconcileChildSessions(parentID: parent.id, children: children, snapshot: snapshot, protectedIDs: protected)
        // Resolve status-only events received before child discovery.
        for child in children where !protected.contains(child.id) { _ = registry.targetStore(forV2Session: child) }
        if let key = registry.key(for: owner) {
            model.persistDirectoryToLocalCache(owner, directory: DirectoryStoreRegistry.directory(forKey: key), marksValidated: false)
        }

        // /active is read after discovery so previously unknown children participate
        // in revision-guarded status hydration.
        try await model.reloadSessionStatuses()
        guard current() else { throw CancellationError() }
        var complete = true
        let sessions = owner.sessions.filter { $0.parentID == parent.id && !$0.isArchived }
        // Bounded concurrency: history enumeration never waits for each child's
        // permission/form requests before fetching the next page.
        for start in stride(from: 0, to: sessions.count, by: 6) {
            guard current() else { throw CancellationError() }
            let batch = sessions[start..<min(start + 6, sessions.count)]
            let results = await withTaskGroup(of: Bool.self) { group in
                for child in batch {
                    group.addTask { [model, child] in await model.hydrateV2Interactions(for: child) }
                }
                var results: [Bool] = []
                for await result in group { results.append(result) }
                return results
            }
            complete = complete && results.allSatisfy { $0 }
        }
        guard current() else { throw CancellationError() }
        if !complete { throw URLError(.cannotLoadFromNetwork) }
    }
}
