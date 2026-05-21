import AppKit

protocol PermissionApprovalDelegate: AnyObject {
    func permissionApproved(requestId: UInt64)
    func permissionRejected(requestId: UInt64)
}

class PermissionApprovalView: NSView {

    let requestId: UInt64
    weak var delegate: PermissionApprovalDelegate?

    private let titleLabel = NSTextField(labelWithString: "")
    private let descriptionLabel = NSTextField(labelWithString: "")
    private let kindPill = NSTextField(labelWithString: "")
    private let countdownLabel = NSTextField(labelWithString: "")
    private let approveButton = NSButton()
    private let rejectButton = NSButton()
    private var countdownTimer: Timer?
    private var remainingSeconds: Int

    private static let cardBg = NSColor(red: 26.0/255.0, green: 26.0/255.0, blue: 26.0/255.0, alpha: 1.0)
    private static let borderColor = NSColor(red: 51.0/255.0, green: 51.0/255.0, blue: 51.0/255.0, alpha: 1.0)

    init(request: ACPClient.PermissionRequest, timeout: Int) {
        self.requestId = request.requestId
        self.remainingSeconds = timeout
        super.init(frame: .zero)
        setupView(request: request)
        startCountdown()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        countdownTimer?.invalidate()
    }

    private func setupView(request: ACPClient.PermissionRequest) {
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = Self.cardBg.cgColor
        layer?.borderColor = Self.borderColor.cgColor
        layer?.borderWidth = 1

        // Icon
        let iconName = request.kind == .shell ? "exclamationmark.shield" : "lock.shield"
        let iconView = NSImageView()
        if let img = NSImage(systemSymbolName: iconName, accessibilityDescription: "Permission") {
            iconView.image = img
        }
        iconView.contentTintColor = .systemOrange
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 16).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 16).isActive = true

        // Title
        titleLabel.stringValue = request.toolName
        titleLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = NSColor(white: 0.9, alpha: 1.0)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Kind pill
        let kindText = request.kind.rawValue
        kindPill.stringValue = " \(kindText) "
        kindPill.font = NSFont.systemFont(ofSize: 9, weight: .medium)
        kindPill.textColor = .white
        kindPill.isBordered = false
        kindPill.drawsBackground = true
        kindPill.wantsLayer = true
        kindPill.layer?.cornerRadius = 4
        kindPill.backgroundColor = kindColor(for: request.kind)
        kindPill.setContentHuggingPriority(.required, for: .horizontal)

        // Header row
        let headerStack = NSStackView(views: [iconView, titleLabel, kindPill])
        headerStack.orientation = .horizontal
        headerStack.spacing = 6
        headerStack.alignment = .centerY

        // Description
        descriptionLabel.stringValue = request.description
        descriptionLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        descriptionLabel.textColor = NSColor(white: 0.7, alpha: 1.0)
        descriptionLabel.lineBreakMode = .byTruncatingTail
        descriptionLabel.maximumNumberOfLines = 2

        // Buttons
        approveButton.title = "Approve"
        approveButton.bezelStyle = .rounded
        approveButton.controlSize = .small
        approveButton.contentTintColor = .systemGreen
        approveButton.target = self
        approveButton.action = #selector(approveClicked)
        approveButton.keyEquivalent = "\r"
        approveButton.setAccessibilityLabel("Approve permission")

        rejectButton.title = "Reject"
        rejectButton.bezelStyle = .rounded
        rejectButton.controlSize = .small
        rejectButton.contentTintColor = .systemRed
        rejectButton.target = self
        rejectButton.action = #selector(rejectClicked)
        rejectButton.keyEquivalent = "\u{1b}"
        rejectButton.setAccessibilityLabel("Reject permission")

        // Countdown
        countdownLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        countdownLabel.textColor = NSColor(white: 0.5, alpha: 1.0)
        updateCountdownText()

        let buttonStack = NSStackView(views: [approveButton, rejectButton, countdownLabel])
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 8
        buttonStack.alignment = .centerY

        // Main stack
        let mainStack = NSStackView(views: [headerStack, descriptionLabel, buttonStack])
        mainStack.orientation = .vertical
        mainStack.spacing = 4
        mainStack.alignment = .leading
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(mainStack)

        NSLayoutConstraint.activate([
            mainStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            mainStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            mainStack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            mainStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }

    @objc private func approveClicked() {
        countdownTimer?.invalidate()
        delegate?.permissionApproved(requestId: requestId)
    }

    @objc private func rejectClicked() {
        countdownTimer?.invalidate()
        delegate?.permissionRejected(requestId: requestId)
    }

    private func startCountdown() {
        guard remainingSeconds > 0 else { return }
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.remainingSeconds -= 1
            self.updateCountdownText()
            if self.remainingSeconds <= 0 {
                self.countdownTimer?.invalidate()
                self.delegate?.permissionRejected(requestId: self.requestId)
            }
        }
    }

    private func updateCountdownText() {
        countdownLabel.stringValue = remainingSeconds > 0 ? "\(remainingSeconds)s" : ""
    }

    private func kindColor(for kind: ToolCallKind) -> NSColor {
        switch kind {
        case .write: return NSColor(red: 0.8, green: 0.4, blue: 0.1, alpha: 1.0)
        case .shell: return NSColor(red: 0.8, green: 0.2, blue: 0.2, alpha: 1.0)
        case .read, .glob, .grep, .code: return NSColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1.0)
        case .unknown: return NSColor(white: 0.4, alpha: 1.0)
        }
    }
}
