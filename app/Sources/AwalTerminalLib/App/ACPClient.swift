import CAwalTerminal
import Foundation

/// Manages an ACP connection to kiro-cli.
class ACPClient {
    private var handle: OpaquePointer?
    private var pollTimer: DispatchSourceTimer?
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var lineBuffer = Data()
    private var readBuf = [UInt8](repeating: 0, count: 8192)
    private var stdoutSource: DispatchSourceRead?
    private var stderrSource: DispatchSourceRead?

    var onTextChunk: ((String) -> Void)?
    var onTurnEnd: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onToolCallStarted: ((ToolCallState) -> Void)?
    var onToolCallUpdated: ((String, ToolCallStatus, String?) -> Void)?
    var onSessionReady: (() -> Void)?
    var onProcessExited: ((Int32?) -> Void)?
    var onPermissionRequest: ((PermissionRequest) -> Void)?
    var onCancelled: (() -> Void)?
    var onRecovering: (() -> Void)?
    var onRecoveryFailed: (() -> Void)?
    var onAuthRequired: ((String) -> Void)?
    var onFsWriteRequest: ((UInt64, String, String) -> Void)?
    var onSubagentSpawned: ((String, String, String?, String?, [String]) -> Void)?
    var onSubagentProgress: ((String, String, UInt64?) -> Void)?
    var onSubagentComplete: ((String, UInt64?) -> Void)?
    var onSubagentError: ((String, String) -> Void)?

    private(set) var sessionId: String?
    private(set) var isPrompting: Bool = false
    private(set) var activeToolCalls: [String: ToolCallState] = [:]
    private(set) var totalCharsReceived: Int = 0
    private(set) var totalCharsSent: Int = 0
    private(set) var lastTurnCredits: Double = 0.0
    private(set) var totalCreditsUsed: Double = 0.0

    var estimatedTokens: Int { (totalCharsReceived + totalCharsSent) / 4 }

    /// Maximum events to process per poll tick (16ms) to avoid blocking render.
    private let maxEventsPerTick = 100

    struct PermissionRequest {
        let requestId: UInt64
        let toolCallId: String
        let toolName: String
        let description: String
        let kind: ToolCallKind
    }

