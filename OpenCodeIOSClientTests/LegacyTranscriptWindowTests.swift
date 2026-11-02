import Foundation
import XCTest
@testable import OpenClient

@MainActor
final class LegacyTranscriptWindowTests: XCTestCase {
    private static let session = OpenCodeSession(id: "ses_window", title: "Window", workspaceID: nil,
        directory: "/repo", projectID: "project", parentID: nil)

    override func tearDown() async throws {
        LegacyWindowURLProtocol.handler = nil
    }

    func testOnlyCanonicalWindowsWithTheCurrentOpenStreamEpochCanBeReused() {
        let registry = DirectoryStoreRegistry(activeDirectory: "/repo")
        let owner = registry.activeStore
        let id = Self.session.id
        registry.receiveLegacyStreamStatus("stream open status=200")
        XCTAssertFalse(LegacyTranscriptCoordinator.needsCompleteInventory(window: nil,
            streamIsOpen: registry.legacyStreamIsOpen, continuityEpoch: registry.legacyContinuityEpoch))
        for archive in [false, true] {
            owner.recordLegacyCachedWindow(sessionID: id, hasOlderMessages: true, isArchive: archive)
            XCTAssertFalse(registry.canReuseLegacyTranscript(owner.legacyTranscriptWindows[id]))
            XCTAssertFalse(LegacyTranscriptCoordinator.needsCompleteInventory(window: owner.legacyTranscriptWindows[id],
                streamIsOpen: registry.legacyStreamIsOpen, continuityEpoch: registry.legacyContinuityEpoch))
        }
        owner.recordLegacyCanonicalWindow(sessionID: id, hasOlderMessages: true,
            continuityEpoch: registry.legacyContinuityEpoch)
        let canonical = owner.legacyTranscriptWindows[id]
        XCTAssertTrue(registry.canReuseLegacyTranscript(canonical))
        registry.receiveLegacyStreamStatus("stream reconnecting")
        XCTAssertFalse(registry.canReuseLegacyTranscript(canonical))
        XCTAssertTrue(LegacyTranscriptCoordinator.needsCompleteInventory(window: canonical,
            streamIsOpen: registry.legacyStreamIsOpen, continuityEpoch: registry.legacyContinuityEpoch))
        registry.receiveLegacyStreamStatus("stream open status=200")
        XCTAssertFalse(registry.canReuseLegacyTranscript(canonical), "Opening a new stream does not repair a missed interval.")
        owner.recordLegacyCanonicalWindow(sessionID: id, hasOlderMessages: true,
            continuityEpoch: registry.legacyContinuityEpoch)
        let beforeReset = owner.legacyTranscriptWindows[id]
        XCTAssertTrue(registry.canReuseLegacyTranscript(beforeReset))
        registry.reset()
        registry.receiveLegacyStreamStatus("stream open status=200")
        XCTAssertFalse(registry.canReuseLegacyTranscript(beforeReset), "A previous registry lifetime cannot authorize reuse.")
    }

    func testDiskPreviewAndArchiveDoNotPromoteProvisionalHistoryOrForceAFullRead() async throws {
        for archive in [false, true] {
            let model = makeModel()
            defer { model.backendConnection?.close() }
            let provisional = try Self.messages(0..<600, text: "provisional")
            model.directoryStore.applyCanonicalMessages(provisional, forSessionID: Self.session.id)
            model.chatStore.applyCanonicalMessages(provisional, forSessionID: Self.session.id, isActiveSession: true)
            model.directoryStore.recordLegacyCachedWindow(sessionID: Self.session.id, hasOlderMessages: true, isArchive: archive)
            var reads = 0
            LegacyWindowURLProtocol.handler = { request in
                XCTAssertEqual(request.url?.path, Self.messagesPath)
                XCTAssertEqual(Self.query(request)["limit"], "400")
                XCTAssertNil(Self.query(request)["before"])
                reads += 1
                return (200, [:], try Self.body(600..<1000, text: "server"))
            }
            _ = try await model.loadMessages(for: Self.session, prefetchToolDetails: false, refreshTodos: false)
            XCTAssertEqual(reads, 1)
            XCTAssertEqual(model.messages.count, 400)
            XCTAssertEqual(model.messages.first?.id, "msg_600")
            XCTAssertFalse(model.messages.contains { $0.id == "msg_100" })
            XCTAssertTrue(model.directoryStoreRegistry.canReuseLegacyTranscript(model.directoryStore.legacyTranscriptWindows[Self.session.id]))
            XCTAssertTrue(model.chatStore.hasOlderMessages(forSessionID: Self.session.id))
        }
    }

