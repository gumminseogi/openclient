import Combine
import Foundation

struct ActivityWorkflowStatus: Codable, Hashable, Identifiable, Sendable {
    static let metadataKey = "com.ntoporcov.openclient.workflowStatus"
    static let inProgress = Self(id: "in-progress", name: "", symbol: "circle.lefthalf.filled", color: "yellow")
    static let archived = Self(id: "archived", name: "", symbol: "circle.fill", color: "gray")
    static let symbols = ["circle", "circle.dashed", "circle.dotted", "circle.quarter.filled", "circle.lefthalf.filled", "circle.threequarters.filled", "circle.inset.filled", "circle.fill"]
    static let colors = ["gray", "blue", "purple", "yellow", "green", "orange"]

    let id: String
    let name: String
    let symbol: String
    let color: String

    var isBuiltIn: Bool { id == Self.inProgress.id || id == Self.archived.id }

    var title: String {
        switch id {
        case Self.inProgress.id: String(localized: "In Progress")
        case Self.archived.id: String(localized: "Archived")
        default: name
        }
    }

    static func annotation(in session: OpenCodeSession) -> Self? {
        guard let raw = session.metadata?[metadataKey] else { return nil }
        guard
              let data = try? JSONEncoder().encode(raw),
              let status = try? JSONDecoder().decode(Self.self, from: data),
              !status.id.isEmpty else { return nil }
        // V2 forks inherit metadata. An assignment to the source is not an
        // assignment to its fork. Keep the new-session default across devices,
        // including devices first connected after the fork was created.
        if let owner = raw.objectValue?["sessionID"]?.literalStringValue, owner != session.id { return .inProgress }
        if status.id == inProgress.id { return inProgress }
        if status.id == archived.id { return archived }
        guard !status.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return Self(id: status.id, name: status.name,
                    symbol: symbols.contains(status.symbol) ? status.symbol : "circle",
                    color: colors.contains(status.color) ? status.color : "gray")
    }

    func merging(into metadata: [String: OpenCodeJSONValue]?, sessionID: String? = nil) -> [String: OpenCodeJSONValue] {
        var result = metadata ?? [:]
        var annotation: [String: OpenCodeJSONValue] = [
            "id": .string(id), "name": .string(name), "symbol": .string(symbol), "color": .string(color),
        ]
        if let sessionID { annotation["sessionID"] = .string(sessionID) }
        result[Self.metadataKey] = .object(annotation)
        return result
    }
}

enum ActivityWorkflowLayout: String, Codable, CaseIterable {
    case recent, list, board
}

/// Global status vocabulary and local-only fallback annotations. Server metadata
/// owns assignments; local definitions and deletion redirects keep the vocabulary consistent.
@MainActor
final class ActivityWorkflowStore: ObservableObject {
    private struct State: Codable {
        var introducedAt: Double
        var customStatuses: [ActivityWorkflowStatus] = []
        var localAssignments: [String: ActivityWorkflowStatus] = [:]
        var layout: ActivityWorkflowLayout = .recent
        var showsArchived = true
        // Optional for compatibility with existing workflow preferences.
        var collapsedStatusIDs: Set<String>? = nil
        /// Deleted IDs remain redirected so stale/unloaded metadata cannot recreate a status.
        var statusReplacements: [String: ActivityWorkflowStatus]? = nil
    }

    private let defaults: UserDefaults
    private let persists: Bool
    private let key = "activityWorkflow.v1"
    @Published private var state: State

    init(defaults: UserDefaults = .standard, now: Date = Date(), persists: Bool = true) {
        self.defaults = defaults
        self.persists = persists
        state = (persists ? defaults.data(forKey: key) : nil).flatMap { try? JSONDecoder().decode(State.self, from: $0) }
            ?? State(introducedAt: now.timeIntervalSince1970 * 1000)
        persist()
    }

