import AppKit

/// A small sparkline view showing context usage over session turns.
class ContextSparklineView: NSView {

    /// Data points as fractions (0.0 to 1.0).
    var dataPoints: [Double] = [] {
        didSet { needsDisplay = true }
    }

    /// Threshold fraction at which compaction warning triggers.
    var warningThreshold: Double = 0.8

    private let lineColor = NSColor(red: 130.0/255.0, green: 170.0/255.0, blue: 255.0/255.0, alpha: 0.8)
    private let warningColor = NSColor(red: 240.0/255.0, green: 100.0/255.0, blue: 70.0/255.0, alpha: 0.4)

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard dataPoints.count >= 2 else { return }

        let bounds = self.bounds
        let inset: CGFloat = 1
        let drawRect = bounds.insetBy(dx: inset, dy: inset)

        // Draw warning zone background
        let warningY = drawRect.minY + drawRect.height * CGFloat(warningThreshold)
        let warningRect = NSRect(x: drawRect.minX, y: warningY,
                                 width: drawRect.width,
                                 height: drawRect.maxY - warningY)
        warningColor.setFill()
        NSBezierPath(roundedRect: warningRect, xRadius: 2, yRadius: 2).fill()

        // Draw sparkline
        let path = NSBezierPath()
        let stepX = drawRect.width / CGFloat(dataPoints.count - 1)

        for (i, value) in dataPoints.enumerated() {
            let x = drawRect.minX + stepX * CGFloat(i)
            let y = drawRect.minY + drawRect.height * CGFloat(min(value, 1.0))
            if i == 0 {
                path.move(to: NSPoint(x: x, y: y))
            } else {
                path.line(to: NSPoint(x: x, y: y))
            }
        }

        lineColor.setStroke()
        path.lineWidth = 1.0
        path.stroke()
    }
}
