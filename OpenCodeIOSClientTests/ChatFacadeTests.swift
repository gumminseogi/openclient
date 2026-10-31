import Combine
import XCTest
@testable import OpenClient

@MainActor
final class InitialChatHydrationTests: XCTestCase {
    private var originalDrafts: Data?
    private let session = OpenCodeSession(id: "ses_initial", title: "Initial", workspaceID: nil,
        directory: "/repo", projectID: "project", parentID: nil)

    override func setUp() async throws {
        originalDrafts = UserDefaults.standard.data(forKey: OpenClientStorageKey.messageDraftsByChat)
    }

    override func tearDown() async throws {
        InitialHydrationURLProtocol.handler = nil
        UserDefaults.standard.set(originalDrafts, forKey: OpenClientStorageKey.messageDraftsByChat)
    }

    func testPresentationAndSelectionShareInFlightAndCompletedReadButManualRefreshReadsAgain() async throws {
        let model = makeModel()
        defer { model.backendConnection?.close() }
        let requested = expectation(description: "Presentation canonical read held")
        let selecting = expectation(description: "Selection metadata requested")
        var release: CheckedContinuation<Void, Never>?
        var reads = 0
        var todos = 0
        InitialHydrationURLProtocol.handler = { request in
            switch request.url?.path {
            case "/session/ses_initial/message":
                reads += 1
                if reads == 1 { await withCheckedContinuation { release = $0; requested.fulfill() } }
                return (200, Self.page(sessionID: self.session.id, messageID: "msg_\(reads)"))
            case "/permission":
                selecting.fulfill()
                return (200, "[]")
            case "/session/ses_initial/todo":
                todos += 1
                return (200, "[]")
            default: return self.response(request)
            }
        }
        let presentation = Task { await model.chatFacade.hydrateSessionForPresentation(session) }
        await fulfillment(of: [requested], timeout: 2)
        let selection = Task { await model.selectSession(session) }
        await fulfillment(of: [selecting], timeout: 2)
        presentation.cancel()
        release?.resume()
        await presentation.value
        await selection.value
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(todos, 1, "The false/false presentation must not suppress selection's todo refresh")
        XCTAssertEqual(model.messages.map(\.id), ["msg_1"])
        await model.chatFacade.hydrateSessionForPresentation(session)
        XCTAssertEqual(reads, 1, "A later view task in the same navigation reuses the completed read")

        InitialHydrationURLProtocol.handler = { request in
            if request.url?.path == "/session/ses_initial/message" {
                reads += 1
                return (200, Self.page(sessionID: self.session.id, messageID: "msg_refreshed"))
            }
            return self.response(request)
        }
        await model.refreshChatData(for: session.id)
        XCTAssertEqual(reads, 2, "Explicit refresh is never memoized by the initial hydration task")
        XCTAssertEqual(Set(model.messages.map(\.id)), ["msg_1", "msg_refreshed"])
    }

    func testFailedInitialReadCanRetryWithinSameNavigation() async throws {
        let model = makeModel()
        defer { model.backendConnection?.close() }
        var reads = 0
        InitialHydrationURLProtocol.handler = { request in
            guard request.url?.path == "/session/ses_initial/message" else { return self.response(request) }
            reads += 1
            return reads == 1 ? (503, "{}") : (200, Self.page(sessionID: self.session.id, messageID: "msg_retry"))
        }
        do {
            try await model.chatFacade.loadInitialMessages(for: session, prefetchToolDetails: false, refreshTodos: false)
            XCTFail("The failing canonical read must propagate its error")
        } catch {}
        try await model.chatFacade.loadInitialMessages(for: session, prefetchToolDetails: false, refreshTodos: false)
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(model.messages.map(\.id), ["msg_retry"])
    }

    func testNavigationAndScopeChangesDoNotReuseOrPublishStaleRead() async throws {
        let model = makeModel()
        defer { model.backendConnection?.close() }
        let requested = expectation(description: "Old navigation held")
        var release: CheckedContinuation<Void, Never>?
        var reads = 0
        InitialHydrationURLProtocol.handler = { request in
            guard request.url?.path?.hasSuffix("/message") == true else { return self.response(request) }
            reads += 1
            let read = reads
            if read == 1 { await withCheckedContinuation { release = $0; requested.fulfill() } }
            let id = request.url!.pathComponents[2]
            return (200, Self.page(sessionID: id, messageID: "msg_\(read)"))
        }
        let old = Task { try? await model.chatFacade.loadInitialMessages(for: session,
            prefetchToolDetails: false, refreshTodos: false) }
        await fulfillment(of: [requested], timeout: 2)
        let other = OpenCodeSession(id: "ses_other", title: nil, workspaceID: nil,
            directory: "/repo", projectID: "project", parentID: nil)
        model.directoryStore.insertV2Session(other)
        _ = model.beginSessionNavigation(other)
        model.prepareSessionSelection(other, preservingDraftForSessionID: nil, animatesChanges: false)
        try await model.chatFacade.loadInitialMessages(for: other, prefetchToolDetails: false, refreshTodos: false)
        release?.resume()
        await old.value
        XCTAssertEqual(model.messages.map(\.id), ["msg_2"])
        XCTAssertEqual(model.selectedSession?.id, other.id)

        let moved = OpenCodeSession(id: other.id, title: nil, workspaceID: "worktree",
            directory: "/repo/worktree", projectID: "project", parentID: nil)
        model.directoryStore.insertV2Session(moved)
        model.selectedSession = moved
        // Same ID and navigation generation still require a new read for a different scope.
        try await model.chatFacade.loadInitialMessages(for: moved, prefetchToolDetails: false, refreshTodos: false)
        XCTAssertEqual(reads, 3)
        XCTAssertEqual(Set(model.messages.map(\.id)), ["msg_2", "msg_3"])
        XCTAssertTrue(model.directoryStore.syncState.messageEnvelopes(forSessionID: session.id).isEmpty)
    }

