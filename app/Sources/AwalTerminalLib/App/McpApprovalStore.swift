import Foundation
import CommonCrypto

/// Persists user approval of MCP server configurations.
///
/// Each approved server is stored as `{serverName: sha256OfConfigJSON}`.
/// If a server's config changes after a registry sync the hash will no
/// longer match and the server is treated as unapproved.
final class McpApprovalStore {
    static let shared = McpApprovalStore()

    /// Posted when unapproved MCP servers are detected during injection.
    static let unapprovedMcpServersDetectedNotification = Notification.Name("unapprovedMcpServersDetected")

    private let storePath: URL
    private let auditLogPath: URL
    private var approvals: [String: String] // serverName → sha256

    private init() {
        let configDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/awal")
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        storePath = configDir.appendingPathComponent("approved-mcp-servers.json")
        auditLogPath = configDir.appendingPathComponent("mcp-audit.log")
        approvals = [:]
        load()
    }

    // MARK: - Public API

    func isApproved(name: String, config: [String: Any]) -> Bool {
        guard let storedHash = approvals[name] else { return false }
        return storedHash == configHash(config)
    }

    func approve(name: String, config: [String: Any]) {
        approvals[name] = configHash(config)
        save()
        logAuditEvent("APPROVED", key: name)
    }

    func revoke(name: String) {
        approvals.removeValue(forKey: name)
        save()
        logAuditEvent("REVOKED", key: name)
    }

    func filterApproved(configs: [String: [String: Any]])
        -> (approved: [String: [String: Any]], unapproved: [String: [String: Any]])
    {
        var approved: [String: [String: Any]] = [:]
        var unapproved: [String: [String: Any]] = [:]
        for (name, config) in configs {
            if isApproved(name: name, config: config) {
                approved[name] = config
            } else {
                unapproved[name] = config
            }
        }
        return (approved, unapproved)
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: storePath),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return }
        approvals = dict
    }

    private func save() {
        guard let data = try? JSONSerialization.data(
            withJSONObject: approvals,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? data.write(to: storePath, options: .atomic)
    }

    // MARK: - Audit Trail

    private func logAuditEvent(_ action: String, key: String) {
        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.string(from: Date())
        let entry = "\(timestamp) \(action) \(key)\n"
        if let data = entry.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: auditLogPath.path) {
                if let handle = try? FileHandle(forWritingTo: auditLogPath) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: auditLogPath, options: .atomic)
            }
        }
    }

    // MARK: - Hashing

    private func configHash(_ config: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: config, options: .sortedKeys) else { return "" }
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        _ = data.withUnsafeBytes { CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash) }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
