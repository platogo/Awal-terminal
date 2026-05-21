import AppKit
import CAwalTerminal

/// Manages per-hunk accept/reject for a file diff from an AI agent write request.
class DiffReviewController: NSViewController {

    weak var parentPopover: NSPopover?
    var onResolve: ((_ finalContent: String) -> Void)?
    var onDismiss: (() -> Void)?

    private let filePath: String
    private let originalContent: String
    private let newContent: String
    private let diffText: String

    private let headerLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let modeToggle = NSSegmentedControl(labels: ["Unified", "Side-by-Side"], trackingMode: .selectOne, target: nil, action: nil)
    private let acceptAllButton = NSButton(title: "Accept All", target: nil, action: nil)
    private let rejectAllButton = NSButton(title: "Reject All", target: nil, action: nil)
    private let scrollView = NSScrollView()
    private let stackView = NSStackView()

    private var hunkViews: [HunkView] = []
    private var hunkAccepted: [Bool] = []
    private var isSideBySide = false

    private static let monoFont = NSFont.monospacedSystemFont(ofSize: 11.0, weight: .regular)
    private static let monoBoldFont = NSFont.monospacedSystemFont(ofSize: 11.0, weight: .medium)

    init(filePath: String, originalContent: String, newContent: String, diffText: String) {
        self.filePath = filePath
        self.originalContent = originalContent
        self.newContent = newContent
        self.diffText = diffText
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 450))
        container.wantsLayer = true

        // Header
        headerLabel.stringValue = (filePath as NSString).lastPathComponent
        headerLabel.font = Self.monoBoldFont
        headerLabel.textColor = NSColor(white: 0.8, alpha: 1.0)
        headerLabel.lineBreakMode = .byTruncatingMiddle
        headerLabel.toolTip = filePath
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(headerLabel)

        // Close button
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.title = ""
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")
        closeButton.contentTintColor = NSColor(white: 0.5, alpha: 1.0)
        closeButton.target = self
        closeButton.action = #selector(closePopover)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(closeButton)

        // Mode toggle
        modeToggle.selectedSegment = 0
        modeToggle.target = self
        modeToggle.action = #selector(modeChanged(_:))
        modeToggle.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(modeToggle)

        // Accept/Reject all buttons
        acceptAllButton.bezelStyle = .rounded
        acceptAllButton.contentTintColor = NSColor(red: 0.2, green: 0.7, blue: 0.3, alpha: 1.0)
        acceptAllButton.target = self
        acceptAllButton.action = #selector(acceptAll)
        acceptAllButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(acceptAllButton)

        rejectAllButton.bezelStyle = .rounded
        rejectAllButton.contentTintColor = NSColor(red: 0.8, green: 0.2, blue: 0.2, alpha: 1.0)
        rejectAllButton.target = self
        rejectAllButton.action = #selector(rejectAll)
        rejectAllButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(rejectAllButton)

        // Scroll view with hunk stack
        stackView.orientation = .vertical
        stackView.spacing = 2
        stackView.alignment = .leading
        stackView.translatesAutoresizingMaskIntoConstraints = false

        scrollView.documentView = stackView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            headerLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            headerLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            headerLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -4),

            closeButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            closeButton.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            closeButton.widthAnchor.constraint(equalToConstant: 20),
            closeButton.heightAnchor.constraint(equalToConstant: 20),

            modeToggle.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            modeToggle.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 6),

            rejectAllButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            rejectAllButton.centerYAnchor.constraint(equalTo: modeToggle.centerYAnchor),

            acceptAllButton.trailingAnchor.constraint(equalTo: rejectAllButton.leadingAnchor, constant: -6),
            acceptAllButton.centerYAnchor.constraint(equalTo: modeToggle.centerYAnchor),

            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: modeToggle.bottomAnchor, constant: 6),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            stackView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
        ])

        self.view = container
        parseAndRender()
    }

    // MARK: - Actions

    @objc private func closePopover() {
        onDismiss?()
        parentPopover?.performClose(nil)
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        isSideBySide = sender.selectedSegment == 1
        renderHunks()
    }

    @objc private func acceptAll() {
        for i in hunkAccepted.indices { hunkAccepted[i] = true }
        resolve()
    }

    @objc private func rejectAll() {
        for i in hunkAccepted.indices { hunkAccepted[i] = false }
        resolve()
    }

    func acceptHunk(at index: Int) {
        guard index < hunkAccepted.count else { return }
        hunkAccepted[index] = true
        hunkViews[index].setAccepted(true)
        checkAllResolved()
    }

    func rejectHunk(at index: Int) {
        guard index < hunkAccepted.count else { return }
        hunkAccepted[index] = false
        hunkViews[index].setAccepted(false)
        checkAllResolved()
    }

    /// Handle keyboard shortcuts. Returns true if handled.
    func handleKey(_ event: NSEvent) -> Bool {
        guard let chars = event.charactersIgnoringModifiers else { return false }
        switch chars {
        case "d":
            modeToggle.selectedSegment = isSideBySide ? 0 : 1
            modeChanged(modeToggle)
            return true
        case "a":
            acceptAll()
            return true
        case "r":
            rejectAll()
            return true
        default:
            return false
        }
    }

    // MARK: - Private

    private func parseAndRender() {
        let hunkCount = countHunks()
        hunkAccepted = Array(repeating: true, count: hunkCount) // default: accept all
        renderHunks()
    }

    private func countHunks() -> Int {
        diffText.components(separatedBy: "\n").filter { $0.hasPrefix("@@") }.count
    }

    private func renderHunks() {
        stackView.arrangedSubviews.forEach {
            stackView.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        hunkViews.removeAll()

        let hunks = parseDiffHunks()
        for (i, hunk) in hunks.enumerated() {
            let hunkView = HunkView(
                index: i,
                header: hunk.header,
                lines: hunk.lines,
                sideBySide: isSideBySide,
                accepted: hunkAccepted.indices.contains(i) ? hunkAccepted[i] : true
            )
            hunkView.onAccept = { [weak self] idx in self?.acceptHunk(at: idx) }
            hunkView.onReject = { [weak self] idx in self?.rejectHunk(at: idx) }
            hunkView.translatesAutoresizingMaskIntoConstraints = false
            stackView.addArrangedSubview(hunkView)
            hunkView.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
            hunkViews.append(hunkView)
        }
    }

    private func checkAllResolved() {
        // Auto-resolve when all hunks have been explicitly acted on
        // For now, don't auto-close — user can click Accept All / Reject All
    }

    private func resolve() {
        let result = diffText.withCString { diffPtr in
            originalContent.withCString { origPtr -> String in
                var accepted = hunkAccepted
                guard let resultPtr = at_acp_apply_hunks(
                    origPtr, diffPtr,
                    &accepted, UInt32(accepted.count)
                ) else {
                    return newContent // fallback
                }
                let str = String(cString: resultPtr)
                at_free_string(resultPtr)
                return str
            }
        }
        onResolve?(result)
        parentPopover?.performClose(nil)
    }

    fileprivate struct ParsedHunk {
        let header: String
        let lines: [(kind: DiffLineKind, content: String)]
    }

    fileprivate enum DiffLineKind {
        case context, add, remove
    }

    private func parseDiffHunks() -> [ParsedHunk] {
        var hunks: [ParsedHunk] = []
        var currentHeader = ""
        var currentLines: [(kind: DiffLineKind, content: String)] = []

        for line in diffText.components(separatedBy: "\n") {
            if line.hasPrefix("@@") {
                if !currentHeader.isEmpty {
                    hunks.append(ParsedHunk(header: currentHeader, lines: currentLines))
                }
                currentHeader = line
                currentLines = []
            } else if !currentHeader.isEmpty {
                if line.hasPrefix("+") {
                    currentLines.append((.add, String(line.dropFirst())))
                } else if line.hasPrefix("-") {
                    currentLines.append((.remove, String(line.dropFirst())))
                } else if line.hasPrefix(" ") {
                    currentLines.append((.context, String(line.dropFirst())))
                } else {
                    currentLines.append((.context, line))
                }
            }
        }
        if !currentHeader.isEmpty {
            hunks.append(ParsedHunk(header: currentHeader, lines: currentLines))
        }
        return hunks
    }
}