    func testDisconnectAndConnectionReplacementInvalidateCompletedAndInFlightRead() async throws {
        let model = makeModel()
        defer { model.backendConnection?.close() }
        var reads = 0
        var release: CheckedContinuation<Void, Never>?
        let requested = expectation(description: "Old connection held")
        InitialHydrationURLProtocol.handler = { request in
            guard request.url?.path == "/session/ses_initial/message" else { return self.response(request) }
            reads += 1
            let read = reads
            if read == 3 { await withCheckedContinuation { release = $0; requested.fulfill() } }
            return (200, Self.page(sessionID: self.session.id, messageID: "msg_\(read)"))
        }
        try await model.chatFacade.loadInitialMessages(for: session, prefetchToolDetails: false, refreshTodos: false)
        model.connectionStore.isConnected = false
        model.connectionStore.isConnected = true
        try await model.chatFacade.loadInitialMessages(for: session, prefetchToolDetails: false, refreshTodos: false)
        XCTAssertEqual(reads, 2)
        _ = model.beginSessionNavigation(session)
        let old = Task { try? await model.chatFacade.loadInitialMessages(for: session,
            prefetchToolDetails: false, refreshTodos: false) }
        await fulfillment(of: [requested], timeout: 2)
        model.backendConnection?.close()
        model.backendConnection = makeConnection(config: model.config)
        try await model.chatFacade.loadInitialMessages(for: session, prefetchToolDetails: false, refreshTodos: false)
        release?.resume()
        await old.value
        XCTAssertEqual(reads, 4)
        XCTAssertEqual(Set(model.messages.map(\.id)), ["msg_1", "msg_2", "msg_4"])
    }

    private func makeModel() -> AppViewModel {
        let config = OpenCodeServerConfig(baseURL: "https://initial-hydration.invalid", apiPreference: .legacy)
        let factory = OpenCodeBackendFactory(client: OpenCodeAPIClient(config: config), eventManager: OpenCodeEventManager())
        // Injected construction skips saved server/Keychain hydration.
        let model = AppViewModel(backendFactory: factory)
        model.config = config
        model.backendConnection = makeConnection(config: config)
        model.connectionStore.applySuccessfulServerConnection(version: "1", healthy: true)
        model.localCacheRepository = NoOpOpenCodeLocalCacheRepository()
        model.directoryStoreRegistry.activate("/repo")
        model.directoryStore.insertV2Session(session)
        _ = model.beginSessionNavigation(session)
        model.prepareSessionSelection(session, preservingDraftForSessionID: nil, animatesChanges: false)
        return model
    }

    private func makeConnection(config: OpenCodeServerConfig) -> BackendConnection {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InitialHydrationURLProtocol.self]
        let client = OpenCodeAPIClient(config: config, session: URLSession(configuration: configuration))
        return OpenCodeBackendFactory(client: client, eventManager: OpenCodeEventManager())
            .makeConnection(profile: .legacy, version: "1", healthy: true)
    }

    private func response(_ request: URLRequest) -> (Int, String) {
        switch request.url?.path {
        case "/session": return (200, #"[{"id":"ses_initial","directory":"/repo","projectID":"project","title":"Initial"}]"#)
        case "/session/status": return (200, "{}")
        case "/permission", "/question", "/command", "/session/ses_initial/todo": return (200, "[]")
        default:
            XCTFail("Unexpected initial hydration request: \(request.url?.path ?? "nil")")
            return (404, "{}")
        }
    }

    private static func page(sessionID: String, messageID: String) -> String {
        #"[{"info":{"id":"\#(messageID)","sessionID":"\#(sessionID)","role":"user","time":{"created":100}},"parts":[]}]"#
    }
}

private final class InitialHydrationURLProtocol: URLProtocol {
    @MainActor static var handler: (@MainActor (URLRequest) async throws -> (Int, String))?
    private struct Delivery: @unchecked Sendable { let loader: InitialHydrationURLProtocol }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let delivery = Delivery(loader: self)
        let request = request
        Task { @MainActor in
            do {
                let handler = try XCTUnwrap(Self.handler)
                let (status, body) = try await handler(request)
                let response = try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]))
                delivery.loader.client?.urlProtocol(delivery.loader, didReceive: response, cacheStoragePolicy: .notAllowed)
                delivery.loader.client?.urlProtocol(delivery.loader, didLoad: Data(body.utf8))
                delivery.loader.client?.urlProtocolDidFinishLoading(delivery.loader)
            } catch { delivery.loader.client?.urlProtocol(delivery.loader, didFailWithError: error) }
        }
    }
    override func stopLoading() {}
}