    func spawn(kiroPath: String, cwd: String, agent: String? = nil, engine: String? = nil, trustTools: String? = nil, tokenPath: String? = nil) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: kiroPath)
        var args = ["acp"]
        if let a = agent { args += ["--agent", a] }
        if let e = engine { args += ["--agent-engine", e] }
        if let t = trustTools {
            if t == "all" { args.append("--trust-all-tools") }
            else { args += ["--trust-tools", t] }
        }
        if let tok = tokenPath { args += ["--token-path", tok] }
        proc.arguments = args
        proc.currentDirectoryURL = URL(fileURLWithPath: cwd)

        // GUI apps don't inherit shell PATH — set explicit environment
        var env = ProcessInfo.processInfo.environment
        let binDir = (kiroPath as NSString).deletingLastPathComponent
        let existing = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = "\(binDir):\(existing):/usr/local/bin:/opt/homebrew/bin"
        proc.environment = env

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do { try proc.run() } catch { return false }

        self.process = proc
        self.stdinPipe = inPipe
        self.stdoutPipe = outPipe
        self.stderrPipe = errPipe

        let stdinFd = dup(inPipe.fileHandleForWriting.fileDescriptor)
        guard stdinFd >= 0, let h = at_acp_create_writer(stdinFd) else {
            proc.terminate()
            return false
        }
        handle = h
        cwd.withCString { ptr in at_acp_set_cwd(h, ptr) }

        let outFd = outPipe.fileHandleForReading.fileDescriptor
        _ = fcntl(outFd, F_SETFL, fcntl(outFd, F_GETFL) | O_NONBLOCK)

        let outSource = DispatchSource.makeReadSource(fileDescriptor: outFd, queue: .main)
        outSource.setEventHandler { [weak self] in
            guard let self, let handle = self.handle else { return }
            let n = read(outFd, &self.readBuf, self.readBuf.count)
            if n > 0 {
                self.lineBuffer.append(contentsOf: self.readBuf[..<n])
                while let idx = self.lineBuffer.firstIndex(of: 0x0A) {
                    let lineData = self.lineBuffer[self.lineBuffer.startIndex..<idx]
                    self.lineBuffer = Data(self.lineBuffer[(idx + 1)...])
                    if !lineData.isEmpty, let line = String(data: lineData, encoding: .utf8) {
                        line.withCString { ptr in at_acp_feed_line(handle, ptr) }
                    }
                }
            } else if n == 0 || (n < 0 && errno != EAGAIN) {
                self.stdoutSource?.cancel()
                self.stdoutSource = nil
            }
        }
        outSource.resume()
        stdoutSource = outSource

        let errFd = errPipe.fileHandleForReading.fileDescriptor
        _ = fcntl(errFd, F_SETFL, fcntl(errFd, F_GETFL) | O_NONBLOCK)

        let errSource = DispatchSource.makeReadSource(fileDescriptor: errFd, queue: .main)
        errSource.setEventHandler { [weak self] in
            guard let self else { return }
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = read(errFd, &buf, buf.count)
            if n > 0 {
                if let str = String(bytes: buf[..<n], encoding: .utf8) {
                    for line in str.split(separator: "\n") {
                        debugLog("ACP stderr: \(line)")
                    }
                }
            } else if n == 0 || (n < 0 && errno != EAGAIN) {
                self.stderrSource?.cancel()
                self.stderrSource = nil
            }
        }
        errSource.resume()
        stderrSource = errSource

        proc.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                self?.stdoutSource?.cancel()
                self?.stdoutSource = nil
                self?.stderrSource?.cancel()
                self?.stderrSource = nil
                self?.onProcessExited?(proc.terminationStatus)
            }
        }

        startPolling()
        return true
    }

    func spawnAndResume(kiroPath: String, cwd: String, sessionId: String, engine: String? = nil, trustTools: String? = nil, tokenPath: String? = nil) -> Bool {
        guard spawn(kiroPath: kiroPath, cwd: cwd, engine: engine, trustTools: trustTools, tokenPath: tokenPath) else { return false }
        guard let handle else { return false }
        sessionId.withCString { ptr in at_acp_set_resume_session(handle, ptr) }
        return true
    }

    func getSessionId() -> String? {
        guard let handle else { return nil }
        guard let ptr = at_acp_get_session_id(handle) else { return nil }
        let str = String(cString: ptr)
        at_free_string(ptr)
        return str
    }

    func sendPrompt(_ text: String) -> Bool {
        guard let handle else { return false }
        isPrompting = true
        totalCharsSent += text.count
        return text.withCString { textPtr in
            at_acp_send_prompt(handle, textPtr) == 0
        }
    }

    func cancel() -> Bool {
        guard let handle else { return false }
        return at_acp_cancel(handle) == 0
    }

    func cancelSubagent(id: String) -> Bool {
        guard let handle else { return false }
        return id.withCString { idPtr in
            at_acp_cancel_subagent(handle, idPtr) == 0
        }
    }

    func sendRewind() -> Bool {
        guard let handle else { return false }
        return at_acp_send_rewind(handle) == 0
    }

    func forceKill() {
        guard let handle else { return }
        at_acp_force_kill(handle)
        stdoutSource?.cancel()
        stdoutSource = nil
        stderrSource?.cancel()
        stderrSource = nil
        process?.terminate()
        process = nil
    }

    func respondPermission(requestId: UInt64, approved: Bool) {
        guard let handle else { return }
        _ = at_acp_respond_permission(handle, requestId, approved)
    }

    func respondFsRead(requestId: UInt64, content: String?) {
        guard let handle else { return }
        if let content {
            content.withCString { ptr in
                _ = at_acp_respond_fs_read(handle, requestId, ptr)
            }
        } else {
            _ = at_acp_respond_fs_read(handle, requestId, nil)
        }
    }

    func respondFsWrite(requestId: UInt64, success: Bool) {
        guard let handle else { return }
        _ = at_acp_respond_fs_write(handle, requestId, success)
    }

    func destroy() {
        stdoutSource?.cancel()
        stdoutSource = nil
        stderrSource?.cancel()
        stderrSource = nil
        pollTimer?.cancel()
        pollTimer = nil
        process?.terminate()
        process = nil
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
        var eventsProcessed = 0
        while eventsProcessed < maxEventsPerTick, let event = at_acp_poll_event(handle) {
            defer { at_acp_free_event(event) }
            eventsProcessed += 1
            let type_ = event.pointee.event_type
            let text: String? = event.pointee.text.map { String(cString: $0) }
            let text2: String? = event.pointee.text2.map { String(cString: $0) }

            switch type_ {
            case 0: // Initialized — wait for SessionCreated
                break
            case 1: // SessionCreated
                if let text { sessionId = text }
                onSessionReady?()
            case 2: // TextChunk
                if let text {
                    totalCharsReceived += text.count
                    onTextChunk?(text)
                }
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
                isPrompting = false
                activeToolCalls.removeAll()
                lastTurnCredits = 0.0
                var stopReason = text2 ?? ""
                if let meta = text2 {
                    let parts = meta.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                    stopReason = parts.count > 0 ? String(parts[0]) : ""
                    if parts.count > 1, let c = Double(parts[1]) {
                        lastTurnCredits = c
                        totalCreditsUsed += c
                    }
                }
                onTurnEnd?(stopReason)
            case 6: // Error
                if let text { onError?(text) }
            case 7: // ProcessExited
                isPrompting = false
                let code = text.flatMap { Int32($0) }
                onProcessExited?(code)
            case 8: // PermissionRequest
                if let desc = text, let meta = text2 {
                    let parts = meta.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
                    let requestId = parts.count > 0 ? UInt64(parts[0]) ?? 0 : 0
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
            case 9: // Cancelled
                isPrompting = false
                onCancelled?()
            case 10: // AuthRequired
                isPrompting = false
                onAuthRequired?(text ?? "Authentication required")
            case 11: // FsReadRequest
                if let path = text, let meta = text2, let requestId = UInt64(meta) {
                    handleFsRead(requestId: requestId, path: path)
                }
            case 12: // FsWriteRequest
                if let content = text, let meta = text2 {
                    let parts = meta.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                    guard parts.count > 0, let requestId = UInt64(parts[0]) else {
                        NSLog("[ACP] FsWriteRequest: failed to parse requestId, skipping")
                        break
                    }
                    let path = parts.count > 1 ? String(parts[1]) : ""
                    if let handler = onFsWriteRequest {
                        handler(requestId, path, content)
                    } else {
                        // No handler — auto-deny
                        respondFsWrite(requestId: requestId, success: false)
                    }
                }
            case 13: // SubagentSpawned
                if let name = text, let meta = text2 {
                    let parts = meta.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
                    let subId = parts.count > 0 ? String(parts[0]) : ""
                    let role = parts.count > 1 ? String(parts[1]) : nil
                    let parentSid = parts.count > 2 ? String(parts[2]) : nil
                    let depsStr = parts.count > 3 ? String(parts[3]) : ""
                    let deps = depsStr.isEmpty ? [] : depsStr.split(separator: ",").map(String.init)
                    onSubagentSpawned?(subId, name, role?.isEmpty == true ? nil : role, parentSid?.isEmpty == true ? nil : parentSid, deps)
                }
            case 14: // SubagentProgress
                if let phase = text, let meta = text2 {
                    let parts = meta.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                    let subId = parts.count > 0 ? String(parts[0]) : ""
                    let tokens: UInt64? = parts.count > 1 ? UInt64(parts[1]).flatMap { $0 == UInt64.max ? nil : $0 } : nil
                    onSubagentProgress?(subId, phase, tokens)
                }
            case 15: // SubagentComplete
                if let meta = text2 {
                    let parts = meta.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                    let subId = parts.count > 0 ? String(parts[0]) : ""
                    let tokens: UInt64? = parts.count > 1 ? UInt64(parts[1]).flatMap { $0 == UInt64.max ? nil : $0 } : nil
                    onSubagentComplete?(subId, tokens)
                }
            case 16: // SubagentError
                if let message = text, let subId = text2 {
                    onSubagentError?(subId, message)
                }
            case 17: // Stderr
                if let text {
                    debugLog("ACP stderr: \(text)")
                }
            case 18: // ProtocolLog
                if let text {
                    debugLog("ACP protocol: \(text)")
                }
            default:
                break
            }
            // Guard against use-after-free: callbacks above may destroy this client
            guard self.handle != nil else { return }
        }
    }

    private func handlePermissionRequest(_ request: PermissionRequest) {
        let trust = AppConfig.shared.kiroTrustLevel
        switch trust {
        case .all:
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

    /// Auto-approve file reads — read the file and respond immediately.
    private func handleFsRead(requestId: UInt64, path: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let content = try? String(contentsOfFile: path, encoding: .utf8)
            DispatchQueue.main.async {
                self?.respondFsRead(requestId: requestId, content: content)
            }
        }
    }
}
