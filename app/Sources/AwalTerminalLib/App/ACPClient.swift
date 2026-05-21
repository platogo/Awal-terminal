import CAwalTerminal
import Foundation

/// Manages an ACP connection to kiro-cli.
class ACPClient {
    private var handle: OpaquePointer?
    private var pollTimer: DispatchSourceTimer?

    var onTextChunk: ((String) -> Void)?
    var onTurnEnd: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onToolCall: ((String, String) -> Void)?
    var onSessionReady: (() -> Void)?
    var onProcessExited: ((Int32?) -> Void)?

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
                    let parts = meta.split(separator: "\t", maxSplits: 1)
                    let status = parts.count > 1 ? String(parts[1]) : ""
                    onToolCall?(title, status)
                }
            case 4: // ToolCallUpdate
                if let content = text, !content.isEmpty {
                    onTextChunk?(content)
                }
            case 5: // TurnEnd
                onTurnEnd?(text2 ?? "")
            case 6: // Error
                if let text { onError?(text) }
            case 7: // ProcessExited
                let code = text.flatMap { Int32($0) }
                onProcessExited?(code)
                destroy()
            default:
                break
            }
        }
    }
}
