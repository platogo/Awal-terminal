import AppKit

class ToolCallStackView: NSView {

    private let scrollView = NSScrollView()
    private let stackView = NSStackView()
    private var cardMap: [String: ToolCallCardView] = [:]

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
}
