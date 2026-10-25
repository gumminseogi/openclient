import Foundation

enum OpenCodeStateReducer {
    static func applyGlobalEvent(
        event: OpenCodeTypedEvent,
        projects: inout [OpenCodeProject],
        currentProject: inout OpenCodeProject?
    ) -> Bool {
        switch event {
        case let .projectUpdated(project):
            if let index = projects.firstIndex(where: { $0.id == project.id }) {
                projects[index] = project
            } else {
                projects.append(project)
                projects.sort { $0.id < $1.id }
            }
            if currentProject?.id == project.id {
                currentProject = project
            }
            return true
        case .serverConnected, .globalDisposed:
            return true
        default:
            return false
        }
    }

    static func applyDirectoryEvent(
        event: OpenCodeTypedEvent,
        sessions: inout [OpenCodeSession],
        selectedSession: inout OpenCodeSession?,
        sessionStatuses: inout [String: String],
        syncState: inout OpenCodeDirectorySyncState,
        messages: inout [OpenCodeMessageEnvelope],
        todos: inout [OpenCodeTodo],
        permissions: inout [OpenCodePermission],
        questions: inout [OpenCodeQuestionRequest]
    ) -> SessionEventResult {
        switch event {
        case let .sessionCreated(session):
            upsertSession(session, into: &sessions)
            return .sessionChanged
        case let .sessionUpdated(session):
            if session.isArchived {
                removeSession(
                    session,
                    sessions: &sessions,
                    selectedSession: &selectedSession,
                    sessionStatuses: &sessionStatuses,
                    syncState: &syncState,
                    messages: &messages,
                    todos: &todos,
                    permissions: &permissions,
                    questions: &questions
                )
                return .sessionChanged
            }
            upsertSession(session, into: &sessions)
            if selectedSession?.id == session.id {
                selectedSession = selectedSession?.merged(with: session)
            }
            return .sessionChanged
        case let .sessionDeleted(session):
            removeSession(
                session,
                sessions: &sessions,
                selectedSession: &selectedSession,
                sessionStatuses: &sessionStatuses,
                syncState: &syncState,
                messages: &messages,
                todos: &todos,
                permissions: &permissions,
                questions: &questions
            )
            return .sessionChanged
        case let .sessionStatus(sessionID, status):
            sessionStatuses[sessionID] = status
            syncState.sessionStatusesBySessionID[sessionID] = status
            return status == "idle" && selectedSession?.id == sessionID ? .idle : .statusChanged
        case let .sessionIdle(sessionID):
            // v1 emits session.status(idle) followed by the legacy session.idle.
            // Keep status events authoritative, but reconcile their legacy echo only once.
            let wasIdle = sessionStatuses[sessionID] == "idle"
            sessionStatuses[sessionID] = "idle"
            syncState.sessionStatusesBySessionID[sessionID] = "idle"
            return !wasIdle && selectedSession?.id == sessionID ? .idle : .statusChanged
        case let .sessionDiff(sessionID, diff):
            syncState.sessionDiffsBySessionID[sessionID] = diff.sorted { $0.file < $1.file }
            return .statusChanged
        case let .todoUpdated(sessionID, updatedTodos):
            syncState.todosBySessionID[sessionID] = updatedTodos
            if sessionID == selectedSession?.id {
                todos = updatedTodos
            }
            return .todoChanged
        case let .messageUpdated(info):
            guard syncState.applyMessageUpdated(info) else { return .ignored("missing session") }
            if info.sessionID == selectedSession?.id, let sessionID = info.sessionID {
                messages = syncState.messageEnvelopes(forSessionID: sessionID)
            }
            return .message("message updated")
        case let .messagePartUpdated(part):
            guard syncState.applyPartUpdated(part) else { return .ignored("missing part/message id") }
            if part.sessionID == selectedSession?.id, let sessionID = part.sessionID {
                messages = syncState.messageEnvelopes(forSessionID: sessionID)
            }
            return .message("part updated")
        case let .messagePartDelta(sessionID, messageID, partID, field, delta):
            guard syncState.applyPartDelta(messageID: messageID, partID: partID, field: field, delta: delta) else {
                return .ignored("missing delta part")
            }
            if sessionID == selectedSession?.id {
                messages = syncState.messageEnvelopes(forSessionID: sessionID)
            }
            return .message("delta applied")
        case let .messageRemoved(sessionID, messageID):
            guard syncState.removeMessage(sessionID: sessionID, messageID: messageID) else {
                return .ignored("message missing")
            }
            if sessionID == selectedSession?.id {
                messages = syncState.messageEnvelopes(forSessionID: sessionID)
            }
            return .message("message removed")
        case let .messagePartRemoved(messageID, partID):
            guard syncState.removePart(messageID: messageID, partID: partID) else {
                return .ignored("part missing")
            }
            if let selectedSessionID = selectedSession?.id,
               syncState.messagesBySessionID[selectedSessionID]?.contains(where: { $0.id == messageID }) == true {
                messages = syncState.messageEnvelopes(forSessionID: selectedSessionID)
            }
            return .message("part removed")
        case let .permissionAsked(permission):
            var sessionPermissions = syncState.permissionsBySessionID[permission.sessionID] ?? []
            if let index = sessionPermissions.firstIndex(where: { $0.id == permission.id }) {
                sessionPermissions[index] = permission
            } else {
                sessionPermissions.append(permission)
            }
            sessionPermissions.sort { $0.id < $1.id }
            syncState.permissionsBySessionID[permission.sessionID] = sessionPermissions
            if permission.sessionID == selectedSession?.id {
                if let index = permissions.firstIndex(where: { $0.id == permission.id }) {
                    permissions[index] = permission
                } else {
                    permissions.append(permission)
                }
                permissions.sort { $0.id < $1.id }
            }
            return .permissionChanged
        case let .permissionReplied(sessionID, requestID, _):
            syncState.permissionsBySessionID[sessionID]?.removeAll { $0.id == requestID }
            if selectedSession?.id != sessionID {
                return .statusChanged
            }
            permissions.removeAll { $0.id == requestID }
            return .permissionChanged
        case let .questionAsked(question):
            var sessionQuestions = syncState.questionsBySessionID[question.sessionID] ?? []
            if let index = sessionQuestions.firstIndex(where: { $0.id == question.id }) {
                sessionQuestions[index] = question
            } else {
                sessionQuestions.append(question)
            }
            sessionQuestions.sort { $0.id < $1.id }
            syncState.questionsBySessionID[question.sessionID] = sessionQuestions
            if question.sessionID == selectedSession?.id {
                if let index = questions.firstIndex(where: { $0.id == question.id }) {
                    questions[index] = question
                } else {
                    questions.append(question)
                }
                questions.sort { $0.id < $1.id }
            }
            return .questionChanged
        case let .questionReplied(sessionID, requestID), let .questionRejected(sessionID, requestID):
            syncState.questionsBySessionID[sessionID]?.removeAll { $0.id == requestID }
            if selectedSession?.id != sessionID {
                return .statusChanged
            }
            questions.removeAll { $0.id == requestID }
            return .questionChanged
        default:
            return .ignored("unhandled")
        }
    }