@MainActor
final class ChatFacadeTests: XCTestCase {
    func testAgentActivityUsesChildLifecycleAndDoesNotTreatIdleAsSuccess() throws {
        let model = AppViewModel()
        let owner = model.directoryStore
        let parent = OpenCodeSession(id: "ses_parent", title: "Parent", workspaceID: nil, directory: nil, projectID: nil, parentID: nil)
        var child = OpenCodeSession(id: "ses_child", title: "Inspect code", workspaceID: nil, directory: nil, projectID: nil, parentID: parent.id)
        child.outcome = "succeeded"
        owner.insertV2Session(parent)
        owner.insertV2Session(child)
        owner.applySessionStatus("busy", forSessionID: child.id)
        XCTAssertEqual(model.chatFacade.agentActivity(parentID: parent.id).map(\.status), [.running])

        let event = try XCTUnwrap(OpenCodeEventManager.decodeV2Event(from:
            #"{"type":"session.execution.failed","data":{"sessionID":"ses_child"}}"#))
        XCTAssertTrue(owner.applyV2Event(event))
        XCTAssertEqual(model.chatFacade.agentActivity(parentID: parent.id).map(\.status), [.failed])

        child.outcome = nil
        owner.insertV2Session(child)
        XCTAssertEqual(model.chatFacade.agentActivity(parentID: parent.id).map(\.status), [.idle])
        XCTAssertTrue(model.chatFacade.agentActivity(parentID: "unrelated").isEmpty)
    }

    func testAgentPermissionTakesPrecedenceOverRunning() throws {
        let model = AppViewModel()
        let owner = model.directoryStore
        let child = OpenCodeSession(id: "ses_child", title: "Review", workspaceID: nil, directory: nil, projectID: nil, parentID: "ses_parent")
        owner.insertV2Session(child)
        owner.applySessionStatus("busy", forSessionID: child.id)
        let event = try XCTUnwrap(OpenCodeEventManager.decodeV2Event(from:
            #"{"type":"permission.asked","data":{"sessionID":"ses_child","id":"permission_1","action":"shell","resources":["swift test"]}}"#))
        XCTAssertTrue(owner.applyV2Event(event))
        XCTAssertEqual(model.chatFacade.agentActivity(parentID: "ses_parent").map(\.status), [.permission])
    }

    func testToolbarWidthBudgetLeavesSpaceForBackContextAndNativeMargins() {
        for width: CGFloat in [320, 375, 390, 440, 650, 900] {
            let budget = ChatToolbarWidthBudget(containerWidth: width)
            XCTAssertGreaterThanOrEqual(budget.header - 44 - budget.spacing, 44)
            XCTAssertGreaterThanOrEqual(budget.model, 52)
            XCTAssertLessThanOrEqual(budget.header, 220)
            XCTAssertLessThanOrEqual(budget.model, 192)
            XCTAssertGreaterThan(budget.header, budget.model)
            XCTAssertLessThanOrEqual(budget.header + budget.model + 124, width)
        }
        XCTAssertEqual(ChatToolbarWidthBudget(containerWidth: 440).header, 174)
        XCTAssertEqual(ChatToolbarWidthBudget(containerWidth: 440).model, 142)
        XCTAssertEqual(ChatToolbarWidthBudget(containerWidth: 320).header, 112)
        XCTAssertEqual(ChatToolbarWidthBudget(containerWidth: 320).model, 84)
        XCTAssertLessThan(ChatToolbarWidthBudget(containerWidth: 320).header, ChatToolbarWidthBudget(containerWidth: 440).header)
        XCTAssertLessThan(ChatToolbarWidthBudget(containerWidth: 320).model, ChatToolbarWidthBudget(containerWidth: 440).model)
    }

    func testAssistantToolbarUsesSinglePillNativeBarAllowance() {
        for width: CGFloat in [320, 375, 390, 440, 844] {
            let budget = ChatToolbarWidthBudget(containerWidth: width)
            XCTAssertEqual(budget.assistantHeader, max(92, width - 104))
            XCTAssertEqual(budget.assistantHeaderWithTrailingItem, max(92, width - 160))
            XCTAssertGreaterThanOrEqual(budget.assistantHeader - 44 - budget.spacing, 44)
        }

        XCTAssertEqual(ChatToolbarWidthBudget(containerWidth: 320).assistantHeader, 216)
        XCTAssertEqual(ChatToolbarWidthBudget(containerWidth: 390).assistantHeader, 286)
        XCTAssertEqual(ChatToolbarWidthBudget(containerWidth: 440).assistantHeader, 336)
        XCTAssertEqual(ChatToolbarWidthBudget(containerWidth: 844).assistantHeader, 740)
    }

    func testProviderLogoUsesExactBundledProviderIDWithSyntheticFallback() {
        for id in ["openai", "openrouter", "amazon-bedrock", "azure", "github-copilot"] {
            XCTAssertEqual(ProviderIcon.assetName(for: id), "ProviderIcon_\(id)")
        }
        XCTAssertEqual(ProviderIcon.assetName(for: "custom-local-provider"), "ProviderIcon_synthetic")
        XCTAssertEqual(ProviderIcon.assetName(for: "OpenRouter"), "ProviderIcon_synthetic")
    }

    func testSameModelNameOnDifferentProvidersChangesDisplayedProvider() {
        let model = makeViewModel()
        let session = makeSession(id: "provider-switch")
        let routed = OpenCodeProvider(id: "openrouter", name: "OpenRouter", models: [
            "reasoner": makeModel(id: "reasoner", providerID: "openrouter", name: "Reasoner"),
        ])
        model.modelConfigurationStore.allProviders.append(routed)
        model.modelConfigurationStore.availableProviders.append(routed)
        model.chatFacade.selectModel(.init(providerID: "openai", modelID: "reasoner"), for: session)
        let first = model.chatFacade.toolbarSnapshot(for: session)
        model.chatFacade.selectModel(.init(providerID: "openrouter", modelID: "reasoner"), for: session)
        let second = model.chatFacade.toolbarSnapshot(for: session)

        XCTAssertEqual(first.modelTitle, second.modelTitle)
        XCTAssertEqual(first.displayedModelReference?.providerID, "openai")
        XCTAssertEqual(second.displayedModelReference?.providerID, "openrouter")
        XCTAssertEqual(second.modelProviderName, "OpenRouter")
        XCTAssertNotEqual(first, second, "Equal model names must not suppress provider-logo updates")
    }

    func testDisplayedProviderFollowsMessageFallbackWithoutCatalogEntry() {
        let model = makeViewModel()
        let session = makeSession(id: "message-provider")
        model.selectedSession = session
        model.isLoadingSelectedSession = true
        let message = OpenCodeMessageEnvelope(info: OpenCodeMessage(id: "routed-message", role: "user",
            sessionID: session.id, time: nil, agent: nil,
            model: OpenCodeMessageModelReference(providerID: "custom-router", modelID: "claude-custom", variant: nil)), parts: [])
        model.messages = [message]

        let snapshot = model.chatFacade.toolbarSnapshot(for: session)
        XCTAssertEqual(snapshot.modelTitle, "claude-custom")
        XCTAssertEqual(snapshot.displayedModelReference?.providerID, "custom-router")
        XCTAssertEqual(snapshot.modelProviderName, "custom-router")
        XCTAssertNil(snapshot.selectedModelReference)
    }

    func testDisplayedProviderFollowsEffectiveDefault() {
        let model = makeViewModel()
        let snapshot = model.chatFacade.toolbarSnapshot(for: makeSession(id: "default-provider"))
        XCTAssertEqual(snapshot.modelTitle, "Basic")
        XCTAssertEqual(snapshot.displayedModelReference, .init(providerID: "openai", modelID: "basic"))
        XCTAssertEqual(snapshot.modelProviderName, "OpenAI")
    }

    func testSelectingUnpreparedSessionDoesNotExposePreviousTranscript() {
        let model = AppViewModel()
        let first = makeSession(id: "first")
        let second = makeSession(id: "second")
        model.selectedDirectory = first.directory
        model.allSessions = [first, second]
        model.selectedSession = first
        model.chatStore.beginSelectingSession(sessionID: first.id,
            cachedMessages: [makeMessage(id: "first-message", sessionID: first.id, role: "user")])

        _ = model.beginSessionNavigation(second)

        XCTAssertTrue(model.chatFacade.messageSource(for: second).isEmpty)
        XCTAssertTrue(model.chatFacade.presentationMessages.isEmpty)
    }

    func testInactiveDirectorySelectionCannotReadActiveTranscript() {
        let model = AppViewModel()
        let first = makeSession(id: "first")
        let second = makeSession(id: "second", directory: "/tmp/other")
        model.selectedDirectory = first.directory
        model.allSessions = [first]
        model.selectedSession = first
        model.chatStore.messages = [makeMessage(id: "first-message", sessionID: first.id, role: "user")]
        let other = model.directoryStoreRegistry.store(for: second.directory)
        other.sessions = [second]
        other.selectedSession = second

        XCTAssertTrue(model.chatFacade.messageSource(for: second).isEmpty)
    }

    func testActiveTranscriptFallbackFiltersEveryEnvelopeBySession() {
        let model = AppViewModel()
        let second = makeSession(id: "second")
        model.selectedDirectory = second.directory
        model.selectedSession = second
        let expected = makeMessage(id: "second-message", sessionID: second.id, role: "user")
        model.chatStore.beginSelectingSession(sessionID: second.id, cachedMessages: [
            makeMessage(id: "first-message", sessionID: "first", role: "assistant"), expected,
        ])

        XCTAssertEqual(model.chatFacade.messageSource(for: second), [expected])
        XCTAssertEqual(model.chatFacade.presentationMessages, [expected])
        model.selectedSession = nil
        XCTAssertTrue(model.chatFacade.presentationMessages.isEmpty)
    }

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "opencode.modelVisibility.v1")
        UserDefaults.standard.removeObject(forKey: "chatBreadcrumbs")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "opencode.modelVisibility.v1")
        UserDefaults.standard.removeObject(forKey: "chatBreadcrumbs")
        super.tearDown()
    }

    func testSnapshotContainsSelectedValuesAndTitles() {
        let viewModel = makeViewModel()
        let session = makeSession(id: "session-selected")
        let modelReference = OpenCodeModelReference(providerID: "openai", modelID: "reasoner")

        viewModel.chatFacade.selectAgent(named: "review", for: session)
        viewModel.chatFacade.selectModel(modelReference, for: session)
        viewModel.chatFacade.selectReasoningVariant("deep_think", for: session)

        let snapshot = viewModel.chatFacade.toolbarSnapshot(for: session)

        XCTAssertEqual(snapshot.selectedAgentName, "review")
        XCTAssertEqual(snapshot.selectedModelReference, modelReference)
        XCTAssertEqual(snapshot.selectedReasoningVariant, "deep_think")
        XCTAssertEqual(snapshot.agentTitle, "review")
        XCTAssertEqual(snapshot.modelTitle, "Reasoner")
        XCTAssertEqual(snapshot.reasoningTitle, "Deep Think")
    }

    func testToolbarSnapshotChangesAfterEachPickerSelection() {
        let viewModel = makeViewModel()
        let session = makeSession(id: "session-picker-updates")
        var previous = viewModel.chatFacade.toolbarSnapshot(for: session)

        viewModel.chatFacade.selectAgent(named: "review", for: session)
        var current = viewModel.chatFacade.toolbarSnapshot(for: session)
        XCTAssertNotEqual(current, previous)
        previous = current

        viewModel.chatFacade.selectModel(
            OpenCodeModelReference(providerID: "openai", modelID: "reasoner"),
            for: session
        )
        current = viewModel.chatFacade.toolbarSnapshot(for: session)
        XCTAssertNotEqual(current, previous)
        previous = current

        viewModel.chatFacade.selectReasoningVariant("high", for: session)
        current = viewModel.chatFacade.toolbarSnapshot(for: session)
        XCTAssertNotEqual(current, previous)
    }

    func testSnapshotUsesLatestUserMessageAsToolbarFallback() {
        let viewModel = makeViewModel()
        let session = makeSession(id: "session-message")
        viewModel.selectedSession = session
        viewModel.isLoadingSelectedSession = true
        viewModel.messages = [
            makeMessage(id: "message-001", sessionID: session.id, role: "user", agent: "build", modelID: "basic"),
            makeMessage(id: "message-002", sessionID: session.id, role: "assistant"),
            makeMessage(id: "message-003", sessionID: session.id, role: "user", agent: "  review  ", modelID: "reasoner"),
        ]

        let snapshot = viewModel.chatFacade.toolbarSnapshot(for: session)

        XCTAssertEqual(snapshot.agentTitle, "review")
        XCTAssertEqual(snapshot.modelTitle, "Reasoner")
        XCTAssertEqual(snapshot.displayedModelReference, .init(providerID: "openai", modelID: "reasoner"))
        XCTAssertEqual(snapshot.modelProviderName, "OpenAI")
        XCTAssertFalse(snapshot.isLoading)
    }

    func testSnapshotUsesLoadingPlaceholdersBeforeSelectionHydrates() {
        let viewModel = makeViewModel()
        let session = makeSession(id: "session-loading")
        viewModel.selectedSession = session
        viewModel.isLoadingSelectedSession = true

        let snapshot = viewModel.chatFacade.toolbarSnapshot(for: session)

        XCTAssertEqual(snapshot.agentTitle, "Agent")
        XCTAssertEqual(snapshot.modelTitle, "Model")
        XCTAssertNil(snapshot.displayedModelReference)
        XCTAssertNil(snapshot.modelProviderName)
        XCTAssertTrue(snapshot.isAgentLoading)
        XCTAssertTrue(snapshot.isModelLoading)
        XCTAssertTrue(snapshot.isLoading)
    }

    func testSnapshotContainsSortedProviderGroupsWithVisibleModelsOnly() throws {
        let viewModel = makeViewModel()
        let hiddenReference = OpenCodeModelReference(providerID: "openai", modelID: "basic")
        viewModel.modelConfigurationStore.setModelVisibility(hiddenReference, isVisible: false)

        let snapshot = viewModel.chatFacade.toolbarSnapshot(for: makeSession(id: "session-providers"))
        let openAI = try XCTUnwrap(snapshot.providerGroups.first { $0.id == "openai" })

        XCTAssertEqual(snapshot.providerGroups.map(\.id), ["anthropic", "openai"])
        XCTAssertEqual(openAI.models.map(\.id), ["reasoner"])
    }

    func testSnapshotPreparesReasoningVariantsAndDefaultTitle() {
        let viewModel = makeViewModel()
        let session = makeSession(id: "session-reasoning")
        viewModel.chatFacade.selectModel(
            OpenCodeModelReference(providerID: "openai", modelID: "reasoner"),
            for: session
        )

        var snapshot = viewModel.chatFacade.toolbarSnapshot(for: session)
        XCTAssertEqual(snapshot.reasoningVariants.map(\.id), ["deep_think", "high"])
        XCTAssertEqual(snapshot.reasoningVariants.map(\.title), ["Deep Think", "High"])
        XCTAssertEqual(snapshot.reasoningTitle, "Default")

        viewModel.chatFacade.selectReasoningVariant("high", for: session)
        snapshot = viewModel.chatFacade.toolbarSnapshot(for: session)
        XCTAssertEqual(snapshot.reasoningTitle, "High")
    }

    func testSelectionIntentsRemainIsolatedBySession() {
        let viewModel = makeViewModel()
        let first = makeSession(id: "session-first")
        let second = makeSession(id: "session-second")
        let reference = OpenCodeModelReference(providerID: "openai", modelID: "reasoner")

        viewModel.chatFacade.selectAgent(named: "review", for: first)
        viewModel.chatFacade.selectModel(reference, for: first)
        viewModel.chatFacade.selectReasoningVariant("high", for: first)

        let firstSnapshot = viewModel.chatFacade.toolbarSnapshot(for: first)
        let secondSnapshot = viewModel.chatFacade.toolbarSnapshot(for: second)

        XCTAssertEqual(firstSnapshot.selectedAgentName, "review")
        XCTAssertEqual(firstSnapshot.selectedModelReference, reference)
        XCTAssertEqual(firstSnapshot.selectedReasoningVariant, "high")
        XCTAssertNil(secondSnapshot.selectedAgentName)
        XCTAssertNil(secondSnapshot.selectedModelReference)
        XCTAssertNil(secondSnapshot.selectedReasoningVariant)
    }

    func testGameSessionHidesAgentMenuAndDoesNotWaitForAgentSelection() {
        let viewModel = makeViewModel()
        let session = makeSession(id: "session-game")
        viewModel.selectedSession = session
        viewModel.isLoadingSelectedSession = true
        viewModel.funAndGamesStore.recordFindBugSession(
            FindBugGameSession(sessionID: session.id, language: FindBugGameLanguage(id: "swift", title: "Swift"))
        )
        viewModel.chatFacade.selectModel(
            OpenCodeModelReference(providerID: "openai", modelID: "reasoner"),
            for: session
        )

        let snapshot = viewModel.chatFacade.toolbarSnapshot(for: session)

        XCTAssertFalse(snapshot.showsAgentMenu)
        XCTAssertFalse(snapshot.isAgentLoading)
        XCTAssertFalse(snapshot.isLoading)
        XCTAssertEqual(snapshot.agentTitle, "plan")
    }

    func testForkSessionSnapshotContainsForkableMessagesAndPendingState() {
        let viewModel = makeViewModel()
        let session = makeSession(id: "session-fork")
        viewModel.selectedSession = session
        viewModel.messages = [
            OpenCodeMessageEnvelope.local(
                role: "user",
                text: "First prompt",
                messageID: "message-first",
                sessionID: session.id
            ),
            OpenCodeMessageEnvelope.local(
                role: "assistant",
                text: "Response",
                messageID: "message-response",
                sessionID: session.id
            ),
            OpenCodeMessageEnvelope.local(
                role: "user",
                text: "Latest\nprompt",
                messageID: "message-latest",
                sessionID: session.id
            ),
        ]
        viewModel.chatPresentationStore.pendingForkMessageID = "message-latest"

        let snapshot = viewModel.chatFacade.forkSessionSnapshot

        XCTAssertEqual(snapshot.messages.map(\.id), ["message-latest", "message-first"])
        XCTAssertEqual(snapshot.messages.map(\.text), ["Latest prompt", "First prompt"])
        XCTAssertEqual(snapshot.pendingMessageID, "message-latest")
    }

    func testTodoInspectorSnapshotUsesSelectedSessionTodos() {
        let viewModel = makeViewModel()
        let session = makeSession(id: "session-todos")
        let todos = [makeTodo(content: "Canonical todo")]
        viewModel.selectedSession = session
        viewModel.directoryStore.applyTodos(todos, forSessionID: session.id)
        viewModel.sessionInteractionStore.todos = [makeTodo(content: "Compatibility fallback")]

        let snapshot = viewModel.chatFacade.todoInspectorSnapshot

        XCTAssertEqual(snapshot.selectedSessionID, session.id)
        XCTAssertEqual(snapshot.todos, todos)
    }

    func testTodoRefreshStateKeepsSuccessfulEmptyResultDistinctFromUnrefreshedState() {
        let fallback = [makeTodo(content: "Stale todo")]
        var state = TodoInspectorRefreshState()

        XCTAssertEqual(state.visibleTodos(fallback: fallback), fallback)

        state.apply([])

        XCTAssertEqual(state.refreshedTodos, [])
        XCTAssertEqual(state.visibleTodos(fallback: fallback), [])
    }

    func testObservationRebindsToNewActiveDirectoryStoreAndSyncStore() async {
        let viewModel = makeViewModel()
        let facade = viewModel.chatFacade
        let oldStore = viewModel.directoryStoreRegistry.activeStore
        let newStore = viewModel.directoryStoreRegistry.activate("/tmp/other")

        // Rebinding and activation invalidations are queued on main before this checkpoint.
        let activated = expectation(description: "Active directory observation rebound")
        DispatchQueue.main.async { activated.fulfill() }
        await fulfillment(of: [activated], timeout: 1)

        var changeCount = 0
        var pendingChange: XCTestExpectation?
        let observation = facade.objectWillChange.sink {
            changeCount += 1
            pendingChange?.fulfill()
            pendingChange = nil
        }

        oldStore.selectedSession = makeSession(id: "session-old")
        oldStore.applyTodos([makeTodo(content: "Old")], forSessionID: "session-old")

        // Drain queued forwarding before checking that old-store subscriptions were detached.
        let oldStoreDelivered = expectation(description: "Old directory notification queue drained")
        DispatchQueue.main.async { oldStoreDelivered.fulfill() }
        await fulfillment(of: [oldStoreDelivered], timeout: 1)
        XCTAssertEqual(changeCount, 0)

        let selectionChanged = expectation(description: "New active directory changes delivered")
        pendingChange = selectionChanged
        newStore.selectedSession = makeSession(id: "session-new")
        await fulfillment(of: [selectionChanged], timeout: 1)
        let selectionDrained = expectation(description: "Selection notifications drained")
        DispatchQueue.main.async { selectionDrained.fulfill() }
        await fulfillment(of: [selectionDrained], timeout: 1)
        // Derived snapshots can publish more than once; forwarding is not one-to-one.
        XCTAssertGreaterThan(changeCount, 0)
        XCTAssertEqual(facade.todoInspectorSnapshot.selectedSessionID, "session-new")

        let selectionChangeCount = changeCount
        let syncChanged = expectation(description: "New active sync store change delivered")
        pendingChange = syncChanged
        let todos = [makeTodo(content: "New")]
        newStore.applyTodos(todos, forSessionID: "session-new")

        await fulfillment(of: [syncChanged], timeout: 1)
        XCTAssertGreaterThan(changeCount, selectionChangeCount)
        XCTAssertEqual(facade.todoInspectorSnapshot.todos, todos)
        withExtendedLifetime(observation) {}
    }

    func testDismissForkPresentationDoesNotChangeSelectionOrPendingAction() {
        let viewModel = makeViewModel()
        let selectedSession = makeSession(id: "session-selected")
        viewModel.selectedSession = selectedSession
        viewModel.chatPresentationStore.isShowingForkSessionSheet = true
        viewModel.chatPresentationStore.pendingForkSessionID = selectedSession.id
        viewModel.chatPresentationStore.pendingForkMessageID = "message-pending"

        viewModel.chatFacade.dismissForkSessionSheet()

        XCTAssertFalse(viewModel.chatPresentationStore.isShowingForkSessionSheet)
        XCTAssertEqual(viewModel.selectedSession?.id, selectedSession.id)
        XCTAssertEqual(viewModel.chatPresentationStore.pendingForkSessionID, selectedSession.id)
        XCTAssertEqual(viewModel.chatPresentationStore.pendingForkMessageID, "message-pending")
    }

    func testDirectoryStoreResolvesSessionOwnerInsteadOfStaleActiveStore() {
        let viewModel = makeViewModel()
        let activeStore = viewModel.directoryStoreRegistry.activeStore
        let ownerStore = viewModel.directoryStoreRegistry.store(for: "/tmp/owner")
        let session = makeSession(id: "session-owned")
        ownerStore.sessions = [session]

        XCTAssertTrue(viewModel.chatFacade.directoryStore(forSessionID: session.id) === ownerStore)
        XCTAssertFalse(viewModel.chatFacade.directoryStore(forSessionID: session.id) === activeStore)
        XCTAssertTrue(viewModel.chatFacade.directoryStore(forSessionID: "session-unknown") === activeStore)
    }

    func testChatWindowRoutePreservesServerAndOwningDirectory() {
        let viewModel = makeViewModel()
        viewModel.config = OpenCodeServerConfig(
            name: "Test",
            baseURL: "https://example.com",
            username: "tester"
        )
        let ownerStore = viewModel.directoryStoreRegistry.store(for: "/tmp/owner")
        let session = makeSession(id: "session-window")
        ownerStore.sessions = [session]

        let route = viewModel.chatFacade.windowRoute(for: session)

        XCTAssertEqual(route.serverID, "https://example.com|tester")
        XCTAssertEqual(route.directoryKey, "/tmp/owner")
        XCTAssertEqual(route.sessionID, session.id)
        XCTAssertTrue(
            viewModel.chatFacade.directoryStore(
                forSessionID: "session-not-hydrated",
                preferredDirectoryKey: route.directoryKey
            ) === ownerStore
        )
    }

    func testActiveChatLifecycleClearsOnlyMatchingSessionAndUpdatesChatStore() {
        let viewModel = makeViewModel()
        let facade = viewModel.chatFacade

        facade.setActiveChatSessionID("session-first")
        XCTAssertEqual(facade.activeChatSessionID, "session-first")
        XCTAssertEqual(viewModel.chatStore.activeChatSessionID, "session-first")

        facade.setActiveChatSessionID("session-newer")
        facade.clearActiveChatSessionIfMatching("session-first")
        XCTAssertEqual(facade.activeChatSessionID, "session-newer")
        XCTAssertEqual(viewModel.chatStore.activeChatSessionID, "session-newer")

        facade.clearActiveChatSessionIfMatching("session-newer")
        XCTAssertNil(facade.activeChatSessionID)
        XCTAssertNil(viewModel.chatStore.activeChatSessionID)
    }

    func testComposerOverlaySnapshotPreservesStoreInputsAndSessionFiltering() {
        let viewModel = makeViewModel()
        let sessionID = "session-overlay"
        let todo = makeTodo(content: "Inspect overlay")
        let attachment = OpenCodeComposerAttachment(
            id: "attachment-1",
            kind: .file,
            filename: "notes.txt",
            mime: "text/plain",
            dataURL: "data:text/plain;base64,QQ=="
        )
        let permission = OpenCodePermission(
            id: "permission-1",
            sessionID: sessionID,
            permission: "edit",
            patterns: [],
            always: nil,
            metadata: nil,
            tool: nil
        )
        let otherPermission = OpenCodePermission(
            id: "permission-other",
            sessionID: "session-other",
            permission: "edit",
            patterns: [],
            always: nil,
            metadata: nil,
            tool: nil
        )
        let question = OpenCodeQuestionRequest(
            id: "question-1",
            sessionID: sessionID,
            questions: [],
            tool: nil
        )
        viewModel.sessionInteractionStore.todos = [todo]
        viewModel.sessionInteractionStore.permissions = [permission, otherPermission]
        viewModel.sessionInteractionStore.questions = [question]
        viewModel.composerStore.draftAttachments = [attachment]

        let snapshot: ChatFacade.ChatComposerOverlaySnapshot = viewModel.chatFacade.composerOverlaySnapshot(
            forSessionID: sessionID
        )

        XCTAssertEqual(snapshot.todos, [todo])
        XCTAssertEqual(snapshot.attachmentIDs, [attachment.id])
        XCTAssertEqual(snapshot.permissions, [permission])
        XCTAssertEqual(snapshot.questions, [question])
        XCTAssertEqual(snapshot.incompleteTodoIDs, [todo.id])
        XCTAssertTrue(snapshot.showsAccessoryArea)
    }

    func testComposerOverlaySnapshotBubblesChildSessionInteractionsToParent() {
        let viewModel = makeViewModel()
        let parent = makeSession(id: "session-parent")
        let child = OpenCodeSession(
            id: "session-child",
            title: "Child",
            workspaceID: nil,
            directory: parent.directory,
            projectID: parent.projectID,
            parentID: parent.id
        )
        let permission = OpenCodePermission(
            id: "permission-child",
            sessionID: child.id,
            permission: "bash",
            patterns: ["git status"],
            always: nil,
            metadata: nil,
            tool: nil
        )
        let question = OpenCodeQuestionRequest(
            id: "question-child",
            sessionID: child.id,
            questions: [],
            tool: nil
        )
        viewModel.directoryStore.sessions = [parent, child]
        viewModel.sessionInteractionStore.permissions = [permission]
        viewModel.sessionInteractionStore.questions = [question]

        let snapshot = viewModel.chatFacade.composerOverlaySnapshot(forSessionID: parent.id)

        XCTAssertEqual(snapshot.permissions, [permission])
        XCTAssertEqual(snapshot.questions, [question])
    }

    func testComposerSnapshotContainsPreparedComposerState() {
        let viewModel = makeViewModel()
        viewModel.backendConnection = OpenCodeBackendFactory(client: OpenCodeAPIClient(config: .init()), eventManager: viewModel.eventManager)
            .makeConnection(profile: .legacy, version: "test", healthy: true)
        let session = makeSession(id: "session-composer")
        viewModel.selectedSession = session
        viewModel.directoryStore.commands = [makeCommand(name: "explain")]
        viewModel.messages = [
            OpenCodeMessageEnvelope.local(
                role: "user",
                text: "Fork this",
                messageID: "message-user",
                sessionID: session.id
            ),
        ]
        viewModel.composerStore.draftAttachments = [
            OpenCodeComposerAttachment(
                id: "attachment-1",
                kind: .file,
                filename: "notes.txt",
                mime: "text/plain",
                dataURL: "data:text/plain;base64,QQ=="
            ),
        ]
        viewModel.mcpStore.statuses = [
            "server": OpenCodeMCPStatus(status: "connected", error: nil),
        ]
        viewModel.mcpStore.isLoading = true
        let forkableMessages = viewModel.forkableMessages

        let snapshot = viewModel.chatFacade.composerSnapshot(
            for: session,
            isBusy: true,
            forkableMessages: forkableMessages
        )

        XCTAssertEqual(snapshot.commands.map(\.name), ["explain", "compact", "fork"])
        XCTAssertEqual(snapshot.attachmentCount, 1)
        XCTAssertTrue(snapshot.isBusy)
        XCTAssertTrue(snapshot.canFork)
        XCTAssertEqual(snapshot.forkableMessages.map(\.text), ["Fork this"])
        XCTAssertEqual(snapshot.mcp.connectedServerCount, 1)
        XCTAssertTrue(snapshot.mcp.isLoading)
        XCTAssertEqual(snapshot.actionSignature, "session-composer|/tmp/project||project|")
    }

    func testHeaderSnapshotContainsChildSessionTitles() {
        let viewModel = makeViewModel()
        let parent = OpenCodeSession(
            id: "session-parent",
            title: "Parent Chat",
            workspaceID: nil,
            directory: "/tmp/project",
            projectID: "project",
            parentID: nil
        )
        let child = OpenCodeSession(
            id: "session-child",
            title: "Fix issue (@build subagent)",
            workspaceID: nil,
            directory: "/tmp/project",
            projectID: "project",
            parentID: parent.id
        )
        viewModel.directoryStore.sessions = [parent, child]

        let snapshot = viewModel.chatFacade.headerSnapshot(for: child)

        XCTAssertTrue(snapshot.isChildSession)
        XCTAssertEqual(snapshot.parentSession?.id, parent.id)
        XCTAssertEqual(snapshot.parentTitle, "Parent Chat")
        XCTAssertEqual(snapshot.childTitle, "Fix issue")
        XCTAssertEqual(snapshot.navigationTitle, "Fix issue")
    }

    func testSessionForPresentationKeepsParentSelected() async {
        let viewModel = makeViewModel()
        let parent = OpenCodeSession(
            id: "session-parent",
            title: "Parent Chat",
            workspaceID: nil,
            directory: "/tmp/project",
            projectID: "project",
            parentID: nil
        )
        let child = OpenCodeSession(
            id: "session-child",
            title: "Review changes (@explore subagent)",
            workspaceID: nil,
            directory: "/tmp/project",
            projectID: "project",
            parentID: parent.id
        )
        viewModel.directoryStore.sessions = [parent, child]
        viewModel.directoryStore.selectedSession = parent

        let presentedSession = await viewModel.chatFacade.sessionForPresentation(sessionID: child.id)

        XCTAssertEqual(presentedSession?.id, child.id)
        XCTAssertEqual(viewModel.directoryStore.selectedSession?.id, parent.id)
    }

    func testChildSessionToolbarUsesChildMessageMetadataWhileParentIsSelected() {
        let viewModel = makeViewModel()
        let parent = makeSession(id: "session-parent")
        let child = OpenCodeSession(
            id: "session-child",
            title: "Review changes (@explore subagent)",
            workspaceID: nil,
            directory: "/tmp/project",
            projectID: "project",
            parentID: parent.id
        )
        viewModel.directoryStore.sessions = [parent, child]
        viewModel.directoryStore.selectedSession = parent
        viewModel.chatStore.messages = [
            makeMessage(id: "parent-message", sessionID: parent.id, role: "assistant", agent: "build", modelID: "basic"),
        ]
        viewModel.directoryStore.applyCanonicalMessages(
            [makeMessage(id: "child-message", sessionID: child.id, role: "assistant", agent: "review", modelID: "reasoner")],
            forSessionID: child.id
        )

        let snapshot = viewModel.chatFacade.childSessionToolbarSnapshot(for: child)

        XCTAssertEqual(snapshot.agentTitle, "review")
        XCTAssertEqual(snapshot.modelTitle, "Reasoner")
    }

    func testPreferenceScopeKeyCoversServerDirectoryGlobalAndAppleIntelligence() {
        let viewModel = makeViewModel()
        viewModel.config = OpenCodeServerConfig(
            name: "Test",
            baseURL: "https://example.com",
            username: "alice",
            password: ""
        )

        XCTAssertEqual(
            viewModel.chatFacade.preferenceScopeKey(),
            "server|\(viewModel.config.recentServerID)|global"
        )

        viewModel.projectStore.selectedDirectory = "/tmp/project"
        XCTAssertEqual(
            viewModel.chatFacade.preferenceScopeKey(),
            "server|\(viewModel.config.recentServerID)|/tmp/project"
        )

        viewModel.connectionStore.backendMode = .appleIntelligence
        viewModel.activeAppleIntelligenceWorkspaceID = "workspace-local"
        XCTAssertEqual(
            viewModel.chatFacade.preferenceScopeKey(),
            "apple-intelligence|workspace-local"
        )
    }

    func testDiagnosticFacadeGettersReflectCompatibilityDiagnostics() {
        let viewModel = makeViewModel()
        let facade = viewModel.chatFacade
        viewModel.chatPresentationStore.isShowingDebugProbe = true

        facade.appendDebugLog("facade diagnostic")
        facade.markChatBreadcrumb("facade breadcrumb", sessionID: "session-debug")

        XCTAssertEqual(facade.debugProbeLogCount, 1)
        XCTAssertEqual(facade.chatBreadcrumbCount, 1)
        XCTAssertTrue(facade.copyDebugProbeLog().contains("facade diagnostic"))
        XCTAssertTrue(facade.copyChatBreadcrumbs().contains("facade breadcrumb"))
    }

    func testStopSessionTargetsTheChatSessionInsteadOfTheSelectedSession() async {
        let viewModel = makeViewModel()
        let selectedSession = makeSession(id: "session-selected")
        let focusedSession = makeSession(id: "session-focused")
        viewModel.selectedSession = selectedSession
        viewModel.connectionStore.backendMode = .appleIntelligence
        viewModel.sessionStatuses[selectedSession.id] = "busy"
        viewModel.sessionStatuses[focusedSession.id] = "busy"

        await viewModel.chatFacade.stopSession(focusedSession)

        XCTAssertEqual(viewModel.sessionStatuses[focusedSession.id], "idle")
        XCTAssertEqual(viewModel.sessionStatuses[selectedSession.id], "busy")
    }

    private func makeViewModel() -> AppViewModel {
        let viewModel = AppViewModel()
        viewModel.modelConfigurationStore.availableAgents = [
            OpenCodeAgent(name: "review", description: nil, mode: "primary", hidden: false, model: nil, variant: nil),
            OpenCodeAgent(name: "build", description: nil, mode: "primary", hidden: false, model: nil, variant: nil),
        ]
        viewModel.modelConfigurationStore.applyProviderState(
            OpenCodeProviderListResponse(
                all: [
                    OpenCodeProvider(
                        id: "openai",
                        name: "OpenAI",
                        models: [
                            "basic": makeModel(id: "basic", providerID: "openai", name: "Basic"),
                            "reasoner": makeModel(
                                id: "reasoner",
                                providerID: "openai",
                                name: "Reasoner",
                                reasoning: true,
                                variants: ["high": .bool(true), "deep_think": .bool(true)]
                            ),
                        ]
                    ),
                    OpenCodeProvider(
                        id: "anthropic",
                        name: "Anthropic",
                        models: ["sonnet": makeModel(id: "sonnet", providerID: "anthropic", name: "Sonnet")]
                    ),
                ],
                connected: ["openai", "anthropic"],
                default: ["openai": "basic"]
            )
        )
        return viewModel
    }

    private func makeSession(id: String, directory: String = "/tmp/project") -> OpenCodeSession {
        OpenCodeSession(
            id: id,
            title: id,
            workspaceID: nil,
            directory: directory,
            projectID: "project",
            parentID: nil
        )
    }

    private func makeModel(
        id: String,
        providerID: String,
        name: String,
        reasoning: Bool = false,
        variants: [String: OpenCodeJSONValue]? = nil
    ) -> OpenCodeModel {
        OpenCodeModel(
            id: id,
            providerID: providerID,
            name: name,
            capabilities: OpenCodeModelCapabilities(reasoning: reasoning),
            variants: variants
        )
    }

    private func makeCommand(name: String) -> OpenCodeCommand {
        OpenCodeCommand(
            name: name,
            description: name,
            agent: nil,
            model: nil,
            source: "test",
            template: "",
            subtask: false,
            hints: []
        )
    }

    private func makeTodo(content: String) -> OpenCodeTodo {
        OpenCodeTodo(content: content, status: "pending", priority: "medium")
    }

    private func makeMessage(
        id: String,
        sessionID: String,
        role: String,
        agent: String? = nil,
        modelID: String? = nil
    ) -> OpenCodeMessageEnvelope {
        OpenCodeMessageEnvelope(
            info: OpenCodeMessage(
                id: id,
                role: role,
                sessionID: sessionID,
                time: nil,
                agent: agent,
                model: modelID.map { OpenCodeMessageModelReference(providerID: "openai", modelID: $0, variant: nil) }
            ),
            parts: []
        )
    }
}
