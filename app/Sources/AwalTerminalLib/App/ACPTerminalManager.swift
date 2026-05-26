import Foundation

/// Manages spawned processes for the ACP terminal protocol.
class ACPTerminalManager {
    private var terminals: [String: ManagedTerminal] = [:]
    private let queue = DispatchQueue(label: "com.awal.terminal-manager", attributes: .concurrent)

    private class ManagedTerminal {
        let id: String
        let process: Process
        let outputPipe: Pipe
        let outputByteLimit: Int
        var outputData = Data()
        var truncated = false
        var exitCode: Int32?
        var signal: Int32?
        var exited = false
        var waitContinuations: [(Int32?, Int32?) -> Void] = []

        init(id: String, process: Process, outputPipe: Pipe, outputByteLimit: Int) {
            self.id = id
            self.process = process
            self.outputPipe = outputPipe
            self.outputByteLimit = outputByteLimit
        }
    }

    func create(command: String, args: [String], env: [(String, String)], cwd: String?, outputByteLimit: Int) -> String? {
        let id = UUID().uuidString
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = args

        var environment = ProcessInfo.processInfo.environment
        for (key, value) in env {
            environment[key] = value
        }
        process.environment = environment

        if let cwd {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let terminal = ManagedTerminal(id: id, process: process, outputPipe: pipe, outputByteLimit: outputByteLimit)

        pipe.fileHandleForReading.readabilityHandler = { [weak self, weak terminal] handle in
            guard let self, let terminal else { return }
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self.queue.async(flags: .barrier) {
                terminal.outputData.append(data)
                if terminal.outputByteLimit > 0 && terminal.outputData.count > terminal.outputByteLimit {
                    let excess = terminal.outputData.count - terminal.outputByteLimit
                    terminal.outputData.removeFirst(excess)
                    terminal.truncated = true
                }
            }
        }

        process.terminationHandler = { [weak self, weak terminal] proc in
            guard let self, let terminal else { return }
            self.queue.async(flags: .barrier) {
                terminal.exitCode = proc.terminationStatus
                if proc.terminationReason == .uncaughtSignal {
                    terminal.signal = proc.terminationStatus
                    terminal.exitCode = nil
                }
                terminal.exited = true
                pipe.fileHandleForReading.readabilityHandler = nil
                let continuations = terminal.waitContinuations
                terminal.waitContinuations.removeAll()
                for cont in continuations {
                    DispatchQueue.main.async {
                        cont(terminal.exitCode, terminal.signal)
                    }
                }
            }
        }

        do {
            try process.run()
        } catch {
            debugLog("ACPTerminalManager: failed to spawn process: \(error)")
            return nil
        }

        queue.async(flags: .barrier) {
            self.terminals[id] = terminal
        }
        return id
    }

    func getOutput(terminalId: String) -> (output: String, truncated: Bool, exitCode: Int32?, signal: Int32?)? {
        var result: (output: String, truncated: Bool, exitCode: Int32?, signal: Int32?)?
        queue.sync {
            guard let terminal = terminals[terminalId] else { return }
            let output = String(data: terminal.outputData, encoding: .utf8) ?? ""
            result = (output, terminal.truncated, terminal.exitCode, terminal.signal)
        }
        return result
    }

    func waitForExit(terminalId: String, completion: @escaping (Int32?, Int32?) -> Void) {
        queue.async(flags: .barrier) {
            guard let terminal = self.terminals[terminalId] else {
                DispatchQueue.main.async { completion(nil, nil) }
                return
            }
            if terminal.exited {
                let exitCode = terminal.exitCode
                let signal = terminal.signal
                DispatchQueue.main.async { completion(exitCode, signal) }
            } else {
                terminal.waitContinuations.append(completion)
            }
        }
    }

    func kill(terminalId: String) -> Bool {
        var found = false
        queue.sync {
            guard let terminal = terminals[terminalId] else { return }
            found = true
            if terminal.process.isRunning {
                terminal.process.terminate()
            }
        }
        return found
    }

    func release(terminalId: String) -> Bool {
        var found = false
        queue.sync(flags: .barrier) {
            guard let terminal = self.terminals.removeValue(forKey: terminalId) else { return }
            found = true
            let continuations = terminal.waitContinuations
            terminal.waitContinuations.removeAll()
            for cont in continuations {
                DispatchQueue.main.async { cont(nil, nil) }
            }
            if terminal.process.isRunning {
                terminal.process.terminate()
            }
            terminal.outputPipe.fileHandleForReading.readabilityHandler = nil
        }
        return found
    }

    func releaseAll() {
        queue.sync(flags: .barrier) {
            for (_, terminal) in self.terminals {
                let continuations = terminal.waitContinuations
                terminal.waitContinuations.removeAll()
                for cont in continuations {
                    DispatchQueue.main.async { cont(nil, nil) }
                }
                terminal.outputPipe.fileHandleForReading.readabilityHandler = nil
                if terminal.process.isRunning {
                    terminal.process.terminate()
                }
            }
            self.terminals.removeAll()
        }
    }
}