    private static func upsertSession(_ session: OpenCodeSession, into sessions: inout [OpenCodeSession]) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = sessions[index].merged(with: session)
        } else {
            sessions.append(session)
        }
    }

    private static func removeSession(
        _ session: OpenCodeSession,
        sessions: inout [OpenCodeSession],
        selectedSession: inout OpenCodeSession?,
        sessionStatuses: inout [String: String],
        syncState: inout OpenCodeDirectorySyncState,
        messages: inout [OpenCodeMessageEnvelope],
        todos: inout [OpenCodeTodo],
        permissions: inout [OpenCodePermission],
        questions: inout [OpenCodeQuestionRequest]
    ) {
        sessions.removeAll { $0.id == session.id }
        sessionStatuses[session.id] = nil
        syncState.sessionStatusesBySessionID[session.id] = nil
        syncState.todosBySessionID[session.id] = nil
        syncState.permissionsBySessionID[session.id] = nil
        syncState.questionsBySessionID[session.id] = nil
        syncState.sessionDiffsBySessionID[session.id] = nil
        syncState.removeMessages(forSessionID: session.id)
        if selectedSession?.id == session.id {
            selectedSession = nil
            messages = []
            todos = []
            permissions = []
            questions = []
        }
    }
}

enum SessionEventResult {
    case message(String)
    case sessionChanged
    case todoChanged
    case permissionChanged
    case questionChanged
    case statusChanged
    case idle
    case ignored(String)
}
