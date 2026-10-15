import XCTest
@testable import OpenClient

@MainActor
final class ActivityWorkflowTests: XCTestCase {
    func testCollapsedSectionsSurviveRelaunchAndExpansionIsSaved() throws {
        let suite = "ActivityWorkflowTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ActivityWorkflowStore(defaults: defaults)
        let custom = try XCTUnwrap(store.createStatus(name: "Review", symbol: "circle", color: "blue"))
        store.setCollapsed(true, for: "archived")
        store.setCollapsed(true, for: custom.id)
        let reloaded = ActivityWorkflowStore(defaults: defaults)
        XCTAssertEqual(reloaded.collapsedStatusIDs, ["archived", custom.id])
        reloaded.setCollapsed(false, for: "archived")
        XCTAssertEqual(ActivityWorkflowStore(defaults: defaults).collapsedStatusIDs, [custom.id])
    }

    func testPreCollapsePreferencesKeepTheirStatusesAndAssignments() throws {
        let suite = "ActivityWorkflowTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ActivityWorkflowStore(defaults: defaults, now: Date(timeIntervalSince1970: 100))
        let custom = try XCTUnwrap(store.createStatus(name: "Review", symbol: "circle", color: "blue"))
        store.assignLocally(custom, sessionID: "session", serverID: "server")
        store.setLayout(.list)
        let data = try XCTUnwrap(defaults.data(forKey: "activityWorkflow.v1"))
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "collapsedStatusIDs")
        defaults.set(try JSONSerialization.data(withJSONObject: legacy), forKey: "activityWorkflow.v1")
        let reloaded = ActivityWorkflowStore(defaults: defaults, now: Date(timeIntervalSince1970: 200))
        let session = OpenCodeSession(id: "session", title: nil, workspaceID: nil, directory: nil, projectID: nil, parentID: nil)
        XCTAssertTrue(reloaded.collapsedStatusIDs.isEmpty)
        XCTAssertEqual(reloaded.layout, .list)
        XCTAssertEqual(reloaded.status(for: session, serverID: "server"), custom)
        XCTAssertEqual(reloaded.statuses(in: [], serverID: "server"), [.inProgress, custom, .archived])
    }

    func testMigrationDefaultsPersistAndAssignmentsAreServerScoped() throws {
        let suite = "ActivityWorkflowTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ActivityWorkflowStore(defaults: defaults, now: Date(timeIntervalSince1970: 100))
        var session = OpenCodeSession(id: "same-id", title: nil, workspaceID: nil, directory: "/repo", projectID: nil, parentID: nil)
        session.time = .init(created: 99_000)
        XCTAssertEqual(store.status(for: session, serverID: "a"), .archived)
        session.time = .init(created: 101_000)
        XCTAssertEqual(store.status(for: session, serverID: "a"), .inProgress)
        store.assignLocally(.archived, sessionID: session.id, serverID: "a")
        XCTAssertEqual(store.status(for: session, serverID: "a"), .archived)
        XCTAssertEqual(store.status(for: session, serverID: "b"), .inProgress)
        let reloaded = ActivityWorkflowStore(defaults: defaults, now: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(reloaded.status(for: session, serverID: "b"), .inProgress, "Relaunch must not reclassify new sessions")
        session.metadata = ActivityWorkflowStatus.inProgress.merging(into: nil)
        XCTAssertEqual(reloaded.status(for: session, serverID: "a"), .inProgress, "Canonical metadata wins over fallback")
    }

    func testCustomStatusTravelsWithMetadataAndPreservesOtherAnnotations() throws {
        let suite = "ActivityWorkflowTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ActivityWorkflowStore(defaults: defaults)
        let status = try XCTUnwrap(store.createStatus(name: " Review ", symbol: "circle.dashed", color: "purple"))
        XCTAssertEqual(status.name, "Review")
        var session = OpenCodeSession(id: "review", title: nil, workspaceID: nil, directory: nil, projectID: nil, parentID: nil)
        session.metadata = status.merging(into: ["other-client": .object(["value": .bool(true)])])
        XCTAssertEqual(session.metadata?["other-client"], .object(["value": .bool(true)]))
        let decoded = try JSONDecoder().decode(OpenCodeSession.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(ActivityWorkflowStatus.annotation(in: decoded), status)
        XCTAssertEqual(store.statuses(in: [session], serverID: "server").map(\.id), ["in-progress", status.id, "archived"])
        XCTAssertNil(store.createStatus(name: "  ", symbol: "circle", color: "blue"))
    }

    func testNewForkDoesNotInheritItsSourcesArchivedAssignment() throws {
        let suite = "ActivityWorkflowTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ActivityWorkflowStore(defaults: defaults, now: Date(timeIntervalSince1970: 100))
        var fork = OpenCodeSession(id: "fork", title: nil, workspaceID: nil, directory: nil, projectID: nil, parentID: nil)
        fork.time = .init(created: 101_000)
        fork.metadata = ActivityWorkflowStatus.archived.merging(into: nil, sessionID: "source")
        XCTAssertEqual(store.status(for: fork, serverID: "server"), .inProgress)
        let newDevice = ActivityWorkflowStore(now: Date(timeIntervalSince1970: 200), persists: false)
        XCTAssertEqual(newDevice.status(for: fork, serverID: "server"), .inProgress)
        fork.metadata = ActivityWorkflowStatus.archived.merging(into: fork.metadata, sessionID: "fork")
        XCTAssertEqual(store.status(for: fork, serverID: "server"), .archived)
    }

    func testMetadataEventsSurviveRenameAndRejectMalformedReplacement() throws {
        let store = DirectoryStore()
        var session = OpenCodeSession(id: "ses_status", title: "Test", workspaceID: nil, directory: "/repo", projectID: "p", parentID: nil)
        session.metadata = ActivityWorkflowStatus.inProgress.merging(into: nil)
        store.insertV2Session(session)
        func event(_ type: String, _ fields: String) throws -> OpenCodeV2ManagedEvent {
            try XCTUnwrap(OpenCodeEventManager.decodeV2Event(from:
                #"{"type":"\#(type)","location":{"directory":"/repo"},"data":{"sessionID":"ses_status",\#(fields)}}"#))
        }
        let raw = String(data: try JSONEncoder().encode(ActivityWorkflowStatus.archived.merging(into: ["extra": .string("keep")])), encoding: .utf8)!
        XCTAssertTrue(store.applyV2Event(try event("session.metadata.updated", "\"metadata\":\(raw)")))
        XCTAssertTrue(store.applyV2Event(try event("session.renamed", #""title":"Renamed""#)))
        XCTAssertEqual(ActivityWorkflowStatus.annotation(in: try XCTUnwrap(store.sessions.first)), .archived)
        XCTAssertEqual(store.sessions.first?.metadata?["extra"], .string("keep"))
        XCTAssertFalse(store.applyV2Event(try event("session.metadata.updated", #""metadata":[]"#)))
        XCTAssertEqual(store.sessions.first?.metadata?["extra"], .string("keep"))
    }
}
