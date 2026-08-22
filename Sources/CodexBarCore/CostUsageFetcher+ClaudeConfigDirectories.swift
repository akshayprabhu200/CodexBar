import Foundation

extension CostUsageFetcher {
    static func addingClaudeConfigDirectories(
        _ directories: [String],
        provider: UsageProvider,
        environment: [String: String],
        to options: CostUsageScanner.Options) -> CostUsageScanner.Options
    {
        guard provider == .claude, !directories.isEmpty else { return options }

        var resolved = options
        var roots = CostUsageScanner.defaultClaudeProjectsRoots(
            options: options,
            environment: environment)
        for directory in directories {
            let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let expanded = (trimmed as NSString).expandingTildeInPath
            guard expanded.hasPrefix("/") else { continue }
            roots.append(URL(fileURLWithPath: expanded, isDirectory: true)
                .appendingPathComponent("projects", isDirectory: true))
        }
        resolved.claudeProjectsRoots = roots
        return resolved
    }
}
