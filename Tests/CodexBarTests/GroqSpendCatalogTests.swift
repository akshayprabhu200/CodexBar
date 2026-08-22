import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct GroqSpendCatalogTests {
    @Test
    func `console activity publishes vendor spend through the snapshot catalog`() throws {
        let now = Date(timeIntervalSince1970: 1_783_987_200)
        let usage = Self.consoleUsage(now: now).toUsageSnapshot()
        let settings = testSettingsStore(suiteName: "GroqSpendCatalogTests-catalog")
        settings.costUsageEnabled = true
        let store = Self.store(settings: settings)

        #expect(ProviderDescriptorRegistry.descriptor(for: .groq).tokenCost.supportsTokenCost)
        #expect(UsageStore.tokenCostRequiresProviderSnapshot(.groq))
        let snapshot = try #require(store.tokenSnapshot(fromProviderSnapshot: usage, provider: .groq))
        #expect(snapshot.last30DaysCostUSD == 1.25)
        #expect(snapshot.last30DaysTokens == 150)
        #expect(snapshot.last30DaysRequests == 4)
        #expect(snapshot.costProvenance == .vendorMetered)
        #expect(snapshot.daily.first?.modelBreakdowns?.first?.modelName == "llama-3.1-8b-instant")
    }

    @Test
    func `spend dashboard captures Groq without adding local Grok`() async throws {
        let now = Date(timeIntervalSince1970: 1_783_987_200)
        let usage = Self.consoleUsage(now: now).toUsageSnapshot()
        let settings = testSettingsStore(suiteName: "GroqSpendCatalogTests-dashboard")
        settings.costUsageEnabled = true
        for provider in UsageProvider.allCases {
            guard let metadata = ProviderRegistry.shared.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: provider == .groq)
        }
        let store = Self.store(settings: settings)
        store._setSnapshotForTesting(usage, provider: .groq)
        store.publishProviderDerivedTokenSnapshot(from: usage, for: .groq)

        let request = await SpendDashboardSource.makeRequest(
            settings: settings,
            store: store,
            mode: .captureOnly,
            now: now)
        let captured = try #require(request.capturedInputs.first)
        #expect(request.capturedInputs.count == 1)
        #expect(captured.provider == .groq)
        #expect(captured.snapshot.last30DaysCostUSD == 1.25)

        let model = SpendDashboardModel.build(
            inputs: request.capturedInputs,
            requestedDays: 30,
            now: now)
        #expect(model.availableSources.map(\.id) == [UsageProvider.groq.rawValue])
        #expect(model.groups.first?.providers.first?.provider == .groq)
        #expect(model.groups.first?.providers.first?.totalCost == 1.25)
        #expect(model.groups.first?.providers.first?.totalTokens == 150)
        #expect(model.groups.first?.models.first?.modelName == "llama-3.1-8b-instant")
        #expect(!model.availableSources.map(\.id).contains(UsageProvider.grok.rawValue))
    }

    @Test
    func `quota only Groq snapshot stays unavailable to spend`() {
        let now = Date(timeIntervalSince1970: 1_783_987_200)
        let settings = testSettingsStore(suiteName: "GroqSpendCatalogTests-quota-only")
        let store = Self.store(settings: settings)
        let quotaOnly = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 50,
                windowMinutes: 60,
                resetsAt: nil,
                resetDescription: nil),
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: 99,
                limit: 100,
                currencyCode: "USD",
                period: "Monthly",
                updatedAt: now),
            updatedAt: now)

        #expect(store.tokenSnapshot(fromProviderSnapshot: quotaOnly, provider: .groq) == nil)
    }

    private static func store(settings: SettingsStore) -> UsageStore {
        UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
    }

    private static func consoleUsage(now: Date) -> GroqConsoleUsageSnapshot {
        GroqConsoleUsageSnapshot(
            daily: [
                GroqConsoleUsageSnapshot.DailyBucket(
                    day: "2026-07-13",
                    startTime: now.addingTimeInterval(-86400),
                    endTime: now,
                    costUSD: 1.25,
                    requests: 4,
                    inputTokens: 100,
                    cachedInputTokens: 0,
                    outputTokens: 50,
                    totalTokens: 150,
                    models: [
                        GroqConsoleUsageSnapshot.ModelBreakdown(
                            name: "llama-3.1-8b-instant",
                            requests: 4,
                            inputTokens: 100,
                            cachedInputTokens: 0,
                            outputTokens: 50,
                            totalTokens: 150,
                            costUSD: 1.25),
                    ]),
            ],
            updatedAt: now,
            historyDays: 30,
            organizationName: "Example")
    }
}
