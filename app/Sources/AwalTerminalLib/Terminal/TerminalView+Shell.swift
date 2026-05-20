import AppKit
import CAwalTerminal
import os.log
import QuartzCore

private let hookLog = OSLog(subsystem: "com.awal.terminal", category: "hooks")

// MARK: - Shell & PTY

extension TerminalView {

    func spawnShell() {
        guard let s = surface else { return }

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let result = shell.withCString { cstr in
            at_surface_spawn_shell(s, cstr)
        }

        if result != 0 {
            debugLog("Failed to spawn shell")
            return
        }

        setupPtyReader()
    }

    /// Execute a hook script synchronously in a sandboxed subprocess.
    func executeHookScript(_ scriptURL: URL, verifiedData: Data, workingDir: String?) {
        runSandboxedHook(scriptURL, verifiedData: verifiedData, workingDir: workingDir)
    }

    /// Execute post-session hooks asynchronously in sandboxed subprocesses.
    func executePostSessionHooks() {
        guard !postSessionHooks.isEmpty else { return }
        let hooks = postSessionHooks
        let dir = lastWorkingDir
        postSessionHooks = []
        DispatchQueue.global(qos: .utility).async { [weak self] in
            for hook in hooks {
                self?.runSandboxedHook(hook.url, verifiedData: hook.data, workingDir: dir)
            }
        }
    }

    // MARK: - Sandboxed Hook Execution

    @discardableResult
    private func runSandboxedHook(_ scriptURL: URL, verifiedData: Data, workingDir: String?) -> Int32 {
        let dir = workingDir ?? FileManager.default.temporaryDirectory.path

        // Allowlist: only printable ASCII (0x20-0x7E) excluding ", (, ), \
        let pathIsValid: (String) -> Bool = { path in
            path.utf8.allSatisfy { byte in
                byte >= 0x20 && byte <= 0x7E
                    && byte != 0x22 && byte != 0x28 && byte != 0x29 && byte != 0x5C
            }
        }

        if !pathIsValid(dir) {
            os_log(.error, log: hookLog, "Hook rejected: working dir contains unsafe characters: %{public}@", dir)
            logHookAudit(scriptURL, entry: "SANDBOX_DENIED", detail: "unsafe workingDir path")
            return -1
        }

        // Write verified data to a secure staging directory (eliminates TOCTOU)
        let stagingDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let stagedScript: URL
        do {
            try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            stagedScript = stagingDir.appendingPathComponent(scriptURL.lastPathComponent)
            try verifiedData.write(to: stagedScript, options: .atomic)
        } catch {
            os_log(.error, log: hookLog, "Hook staging failed: %{public}@", error.localizedDescription)
            logHookAudit(scriptURL, entry: "SANDBOX_DENIED", detail: "staging failed: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: stagingDir)
            return -1
        }

        defer { try? FileManager.default.removeItem(at: stagingDir) }

        let profile = """
            (version 1)
            (deny default)
            (allow process*)
            (allow file-read-metadata)
            (allow file-read* (subpath "/private/tmp"))
            (allow file-read* (subpath "\(dir)"))
            (allow file-read* (literal "\(stagedScript.path)"))
            (allow file-read* (subpath "/usr"))
            (allow file-read* (subpath "/bin"))
            (allow file-read* (subpath "/Library"))
            (allow file-read* (subpath "/System"))
            (allow file-write* (subpath "/private/tmp"))
            (allow file-write* (subpath "\(dir)"))
            (allow sysctl-read)
            (allow mach-lookup)
            """

        let stderrPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-p", profile, "/bin/bash", "--", stagedScript.path]
        process.currentDirectoryURL = URL(fileURLWithPath: dir)

        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe

        let start = DispatchTime.now()
        do {
            try process.run()
        } catch {
            os_log(.error, log: hookLog, "Hook launch failed: %{public}@ — %{public}@",
                   scriptURL.lastPathComponent, error.localizedDescription)
            logHookAudit(scriptURL, entry: "SANDBOX_DENIED", detail: error.localizedDescription)
            return -1
        }

        let timeout = AppConfig.shared.aiComponentsHookTimeout
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeout)) {
            if process.isRunning { process.terminate() }
        }
        process.waitUntilExit()

        // Capture stderr output (capped at 4KB)
        let maxOutput = 4096
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let outputTruncated = stderrData.count > maxOutput
        let capturedOutput = String(data: stderrData.prefix(maxOutput), encoding: .utf8) ?? ""

        let elapsed = Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
        let timedOut = process.terminationReason == .uncaughtSignal && elapsed >= timeout * 1000
        let code = process.terminationStatus

        let outputSuffix = capturedOutput.isEmpty ? "" : " stderr=\(capturedOutput)\(outputTruncated ? "…[truncated]" : "")"

        if timedOut {
            os_log(.error, log: hookLog, "Hook timed out: %{public}@ killed after %ds", scriptURL.lastPathComponent, timeout)
            logHookAudit(scriptURL, entry: "TIMEOUT", detail: "killed after \(timeout)s\(outputSuffix)")
        } else {
            os_log(.info, log: hookLog, "Hook executed: %{public}@ exit=%d duration=%dms", scriptURL.lastPathComponent, code, elapsed)
            logHookAudit(scriptURL, entry: "EXECUTED", detail: "exit=\(code) duration=\(elapsed)ms\(outputSuffix)")
        }

