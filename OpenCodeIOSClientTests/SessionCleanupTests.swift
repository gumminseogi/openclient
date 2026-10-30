import XCTest
@testable import OpenClient

@MainActor
final class SessionCleanupTests: XCTestCase {
    private func session(_ id: String, parent: String? = nil, updated: Double? = nil) -> OpenCodeSession {
        var value = OpenCodeSession(id: id, title: id, workspaceID: nil, directory: "/project",
            projectID: "project", parentID: parent)
        value.time = .init(updated: updated)
        return value
    }

    func testRunningGrandchildProtectsEntireConversation() {
        let sessions = [session("root", updated: 1_000), session("child", parent: "root"),
                        session("grandchild", parent: "child"), session("other", updated: 2_000)]
        let result = SessionCleanupStore.candidates(sessions: sessions, statuses: ["grandchild": "busy"])
        XCTAssertEqual(result.map(\.id), ["other"])
    }

    func testRecentChildAndUnknownDatesAreNotSelectedByAge() {
        let store = SessionCleanupStore()
        store.candidates = SessionCleanupStore.candidates(sessions: [session("old", updated: 1_000),
            session("root", updated: 1_000), session("child", parent: "root", updated: 9_000), session("unknown")], statuses: [:])
        XCTAssertEqual(store.older(than: Date(timeIntervalSince1970: 5)).map(\.id), ["old"])
        XCTAssertEqual(store.candidates.first(where: { $0.id == "root" })?.memberIDs, ["root", "child"])
    }

    func testReviewQueuesDeletionAndUndoRestoresPreviousCard() {
        let store = SessionCleanupStore()
        store.candidates = SessionCleanupStore.candidates(sessions: [session("a", updated: 1_000), session("b", updated: 2_000)], statuses: [:])
        store.decide(delete: true)
        store.decide(delete: false)
        XCTAssertNil(store.current)
        XCTAssertEqual(store.pendingIDs, ["a"])
        XCTAssertEqual(store.candidates.count, 2)
        store.undo()
        XCTAssertEqual(store.current?.id, "b")
        store.undo()
        XCTAssertEqual(store.current?.id, "a")
        XCTAssertTrue(store.pendingIDs.isEmpty)
    }

    func testInventoryFollowsPagesAndDeletionRechecksNewChildActivity() async {
        let backend = CleanupTestBackend(records: [session("a", updated: 1_000), session("b", updated: 2_000)])
        var deleted: [String] = []
        let coordinator = SessionCleanupCoordinator(connection: backend.connection(), isCurrent: { true }, delete: {
            deleted.append($0.id)
            return true
        })
        await coordinator.load()
        XCTAssertEqual(coordinator.store.candidates.map(\.id), ["a", "b"])
        XCTAssertEqual(backend.pagesRead, 2)
        let targets = coordinator.store.candidates
        backend.records.append(session("new-child", parent: "a", updated: 3_000))
        backend.statuses["new-child"] = "busy"
        await coordinator.deleteCandidates(targets)
        XCTAssertEqual(deleted, ["b"])
        XCTAssertNotNil(coordinator.store.failures["a"])
        XCTAssertEqual(coordinator.store.progress, 2)
    }

    func testFailedDeleteDoesNotDiscardDecisionOrPreventRemainingDeletes() async {
        let backend = CleanupTestBackend(records: [session("a", updated: 1_000), session("b", updated: 2_000)])
        var attempted: [String] = []
        let coordinator = SessionCleanupCoordinator(connection: backend.connection(), isCurrent: { true }, delete: {
            attempted.append($0.id)
            return $0.id != "a"
        })
        await coordinator.load()
        coordinator.store.decide(delete: true)
        coordinator.store.decide(delete: true)
        await coordinator.deleteCandidates(coordinator.store.candidates)
        XCTAssertEqual(attempted, ["a", "b"])
        XCTAssertEqual(coordinator.store.pendingIDs, ["a"])
        XCTAssertEqual(coordinator.store.candidates.map(\.id), ["a"])
        XCTAssertNotNil(coordinator.store.failures["a"])
    }

    func testChangedConnectionCannotDeleteOldServerSessions() async {
        let backend = CleanupTestBackend(records: [session("a", updated: 1_000)])
        var current = true
        var attempted = false
        let coordinator = SessionCleanupCoordinator(connection: backend.connection(), isCurrent: { current }, delete: { _ in
            attempted = true
            return true
        })
        await coordinator.load()
        current = false
        await coordinator.deleteCandidates(coordinator.store.candidates)
        XCTAssertFalse(attempted)
        XCTAssertNotNil(coordinator.store.error)
        XCTAssertFalse(coordinator.store.isDeleting)
    }
}

@MainActor
private final class CleanupTestBackend: BackendProjectsService, BackendSessionsService, BackendChatService,
    BackendModelsService, BackendEventSource, BackendSessionActivityService {
    var records: [OpenCodeSession]
    var statuses: [String: String] = [:]
    var pagesRead = 0
    init(records: [OpenCodeSession]) { self.records = records }
    func connection() -> BackendConnection {
        BackendConnection(descriptor: .init(id: "cleanup-test", name: "Test", version: "1"),
            projects: self, sessions: self, chat: self, models: self, events: self, sessionActivity: self)
    }
    func projectsSnapshot() async throws -> BackendProjectsSnapshot {
        .init(projects: [.init(id: "project", worktree: "/project", vcs: nil, name: "Project", sandboxes: nil, icon: nil, time: nil)])
    }
    func sessions(scope: BackendScope, cursor: String?, limit: Int, roots: Bool) async throws -> BackendSessionPage {
        pagesRead += 1
        let index = cursor.flatMap(Int.init) ?? 0
        guard index < records.count else { return .init(sessions: []) }
        return .init(sessions: [records[index]], nextCursor: index + 1 < records.count ? String(index + 1) : nil)
    }
    func childSessions(parentID: String, scope: BackendScope, cursor: String?) async throws -> BackendSessionPage {
        .init(sessions: records.filter { $0.parentID == parentID })
    }
    func session(id: String, scope: BackendScope) async throws -> OpenCodeSession {
        guard let value = records.first(where: { $0.id == id }) else { throw BackendError.invalidScope }
        return value
    }
    func sessionStatuses(scope: BackendScope) async throws -> [String: String] { statuses }
    func transcript(sessionID: String, scope: BackendScope, cursor: String?, limit: Int) async throws -> BackendTranscriptPage { .init(messages: []) }
    func modelCatalog(scope: BackendScope) async throws -> BackendModelCatalog { .init() }
    func start(receive: @escaping @MainActor (BackendEvent) -> Void) { }
    func stop() { }
    func createSession(_ request: BackendSessionCreation) async throws -> OpenCodeSession { throw BackendError.invalidScope }
    func renameSession(id: String, title: String, scope: BackendScope) async throws -> OpenCodeSession { throw BackendError.invalidScope }
    func deleteSession(id: String, scope: BackendScope) async throws { throw BackendError.invalidScope }
    func searchSessions(query: String, scope: BackendScope, limit: Int) async throws -> [OpenCodeSession] { [] }
    func submit(_ request: BackendSubmission) async throws -> BackendAdmission { throw BackendError.invalidScope }
    func interrupt(sessionID: String, scope: BackendScope) async throws { }
}
