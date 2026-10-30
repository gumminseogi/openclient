import Combine
import Foundation

@MainActor
final class SessionCleanupStore: ObservableObject {
    struct Candidate: Identifiable {
        let session: OpenCodeSession
        let lastActivity: Date?
        var memberIDs: Set<String> = []
        var id: String { session.id }
    }

    struct Transcript {
        var messages: [OpenCodeMessageEnvelope] = []
        var olderCursor: String?
        var isLoading = false
        var error: String?
        var loaded = false
    }

    @Published var candidates: [Candidate] = []
    @Published var projects: [OpenCodeProject] = []
    @Published var isLoading = false
    @Published var isDeleting = false
    @Published var error: String?
    @Published var progress = 0
    @Published var total = 0
    @Published var failures: [String: String] = [:]
    @Published var transcripts: [String: Transcript] = [:]
    @Published private(set) var decisions: [(id: String, delete: Bool)] = []

    var pendingIDs: Set<String> { Set(decisions.filter(\.delete).map(\.id)) }
    var reviewCards: [Candidate] {
        let reviewed = Set(decisions.map(\.id))
        // Keep a reserve card ready to enter beneath the visible three during a swipe.
        return Array(candidates.lazy.filter { !reviewed.contains($0.id) }.prefix(4))
    }
    var current: Candidate? {
        let reviewed = Set(decisions.map(\.id))
        return candidates.first { !reviewed.contains($0.id) }
    }

    func decide(delete: Bool) {
        guard !isDeleting, let current else { return }
        decisions.append((current.id, delete))
    }

    func undo() { if !isDeleting { _ = decisions.popLast() } }

    func remove(_ id: String) {
        candidates.removeAll { $0.id == id }
        decisions.removeAll { $0.id == id }
        transcripts[id] = nil
        failures[id] = nil
    }

    func older(than date: Date) -> [Candidate] {
        candidates.filter { $0.lastActivity.map { $0 < date } ?? false }
    }

    func projectName(_ id: String?) -> String {
        guard let project = projects.first(where: { $0.id == id }) else { return id ?? "" }
        return project.name ?? project.worktree
    }

    /// A root is eligible only when its entire child tree is inactive. Use the
    /// newest activity in that tree so old roots with recent agents are preserved.
    static func candidates(sessions: [OpenCodeSession], statuses: [String: String]) -> [Candidate] {
        let byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        var blocked = Set<String>()
        var activity: [String: Double] = [:]
        var members: [String: Set<String>] = [:]
        for session in sessions {
            let busy = statuses[session.id].map { $0 != "idle" } ?? false
            let timestamp = session.time?.updated ?? session.time?.created
            var id: String? = session.id
            var visited = Set<String>()
            while let current = id, visited.insert(current).inserted {
                members[current, default: []].insert(session.id)
                if busy { blocked.insert(current) }
                if let timestamp { activity[current] = max(activity[current] ?? timestamp, timestamp) }
                id = byID[current]?.parentID
            }
        }
        return sessions.filter { $0.isRootSession && !blocked.contains($0.id) }.map {
            Candidate(session: $0, lastActivity: activity[$0.id].map { Date(timeIntervalSince1970: $0 / 1_000) },
                memberIDs: members[$0.id] ?? [$0.id])
        }.sorted {
            if $0.lastActivity == $1.lastActivity { return $0.id < $1.id }
            return ($0.lastActivity ?? .distantFuture) < ($1.lastActivity ?? .distantFuture)
        }
    }
}
