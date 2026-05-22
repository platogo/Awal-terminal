import AppKit

/// Maps subagent roles to pipeline stage colors.
enum PipelineStage: String {
    case planning, implementing, reviewing, documentation

    var color: NSColor {
        switch self {
        case .planning:
            return NSColor(red: 0.3, green: 0.5, blue: 0.9, alpha: 1.0)
        case .implementing:
            return NSColor(red: 0.3, green: 0.8, blue: 0.4, alpha: 1.0)
        case .reviewing:
            return NSColor(red: 0.9, green: 0.6, blue: 0.2, alpha: 1.0)
        case .documentation:
            return NSColor(red: 0.6, green: 0.4, blue: 0.9, alpha: 1.0)
        }
    }

    static func from(role: String?) -> PipelineStage? {
        guard let role = role?.lowercased() else { return nil }
        if role.contains("plan") || role.contains("research") { return .planning }
        if role.contains("implement") || role.contains("develop") || role.contains("code") { return .implementing }
        if role.contains("review") || role.contains("test") { return .reviewing }
        if role.contains("archiv") || role.contains("doc") { return .documentation }
        return nil
    }
}

class TabGroup {
    let id: UUID
    var name: String
    var color: NSColor?
    var isCollapsed: Bool
    var pipelineSessionId: String?
    var totalStages: Int = 0
    var completedStages: Int = 0
    var autoCloseOnComplete: Bool

    var progressLabel: String? {
        guard totalStages > 0 else { return nil }
        return "\(completedStages)/\(totalStages)"
    }

    init(id: UUID = UUID(), name: String, color: NSColor? = nil, isCollapsed: Bool = false,
         pipelineSessionId: String? = nil, autoCloseOnComplete: Bool = false) {
        self.id = id
        self.name = name
        self.color = color
        self.isCollapsed = isCollapsed
        self.pipelineSessionId = pipelineSessionId
        self.autoCloseOnComplete = autoCloseOnComplete
    }
}
