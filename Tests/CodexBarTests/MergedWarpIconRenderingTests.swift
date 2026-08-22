import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct MergedWarpIconRenderingTests {
    @Test
    func `merged warp bonus lane is preserved in show used mode when bonus is unused`() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "MergedWarpIconRenderingTests-unused-bonus"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .warp
        settings.menuBarShowsBrandIconWithPercent = false
        settings.usageBarsShowUsed = true

        let registry = ProviderRegistry.shared
        if let warpMeta = registry.metadata[.warp] {
            settings.setProviderEnabled(provider: .warp, metadata: warpMeta, enabled: true)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
        defer { controller.releaseStatusItemsForTesting() }

        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 10, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 0, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())
        store._setSnapshotForTesting(snapshot, provider: .warp)
        store._setErrorForTesting(nil, provider: .warp)

        controller.applyIcon(phase: nil)

        guard let image = controller.statusItem.button?.image else {
            #expect(Bool(false))
            return
        }
        let rep = image.representations.compactMap { $0 as? NSBitmapImageRep }.first(where: {
            $0.pixelsWide == 36 && $0.pixelsHigh == 36
        })
        #expect(rep != nil)
        guard let rep else { return }

        // A present-but-unused bonus must remain an empty lane, not Warp's missing-secondary layout.
        let alpha = (rep.colorAt(x: 31, y: 25) ?? .clear).alphaComponent
        #expect(alpha < 0.6)
    }
}
