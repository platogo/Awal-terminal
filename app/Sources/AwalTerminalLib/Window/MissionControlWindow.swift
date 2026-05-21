import AppKit

/// Dashboard window aggregating all active AI agents across tabs/windows
/// with real-time status, spend, and kill switches.
class MissionControlWindow: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {

    private static var shared: MissionControlWindow?

    static func show() {
        if let existing = shared {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = MissionControlWindow()
        shared = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    static func toggle() {
        if let existing = shared, existing.window?.isVisible == true {
            existing.window?.close()
        } else {
            show()
        }
    }

    // MARK: - Data

    struct AgentRow {
        let windowController: TerminalWindowController
        let tabIndex: Int
        let tab: TabState
        let terminal: TerminalView

        var isGenerating: Bool { terminal.isGenerating }
        var modelName: String { tab.statusBar.currentModelName }
        var workingDir: String { tab.statusBar.currentPath ?? "" }
        var phase: String { terminal.isGenerating ? terminal.generationPhase : "Idle" }
        var isDanger: Bool { tab.isDangerMode }
    }

    /// A row in the table — either a top-level agent or an indented subagent.
    enum DisplayRow {
        case agent(AgentRow)
        case subagent(SubagentState, ACPClient?)
    }

    private var rows: [AgentRow] = []
    private var displayRows: [DisplayRow] = []
    private var refreshTimer: Timer?

    // MARK: - UI

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()

    // Header
    private let totalCostLabel = NSTextField(labelWithString: "")
    private let totalTokensLabel = NSTextField(labelWithString: "")
    private let activeAgentLabel = NSTextField(labelWithString: "")

    // Pipeline DAG
    private let dagView = PipelineDAGView()
    private var dagHeightConstraint: NSLayoutConstraint?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 500),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Mission Control"
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 600, height: 300)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Theme.windowBg

        super.init(window: window)
        window.delegate = self

        setupUI()
        refreshData()

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.refreshData()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func windowWillClose(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
        Self.shared = nil
    }

    // MARK: - UI Setup

    private func setupUI() {
        guard let contentView = window?.contentView else { return }
        contentView.wantsLayer = true

        // Header bar
        let headerView = NSView()
        headerView.translatesAutoresizingMaskIntoConstraints = false
        headerView.wantsLayer = true
        headerView.layer?.backgroundColor = NSColor(white: 0.10, alpha: 1.0).cgColor
        contentView.addSubview(headerView)

        for label in [totalCostLabel, totalTokensLabel, activeAgentLabel] {
            label.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
            label.textColor = NSColor(white: 0.80, alpha: 1.0)
            label.translatesAutoresizingMaskIntoConstraints = false
            headerView.addSubview(label)
        }

        // Table
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        contentView.addSubview(scrollView)

        tableView.headerView = NSTableHeader()
        tableView.backgroundColor = .clear
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.rowHeight = 36
        tableView.style = .plain
        tableView.dataSource = self
        tableView.delegate = self
        tableView.gridStyleMask = [.solidHorizontalGridLineMask]
        tableView.gridColor = NSColor(white: 0.2, alpha: 1.0)

        let columns: [(String, String, CGFloat)] = [
            ("status", "", 24),
            ("model", "Model", 110),
            ("dir", "Directory", 120),
            ("phase", "Phase", 130),
            ("tokens", "Tokens", 120),
            ("cost", "Cost", 80),
            ("elapsed", "Elapsed", 70),
            ("kill", "", 50),
        ]

        for (id, title, width) in columns {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            col.title = title
            col.width = width
            col.minWidth = id == "status" ? 24 : 40
            if id == "dir" || id == "phase" {
                col.resizingMask = .autoresizingMask
            }
            tableView.addTableColumn(col)
        }

        scrollView.documentView = tableView

        // DAG view
        dagView.translatesAutoresizingMaskIntoConstraints = false
        dagView.wantsLayer = true
        dagView.layer?.backgroundColor = NSColor(white: 0.08, alpha: 1.0).cgColor
        contentView.addSubview(dagView)

        let dagHeight = dagView.heightAnchor.constraint(equalToConstant: 0)
        dagHeightConstraint = dagHeight

        // Constraints
        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: contentView.topAnchor),
            headerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            headerView.heightAnchor.constraint(equalToConstant: 40),