    var layout: ActivityWorkflowLayout { state.layout }
    var showsArchived: Bool { state.showsArchived }
    var collapsedStatusIDs: Set<String> { state.collapsedStatusIDs ?? [] }
    func setLayout(_ layout: ActivityWorkflowLayout) { state.layout = layout; persist() }
    func setShowsArchived(_ value: Bool) { state.showsArchived = value; persist() }

    func setCollapsed(_ collapsed: Bool, for statusID: String) {
        var ids = collapsedStatusIDs
        guard ids.contains(statusID) != collapsed else { return }
        if collapsed { ids.insert(statusID) } else { ids.remove(statusID) }
        state.collapsedStatusIDs = ids
        persist()
    }

    func status(for session: OpenCodeSession, serverID: String) -> ActivityWorkflowStatus {
        if let annotation = ActivityWorkflowStatus.annotation(in: session) { return resolve(annotation) }
        if let local = state.localAssignments[assignmentKey(session.id, serverID)] { return resolve(local) }
        return (session.time?.created ?? 0) >= state.introducedAt ? .inProgress : .archived
    }

    func resolve(_ status: ActivityWorkflowStatus) -> ActivityWorkflowStatus {
        var current = status
        var visited = Set<String>()
        while let replacement = state.statusReplacements?[current.id] {
            guard visited.insert(current.id).inserted else { return .archived }
            current = replacement
        }
        return state.customStatuses.first(where: { $0.id == current.id }) ?? current
    }

    @discardableResult
    func updateStatus(_ status: ActivityWorkflowStatus) -> Bool {
        guard !status.isBuiltIn, resolve(status).id == status.id,
              !status.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              ActivityWorkflowStatus.symbols.contains(status.symbol),
              ActivityWorkflowStatus.colors.contains(status.color) else { return false }
        if let index = state.customStatuses.firstIndex(where: { $0.id == status.id }) {
            state.customStatuses[index] = status
        } else {
            state.customStatuses.append(status)
        }
        persist()
        return true
    }

    @discardableResult
    func deleteStatus(_ status: ActivityWorkflowStatus, replacingWith replacement: ActivityWorkflowStatus) -> Bool {
        let target = resolve(replacement)
        guard !status.isBuiltIn, resolve(status).id == status.id, target.id != status.id else { return false }
        var next = state
        next.customStatuses.removeAll { $0.id == status.id }
        next.statusReplacements = (next.statusReplacements ?? [:]).merging([status.id: target]) { _, new in new }
        next.localAssignments = next.localAssignments.mapValues { $0.id == status.id ? target : $0 }
        next.collapsedStatusIDs?.remove(status.id)
        state = next
        persist()
        return true
    }

    func statuses(in sessions: [OpenCodeSession], serverID: String) -> [ActivityWorkflowStatus] {
        var result = [ActivityWorkflowStatus.inProgress] + state.customStatuses
        var seen = Set(result.map(\.id))
        seen.insert(ActivityWorkflowStatus.archived.id)
        for session in sessions {
            let status = status(for: session, serverID: serverID)
            if seen.insert(status.id).inserted { result.append(status) }
        }
        return result + [.archived]
    }

    @discardableResult
    func createStatus(name: String, symbol: String, color: String) -> ActivityWorkflowStatus? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, ActivityWorkflowStatus.symbols.contains(symbol),
              ActivityWorkflowStatus.colors.contains(color) else { return nil }
        let status = ActivityWorkflowStatus(id: UUID().uuidString, name: name, symbol: symbol, color: color)
        state.customStatuses.append(status)
        persist()
        return status
    }

    func assignLocally(_ status: ActivityWorkflowStatus, sessionID: String, serverID: String) {
        state.localAssignments[assignmentKey(sessionID, serverID)] = status
        persist()
    }

    private func assignmentKey(_ sessionID: String, _ serverID: String) -> String {
        // Length prefix avoids collisions when either identifier contains separators.
        "\(serverID.utf8.count):\(serverID)\(sessionID)"
    }

    private func persist() {
        guard persists else { return }
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: key)
    }
}
