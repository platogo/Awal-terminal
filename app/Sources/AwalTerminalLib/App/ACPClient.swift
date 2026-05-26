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
    var onAgentThought: ((String) -> Void)?
    var onPlanUpdate: ((String) -> Void)?
    var onImageContent: ((String, String) -> Void)?
    var onUsageUpdate: ((UInt64, UInt64, Double?, String?) -> Void)?
    var onMetadataUpdate: ((Double, Double?) -> Void)?
    var onSessionInfoUpdate: ((String) -> Void)?
    var onCompactionStatus: ((String) -> Void)?
    var onSessionList: ((String) -> Void)?
    var onTerminalCreate: ((UInt64, String, String, [String], [(String, String)], String?, Int) -> Void)?
    var onTerminalOutput: ((UInt64, String) -> Void)?
    var onTerminalWaitForExit: ((UInt64, String) -> Void)?
    var onTerminalKill: ((UInt64, String) -> Void)?
    var onTerminalRelease: ((UInt64, String) -> Void)?
    var onConfigOptions: ((String) -> Void)?
    var onAvailableCommands: ((String) -> Void)?
    var onMcpOAuthRequest: ((String) -> Void)?

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

        do { try proc.run() } catch {
            debugLog("ACP: failed to launch process: \(error)")
            return false
        }

        self.process = proc
        self.stdinPipe = inPipe
        self.stdoutPipe = outPipe
        self.stderrPipe = errPipe

        let stdinFd = dup(inPipe.fileHandleForWriting.fileDescriptor)
        guard stdinFd >= 0, let h = at_acp_create_writer(stdinFd) else {
            if stdinFd >= 0 { close(stdinFd) }
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

    func sendClose() {
        guard let handle else { return }
        _ = at_acp_send_close(handle)
    }

    func listSessions() -> Bool {
        guard let handle else { return false }
        return at_acp_send_list_sessions(handle) == 0
    }

    func setConfigOption(configId: String, value: String) -> Bool {
        guard let handle else { return false }
        return configId.withCString { idPtr in
            value.withCString { valPtr in
                at_acp_set_config_option(handle, idPtr, valPtr) == 0
            }
        }
    }

    func terminateSession(sessionId: String) -> Bool {
        guard let handle else { return false }
        return sessionId.withCString { ptr in
            at_acp_terminate_session(handle, ptr) == 0
        }
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

    func respondJson(requestId: UInt64, json: String) {
        guard let handle else { return }
        json.withCString { ptr in
            _ = at_acp_respond_json(handle, requestId, ptr)
        }
    }

    func respondError(requestId: UInt64, code: Int64, message: String) {
        guard let handle else { return }
        message.withCString { ptr in
            _ = at_acp_respond_error(handle, requestId, code, ptr)
        }
    }

    func destroy() {
        sendClose()
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
                guard let title = text, let meta = text2 else {
                    debugLog("ACP poll: ToolCall event missing text/text2")
                    break
                }
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
            case 4: // ToolCallUpdate
                guard let meta = text2 else {
                    debugLog("ACP poll: ToolCallUpdate event missing text2")
                    break
                }
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
                guard let desc = text, let meta = text2 else {
                    debugLog("ACP poll: PermissionRequest event missing text/text2")
                    break
                }
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
                onPermissionRequest?(request)
            case 9: // Cancelled
                isPrompting = false
                onCancelled?()
            case 10: // AuthRequired
                isPrompting = false
                onAuthRequired?(text ?? "Authentication required")
            case 11: // FsReadRequest
                guard let path = text, let meta = text2, let requestId = UInt64(meta) else {
                    debugLog("ACP poll: FsReadRequest event missing text/text2 or invalid requestId")
                    break
                }
                handleFsRead(requestId: requestId, path: path)
            case 12: // FsWriteRequest
                guard let content = text, let meta = text2 else {
                    debugLog("ACP poll: FsWriteRequest event missing text/text2")
                    break
                }
                let parts = meta.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count > 0, let requestId = UInt64(parts[0]) else {
                    debugLog("ACP poll: FsWriteRequest failed to parse requestId")
                    break
                }
                let path = parts.count > 1 ? String(parts[1]) : ""
                if let handler = onFsWriteRequest {
                    handler(requestId, path, content)
                } else {
                    // No handler — auto-deny
                    respondFsWrite(requestId: requestId, success: false)
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
            case 19: // AgentThought
                if let text { onAgentThought?(text) }
            case 20: // PlanUpdate
                if let text { onPlanUpdate?(text) }
            case 21: // ImageContent
                if let data = text, let mimeType = text2 {
                    onImageContent?(data, mimeType)
                }
            case 22: // UsageUpdate
                if let meta = text {
                    let parts = meta.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                    let used = parts.count > 0 ? UInt64(parts[0]) ?? 0 : 0
                    let size = parts.count > 1 ? UInt64(parts[1]) ?? 0 : 0
                    var cost: Double?
                    var currency: String?
                    if let meta2 = text2 {
                        let p2 = meta2.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                        cost = p2.count > 0 ? Double(p2[0]) : nil
                        currency = p2.count > 1 && !p2[1].isEmpty ? String(p2[1]) : nil
                    }
                    onUsageUpdate?(used, size, cost, currency)
                }
            case 23: // MetadataUpdate
                if let meta = text {
                    let parts = meta.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                    let pct = parts.count > 0 ? Double(parts[0]) ?? 0 : 0
                    let credits: Double? = parts.count > 1 ? Double(parts[1]).flatMap { $0 < 0 ? nil : $0 } : nil
                    onMetadataUpdate?(pct, credits)
                }
            case 24: // SessionInfoUpdate
                if let text { onSessionInfoUpdate?(text) }
            case 25: // CompactionStatus
                if let text { onCompactionStatus?(text) }
            case 26: // SessionList
                if let text { onSessionList?(text) }
            case 27: // TerminalCreate
                guard let paramsJson = text, let meta = text2 else {
                    debugLog("ACP poll: TerminalCreate event missing text/text2")
                    break
                }
                let parts = meta.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count > 0, let requestId = UInt64(parts[0]) else {
                    debugLog("ACP poll: TerminalCreate failed to parse requestId")
                    break
                }
                let sessionId = parts.count > 1 ? String(parts[1]) : ""
                // Parse JSON params
                guard let data = paramsJson.data(using: .utf8),
                      let params = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let command = params["command"] as? String else {
                    debugLog("ACP poll: TerminalCreate failed to parse params JSON")
                    break
                }
                let args = params["args"] as? [String] ?? []
                let envObj = params["env"] as? [[Any]] ?? []
                let env: [(String, String)] = envObj.compactMap { pair in
                    guard pair.count == 2, let k = pair[0] as? String, let v = pair[1] as? String else { return nil }
                    return (k, v)
                }
                let cwd = params["cwd"] as? String
                let byteLimit = params["outputByteLimit"] as? Int ?? 0
                onTerminalCreate?(requestId, sessionId, command, args, env, cwd, byteLimit)
            case 28: // TerminalOutput
                guard let terminalId = text, let meta = text2, let requestId = UInt64(meta) else {
                    debugLog("ACP poll: TerminalOutput event missing text/text2")
                    break
                }
                onTerminalOutput?(requestId, terminalId)
            case 29: // TerminalWaitForExit
                guard let terminalId = text, let meta = text2, let requestId = UInt64(meta) else {
                    debugLog("ACP poll: TerminalWaitForExit event missing text/text2")
                    break
                }
                onTerminalWaitForExit?(requestId, terminalId)
            case 30: // TerminalKill
                guard let terminalId = text, let meta = text2, let requestId = UInt64(meta) else {
                    debugLog("ACP poll: TerminalKill event missing text/text2")
                    break
                }
                onTerminalKill?(requestId, terminalId)
            case 31: // TerminalRelease
                guard let terminalId = text, let meta = text2, let requestId = UInt64(meta) else {
                    debugLog("ACP poll: TerminalRelease event missing text/text2")
                    break
                }
                onTerminalRelease?(requestId, terminalId)
            case 32: // ConfigOptionsReceived
                if let text { onConfigOptions?(text) }
            case 33: // AvailableCommands
                if let text { onAvailableCommands?(text) }
            case 34: // McpOAuthRequest
                if let text { onMcpOAuthRequest?(text) }
            default:
                break
            }
            // Guard against use-after-free: callbacks above may destroy this client
            guard self.handle != nil else { return }
        }
    }

    /// Auto-approve file reads — read the file and respond immediately.
    private func handleFsRead(requestId: UInt64, path: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let maxSize: Int = 10 * 1024 * 1024 // 10MB
            let content: String?
            if let handle = FileHandle(forReadingAtPath: path) {
                let data = handle.readData(ofLength: maxSize + 1)
                handle.closeFile()
                if data.count > maxSize {
                    content = nil // Too large
                } else {
                    content = String(data: data, encoding: .utf8)
                }
            } else {
                content = nil
            }
            DispatchQueue.main.async {
                self?.respondFsRead(requestId: requestId, content: content)
            }
        }
    }
}
