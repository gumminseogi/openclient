import XCTest
@testable import OpenClient

@MainActor
final class ActivityWorkflowManagementTests: XCTestCase {
    func testEditKeepsIdentityAndDeletionRedirectsStaleMetadataAcrossRelaunch() throws {
        let suite = "ActivityWorkflowManagementTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ActivityWorkflowStore(defaults: defaults)
        let source = try XCTUnwrap(store.createStatus(name: "Review", symbol: "circle", color: "blue"))
        let target = try XCTUnwrap(store.createStatus(name: "Ready", symbol: "circle.dashed", color: "green"))
        var session = Self.session("old", status: source)
        let edited = ActivityWorkflowStatus(id: source.id, name: "Reviewing", symbol: "circle.dotted", color: "purple")
        XCTAssertTrue(store.updateStatus(edited))
        XCTAssertEqual(store.status(for: session, serverID: "server"), edited)
        store.setCollapsed(true, for: source.id)
        store.assignLocally(source, sessionID: "local", serverID: "other-server")
        XCTAssertTrue(store.deleteStatus(edited, replacingWith: target))
        XCTAssertTrue(store.deleteStatus(target, replacingWith: .archived))
        let restored = ActivityWorkflowStore(defaults: defaults)
        XCTAssertEqual(restored.status(for: session, serverID: "server"), .archived)
        session = Self.session("local", status: nil)
        XCTAssertEqual(restored.status(for: session, serverID: "other-server"), .archived)
        XCTAssertEqual(restored.statuses(in: [session], serverID: "server"), [.inProgress, .archived])
        XCTAssertFalse(restored.collapsedStatusIDs.contains(source.id))
        XCTAssertFalse(restored.updateStatus(.inProgress))
        XCTAssertFalse(restored.deleteStatus(.archived, replacingWith: .inProgress))
        XCTAssertFalse(restored.deleteStatus(source, replacingWith: .inProgress))
    }

    func testDeletionEnumeratesUnloadedPagesAndKeepsSourceOnPartialFailure() async throws {
        let (model, facade, service, source) = try await fixture()
        defer { model.disconnect() }
        service.failWriteID = "b"
        do {
            try await facade.deleteWorkflowStatus(source, replacement: .archived)
            XCTFail("The status must remain available if any session move fails")
        } catch { }
        XCTAssertEqual(ActivityWorkflowStatus.annotation(in: try XCTUnwrap(service.records["a"])), .archived)
        XCTAssertEqual(ActivityWorkflowStatus.annotation(in: try XCTUnwrap(service.records["b"])), source)
        XCTAssertTrue(facade.workflowStatuses.contains { $0.id == source.id })
        XCTAssertFalse(facade.isManagingWorkflowStatus)
        XCTAssertTrue(service.requestedCursors.contains("1"), "Must read beyond Activity's loaded window")
        XCTAssertTrue(service.rootsArguments.allSatisfy { !$0 }, "Include explicitly annotated child sessions too")
        service.failWriteID = nil
        try await facade.deleteWorkflowStatus(source, replacement: .archived)
        XCTAssertFalse(facade.workflowStatuses.contains { $0.id == source.id })
        XCTAssertEqual(service.writeIDs.filter { $0 == "a" }.count, 1, "Retry must skip already-moved sessions")
        for session in service.records.values {
            XCTAssertEqual(ActivityWorkflowStatus.annotation(in: session), .archived)
            XCTAssertEqual(session.metadata?["other-client"], .string("preserve"))
        }
    }

    func testEditUpdatesAllMetadataAndRetainsStatusID() async throws {
        let (model, facade, service, source) = try await fixture()
        defer { model.disconnect() }
        try await facade.editWorkflowStatus(source, name: " Ready ", symbol: "circle.inset.filled", color: "green")
        let edited = try XCTUnwrap(facade.workflowStatuses.first { $0.id == source.id })
        XCTAssertEqual(edited.name, "Ready")
        XCTAssertEqual(edited.color, "green")
        XCTAssertEqual(service.writeIDs.sorted(), ["a", "b"])
        for session in service.records.values {
            XCTAssertEqual(ActivityWorkflowStatus.annotation(in: session), edited)
            XCTAssertEqual(session.metadata?["other-client"], .string("preserve"))
        }
    }

