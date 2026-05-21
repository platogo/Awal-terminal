import Foundation

enum ToolCallKind: String {
    case read, write, shell, code, glob, grep, unknown

    var icon: String {
        switch self {
        case .read: return "doc.text"
        case .write: return "pencil.line"
        case .shell: return "terminal"
        case .code, .glob, .grep: return "magnifyingglass"
        case .unknown: return "wrench"
        }
    }
}

enum ToolCallStatus: String {
    case pending, running, completed, failed
}

class ToolCallState {
    let id: String
    let title: String
    let kind: ToolCallKind
    var status: ToolCallStatus
    var content: String = ""
    let startTime: Date = Date()

    init(id: String, title: String, kind: ToolCallKind, status: ToolCallStatus) {
        self.id = id
        self.title = title
        self.kind = kind
        self.status = status
    }
}