    func testWarmNewNavigationUsesTheCanonicalWindowWithoutAnotherHTTPRead() async throws {
        let model = makeModel()
        defer { model.backendConnection?.close() }
        var reads = 0
        LegacyWindowURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, Self.messagesPath)
            XCTAssertEqual(Self.query(request)["limit"], "400")
            reads += 1
            return (200, [:], try Self.body(100..<500))
        }
        try await model.chatFacade.loadInitialMessages(for: Self.session, prefetchToolDetails: false, refreshTodos: false)
        XCTAssertEqual(reads, 1)
        let firstGeneration = model.sessionNavigationGeneration
        _ = model.beginSessionNavigation(Self.session)
        model.prepareSessionSelection(Self.session, preservingDraftForSessionID: nil,
            animatesChanges: false, restoresDraft: false)
        XCTAssertGreaterThan(model.sessionNavigationGeneration, firstGeneration)
        try await model.chatFacade.loadInitialMessages(for: Self.session, prefetchToolDetails: false, refreshTodos: false)
        XCTAssertEqual(reads, 1, "This must exercise a new navigation, not just reuse the completed initial task.")
        XCTAssertEqual(model.directoryStore.syncStore.messageCount(forSessionID: Self.session.id), 400)
        XCTAssertFalse(model.chatStore.isLoadingSelectedSession)
    }

    func testReconnectWithinTheSameNavigationCannotReuseTheCompletedInitialTask() async throws {
        let model = makeModel()
        defer { model.backendConnection?.close() }
        var limits: [String?] = []
        LegacyWindowURLProtocol.handler = { request in
            let limit = Self.query(request)["limit"]
            limits.append(limit)
            return (200, [:], try Self.body(limit == nil ? 0..<500 : 100..<500))
        }
        try await model.chatFacade.loadInitialMessages(for: Self.session, prefetchToolDetails: false, refreshTodos: false)
        let generation = model.sessionNavigationGeneration
        model.handleBackendEvent(.status("stream reconnecting"))
        model.handleBackendEvent(.status("stream open status=200"))
        try await model.chatFacade.loadInitialMessages(for: Self.session, prefetchToolDetails: false, refreshTodos: false)
        XCTAssertEqual(model.sessionNavigationGeneration, generation)
        XCTAssertEqual(limits, ["400", nil])
        XCTAssertEqual(model.messages.count, 500)
        XCTAssertTrue(model.directoryStoreRegistry.canReuseLegacyTranscript(model.directoryStore.legacyTranscriptWindows[Self.session.id]))
    }

    func testHealthyRefreshFetchesOnlyFourHundredAndPreservesOlderMessagesAndContinuation() async throws {
        let defaults = UserDefaults.standard
        let originalServers = defaults.object(forKey: "recentServerConfigs")
        let originalDrafts = defaults.object(forKey: OpenClientStorageKey.messageDraftsByChat)
        defer {
            defaults.set(originalServers, forKey: "recentServerConfigs")
            defaults.set(originalDrafts, forKey: OpenClientStorageKey.messageDraftsByChat)
        }
        let model = makeModel(persistenceEnabled: true)
        defer { model.backendConnection?.close() }
        let repository = try OpenCodeLocalCacheRepositoryFactory.makeInMemory()
        model.localCacheRepository = repository
        let namespace = try XCTUnwrap(model.localCacheNamespace)
        var deleted = false
        var limits: [String?] = []
        LegacyWindowURLProtocol.handler = { request in
            let query = Self.query(request)
            limits.append(query["limit"])
            XCTAssertNil(query["before"])
            let limit = try XCTUnwrap(Int(try XCTUnwrap(query["limit"])))
            let ids = (0..<1000).filter { !deleted || $0 != 900 }
            return (200, [:], try Self.body(ids.suffix(limit)))
        }
        _ = try await model.loadMessages(for: Self.session, prefetchToolDetails: false, refreshTodos: false)
        let added = await model.loadOlderMessages(for: Self.session, count: 400)
        XCTAssertEqual(added, 400)
        XCTAssertEqual(model.directoryStore.syncStore.messageCount(forSessionID: Self.session.id), 800)
        deleted = true
        _ = try await model.loadMessages(for: Self.session, prefetchToolDetails: false, refreshTodos: false)
        XCTAssertEqual(model.messages.count, 799)
        XCTAssertTrue(model.messages.contains { $0.id == "msg_200" }, "A limited newest page must retain validated older history.")
        XCTAssertFalse(model.messages.contains { $0.id == "msg_900" }, "The replaced newest suffix must honor covered deletions.")
        _ = await model.loadOlderMessages(for: Self.session, count: 400)
        XCTAssertEqual(limits, ["400", "800", "400", "1200"], "Refreshing must not reset the older-history continuation to 400.")
        XCTAssertEqual(model.messages.count, 999)
        XCTAssertFalse(model.chatStore.hasOlderMessages(forSessionID: Self.session.id))
        for task in Array(model.localCacheWriteTasksByKey.values) { await task.value }
        let snapshot = try await repository.loadChat(serverID: namespace, sessionID: Self.session.id)
        let cached = try XCTUnwrap(snapshot)
        XCTAssertEqual(cached.messages.count, 999, "A terminal older page must persist the full archive, not just its 400-message preview.")
        XCTAssertEqual(cached.messages.first?.id, "msg_0")
        XCTAssertFalse(cached.messages.contains { $0.id == "msg_900" })
    }

    func testInactiveIntervalRecoversMoreThanAWindowOfMessagesAndAnOldDeletion() async throws {
        let model = makeModel()
        defer { model.backendConnection?.close() }
        var suspended = false
        var limits: [String?] = []
        LegacyWindowURLProtocol.handler = { request in
            let query = Self.query(request)
            limits.append(query["limit"])
            XCTAssertNil(query["before"])
            if suspended {
                XCTAssertNil(query["limit"], "A fixed newest window cannot prove the old deletion or fill a large gap.")
                return (200, [:], try Self.body((0..<1000).filter { $0 != 100 }, text: "after suspension"))
            }
            XCTAssertEqual(query["limit"], "400")
            return (200, [:], try Self.body(50..<450))
        }
        _ = try await model.loadMessages(for: Self.session, prefetchToolDetails: false, refreshTodos: false)
        XCTAssertTrue(model.messages.contains { $0.id == "msg_100" })
        suspended = true
        model.applicationActivityChanged(isActive: false)
        model.applicationActivityChanged(isActive: true)
        _ = try await model.loadMessages(for: Self.session, prefetchToolDetails: false, refreshTodos: false)
        XCTAssertEqual(limits, ["400", nil])
        XCTAssertEqual(model.messages.count, 999)
        XCTAssertFalse(model.messages.contains { $0.id == "msg_100" })
        XCTAssertTrue(model.messages.contains { $0.id == "msg_0" })
        XCTAssertTrue((450..<1000).allSatisfy { id in model.messages.contains { $0.id == "msg_\(id)" } })
        XCTAssertFalse(model.chatStore.hasOlderMessages(forSessionID: Self.session.id))
    }

    func testHTTPResponseCannotOverwriteSSEChangesResurrectDeletedMessagesOrLoseNewMessages() async throws {
        let model = makeModel()
        defer { model.backendConnection?.close() }
        LegacyWindowURLProtocol.handler = { _ in (200, [:], try Self.body(0..<3, text: "initial")) }
        _ = try await model.loadMessages(for: Self.session, prefetchToolDetails: false, refreshTodos: false)
        let requested = expectation(description: "Canonical HTTP response is suspended")
        var release: CheckedContinuation<Void, Never>?
        LegacyWindowURLProtocol.handler = { _ in
            await withCheckedContinuation { release = $0; requested.fulfill() }
            return (200, [:], try Self.body(0..<3, text: "stale HTTP"))
        }
        let read = Task {
            try await model.loadMessages(for: Self.session, prefetchToolDetails: false, refreshTodos: false)
        }
        defer { read.cancel(); release?.resume() }
        await fulfillment(of: [requested], timeout: 2)
        var changed = try XCTUnwrap(model.messages.first { $0.id == "msg_1" }?.parts.first)
        changed.text = "live SSE text"
        model.handleManagedEvent(try BackendMutationBridge.managed(directory: "/repo", event: .messagePartUpdated(changed)))
        model.handleManagedEvent(try BackendMutationBridge.managed(directory: "/repo",
            event: .messageRemoved(sessionID: Self.session.id, messageID: "msg_2")))
        let added = try XCTUnwrap(Self.messages([3], text: "new SSE").first)
        model.handleManagedEvent(try BackendMutationBridge.managed(directory: "/repo", event: .messageUpdated(added.info)))
        model.handleManagedEvent(try BackendMutationBridge.managed(directory: "/repo", event: .messagePartUpdated(added.parts[0])))
        model.flushBufferedTranscript(reason: "legacy window test events")
        let continuation = release
        release = nil
        continuation?.resume()
        _ = try await read.value
        XCTAssertEqual(Set(model.messages.map(\.id)), ["msg_0", "msg_1", "msg_3"])
        XCTAssertEqual(model.messages.first { $0.id == "msg_1" }?.parts.first?.text, "live SSE text")
        XCTAssertEqual(model.messages.first { $0.id == "msg_3" }?.parts.first?.text, "new SSE")
        XCTAssertEqual(model.directoryStore.syncState.messageEnvelopes(forSessionID: Self.session.id), model.messages)
    }

    func testLateOlderHTTPResponseCannotReplaceANewerCanonicalReadWithoutSSE() async throws {
        let model = makeModel()
        defer { model.backendConnection?.close() }
        let requested = expectation(description: "Older HTTP request is suspended")
        var release: CheckedContinuation<Void, Never>?
        var reads = 0
        LegacyWindowURLProtocol.handler = { _ in
            reads += 1
            if reads == 1 {
                await withCheckedContinuation { release = $0; requested.fulfill() }
                return (200, [:], try Self.body([0], text: "late stale HTTP"))
            }
            return (200, [:], try Self.body([1], text: "newer HTTP"))
        }
        let older = Task {
            try await model.loadMessages(for: Self.session, prefetchToolDetails: false, refreshTodos: false)
        }
        defer { older.cancel(); release?.resume() }
        await fulfillment(of: [requested], timeout: 2)
        _ = try await model.loadMessages(for: Self.session, prefetchToolDetails: false, refreshTodos: false)
        let continuation = release
        release = nil
        continuation?.resume()
        _ = try await older.value
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(model.messages.map(\.id), ["msg_1"])
        XCTAssertEqual(model.messages.first?.parts.first?.text, "newer HTTP")
    }

    func testMessageRemovedDuringHTTPReadIsNotResurrectedWhenAbsentFromInitialMemory() async throws {
        let model = makeModel()
        defer { model.backendConnection?.close() }
        LegacyWindowURLProtocol.handler = { _ in (200, [:], try Self.body([0], text: "initial")) }
        _ = try await model.loadMessages(for: Self.session, prefetchToolDetails: false, refreshTodos: false)
        let requested = expectation(description: "HTTP contains a message that has not been loaded yet")
        var release: CheckedContinuation<Void, Never>?
        LegacyWindowURLProtocol.handler = { _ in
            await withCheckedContinuation { release = $0; requested.fulfill() }
            return (200, [:], try Self.body([0, 98, 99], text: "canonical HTTP"))
        }
        let read = Task {
            try await model.loadMessages(for: Self.session, prefetchToolDetails: false, refreshTodos: false)
        }
        defer { read.cancel(); release?.resume() }
        await fulfillment(of: [requested], timeout: 2)
        XCTAssertFalse(model.messages.contains { $0.id == "msg_99" })
        model.handleManagedEvent(try BackendMutationBridge.managed(directory: "/repo",
            event: .messageRemoved(sessionID: Self.session.id, messageID: "msg_99")))
        model.flushBufferedTranscript(reason: "unknown message removal during HTTP")
        let continuation = release
        release = nil
        continuation?.resume()
        _ = try await read.value
        XCTAssertEqual(model.messages.map(\.id), ["msg_0", "msg_98"])
        XCTAssertEqual(model.messages.first?.parts.first?.text, "canonical HTTP")
        XCTAssertEqual(model.directoryStore.syncState.messageEnvelopes(forSessionID: Self.session.id), model.messages)
    }

    func testPartRemovedDuringHTTPReadIsNotResurrectedWhenItsMessageIsNotInMemory() async throws {
        for includesSessionID in [false, true] {
            let model = makeModel()
            defer { model.backendConnection?.close() }
            LegacyWindowURLProtocol.handler = { _ in (200, [:], try Self.body([0], text: "initial")) }
            _ = try await model.loadMessages(for: Self.session, prefetchToolDetails: false, refreshTodos: false)
            let requested = expectation(description: "HTTP contains an unseen message part, sessionID=\(includesSessionID)")
            var release: CheckedContinuation<Void, Never>?
            LegacyWindowURLProtocol.handler = { _ in
                await withCheckedContinuation { release = $0; requested.fulfill() }
                return (200, [:], try Self.body([0, 99], text: "canonical HTTP"))
            }
            let read = Task {
                try await model.loadMessages(for: Self.session, prefetchToolDetails: false, refreshTodos: false)
            }
            defer { read.cancel(); release?.resume() }
            await fulfillment(of: [requested], timeout: 2)
            var properties = ["messageID": "msg_99", "partID": "prt_99"]
            if includesSessionID { properties["sessionID"] = Self.session.id }
            let data = try JSONSerialization.data(withJSONObject: ["directory": "/repo",
                "payload": ["type": "message.part.removed", "properties": properties]])
            guard case let .event(event) = OpenCodeEventManager.decodeManagedEvent(from: String(decoding: data, as: UTF8.self)) else {
                XCTFail("A valid part removal did not decode.")
                return
            }
            model.handleManagedEvent(event)
            model.flushBufferedTranscript(reason: "unknown part removal during HTTP")
            let continuation = release
            release = nil
            continuation?.resume()
            _ = try await read.value
            XCTAssertEqual(model.messages.map(\.id), ["msg_0", "msg_99"])
            XCTAssertEqual(model.messages.first?.parts.first?.id, "prt_0")
            XCTAssertTrue(try XCTUnwrap(model.messages.first { $0.id == "msg_99" }).parts.isEmpty)
            XCTAssertEqual(model.directoryStore.syncState.messageEnvelopes(forSessionID: Self.session.id), model.messages)
        }
    }

    func testDroppedTranscriptAndMalformedEventsInvalidateButUnknownNonTranscriptEventsDoNot() async throws {
        let model = makeModel()
        defer { model.backendConnection?.close() }
        model.directoryStore.recordLegacyCanonicalWindow(sessionID: Self.session.id, hasOlderMessages: true,
            continuityEpoch: model.directoryStoreRegistry.legacyContinuityEpoch)
        let window = model.directoryStore.legacyTranscriptWindows[Self.session.id]
        let initialEpoch = model.directoryStoreRegistry.legacyContinuityEpoch
        let rawHeartbeat = #"{"directory":"/repo","payload":{"type":"server.unknown-heartbeat","properties":{}}}"#
        guard case let .event(heartbeat) = OpenCodeEventManager.decodeManagedEvent(from: rawHeartbeat),
              case .unknown("server.unknown-heartbeat") = heartbeat.typed else {
            return XCTFail("Unknown extensions must remain valid typed events.")
        }
        model.handleManagedEvent(heartbeat)
        XCTAssertEqual(model.directoryStoreRegistry.legacyContinuityEpoch, initialEpoch)
        XCTAssertTrue(model.directoryStoreRegistry.canReuseLegacyTranscript(window))
        let missingPart = Self.droppedDiagnostic(#"{"directory":"/repo","payload":{"type":"message.part.updated","properties":{}}}"#)
        model.handleBackendEvent(.diagnostic(try XCTUnwrap(missingPart)))
        XCTAssertFalse(model.directoryStoreRegistry.canReuseLegacyTranscript(window))
        let afterDrop = model.directoryStoreRegistry.legacyContinuityEpoch
        model.handleBackendEvent(.diagnostic(try XCTUnwrap(Self.droppedDiagnostic("{"))))
        XCTAssertGreaterThan(model.directoryStoreRegistry.legacyContinuityEpoch, afterDrop)
    }

    func testCompleteInventoryFollowsRealServerContinuationsAndDeduplicatesBoundaries() async throws {
        let model = makeModel()
        defer { model.backendConnection?.close() }
        var cursors: [String?] = []
        var limits: [String?] = []
        LegacyWindowURLProtocol.handler = { request in
            let query = Self.query(request)
            cursors.append(query["before"])
            limits.append(query["limit"])
            XCTAssertEqual(query["directory"], "/repo")
            switch query["before"] {
            case nil: return (200, ["X-Next-Cursor": "older-1"], try Self.body([20, 30]))
            case "older-1": return (200, ["X-Next-Cursor": "older-2"], try Self.body([10, 20]))
            case "older-2": return (200, [:], try Self.body([0, 10]))
            default: XCTFail("Unexpected inventory continuation"); return (400, [:], Data("{}".utf8))
            }
        }
        let page = try await LegacyTranscriptCoordinator.read(connection: XCTUnwrap(model.backendConnection),
            session: Self.session, completeInventory: true)
        XCTAssertEqual(page.messages.map(\.id), ["msg_0", "msg_10", "msg_20", "msg_30"])
        XCTAssertNil(page.olderCursor)
        XCTAssertEqual(cursors, [nil, "older-1", "older-2"])
        XCTAssertEqual(limits, [nil, "400", "400"])
    }

    func testRepeatedInventoryContinuationFailsInsteadOfAcceptingPartialInventory() async throws {
        let model = makeModel()
        defer { model.backendConnection?.close() }
        var reads = 0
        LegacyWindowURLProtocol.handler = { _ in
            reads += 1
            return (200, ["X-Next-Cursor": "repeated"], try Self.body([reads]))
        }
        do {
            _ = try await LegacyTranscriptCoordinator.read(connection: XCTUnwrap(model.backendConnection),
                session: Self.session, completeInventory: true)
            XCTFail("A looping partial inventory was accepted as complete.")
        } catch OpenCodeAPIError.invalidResponse {
        }
        XCTAssertEqual(reads, 2)
    }

    private func makeModel(persistenceEnabled: Bool = false) -> AppViewModel {
        let config = OpenCodeServerConfig(baseURL: "https://legacy-window.invalid",
            username: "opencode", password: "test-password", apiPreference: .legacy)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LegacyWindowURLProtocol.self]
        let client = OpenCodeAPIClient(config: config, session: URLSession(configuration: configuration))
        let factory = OpenCodeBackendFactory(client: client, eventManager: OpenCodeEventManager())
        let model = persistenceEnabled ? AppViewModel() : AppViewModel(backendFactory: factory)
        model.config = config
        model.backendConnection = factory.makeConnection(profile: .legacy, version: "1", healthy: true)
        model.connectionStore.applySuccessfulServerConnection(version: "1", healthy: true)
        model.localCacheRepository = NoOpOpenCodeLocalCacheRepository()
        model.directoryStoreRegistry.activate("/repo")
        model.directoryStore.insertV2Session(Self.session)
        _ = model.beginSessionNavigation(Self.session)
        model.prepareSessionSelection(Self.session, preservingDraftForSessionID: nil,
            animatesChanges: false, restoresDraft: false)
        model.handleBackendEvent(.status("stream open status=200"))
        return model
    }

    private static let messagesPath = "/session/ses_window/message"

    private static func query(_ request: URLRequest) -> [String: String] {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.compactMap { item in item.value.map { (item.name, $0) } },
            uniquingKeysWith: { _, value in value })
    }

    private static func body<S: Sequence>(_ ids: S, text: String = "server") throws -> Data where S.Element == Int {
        let messages: [[String: Any]] = ids.map { id in
            let info: [String: Any] = ["id": "msg_\(id)", "sessionID": session.id,
                                       "role": "user", "time": ["created": id]]
            let part: [String: Any] = ["id": "prt_\(id)", "messageID": "msg_\(id)", "sessionID": session.id,
                                       "type": "text", "text": text]
            return ["info": info, "parts": [part]]
        }
        return try JSONSerialization.data(withJSONObject: messages)
    }

    private static func messages<S: Sequence>(_ ids: S, text: String) throws -> [OpenCodeMessageEnvelope] where S.Element == Int {
        try JSONDecoder().decode([OpenCodeMessageEnvelope].self, from: body(ids, text: text))
    }

    private static func droppedDiagnostic(_ raw: String) -> String? {
        guard case let .dropped(message) = OpenCodeEventManager.decodeManagedEvent(from: raw) else {
            XCTFail("Malformed or unknown event unexpectedly decoded as a typed event.")
            return nil
        }
        return message
    }
}

private final class LegacyWindowURLProtocol: URLProtocol {
    @MainActor static var handler: (@MainActor (URLRequest) async throws -> (Int, [String: String], Data))?
    private struct Delivery: @unchecked Sendable { let loader: LegacyWindowURLProtocol }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "legacy-window.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let request = request
        let delivery = Delivery(loader: self)
        Task { @MainActor in
            do {
                let handler = try XCTUnwrap(Self.handler)
                let (status, headers, data) = try await handler(request)
                let response = try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: status,
                    httpVersion: nil, headerFields: headers.merging(["Content-Type": "application/json"], uniquingKeysWith: { value, _ in value })))
                delivery.loader.client?.urlProtocol(delivery.loader, didReceive: response, cacheStoragePolicy: .notAllowed)
                delivery.loader.client?.urlProtocol(delivery.loader, didLoad: data)
                delivery.loader.client?.urlProtocolDidFinishLoading(delivery.loader)
            } catch {
                delivery.loader.client?.urlProtocol(delivery.loader, didFailWithError: error)
            }
        }
    }
    override func stopLoading() {}
}
