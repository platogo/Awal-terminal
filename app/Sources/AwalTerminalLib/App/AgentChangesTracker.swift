import Foundation

/// Tracks files modified by the AI agent during a session for the changes tree.
class AgentChangesTracker {

    struct PendingWrite {
        let requestId: UInt64
        let path: String
        let originalContent: String?
        let newContent: String
        let diffText: String
    }

    private(set) var modifiedFiles: [String: PendingWrite] = [:]

    /// Record a pending write from the agent. Reads original content for diff.
    func recordWrite(requestId: UInt64, path: String, content: String, cwd: String, completion: (() -> Void)? = nil) {
        let fullPath = path.hasPrefix("/") ? path : (cwd as NSString).appendingPathComponent(path)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let original = try? String(contentsOfFile: fullPath, encoding: .utf8)
            let diff = self?.generateDiff(original: original, new: content, path: path, cwd: cwd) ?? ""
            let pending = PendingWrite(
                requestId: requestId,
                path: path,
                originalContent: original,
                newContent: content,
                diffText: diff
            )
            DispatchQueue.main.async {
                self?.modifiedFiles[path] = pending
                completion?()
            }
        }
    }

    /// Remove a tracked file (e.g., after resolution).
    func removeFile(_ path: String) {
        modifiedFiles.removeValue(forKey: path)
    }

    /// Clear all tracked changes (e.g., on turn end).
    func clear() {
        modifiedFiles.removeAll()
    }

    /// Get all modified file paths as GitFileChange for the tree view.
    func asGitFileChanges() -> [GitFileChange] {
        modifiedFiles.map { (path, write) in
            let status: GitFileChange.Status = write.originalContent == nil ? .added : .modified
            return GitFileChange(path: path, status: status)
        }.sorted { $0.path < $1.path }
    }

    // MARK: - Private

    private func generateDiff(original: String?, new: String, path: String, cwd: String) -> String {
        guard let original else {
            // New file — show all lines as additions
            let lines = new.components(separatedBy: "\n")
            var diff = "@@ -0,0 +1,\(lines.count) @@\n"
            for line in lines {
                diff += "+\(line)\n"
            }
            return diff
        }

        // Use git diff on temp files for accurate unified diff
        let tempDir = NSTemporaryDirectory()
        let oldFile = (tempDir as NSString).appendingPathComponent("awal_diff_old_\(ProcessInfo.processInfo.processIdentifier)")
        let newFile = (tempDir as NSString).appendingPathComponent("awal_diff_new_\(ProcessInfo.processInfo.processIdentifier)")

        defer {
            try? FileManager.default.removeItem(atPath: oldFile)
            try? FileManager.default.removeItem(atPath: newFile)
        }

        do {
            try original.write(toFile: oldFile, atomically: true, encoding: .utf8)
            try new.write(toFile: newFile, atomically: true, encoding: .utf8)
        } catch {
            return simpleDiff(original: original, new: new)
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/diff")
        proc.arguments = ["-u", oldFile, newFile]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            // Strip header lines, keep hunks
            let lines = output.components(separatedBy: "\n")
            var filtered: [String] = []
            var inHunk = false
            for line in lines {
                if line.hasPrefix("@@") { inHunk = true }
                if inHunk { filtered.append(line) }
            }
            return filtered.joined(separator: "\n")
        } catch {
            return simpleDiff(original: original, new: new)
        }
    }

    private func simpleDiff(original: String, new: String) -> String {
        let oldLines = original.components(separatedBy: "\n")
        let newLines = new.components(separatedBy: "\n")
        var diff = "@@ -1,\(oldLines.count) +1,\(newLines.count) @@\n"
        for line in oldLines { diff += "-\(line)\n" }
        for line in newLines { diff += "+\(line)\n" }
        return diff
    }
}