// MARK: - HunkView

private class HunkView: NSView {

    var onAccept: ((Int) -> Void)?
    var onReject: ((Int) -> Void)?

    private let index: Int
    private let headerLabel = NSTextField(labelWithString: "")
    private let acceptButton = NSButton()
    private let rejectButton = NSButton()
    private let contentView = NSTextView()
    private var accepted: Bool?

    private static let monoFont = NSFont.monospacedSystemFont(ofSize: 11.0, weight: .regular)
    private static let greenBg = NSColor(red: 40.0/255.0, green: 80.0/255.0, blue: 40.0/255.0, alpha: 0.4)
    private static let redBg = NSColor(red: 100.0/255.0, green: 30.0/255.0, blue: 30.0/255.0, alpha: 0.4)
    private static let greenText = NSColor(red: 120.0/255.0, green: 220.0/255.0, blue: 120.0/255.0, alpha: 1.0)
    private static let redText = NSColor(red: 240.0/255.0, green: 100.0/255.0, blue: 100.0/255.0, alpha: 1.0)
    private static let hunkText = NSColor(red: 100.0/255.0, green: 150.0/255.0, blue: 220.0/255.0, alpha: 1.0)
    private static let defaultText = NSColor(white: 0.7, alpha: 1.0)

    init(index: Int, header: String, lines: [(kind: DiffReviewController.DiffLineKind, content: String)], sideBySide: Bool, accepted: Bool) {
        self.index = index
        super.init(frame: .zero)
        self.accepted = accepted
        setupView(header: header, lines: lines, sideBySide: sideBySide)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setAccepted(_ value: Bool) {
        accepted = value
        updateButtonStates()
    }

    private func setupView(header: String, lines: [(kind: DiffReviewController.DiffLineKind, content: String)], sideBySide: Bool) {
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 26.0/255.0, green: 26.0/255.0, blue: 26.0/255.0, alpha: 1.0).cgColor
        layer?.cornerRadius = 4

        // Header row
        headerLabel.stringValue = header
        headerLabel.font = NSFont.monospacedSystemFont(ofSize: 10.0, weight: .medium)
        headerLabel.textColor = Self.hunkText
        headerLabel.isEditable = false
        headerLabel.isBordered = false
        headerLabel.drawsBackground = false
        headerLabel.lineBreakMode = .byTruncatingTail
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerLabel)

