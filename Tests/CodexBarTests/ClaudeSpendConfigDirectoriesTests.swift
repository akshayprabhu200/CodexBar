import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite(.serialized)
@MainActor
struct ClaudeSpendConfigDirectoriesTests {
    @Test
    func `normalizes machine local roots and persists no duplicate aliases`() throws {
        let suite = "ClaudeSpendConfigDirectoriesTests-normalize-\(UUID().uuidString)"
        let settings = testSettingsStore(suiteName: suite)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-spend-roots-\(UUID().uuidString)", isDirectory: true)
        let primary = root.appendingPathComponent("primary", isDirectory: true)
        let alias = root.appendingPathComponent("alias", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: primary, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: primary)

        settings.claudeSpendConfigDirectories = [
            "  \(primary.path)  ",
            alias.path,
            "relative-profile",
            "",
        ]

        #expect(settings.claudeSpendConfigDirectories == [primary.path])
        #expect(settings.userDefaults.stringArray(forKey: "claudeSpendConfigDirectories") == [primary.path])
    }

    @Test
    func `claude spend scope fingerprints roots without exposing local paths`() {
        let suite = "ClaudeSpendConfigDirectoriesTests-scope-\(UUID().uuidString)"
        let settings = testSettingsStore(suiteName: suite)
        settings.claudeSwapEnabled = true
        let first = FileManager.default.temporaryDirectory
            .appendingPathComponent("private-claude-home-one", isDirectory: true).path
        let second = FileManager.default.temporaryDirectory
            .appendingPathComponent("private-claude-home-two", isDirectory: true).path
        settings.claudeSpendConfigDirectories = [first]
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])

        let firstSignature = store.tokenCostScope(for: .claude).signature
        #expect(firstSignature.hasPrefix("claude:config-roots:"))
        #expect(!firstSignature.contains(first))

        settings.claudeSpendConfigDirectories = [second]
        let secondSignature = store.tokenCostScope(for: .claude).signature
        #expect(secondSignature != firstSignature)
        #expect(!secondSignature.contains(second))

        settings.claudeSwapEnabled = false
        #expect(store.tokenCostScope(for: .claude).signature == "claude")
    }
}