    func testDeletionDoesNotOverwriteConcurrentMoveByAnotherClient() async throws {
        let (model, facade, service, source) = try await fixture()
        defer { model.disconnect() }
        service.beforeFetch = { id in
            if id == "b" {
                let metadata = ActivityWorkflowStatus.inProgress.merging(into: service.records[id]?.metadata, sessionID: id)
                service.records[id]?.metadata = metadata
            }
        }
        try await facade.deleteWorkflowStatus(source, replacement: .archived)
        XCTAssertEqual(service.writeIDs, ["a"])
        XCTAssertEqual(ActivityWorkflowStatus.annotation(in: try XCTUnwrap(service.records["b"])), .inProgress)
    }

    func testRepeatedPaginationCursorDoesNotDeleteVocabulary() async throws {
        let (model, facade, service, source) = try await fixture()
        defer { model.disconnect() }
        service.repeatsCursor = true
        do {
            try await facade.deleteWorkflowStatus(source, replacement: .archived)
            XCTFail("Invalid pagination must fail before writing sessions")
        } catch { }
        XCTAssertTrue(service.writeIDs.isEmpty)
        XCTAssertTrue(facade.workflowStatuses.contains { $0.id == source.id })
    }

    private func fixture() async throws -> (AppViewModel, ActivityFacade, WorkflowManagementSessions, ActivityWorkflowStatus) {
        let base = HomeTestBackend()
        let model = AppViewModel(backendFactory: base)
        model.localCacheRepository = NoOpOpenCodeLocalCacheRepository()
        let store = ActivityWorkflowStore(persists: false)
        let source = try XCTUnwrap(store.createStatus(name: "Review", symbol: "circle", color: "blue"))
        let service = WorkflowManagementSessions(records: ["a": Self.session("a", status: source), "b": Self.session("b", status: source)])
        model.backendConnection = BackendConnection(descriptor: .init(id: "workflow-management", name: "Test", version: "1"),
            projects: base, sessions: service, chat: base, models: base, events: base)
        model.connectionStore.applySuccessfulServerConnection(version: "1", healthy: true)
        model.projects = try await base.projectsSnapshot().projects
        // No Activity hydration: both sessions are deliberately outside the rendered snapshot.
        return (model, ActivityFacade(viewModel: model, workflow: store), service, source)
    }

    private static func session(_ id: String, status: ActivityWorkflowStatus?) -> OpenCodeSession {
        var session = OpenCodeSession(id: id, title: id, workspaceID: nil, directory: "/home-project", projectID: "home-project", parentID: id == "b" ? "a" : nil)
        session.metadata = status?.merging(into: ["other-client": .string("preserve")], sessionID: id)
        return session
    }
}

@MainActor
private final class WorkflowManagementSessions: BackendSessionsService, BackendSessionAnnotationsService {
    var records: [String: OpenCodeSession]
    var failWriteID: String?
    var beforeFetch: ((String) -> Void)?
    var repeatsCursor = false
    var writeIDs: [String] = []
    var requestedCursors: [String?] = []
    var rootsArguments: [Bool] = []
    init(records: [String: OpenCodeSession]) { self.records = records }
    var supportsSessionAnnotations: Bool { true }
    func sessions(scope: BackendScope, cursor: String?, limit: Int, roots: Bool) async throws -> BackendSessionPage {
        requestedCursors.append(cursor)
        rootsArguments.append(roots)
        let matching = records.values.filter { $0.directory == scope.directory }.sorted { $0.id < $1.id }
        let index = Int(cursor ?? "0") ?? 0
        return .init(sessions: Array(matching.dropFirst(index).prefix(1)),
            nextCursor: repeatsCursor ? "1" : index + 1 < matching.count ? String(index + 1) : nil)
    }
    func session(id: String, scope: BackendScope) async throws -> OpenCodeSession {
        beforeFetch?(id)
        return try XCTUnwrap(records[id])
    }
    func setSessionMetadata(id: String, metadata: [String: OpenCodeJSONValue]) async throws -> OpenCodeSession {
        if id == failWriteID { throw URLError(.cannotConnectToHost) }
        writeIDs.append(id)
        records[id]?.metadata = metadata
        return try XCTUnwrap(records[id])
    }
    func createSession(_ request: BackendSessionCreation) async throws -> OpenCodeSession { throw BackendError.invalidScope }
    func renameSession(id: String, title: String, scope: BackendScope) async throws -> OpenCodeSession { throw BackendError.invalidScope }
    func deleteSession(id: String, scope: BackendScope) async throws { throw BackendError.invalidScope }
    func searchSessions(query: String, scope: BackendScope, limit: Int) async throws -> [OpenCodeSession] { [] }
}
