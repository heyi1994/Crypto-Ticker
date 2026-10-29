import Foundation
import XCTest
import CryptoTickerCore
@testable import CryptoTicker

final class MarketStoreTests: XCTestCase {
    private func quote(_ symbol: String, price: Double, second: Double) throws -> Quote {
        let payload = """
        [{"symbol":"\(symbol)USDT","lastPrice":"\(price)","priceChangePercent":"99","highPrice":"200","lowPrice":"1","closeTime":\((1000 + second) * 1000)}]
        """
        return try XCTUnwrap(Quote.decodeSnapshot(Data(payload.utf8)).first)
    }

    @MainActor
    func testAlertsOnlyMonitorPinnedCoinsWhileEnabled() throws {
        let suite = "CryptoTickerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["BTC", "ETH"], forKey: "watchlistSymbols")
        defaults.set(["BTC"], forKey: "pinnedSymbols")
        let store = MarketStore(defaults: defaults)
        XCTAssertFalse(store.alertsEnabled)
        store.setAlertsEnabled(true)
        var delivered: [MovementAlert] = []
        let subscription = store.alertEvents.sink { delivered.append($0) }
        defer { subscription.cancel() }
        for (symbol, price, second) in [("ETH", 100.0, 0.0), ("ETH", 110.0, 1.0),
                                        ("BTC", 100.0, 0.0), ("BTC", 101.0, 1.0)] {
            let quote = try quote(symbol, price: price, second: second)
            store.recordMovement(quote, receivedAt: quote.date)
        }
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(store.latestAlert?.symbol, "BTC")
        // The unrelated 24h change is +99%; the detector uses actual sampled prices.
        XCTAssertEqual(try XCTUnwrap(store.latestAlert).changePercent, 1, accuracy: 0.00001)
        store.setAlertsEnabled(false)
        let next = try quote("BTC", price: 120, second: 2)
        store.recordMovement(next, receivedAt: next.date)
        XCTAssertNil(store.latestAlert)
        XCTAssertEqual(delivered.count, 1)
    }

    @MainActor
    func testAlertSettingsPersistWithoutChangingTheDisplayWindow() throws {
        let suite = "CryptoTickerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("4h", forKey: "priceWindow")
        let store = MarketStore(defaults: defaults)
        store.setAlertRule(minutes: 5, thresholdPercent: 3)
        store.setAlertsEnabled(true)
        let restored = MarketStore(defaults: defaults)
        XCTAssertTrue(restored.alertsEnabled)
        XCTAssertEqual(restored.alertRule, VolatilityRule(minutes: 5, thresholdPercent: 3))
        XCTAssertEqual(restored.selectedWindow, .fourHours)
    }

    @MainActor
    func testWindowSelectionPersistsAndRecoversFromInvalidPreference() throws {
        let suite = "CryptoTickerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("invalid", forKey: "priceWindow")
        let store = MarketStore(defaults: defaults)
        XCTAssertEqual(store.selectedWindow, .day)
        for window in [PriceWindow.oneHour, .fourHours, .day] {
            store.selectWindow(window)
            store.stop()
            XCTAssertEqual(defaults.string(forKey: "priceWindow"), window.rawValue)
            let restored = MarketStore(defaults: defaults)
            XCTAssertEqual(restored.selectedWindow, window)
            XCTAssertTrue(restored.menuTitle.hasPrefix(window.rawValue + " · "))
        }
    }

    @MainActor
    func testCustomWatchlistAndPinsPersistAcrossStoreRestoration() throws {
        let suite = "CryptoTickerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["BTC", "ADA"], forKey: "watchlistSymbols")
        defaults.set(["ADA"], forKey: "pinnedSymbols")

        let store = MarketStore(defaults: defaults)
        XCTAssertEqual(store.coins.map(\.symbol), ["BTC", "ADA"])
        XCTAssertEqual(store.pinned, ["ADA"])
        store.togglePin("BTC")

        let restored = MarketStore(defaults: defaults)
        XCTAssertEqual(restored.coins.map(\.symbol), ["BTC", "ADA"])
        XCTAssertEqual(restored.pinned, ["ADA", "BTC"])
        restored.removeCoin("ADA")
        restored.stop()

        let afterRemoval = MarketStore(defaults: defaults)
        XCTAssertEqual(afterRemoval.coins.map(\.symbol), ["BTC"])
        XCTAssertEqual(afterRemoval.pinned, ["BTC"])
        XCTAssertEqual(defaults.stringArray(forKey: "watchlistSymbols"), ["BTC"])
        XCTAssertEqual(defaults.stringArray(forKey: "pinnedSymbols"), ["BTC"])
    }
}
