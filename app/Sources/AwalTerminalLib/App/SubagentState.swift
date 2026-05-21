import Foundation

enum SubagentStatus {
    case running
    case completed
    case error(String)
}

class SubagentState {
    let id: String
    let name: String
    let role: String?
    let parentSessionId: String?
    let dependsOn: [String]
    let startTime: Date = Date()
    var phase: String = "Initializing"
    var tokensUsed: UInt64 = 0
    var status: SubagentStatus = .running

    var isActive: Bool {
        if case .running = status { return true }
        return false
    }

    var elapsed: TimeInterval {
        Date().timeIntervalSince(startTime)
    }

    init(id: String, name: String, role: String?, parentSessionId: String?, dependsOn: [String]) {
        self.id = id
        self.name = name
        self.role = role
        self.parentSessionId = parentSessionId
        self.dependsOn = dependsOn
    }
}

/// Tracks subagents for a single ACP session (per-tab).
class SubagentTracker {
    private(set) var subagents: [String: SubagentState] = [:]

    var orderedSubagents: [SubagentState] {
        subagents.values.sorted { $0.startTime < $1.startTime }
    }

    var activeCount: Int {
        subagents.values.filter(\.isActive).count
    }

    var totalTokens: UInt64 {
        subagents.values.reduce(0) { $0 + $1.tokensUsed }
    }

    func handleSpawned(id: String, name: String, role: String?, parentSessionId: String?, dependsOn: [String]) {
        subagents[id] = SubagentState(
            id: id, name: name, role: role,
            parentSessionId: parentSessionId, dependsOn: dependsOn
        )
    }

    func handleProgress(id: String, phase: String, tokensUsed: UInt64?) {
        guard let sub = subagents[id] else { return }
        sub.phase = phase
        if let t = tokensUsed { sub.tokensUsed = t }
    }

    func handleComplete(id: String, tokensUsed: UInt64?) {
        guard let sub = subagents[id] else { return }
        sub.status = .completed
        sub.phase = "Done"
        if let t = tokensUsed { sub.tokensUsed = t }
    }

    func handleError(id: String, message: String) {
        guard let sub = subagents[id] else { return }
        sub.status = .error(message)
        sub.phase = "Error"
    }

    func reset() {
        subagents.removeAll()
    }
}
