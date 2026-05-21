import CAwalTerminal
import Foundation

/// Manages an ACP connection to kiro-cli.
class ACPClient {
    private var handle: OpaquePointer?
    private var pollTimer: DispatchSourceTimer?

    var onTextChunk: ((String) -> Void)?
    var onTurnEnd: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onToolCallStarted: ((ToolCallState) -> Void)?
    var onToolCallUpdated: ((String, ToolCallStatus, String?) -> Void)?
    var onSessionReady: (() -> Void)?
    var onProcessExited: ((Int32?) -> Void)?
    var onPermissionRequest: ((PermissionRequest) -> Void)?

    private(set) var activeToolCalls: [String: ToolCallState] = [:]

    struct PermissionRequest {
        let requestId: UInt64
        let toolCallId: String
        let toolName: String
        let description: String
        let kind: ToolCallKind
    }

    func spawn(kiroPath: String, cwd: String) -> Bool {
        let h: OpaquePointer? = kiroPath.withCString { kiroPtr in
            cwd.withCString { cwdPtr in
                at_acp_spawn(kiroPtr, cwdPtr)
            }
        }
        guard let h else { return false }
        handle = h
        startPolling()
        return true
    }

    func sendPrompt(_ text: String) -> Bool {
        guard let handle else { return false }
        return text.withCString { textPtr in
            at_acp_send_prompt(handle, textPtr) == 0
        }
    }

    func cancel() -> Bool {
        guard let handle else { return false }
        return at_acp_cancel(handle) == 0
    }

    func respondPermission(requestId: UInt64, approved: Bool) {
        guard let handle else { return }
        _ = at_acp_respond_permission(handle, requestId, approved)
    }

    func destroy() {
        pollTimer?.cancel()
        pollTimer = nil
        if let handle {
            at_acp_destroy(handle)
            self.handle = nil
        }
    }

    deinit {
        destroy()
    }

    // MARK: - Private

    private func startPolling() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(16))
        timer.setEventHandler { [weak self] in
            self?.pollEvents()
        }
        timer.resume()
        pollTimer = timer
    }

    private func pollEvents() {
        guard let handle else { return }
        var budget = 100
        while budget > 0, let event = at_acp_poll_event(handle) {
            budget -= 1
            defer { at_acp_free_event(event) }
            let type_ = event.pointee.event_type
            let text: String? = event.pointee.text.map { String(cString: $0) }
            let text2: String? = event.pointee.text2.map { String(cString: $0) }

            switch type_ {
            case 0: // Initialized — wait for SessionCreated
                break
            case 1: // SessionCreated
                onSessionReady?()
            case 2: // TextChunk
                if let text { onTextChunk?(text) }
            case 3: // ToolCall
                if let title = text, let meta = text2 {
                    let parts = meta.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
                    let id = parts.count > 0 ? String(parts[0]) : ""
                    let statusStr = parts.count > 1 ? String(parts[1]) : ""
                    let kindStr = parts.count > 2 ? String(parts[2]) : ""
                    let kind = ToolCallKind(rawValue: kindStr) ?? .unknown
                    let status: ToolCallStatus = statusStr == "completed" ? .completed
                        : statusStr == "failed" ? .failed
                        : statusStr == "running" ? .running : .pending
                    let state = ToolCallState(id: id, title: title, kind: kind, status: status)
                    activeToolCalls[id] = state
                    onToolCallStarted?(state)
                }
            case 4: // ToolCallUpdate
                if let meta = text2 {
                    let parts = meta.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                    let id = parts.count > 0 ? String(parts[0]) : ""
                    let statusStr = parts.count > 1 ? String(parts[1]) : ""
                    let status: ToolCallStatus = statusStr == "completed" ? .completed
                        : statusStr == "failed" ? .failed
                        : statusStr == "running" ? .running : .pending
                    let content = (text?.isEmpty == false) ? text : nil
                    if let existing = activeToolCalls[id] {
                        existing.status = status
                        if let c = content { existing.content += c }
                    }
                    onToolCallUpdated?(id, status, content)
                }
            case 5: // TurnEnd
                activeToolCalls.removeAll()
                onTurnEnd?(text2 ?? "")
            case 6: // Error
                if let text { onError?(text) }
            case 7: // ProcessExited
                let code = text.flatMap { Int32($0) }
                onProcessExited?(code)
                destroy()
            case 8: // PermissionRequest
                if let desc = text, let meta = text2 {
                    let parts = meta.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
                    guard let requestId = parts.first.flatMap({ UInt64($0) }), requestId > 0 else { break }
                    let toolCallId = parts.count > 1 ? String(parts[1]) : ""
                    let toolName = parts.count > 2 ? String(parts[2]) : ""
                    let kindStr = parts.count > 3 ? String(parts[3]) : ""
                    let kind = ToolCallKind(rawValue: kindStr) ?? .unknown
                    let request = PermissionRequest(
                        requestId: requestId, toolCallId: toolCallId,
                        toolName: toolName, description: desc, kind: kind
                    )
                    handlePermissionRequest(request)
                }
            default:
                break
            }
        }
    }

    private func handlePermissionRequest(_ request: PermissionRequest) {
        let trust = AppConfig.shared.kiroTrustLevel
        switch trust {
        case .all:
            // Should not receive requests with trust=all (--trust-all-tools), but auto-approve if we do
            respondPermission(requestId: request.requestId, approved: true)
        case .safe:
            let safeKinds: Set<ToolCallKind> = [.read, .glob, .grep, .code]
            if safeKinds.contains(request.kind) {
                respondPermission(requestId: request.requestId, approved: true)
            } else {
                onPermissionRequest?(request)
            }
        case .none:
            onPermissionRequest?(request)
        }
    }
}
