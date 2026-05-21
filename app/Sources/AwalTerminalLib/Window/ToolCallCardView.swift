import AppKit

class ToolCallCardView: NSView {

    private let state: ToolCallState
    private let headerStack = NSStackView()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let statusPill = NSTextField(labelWithString: "")
    private let disclosureButton = NSButton()
    private let contentScrollView = NSScrollView()
    private let contentTextView = NSTextView()
    private var isExpanded = false

    private static let monoFont = NSFont.monospacedSystemFont(ofSize: 11.0, weight: .regular)
    private static let cardBg = NSColor(red: 26.0/255.0, green: 26.0/255.0, blue: 26.0/255.0, alpha: 1.0)
    private static let borderColor = NSColor(red: 51.0/255.0, green: 51.0/255.0, blue: 51.0/255.0, alpha: 1.0)
    private static let maxContentHeight: CGFloat = 200.0

    init(state: ToolCallState) {
        self.state = state
        super.init(frame: .zero)
        setupView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupView() {
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = Self.cardBg.cgColor
        layer?.borderColor = Self.borderColor.cgColor
        layer?.borderWidth = 1

        // Icon
        if let img = NSImage(systemSymbolName: state.kind.icon, accessibilityDescription: state.kind.rawValue) {
            iconView.image = img
        }
        iconView.contentTintColor = .secondaryLabelColor
        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
        ])

        // Title
        titleLabel.stringValue = state.title
        titleLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = NSColor(white: 0.85, alpha: 1.0)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Status pill
        statusPill.font = NSFont.systemFont(ofSize: 9, weight: .medium)
        statusPill.isBordered = false
        statusPill.drawsBackground = true
        statusPill.wantsLayer = true
        statusPill.layer?.cornerRadius = 4
        statusPill.alignment = .center
        statusPill.setContentHuggingPriority(.required, for: .horizontal)
        updateStatusPill()

        // Disclosure
        disclosureButton.bezelStyle = .disclosure
        disclosureButton.title = ""
        disclosureButton.state = .off
        disclosureButton.target = self
        disclosureButton.action = #selector(toggleContent(_:))
        disclosureButton.setContentHuggingPriority(.required, for: .horizontal)

