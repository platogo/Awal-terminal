import Foundation

/// Discovers and caches available Kiro agents from ~/.kiro/agents/*.json.
class AgentStore {
    static let shared = AgentStore()

    struct AgentInfo {
        let name: String
        let path: String
        let description: String?
    }

    private var cachedAgents: [AgentInfo]?

    private init() {}

    /// Returns all available agents, scanning on first call or when refreshed.
    func agents() -> [AgentInfo] {
        if let cached = cachedAgents { return cached }
        let result = scan()
        cachedAgents = result
        return result
    }

    /// Force a re-scan of the agents directory.
    func refresh() {
        cachedAgents = nil
    }

    private func scan() -> [AgentInfo] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let agentsDir = home.appendingPathComponent(".kiro/agents")
        let fm = FileManager.default

        guard let files = try? fm.contentsOfDirectory(
            at: agentsDir,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return [] }

        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> AgentInfo? in
                guard let data = try? Data(contentsOf: url),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let name = json["name"] as? String else { return nil }
                let desc = json["description"] as? String
                return AgentInfo(name: name, path: url.path, description: desc)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
