import Combine
import Foundation

/// Presentation lifetimes belong to the sheet's routes, not destination visibility.
@MainActor
final class AgentNavigationStore: ObservableObject {
    @Published var path: [String] = [] {
        didSet {
            for id in Array(presentations.keys) where !path.contains(id) {
                presentations.removeValue(forKey: id)?.windowContext?.close()
            }
        }
    }
    @Published private(set) var presentations: [String: ChatFacade] = [:]

    func open(_ id: String) {
        if let index = path.firstIndex(of: id) { path = Array(path.prefix(index + 1)) }
        else { path.append(id) }
    }

    func retain(_ facade: ChatFacade, for id: String) {
        guard path.contains(id) else { facade.windowContext?.close(); return }
        if let existing = presentations[id], existing !== facade { facade.windowContext?.close(); return }
        presentations[id] = facade
    }

    func close() {
        path = []
    }
}
