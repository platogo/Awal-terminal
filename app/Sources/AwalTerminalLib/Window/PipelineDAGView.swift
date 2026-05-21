import AppKit

/// Draws a simple pipeline DAG showing subagent dependencies.
/// Each node is a rounded rect with the subagent name; edges connect dependsOn relationships.
class PipelineDAGView: NSView {

    private var subagents: [SubagentState] = []

    func update(subagents: [SubagentState]) {
        self.subagents = subagents
        needsDisplay = true
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard !subagents.isEmpty else { return }

        let nodeWidth: CGFloat = 120
        let nodeHeight: CGFloat = 28
        let hSpacing: CGFloat = 20
        let vSpacing: CGFloat = 16
        let startX: CGFloat = 12
        let startY: CGFloat = 8

        // Build layout: assign columns based on dependency depth
        var depths: [String: Int] = [:]
        var visiting = Set<String>()
        for sub in subagents {
            let depth = resolveDepth(sub.id, depths: &depths, visiting: &visiting)
            depths[sub.id] = depth
        }

        let maxDepth = depths.values.max() ?? 0
        var columnCounts = [Int](repeating: 0, count: maxDepth + 1)
        var positions: [String: NSPoint] = [:]

        // Sort by depth then start time
        let sorted = subagents.sorted {
            let d0 = depths[$0.id] ?? 0
            let d1 = depths[$1.id] ?? 0
            if d0 != d1 { return d0 < d1 }
            return $0.startTime < $1.startTime
        }

        for sub in sorted {
            let col = depths[sub.id] ?? 0
            let row = columnCounts[col]
            columnCounts[col] += 1
            let x = startX + CGFloat(col) * (nodeWidth + hSpacing)
            let y = startY + CGFloat(row) * (nodeHeight + vSpacing)
            positions[sub.id] = NSPoint(x: x, y: y)
        }

        // Draw edges
        let edgeColor = NSColor(white: 0.4, alpha: 1.0)
        edgeColor.setStroke()
        for sub in subagents {
            guard let toPos = positions[sub.id] else { continue }
            for dep in sub.dependsOn {
                guard let fromPos = positions[dep] else { continue }
                let path = NSBezierPath()
                path.move(to: NSPoint(x: fromPos.x + nodeWidth, y: fromPos.y + nodeHeight / 2))
                path.line(to: NSPoint(x: toPos.x, y: toPos.y + nodeHeight / 2))
                path.lineWidth = 1.5
                path.stroke()

                // Arrow head
                let arrowSize: CGFloat = 5
                let tip = NSPoint(x: toPos.x, y: toPos.y + nodeHeight / 2)
                let arrow = NSBezierPath()
                arrow.move(to: tip)
                arrow.line(to: NSPoint(x: tip.x - arrowSize, y: tip.y - arrowSize / 2))
                arrow.line(to: NSPoint(x: tip.x - arrowSize, y: tip.y + arrowSize / 2))
                arrow.close()
                edgeColor.setFill()
                arrow.fill()
            }
        }

        // Draw nodes
        for sub in subagents {
            guard let pos = positions[sub.id] else { continue }
            let rect = NSRect(x: pos.x, y: pos.y, width: nodeWidth, height: nodeHeight)
            let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)

            let fillColor: NSColor
            switch sub.status {
            case .running:
                fillColor = NSColor(red: 0.15, green: 0.25, blue: 0.4, alpha: 1.0)
            case .completed:
                fillColor = NSColor(red: 0.1, green: 0.3, blue: 0.15, alpha: 1.0)
            case .error(_):
                fillColor = NSColor(red: 0.35, green: 0.1, blue: 0.1, alpha: 1.0)
            }
            fillColor.setFill()
            path.fill()

            NSColor(white: 0.5, alpha: 1.0).setStroke()
            path.lineWidth = 1
            path.stroke()

            // Label
            let label = sub.name
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
                .foregroundColor: NSColor(white: 0.9, alpha: 1.0),
            ]
            let size = (label as NSString).size(withAttributes: attrs)
            let textX = pos.x + (nodeWidth - size.width) / 2
            let textY = pos.y + (nodeHeight - size.height) / 2
            (label as NSString).draw(at: NSPoint(x: textX, y: textY), withAttributes: attrs)
        }
    }

    private func resolveDepth(_ id: String, depths: inout [String: Int], visiting: inout Set<String>) -> Int {
        if let d = depths[id] { return d }
        guard !visiting.contains(id) else { return 0 }
        visiting.insert(id)
        guard let sub = subagents.first(where: { $0.id == id }) else { return 0 }
        if sub.dependsOn.isEmpty { return 0 }
        let maxParent = sub.dependsOn.map { resolveDepth($0, depths: &depths, visiting: &visiting) }.max() ?? 0
        return maxParent + 1
    }

    override var intrinsicContentSize: NSSize {
        guard !subagents.isEmpty else { return NSSize(width: -1, height: 0) }
        // Estimate height based on max column count
        let nodeHeight: CGFloat = 28
        let vSpacing: CGFloat = 16
        var depths: [String: Int] = [:]
        var visiting = Set<String>()
        for sub in subagents { depths[sub.id] = resolveDepth(sub.id, depths: &depths, visiting: &visiting) }
        let maxDepth = depths.values.max() ?? 0
        var columnCounts = [Int](repeating: 0, count: maxDepth + 1)
        for sub in subagents { columnCounts[depths[sub.id] ?? 0] += 1 }
        let maxRows = columnCounts.max() ?? 1
        return NSSize(width: -1, height: CGFloat(maxRows) * (nodeHeight + vSpacing) + 16)
    }
}
