import Foundation

struct AgentActivitySnapshot: Identifiable, Equatable {
    enum Status: Equatable {
        case running, permission, question, completed, failed, interrupted, idle

        var isFinished: Bool {
            switch self {
            case .completed, .failed, .interrupted: true
            case .running, .permission, .question, .idle: false
            }
        }

        var title: LocalizedStringResource {
            switch self {
            case .running: "Running"
            case .permission: "Needs approval"
            case .question: "Needs an answer"
            case .completed: "Completed"
            case .failed: "Failed"
            case .interrupted: "Interrupted"
            case .idle: "Idle"
            }
        }

        var symbol: String {
            switch self {
            case .running: "arrow.trianglehead.2.clockwise.rotate.90"
            case .permission, .question: "exclamationmark.bubble"
            case .completed: "checkmark.circle"
            case .failed: "exclamationmark.circle"
            case .interrupted: "stop.circle"
            case .idle: "circle.dotted"
            }
        }
    }

    let id: String
    let title: String
    let agent: String?
    let status: Status
}
