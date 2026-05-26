import AppKit

private class ChatTextView: NSTextView {
    var onCtrlC: (() -> Void)?
    var onEscape: (() -> Void)?
    var onSubmit: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), event.charactersIgnoringModifiers == "c" {
            onCtrlC?()
            return
        }
        if event.keyCode == 53 {
            onEscape?()
            return
        }
        if event.keyCode == 36, !event.modifierFlags.contains(.shift) {
            onSubmit?()
            return
        }
        super.keyDown(with: event)
    }
}

class ChatInputView: NSView, NSTextViewDelegate {

    var onSubmit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onRewind: (() -> Void)?

    private let scrollView = NSScrollView()
    private let textView = ChatTextView()
    private let sendButton = NSButton()
    private let rewindButton: NSButton = {
        let btn = NSButton(title: "⏪", target: nil, action: nil)
        btn.bezelStyle = .inline
        btn.isBordered = false
        btn.font = NSFont.systemFont(ofSize: 13)
        btn.toolTip = "Rewind last turn"
        btn.isHidden = true
        btn.translatesAutoresizingMaskIntoConstraints = false
        return btn
    }()
    private let placeholderLabel = NSTextField(labelWithString: "Send a message...")
    private var heightConstraint: NSLayoutConstraint!
    private var maxHeightConstraint: NSLayoutConstraint!
    private var isPrompting = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupView() {
        let config = AppConfig.shared

        // Scroll view + text view
        let font = config.resolvedFont
        textView.font = font
        textView.textColor = config.themeFg
        textView.insertionPointColor = config.themeFg
        textView.backgroundColor = config.themeBg
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.allowsUndo = true
        textView.delegate = self
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.setAccessibilityLabel("Chat message input")

        textView.onCtrlC = { [weak self] in self?.handleCancel() }
        textView.onEscape = { [weak self] in self?.handleCancel() }
        textView.onSubmit = { [weak self] in self?.submit() }

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.wantsLayer = true
        scrollView.layer?.backgroundColor = textView.backgroundColor.cgColor
        addSubview(scrollView)

        // Placeholder
        placeholderLabel.textColor = config.themeFg.withAlphaComponent(0.4)
        placeholderLabel.font = font
        placeholderLabel.isEditable = false
        placeholderLabel.isBordered = false
        placeholderLabel.drawsBackground = false
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholderLabel)

        // Rewind button
        rewindButton.target = self
        rewindButton.action = #selector(rewindClicked)
        addSubview(rewindButton)

        // Send button
        sendButton.image = NSImage(systemSymbolName: "arrow.up.circle.fill", accessibilityDescription: "Send")
        sendButton.contentTintColor = config.themeAccent
        sendButton.isBordered = false
        sendButton.target = self
        sendButton.action = #selector(sendClicked)
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.isHidden = true
        addSubview(sendButton)

        // Layout — no separator, seamless with terminal above
        translatesAutoresizingMaskIntoConstraints = false
        let lineHeight = font.ascender - font.descender + font.leading
        let baseHeight = lineHeight * 3 + 16 // 3 lines + insets
        heightConstraint = heightAnchor.constraint(equalToConstant: baseHeight)
        heightConstraint.priority = .defaultHigh

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: rewindButton.leadingAnchor, constant: -4),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),

            placeholderLabel.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 13),
            placeholderLabel.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 8),

            rewindButton.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -4),
            rewindButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            rewindButton.widthAnchor.constraint(equalToConstant: 24),
            rewindButton.heightAnchor.constraint(equalToConstant: 24),

            sendButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 0),
            sendButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            sendButton.widthAnchor.constraint(equalToConstant: 24),
            sendButton.heightAnchor.constraint(equalToConstant: 24),

            heightConstraint,
        ])
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard let superview else { return }
        maxHeightConstraint?.isActive = false
        maxHeightConstraint = heightAnchor.constraint(lessThanOrEqualTo: superview.heightAnchor, multiplier: 0.5)
        maxHeightConstraint.isActive = true
    }

    // MARK: - Public API

    func setEnabled(_ enabled: Bool) {
        isPrompting = !enabled
        textView.isEditable = enabled
        alphaValue = enabled ? 1.0 : 0.5
    }

    func setPlaceholder(_ text: String) {
        placeholderLabel.stringValue = text
    }

    func focus() {
        window?.makeFirstResponder(textView)
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        let hasText = !textView.string.isEmpty
        placeholderLabel.isHidden = hasText
        sendButton.isHidden = !hasText
        updateHeight()
    }

    // MARK: - Private

    @objc private func sendClicked() {
        submit()
    }

    @objc private func rewindClicked() {
        onRewind?()
    }

    func setRewindVisible(_ visible: Bool) {
        rewindButton.isHidden = !visible
    }

    private func submit() {
        let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        textView.string = ""
        textDidChange(Notification(name: NSText.didChangeNotification))
        onSubmit?(text)
    }

    private func handleCancel() {
        if isPrompting {
            onCancel?()
        } else {
            textView.string = ""
            textDidChange(Notification(name: NSText.didChangeNotification))
        }
    }

    private func updateHeight() {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        layoutManager.ensureLayout(for: container)
        let textHeight = layoutManager.usedRect(for: container).height
        let newHeight = textHeight + 16 + 8 // insets + padding
        heightConstraint.constant = max(newHeight, 30)
        invalidateIntrinsicContentSize()
    }
}