        // Accept button
        acceptButton.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: "Accept hunk")
        acceptButton.bezelStyle = .inline
        acceptButton.isBordered = false
        acceptButton.contentTintColor = NSColor(red: 0.2, green: 0.7, blue: 0.3, alpha: 1.0)
        acceptButton.target = self
        acceptButton.action = #selector(acceptTapped)
        acceptButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(acceptButton)

        // Reject button
        rejectButton.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: "Reject hunk")
        rejectButton.bezelStyle = .inline
        rejectButton.isBordered = false
        rejectButton.contentTintColor = NSColor(red: 0.8, green: 0.2, blue: 0.2, alpha: 1.0)
        rejectButton.target = self
        rejectButton.action = #selector(rejectTapped)
        rejectButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rejectButton)

        // Content
        contentView.isEditable = false
        contentView.isSelectable = true
        contentView.backgroundColor = NSColor(red: 30.0/255.0, green: 30.0/255.0, blue: 30.0/255.0, alpha: 1.0)
        contentView.textContainerInset = NSSize(width: 6, height: 2)
        contentView.isVerticallyResizable = true
        contentView.isHorizontallyResizable = false
        contentView.autoresizingMask = [.width]
        contentView.textContainer?.widthTracksTextView = true
        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView)

        NSLayoutConstraint.activate([
            headerLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            headerLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            headerLabel.trailingAnchor.constraint(equalTo: acceptButton.leadingAnchor, constant: -4),

            rejectButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            rejectButton.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            rejectButton.widthAnchor.constraint(equalToConstant: 20),
            rejectButton.heightAnchor.constraint(equalToConstant: 20),

            acceptButton.trailingAnchor.constraint(equalTo: rejectButton.leadingAnchor, constant: -2),
            acceptButton.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            acceptButton.widthAnchor.constraint(equalToConstant: 20),
            acceptButton.heightAnchor.constraint(equalToConstant: 20),

            contentView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            contentView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 2),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])

        if sideBySide {
            renderSideBySide(lines)
        } else {
            renderUnified(lines)
        }

        updateButtonStates()
    }

    @objc private func acceptTapped() { onAccept?(index) }
    @objc private func rejectTapped() { onReject?(index) }

    private func updateButtonStates() {
        acceptButton.alphaValue = accepted == true ? 1.0 : 0.4
        rejectButton.alphaValue = accepted == false ? 1.0 : 0.4
    }

    private func renderUnified(_ lines: [(kind: DiffReviewController.DiffLineKind, content: String)]) {
        let attributed = NSMutableAttributedString()
        for (i, line) in lines.enumerated() {
            var attrs: [NSAttributedString.Key: Any] = [.font: Self.monoFont]
            let prefix: String
            switch line.kind {
            case .add:
                prefix = "+"
                attrs[.foregroundColor] = Self.greenText
                attrs[.backgroundColor] = Self.greenBg
            case .remove:
                prefix = "-"
                attrs[.foregroundColor] = Self.redText
                attrs[.backgroundColor] = Self.redBg
            case .context:
                prefix = " "
                attrs[.foregroundColor] = Self.defaultText
            }
            let suffix = i < lines.count - 1 ? "\n" : ""
            attributed.append(NSAttributedString(string: prefix + line.content + suffix, attributes: attrs))
        }
        contentView.textStorage?.setAttributedString(attributed)
    }

    private func renderSideBySide(_ lines: [(kind: DiffReviewController.DiffLineKind, content: String)]) {
        // Build left (old) and right (new) columns
        let attributed = NSMutableAttributedString()
        let colWidth = 40 // chars per side

        var leftLines: [(String, NSColor, NSColor?)] = []
        var rightLines: [(String, NSColor, NSColor?)] = []

        for line in lines {
            switch line.kind {
            case .remove:
                leftLines.append((line.content, Self.redText, Self.redBg))
                rightLines.append(("", Self.defaultText, nil))
            case .add:
                leftLines.append(("", Self.defaultText, nil))
                rightLines.append((line.content, Self.greenText, Self.greenBg))
            case .context:
                leftLines.append((line.content, Self.defaultText, nil))
                rightLines.append((line.content, Self.defaultText, nil))
            }
        }

        // Pair up removes with adds where possible
        var paired: [(left: (String, NSColor, NSColor?), right: (String, NSColor, NSColor?))] = []
        var li = 0, ri = 0
        while li < leftLines.count && ri < rightLines.count {
            paired.append((leftLines[li], rightLines[ri]))
            li += 1
            ri += 1
        }

        for (i, pair) in paired.enumerated() {
            let leftStr = String(pair.left.0.prefix(colWidth)).padding(toLength: colWidth, withPad: " ", startingAt: 0)
            let rightStr = String(pair.right.0.prefix(colWidth))
            let sep = " \u{2502} "

            var leftAttrs: [NSAttributedString.Key: Any] = [.font: Self.monoFont, .foregroundColor: pair.left.1]
            if let bg = pair.left.2 { leftAttrs[.backgroundColor] = bg }

            var rightAttrs: [NSAttributedString.Key: Any] = [.font: Self.monoFont, .foregroundColor: pair.right.1]
            if let bg = pair.right.2 { rightAttrs[.backgroundColor] = bg }

            let sepAttrs: [NSAttributedString.Key: Any] = [.font: Self.monoFont, .foregroundColor: NSColor(white: 0.3, alpha: 1.0)]

            attributed.append(NSAttributedString(string: leftStr, attributes: leftAttrs))
            attributed.append(NSAttributedString(string: sep, attributes: sepAttrs))
            attributed.append(NSAttributedString(string: rightStr, attributes: rightAttrs))
            if i < paired.count - 1 {
                attributed.append(NSAttributedString(string: "\n", attributes: sepAttrs))
            }
        }

        contentView.textStorage?.setAttributedString(attributed)
    }
}