        // Header stack
        headerStack.orientation = .horizontal
        headerStack.spacing = 6
        headerStack.alignment = .centerY
        headerStack.addArrangedSubview(iconView)
        headerStack.addArrangedSubview(titleLabel)
        headerStack.addArrangedSubview(statusPill)
        headerStack.addArrangedSubview(disclosureButton)
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerStack)

        // Content text view
        contentTextView.isEditable = false
        contentTextView.isSelectable = true
        contentTextView.backgroundColor = NSColor(red: 30.0/255.0, green: 30.0/255.0, blue: 30.0/255.0, alpha: 1.0)
        contentTextView.font = Self.monoFont
        contentTextView.textColor = NSColor(white: 0.7, alpha: 1.0)
        contentTextView.textContainerInset = NSSize(width: 6, height: 4)
        contentTextView.isVerticallyResizable = true
        contentTextView.isHorizontallyResizable = false
        contentTextView.autoresizingMask = [.width]
        contentTextView.textContainer?.widthTracksTextView = true

        contentScrollView.documentView = contentTextView
        contentScrollView.hasVerticalScroller = true
        contentScrollView.autohidesScrollers = true
        contentScrollView.drawsBackground = false
        contentScrollView.borderType = .noBorder
        contentScrollView.translatesAutoresizingMaskIntoConstraints = false
        contentScrollView.isHidden = true
        addSubview(contentScrollView)

        NSLayoutConstraint.activate([
            headerStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            headerStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            headerStack.topAnchor.constraint(equalTo: topAnchor, constant: 6),

            contentScrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            contentScrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            contentScrollView.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 4),
            contentScrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            contentScrollView.heightAnchor.constraint(lessThanOrEqualToConstant: Self.maxContentHeight),

            heightAnchor.constraint(greaterThanOrEqualToConstant: 30),
        ])

        // Click header to toggle
        let click = NSClickGestureRecognizer(target: self, action: #selector(toggleContent))
        headerStack.addGestureRecognizer(click)
    }

    func update(status: ToolCallStatus, content: String?) {
        state.status = status
        if let c = content {
            state.content += c
        }
        updateStatusPill()
        if isExpanded {
            renderContent()
        }
    }

    func setExpanded(_ expanded: Bool) {
        isExpanded = expanded
        contentScrollView.isHidden = !expanded
        disclosureButton.state = expanded ? .on : .off
        if expanded { renderContent() }
        invalidateIntrinsicContentSize()
    }

    @objc private func toggleContent(_ sender: Any?) {
        if let gesture = sender as? NSGestureRecognizer {
            let loc = gesture.location(in: disclosureButton)
            if disclosureButton.bounds.contains(loc) { return }
        }
        setExpanded(!isExpanded)
    }

    private func updateStatusPill() {
        let (text, bg): (String, NSColor) = {
            switch state.status {
            case .pending: return ("pending", NSColor(white: 0.4, alpha: 1.0))
            case .running: return ("running", NSColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1.0))
            case .completed: return ("done", NSColor(red: 0.2, green: 0.7, blue: 0.3, alpha: 1.0))
            case .failed: return ("failed", NSColor(red: 0.8, green: 0.2, blue: 0.2, alpha: 1.0))
            }
        }()
        statusPill.stringValue = " \(text) "
        statusPill.textColor = .white
        statusPill.backgroundColor = bg
    }

    private func renderContent() {
        guard !state.content.isEmpty else { return }
        if state.kind == .write {
            renderDiff(state.content)
        } else {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: Self.monoFont,
                .foregroundColor: NSColor(white: 0.7, alpha: 1.0),
            ]
            contentTextView.textStorage?.setAttributedString(
                NSAttributedString(string: state.content, attributes: attrs)
            )
        }
    }

    private func renderDiff(_ text: String) {
        let attributed = NSMutableAttributedString()
        let lines = text.components(separatedBy: "\n")
        let greenBg = NSColor(red: 40.0/255.0, green: 80.0/255.0, blue: 40.0/255.0, alpha: 0.4)
        let redBg = NSColor(red: 100.0/255.0, green: 30.0/255.0, blue: 30.0/255.0, alpha: 0.4)
        let greenText = NSColor(red: 120.0/255.0, green: 220.0/255.0, blue: 120.0/255.0, alpha: 1.0)
        let redText = NSColor(red: 240.0/255.0, green: 100.0/255.0, blue: 100.0/255.0, alpha: 1.0)
        let hunkText = NSColor(red: 100.0/255.0, green: 150.0/255.0, blue: 220.0/255.0, alpha: 1.0)
        let defaultText = NSColor(white: 0.7, alpha: 1.0)

        for (i, line) in lines.enumerated() {
            var attrs: [NSAttributedString.Key: Any] = [.font: Self.monoFont]
            let suffix = (i < lines.count - 1) ? "\n" : ""
            if line.hasPrefix("@@") {
                attrs[.foregroundColor] = hunkText
                attrs[.font] = NSFont.monospacedSystemFont(ofSize: 11.0, weight: .medium)
            } else if line.hasPrefix("+++") || line.hasPrefix("---") {
                attrs[.foregroundColor] = defaultText
            } else if line.hasPrefix("+") {
                attrs[.foregroundColor] = greenText
                attrs[.backgroundColor] = greenBg
            } else if line.hasPrefix("-") {
                attrs[.foregroundColor] = redText
                attrs[.backgroundColor] = redBg
            } else {
                attrs[.foregroundColor] = defaultText
            }
            attributed.append(NSAttributedString(string: line + suffix, attributes: attrs))
        }
        contentTextView.textStorage?.setAttributedString(attributed)
    }
}
