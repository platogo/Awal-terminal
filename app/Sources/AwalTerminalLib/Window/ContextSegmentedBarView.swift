import AppKit

/// A color-coded segmented bar showing context window usage by category.
class ContextSegmentedBarView: NSView {

    struct Segment {
        let fraction: CGFloat
        let color: NSColor
        let label: String
    }

    /// Segments to display (fractions should sum to <= 1.0).
    var segments: [Segment] = [] {
        didSet { needsDisplay = true }
    }

    /// Whether compaction warning is active (>= 80%).
    var isWarning: Bool = false {
        didSet {
            if oldValue != isWarning { needsDisplay = true }
        }
    }

    static let systemColor = NSColor(red: 100.0/255.0, green: 140.0/255.0, blue: 220.0/255.0, alpha: 1.0)
    static let skillsColor = NSColor(red: 160.0/255.0, green: 120.0/255.0, blue: 220.0/255.0, alpha: 1.0)
    static let conversationColor = NSColor(red: 80.0/255.0, green: 200.0/255.0, blue: 120.0/255.0, alpha: 1.0)
    static let toolResultsColor = NSColor(red: 220.0/255.0, green: 170.0/255.0, blue: 60.0/255.0, alpha: 1.0)

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let bounds = self.bounds

        // Background
        let bgColor = NSColor(white: 1.0, alpha: 0.08)
        bgColor.setFill()
        let bgPath = NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3)
        bgPath.fill()

        // Clip to rounded rect before drawing segments
        let clipPath = NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3)
        clipPath.addClip()

        // Draw segments left to right
        var x: CGFloat = bounds.minX
        for segment in segments {
            let width = bounds.width * segment.fraction
            guard width > 0 else { continue }
            let segRect = NSRect(x: x, y: bounds.minY, width: width, height: bounds.height)
            segment.color.setFill()
            let segPath = NSBezierPath(roundedRect: segRect, xRadius: 0, yRadius: 0)
            segPath.fill()
            x += width
        }

        // Warning border
        if isWarning {
            let borderColor = NSColor(red: 240.0/255.0, green: 100.0/255.0, blue: 70.0/255.0, alpha: 0.8)
            borderColor.setStroke()
            let borderPath = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
            borderPath.lineWidth = 1.0
            borderPath.stroke()
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 8)
    }
}