            totalCostLabel.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 12),
            totalCostLabel.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),

            totalTokensLabel.centerXAnchor.constraint(equalTo: headerView.centerXAnchor),
            totalTokensLabel.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),

            activeAgentLabel.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -12),
            activeAgentLabel.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),

            scrollView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: dagView.topAnchor),

            dagView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            dagView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            dagView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            dagHeight,
        ])
    }

    // MARK: - Data Collection

    private func refreshData() {
        rows.removeAll()
        displayRows.removeAll()

        for controller in TerminalWindowTracker.shared.allControllers {
            for (index, tab) in controller.tabs.enumerated() {
                let terminal = tab.splitContainer.focusedTerminal
                // Only show tabs with an active AI session (not plain Shell)
                let model = tab.statusBar.currentModelName
                guard !model.isEmpty && model != "Shell" else { continue }
                let agentRow = AgentRow(
                    windowController: controller,
                    tabIndex: index,
                    tab: tab,
                    terminal: terminal
                )
                rows.append(agentRow)
                displayRows.append(.agent(agentRow))

                // Add subagent rows indented under parent
                for sub in tab.subagentTracker.orderedSubagents {
                    displayRows.append(.subagent(sub, tab.acpClient))
                }
            }
        }

        // Update header
        var totalCost: Double = 0
        var totalIn = 0
        var totalOut = 0
        var activeCount = 0

        for row in rows {
            let tracker = row.tab.tokenTracker
            totalCost += tracker.estimatedCost
            totalIn += tracker.currentInput
            totalOut += tracker.totalOutput
            if row.isGenerating { activeCount += 1 }
        }

        totalCostLabel.stringValue = String(format: "Total: $%.4f", totalCost)
        totalTokensLabel.stringValue = "\(formatTokenCount(totalIn)) in · \(formatTokenCount(totalOut)) out"
        activeAgentLabel.stringValue = "\(activeCount) active / \(rows.count) agents"

        if totalCost > 1.0 {
            totalCostLabel.textColor = NSColor(red: 1.0, green: 0.6, blue: 0.3, alpha: 1.0)
        } else {
            totalCostLabel.textColor = NSColor(white: 0.80, alpha: 1.0)
        }

        tableView.reloadData()

        // Update DAG view — show if any subagents have dependencies
        let allSubagents = rows.flatMap { $0.tab.subagentTracker.orderedSubagents }
        let hasDeps = allSubagents.contains { !$0.dependsOn.isEmpty }
        if hasDeps {
            dagView.update(subagents: allSubagents)
            dagView.invalidateIntrinsicContentSize()
            dagHeightConstraint?.constant = min(dagView.intrinsicContentSize.height, 150)
        } else {
            dagView.update(subagents: [])
            dagHeightConstraint?.constant = 0
        }
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        displayRows.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < displayRows.count, let colId = tableColumn?.identifier.rawValue else { return nil }

        switch displayRows[row] {
        case .agent(let agent):
            return viewForAgent(agent, column: colId, row: row)
        case .subagent(let sub, _):
            return viewForSubagent(sub, column: colId, row: row)
        }
    }

    private func viewForAgent(_ agent: AgentRow, column colId: String, row: Int) -> NSView? {
        switch colId {
        case "status":
            return makeStatusDot(agent)
        case "model":
            return makeLabel(agent.modelName)
        case "dir":
            return makeLabel((agent.workingDir as NSString).lastPathComponent)
        case "phase":
            return makeLabel(agent.phase)
        case "tokens":
            let tracker = agent.tab.tokenTracker
            return makeLabel("\(formatTokenCount(tracker.currentInput)) ctx / \(formatTokenCount(tracker.totalOutput)) out")
        case "cost":
            let cost = agent.tab.tokenTracker.estimatedCost
            let label = makeLabel(String(format: "$%.3f", cost))
            if cost > 0.5 {
                (label.subviews.first as? NSTextField)?.textColor = NSColor(red: 1.0, green: 0.6, blue: 0.3, alpha: 1.0)
            }
            return label
        case "elapsed":
            if let start = agent.tab.sessionStartTime {
                let elapsed = Int(Date().timeIntervalSince(start))
                let m = elapsed / 60
                let s = elapsed % 60
                return makeLabel(String(format: "%d:%02d", m, s))
            }
            return makeLabel("—")
        case "kill":
            return makeKillButton(row)
        default:
            return nil
        }
    }

    private func viewForSubagent(_ sub: SubagentState, column colId: String, row: Int) -> NSView? {
        switch colId {
        case "status":
            return makeSubagentStatusDot(sub)
        case "model":
            // Indented name/role
            let display = sub.role.map { "\(sub.name) (\($0))" } ?? sub.name
            return makeLabel("  ↳ \(display)")
        case "dir":
            return makeLabel("")
        case "phase":
            return makeLabel(sub.phase)
        case "tokens":
            return makeLabel(sub.tokensUsed > 0 ? formatTokenCount(Int(sub.tokensUsed)) : "—")
        case "cost":
            return makeLabel("—")
        case "elapsed":
            let elapsed = Int(sub.elapsed)
            let m = elapsed / 60
            let s = elapsed % 60
            return makeLabel(String(format: "%d:%02d", m, s))
        case "kill":
            if sub.isActive {
                return makeSubagentKillButton(row)
            }
            return makeLabel("")
        default:
            return nil
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = NSTableRowView()
        rowView.wantsLayer = true
        guard row < displayRows.count else { return rowView }
        switch displayRows[row] {
        case .agent(let agent):
            if agent.isGenerating {
                rowView.backgroundColor = NSColor(red: 0.1, green: 0.15, blue: 0.1, alpha: 1.0)
            } else if row % 2 == 0 {
                rowView.backgroundColor = NSColor(white: 0.14, alpha: 1.0)
            } else {
                rowView.backgroundColor = .clear
            }
        case .subagent(let sub, _):
            if sub.isActive {
                rowView.backgroundColor = NSColor(red: 0.08, green: 0.12, blue: 0.18, alpha: 1.0)
            } else {
                rowView.backgroundColor = NSColor(white: 0.11, alpha: 1.0)
            }
        }
        return rowView
    }

    // MARK: - Cell Factories

    private func makeLabel(_ text: String) -> NSView {
        let cell = NSView()
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = NSColor(white: 0.90, alpha: 1.0)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func makeStatusDot(_ agent: AgentRow) -> NSView {
        let cell = NSView()
        let dot = NSView()
        dot.wantsLayer = true
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.layer?.cornerRadius = 5

        if agent.isDanger {
            dot.layer?.backgroundColor = NSColor.orange.cgColor
        } else if agent.isGenerating {
            dot.layer?.backgroundColor = NSColor(red: 0.3, green: 0.85, blue: 0.4, alpha: 1.0).cgColor
        } else {
            dot.layer?.backgroundColor = NSColor(white: 0.4, alpha: 1.0).cgColor
        }

        cell.addSubview(dot)
        NSLayoutConstraint.activate([
            dot.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
            dot.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 10),
            dot.heightAnchor.constraint(equalToConstant: 10),
        ])
        return cell
    }

    private func makeKillButton(_ row: Int) -> NSView {
        let cell = NSView()
        let btn = NSButton(title: "Kill", target: self, action: #selector(killAgent(_:)))
        btn.tag = row
        btn.bezelStyle = .rounded
        btn.focusRingType = .none
        btn.refusesFirstResponder = true
        btn.contentTintColor = .systemRed
        btn.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        btn.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(btn)
        NSLayoutConstraint.activate([
            btn.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
            btn.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    @objc private func killAgent(_ sender: NSButton) {
        let row = sender.tag
        guard row < displayRows.count else { return }
        guard case .agent(let agent) = displayRows[row] else { return }

        let alert = NSAlert()
        alert.messageText = "Kill Agent?"
        alert.informativeText = "This will terminate the \(agent.modelName) session in \((agent.workingDir as NSString).lastPathComponent)."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Kill")
        alert.addButton(withTitle: "Cancel")

        guard let window = self.window else { return }
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                agent.terminal.cleanup()
            }
        }
    }

    @objc private func killSubagent(_ sender: NSButton) {
        let row = sender.tag
        guard row < displayRows.count else { return }
        guard case .subagent(let sub, let client) = displayRows[row] else { return }

        let alert = NSAlert()
        alert.messageText = "Cancel Subagent?"
        alert.informativeText = "This will cancel the \(sub.name) subagent."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel Subagent")
        alert.addButton(withTitle: "Keep Running")

        guard let window = self.window else { return }
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                _ = client?.cancelSubagent(id: sub.id)
            }
        }
    }

    // MARK: - Helpers

    private func makeSubagentStatusDot(_ sub: SubagentState) -> NSView {
        let cell = NSView()
        let dot = NSView()
        dot.wantsLayer = true
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.layer?.cornerRadius = 4

        switch sub.status {
        case .running:
            dot.layer?.backgroundColor = NSColor(red: 0.3, green: 0.6, blue: 1.0, alpha: 1.0).cgColor
        case .completed:
            dot.layer?.backgroundColor = NSColor(red: 0.3, green: 0.85, blue: 0.4, alpha: 1.0).cgColor
        case .error:
            dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        }

        cell.addSubview(dot)
        NSLayoutConstraint.activate([
            dot.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
            dot.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
        ])
        return cell
    }

    private func makeSubagentKillButton(_ row: Int) -> NSView {
        let cell = NSView()
        let btn = NSButton(title: "Stop", target: self, action: #selector(killSubagent(_:)))
        btn.tag = row
        btn.bezelStyle = .rounded
        btn.focusRingType = .none
        btn.refusesFirstResponder = true
        btn.contentTintColor = .systemOrange
        btn.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        btn.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(btn)
        NSLayoutConstraint.activate([
            btn.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
            btn.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func formatTokenCount(_ n: Int) -> String {
        if n >= 1_000_000 {
            return String(format: "%.1fM", Double(n) / 1_000_000.0)
        } else if n >= 1_000 {
            return String(format: "%.1fk", Double(n) / 1_000.0)
        }
        return "\(n)"
    }
}

/// Minimal NSTableHeaderView subclass to style the header row.
private class NSTableHeader: NSTableHeaderView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.15, alpha: 1.0).setFill()
        dirtyRect.fill()
        super.draw(dirtyRect)
    }
}