        return code
    }

    private func logHookAudit(_ scriptURL: URL, entry: String, detail: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(timestamp) \(entry) \(scriptURL.lastPathComponent) \(detail)\n"
        let logFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/awal/hook-audit.log")
        let logDir = logFile.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFile.path) {
                if let handle = try? FileHandle(forWritingTo: logFile) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: logFile)
            }
        }
    }

    func setupPtyReader() {
        guard let s = surface else { return }

        let fd = at_surface_get_fd(s)
        if fd < 0 {
            debugLog("Invalid PTY fd")
            return
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            self?.readPTY()
        }
        source.setCancelHandler { }
        source.resume()
        self.readSource = source

        let childPid = at_surface_get_child_pid(s)
        if childPid > 0 {
            onShellSpawned?(pid_t(childPid))

            let procSource = DispatchSource.makeProcessSource(
                identifier: pid_t(childPid), eventMask: .exit, queue: .main)
            procSource.setEventHandler { [weak self] in
                self?.onProcessExited?()
            }
            procSource.resume()
            self.processSource = procSource
        }
    }

    /// Activate the write source to drain queued PTY writes when the fd is writable.
    func activateWriteSource() {
        guard writeSource == nil, let s = surface else { return }
        let fd = at_surface_get_fd(s)
        if fd < 0 { return }

        let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            self?.drainWriteQueue()
        }
        source.setCancelHandler { }
        source.resume()
        self.writeSource = source
    }

    /// Drain queued writes; suspend write source when done.
    func drainWriteQueue() {
        guard let s = surface else { return }
        let result = at_surface_drain_writes(s)
        if result < 0 {
            // Error — stop trying
            writeSource?.cancel()
            writeSource = nil
            return
        }
        if !at_surface_has_pending_writes(s) {
            writeSource?.cancel()
            writeSource = nil
        }
    }

    /// Queue data for writing to the PTY (non-blocking).
    func queuePtyWrite(_ bytes: [UInt8]) {
        guard let s = surface else { return }
        bytes.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            at_surface_queue_write(s, base, UInt32(ptr.count))
        }
        activateWriteSource()
    }

    func readPTY() {
        guard !isCleanedUp else { return }
        guard let s = surface else { return }

        // Clear loading message BEFORE processing PTY data so the cursor
        // is at home position when the shell's first output is rendered.
        if isWaitingForOutput, !loadingMessageText.isEmpty {
            let clear = "\u{1b}[2J\u{1b}[H"
            let clearBytes = Array(clear.utf8)
            clearBytes.withUnsafeBufferPointer { ptr in
                at_surface_feed_bytes(s, ptr.baseAddress!, UInt32(ptr.count))
            }
            loadingMessageText = ""
        }

        var totalRead: Int32 = 0
        var iterations = 0
        let deadline = CACurrentMediaTime() + 0.008 // 8ms cap
        while iterations < 16 {
            let n = at_surface_process_pty(s)
            if n <= 0 { break }
            totalRead += n
            iterations += 1
            if CACurrentMediaTime() >= deadline { break }
        }

        if totalRead > 0 {

            // Run AI analyzer once per batch (not per iteration)
            at_surface_analyze(s)

            // Check for remote control activation and URL updates
            let rcActive = at_surface_is_remote_control_active(s)
            if rcActive {
                // Always prevent sleep during remote control
                acquireSleepAssertion()
                var url: String?
                if let urlPtr = at_surface_get_remote_control_url(s) {
                    url = String(cString: urlPtr)
                    at_free_string(urlPtr)
                }
                let isNew = !isRemoteControlActive
                let urlChanged = url != nil && url != remoteControlURL
                if isNew || urlChanged {
                    isRemoteControlActive = true
                    remoteControlURL = url
                    onRemoteControlChanged?(true, url)
                }
            } else if isRemoteControlActive {
                isRemoteControlActive = false
                onRemoteControlChanged?(false, nil)
                // Release sleep assertion when remote control ends (unless manual prevent_sleep is active with output)
                if !AppConfig.shared.preventSleep || !hadRecentOutput {
                    releaseSleepAssertion()
                }
            }

            let isSynchronized = at_surface_is_synchronized(s)

            // Auto-snap to bottom even during sync mode — data is already processed
            if !userScrolledUp {
                let offset = at_surface_get_viewport_offset(s)
                if offset > 0 {
                    at_surface_scroll_viewport(s, -offset)
                }
            }

            // Defer rendering while synchronized output mode (2026) is active
            if !isSynchronized {
                updateCellBuffer()
                needsRender = true
                syncOutputTimer?.invalidate()
                syncOutputTimer = nil
            } else if syncOutputTimer == nil {
                // Safety timeout: force render if sync mode is held for >2 seconds
                syncOutputTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
                    self?.syncOutputTimer = nil
                    if let s = self?.surface {
                        at_surface_analyze(s)
                    }
                    self?.updateCellBuffer()
                    self?.needsRender = true
                }
            }

            hadRecentOutput = true
            isWaitingForOutput = false
            loadingMessageText = ""
            // Acquire sleep assertion if configured
            if AppConfig.shared.preventSleep {
                acquireSleepAssertion()
            }
            if !isGenerating && !activeModelName.isEmpty {
                isGenerating = true
                onGeneratingChanged?(true)
            }
            resetIdleTimer()
        }
    }

    func resetIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            self?.handleIdleTimeout()
        }
    }

    func handleIdleTimeout() {
        guard hadRecentOutput, !activeModelName.isEmpty else { return }
        hadRecentOutput = false
        if isGenerating {
            isGenerating = false
            onGeneratingChanged?(false)
        }
        // Release sleep assertion on idle unless remote control or manual prevent_sleep is active
        if !isRemoteControlActive && !AppConfig.shared.preventSleep {
            releaseSleepAssertion()
        }
        onTerminalIdle?()
    }
}
