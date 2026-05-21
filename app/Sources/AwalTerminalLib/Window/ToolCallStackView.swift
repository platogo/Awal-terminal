import AppKit

class ToolCallStackView: NSView {

    private let scrollView = NSScrollView()
    private let stackView = NSStackView()
    private var cardMap: [String: ToolCallCardView] = [:]
    private var permissionCards: [UInt64: PermissionApprovalView] = [:]
    weak var permissionDelegate: PermissionApprovalDelegate?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupView() {
        stackView.orientation = .vertical
        stackView.spacing = 6
        stackView.alignment = .leading
        stackView.translatesAutoresizingMaskIntoConstraints = false

        let clipView = NSClipView()
        clipView.documentView = stackView
        clipView.drawsBackground = false

        scrollView.contentView = clipView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            stackView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
        ])
    }

    func addToolCall(_ state: ToolCallState) {
        let card = ToolCallCardView(state: state)
        card.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
        cardMap[state.id] = card
    }

    func updateToolCall(id: String, status: ToolCallStatus, content: String?) {
        cardMap[id]?.update(status: status, content: content)
    }

    func clearAll() {
        stackView.arrangedSubviews.forEach {
            stackView.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        cardMap.removeAll()
    }

    private var allExpanded = false

    func toggleAllExpanded() {
        allExpanded.toggle()
        cardMap.values.forEach { $0.setExpanded(allExpanded) }
    }

    func addPermissionRequest(_ request: ACPClient.PermissionRequest) {
        let timeout = AppConfig.shared.kiroPermissionTimeout
        let card = PermissionApprovalView(request: request, timeout: timeout)
        card.delegate = permissionDelegate
        card.translatesAutoresizingMaskIntoConstraints = false
        stackView.insertArrangedSubview(card, at: 0)
        card.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
        permissionCards[request.requestId] = card
    }

    func removePermissionRequest(requestId: UInt64) {
        guard let card = permissionCards.removeValue(forKey: requestId) else { return }
        stackView.removeArrangedSubview(card)
        card.removeFromSuperview()
    }

    /// Handle keyboard shortcut for topmost permission card.
    /// Returns true if a permission action was taken.
    func handlePermissionKey(isEnter: Bool) -> Bool {
        guard let firstCard = stackView.arrangedSubviews
                    .compactMap({ $0 as? PermissionApprovalView })
                    .first else { return false }
        if isEnter {
            permissionDelegate?.permissionApproved(requestId: firstCard.requestId)
        } else {
            permissionDelegate?.permissionRejected(requestId: firstCard.requestId)
        }
        return true
    }

    var hasPendingPermissions: Bool {
        !permissionCards.isEmpty
    }
}
