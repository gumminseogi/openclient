#if DEBUG
import Foundation

/// Deterministic, in-memory session metadata service for exercising real workflow
/// moves in screenshot UI tests. It follows the same coordinator/store path as a server.
@MainActor
final class ActivityWorkflowScreenshotBackend: BackendProjectsService, BackendSessionsService,
    BackendChatService, BackendModelsService, BackendEventSource, BackendSessionActivityService,
    BackendSessionAnnotationsService {
    private let projects: [OpenCodeProject]
    private var records: [String: OpenCodeSession]
    private let messages: [String: [OpenCodeMessageEnvelope]]
    private var receive: (@MainActor (BackendEvent) -> Void)?
    private let transcriptDelay: Duration

    init(projects: [OpenCodeProject], stores: [DirectoryStore], transcriptDelay: Duration = .zero) {
        self.transcriptDelay = transcriptDelay
        self.projects = projects
        var records: [String: OpenCodeSession] = [:]
        var messages: [String: [OpenCodeMessageEnvelope]] = [:]
        for store in stores {
            for session in store.sessions {
                records[session.id] = session
                messages[session.id] = store.syncState.messageEnvelopes(forSessionID: session.id)
            }
        }
        self.records = records
        self.messages = messages
    }

    func connection() -> BackendConnection {
        BackendConnection(descriptor: .init(id: "workflow-fixture", name: "Workflow Fixture", version: "1"),
            projects: self, sessions: self, chat: self, models: self, events: self, sessionActivity: self)
    }

    func projectsSnapshot() async throws -> BackendProjectsSnapshot { .init(projects: projects) }
    func sessions(scope: BackendScope, cursor: String?, limit: Int, roots: Bool) async throws -> BackendSessionPage {
        .init(sessions: records.values.filter {
            (scope.projectID == nil || $0.projectID == scope.projectID)
                && (scope.directory == nil || $0.directory == scope.directory)
                && (!roots || $0.isRootSession)
        }.sorted { $0.id < $1.id })
    }
    func session(id: String, scope: BackendScope) async throws -> OpenCodeSession {
        guard let session = records[id] else { throw BackendError.invalidScope }
        return session
    }
    var supportsSessionAnnotations: Bool { true }
    func setSessionMetadata(id: String, metadata: [String: OpenCodeJSONValue]) async throws -> OpenCodeSession {
        var updated = try await session(id: id, scope: .init())
        updated.metadata = metadata
        records[id] = updated
        receive?(.mutation(directory: updated.directory, event: .sessionUpdated(updated)))
        return updated
    }
    func transcript(sessionID: String, scope: BackendScope, cursor: String?, limit: Int) async throws -> BackendTranscriptPage {
        if transcriptDelay > .zero { try await Task.sleep(for: transcriptDelay) }
        return .init(messages: messages[sessionID] ?? [])
    }
    func sessionStatuses(scope: BackendScope) async throws -> [String: String] { records.mapValues { _ in "idle" } }
    func modelCatalog(scope: BackendScope) async throws -> BackendModelCatalog { .init() }
    func start(receive: @escaping @MainActor (BackendEvent) -> Void) { self.receive = receive }
    func stop() { receive = nil }

    func createSession(_ request: BackendSessionCreation) async throws -> OpenCodeSession { throw BackendError.invalidScope }
    func renameSession(id: String, title: String, scope: BackendScope) async throws -> OpenCodeSession { throw BackendError.invalidScope }
    func deleteSession(id: String, scope: BackendScope) async throws { throw BackendError.invalidScope }
    func searchSessions(query: String, scope: BackendScope, limit: Int) async throws -> [OpenCodeSession] { [] }
    func submit(_ request: BackendSubmission) async throws -> BackendAdmission { throw BackendError.invalidScope }
    func interrupt(sessionID: String, scope: BackendScope) async throws { throw BackendError.invalidScope }
}
#endif
