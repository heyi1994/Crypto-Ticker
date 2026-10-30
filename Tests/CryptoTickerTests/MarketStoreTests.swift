import Combine
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

    private func frame(_ symbol: String, price: String, high: String = "200", eventTime: Double = 1793269256004) -> Data {
        Data(#"{"stream":"x","data":{"e":"24hrTicker","E":\#(eventTime),"s":"\#(symbol)USDT","c":"\#(price)","P":"1","h":"\#(high)","l":"1"}}"#.utf8)
    }

    @MainActor
    func testUndecodableFrameIsSkippedWithoutDroppingTheConnection() throws {
        let suite = "CryptoTickerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["BTC", "ETH"], forKey: "watchlistSymbols")
        let store = MarketStore(defaults: defaults)
        XCTAssertNoThrow(try store.handleFrame(frame("ETH", price: "3000", high: "0.00000000"), window: .day))
        XCTAssertNoThrow(try store.handleFrame(Data("not json".utf8), window: .day))
        XCTAssertNoThrow(try store.handleFrame(frame("BTC", price: "80000"), window: .day))
        // Quotes for coins outside the watchlist, e.g. a late reply after removal, are ignored.
        XCTAssertNoThrow(try store.handleFrame(frame("SOL", price: "150"), window: .day))
        XCTAssertEqual(store.quotes.keys.sorted(), ["BTC"])
        XCTAssertTrue(store.live)
        let shutdown = Data(#"{"stream":"!serverShutdown","data":{"e":"serverShutdown","E":1793269256004}}"#.utf8)
        XCTAssertThrowsError(try store.handleFrame(shutdown, window: .day))
    }

    @MainActor
    func testEachQuoteFramePublishesOnce() throws {
        let suite = "CryptoTickerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MarketStore(defaults: defaults)
        var changes = 0
        let subscription = store.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }
        try store.handleFrame(frame("BTC", price: "80000", eventTime: 1), window: .day)
        changes = 0
        for eventTime in 2...11 {
            try store.handleFrame(frame("BTC", price: "80000", eventTime: Double(eventTime)), window: .day)
        }
        XCTAssertEqual(changes, 10)
    }

    @MainActor
    func testStoppingReplacesTheLiveStatus() throws {
        let suite = "CryptoTickerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MarketStore(defaults: defaults)
        try store.handleFrame(frame("BTC", price: "80000"), window: .day)
        XCTAssertEqual(store.status, L10n.text("status.live"))
        store.stop()
        XCTAssertFalse(store.live)
        XCTAssertEqual(store.status, L10n.text("status.paused"))
    }

    @MainActor
    func testStalenessUsesLocalReceiveTimeNotExchangeTime() throws {
        let suite = "CryptoTickerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["BTC", "ETH"], forKey: "watchlistSymbols")
        let store = MarketStore(defaults: defaults)
        let received = Date()
        // Exchange timestamps a minute ahead of and behind the local clock.
        for (symbol, offset) in [("BTC", 60.0), ("ETH", -60.0)] {
            let eventTime = (received.timeIntervalSince1970 + offset) * 1000
            try store.handleFrame(frame(symbol, price: "100", eventTime: eventTime), window: .day, receivedAt: received)
            XCTAssertFalse(store.isStale(symbol, at: received.addingTimeInterval(20)))
            XCTAssertTrue(store.isStale(symbol, at: received.addingTimeInterval(20.01)))
        }
        XCTAssertTrue(store.isStale("SOL", at: received))
    }

    @MainActor
    func testEditingTheWatchlistKeepsPinnedAlertBaseline() throws {
        let suite = "CryptoTickerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["BTC", "ETH", "DOGE"], forKey: "watchlistSymbols")
        defaults.set(["BTC"], forKey: "pinnedSymbols")
        let store = MarketStore(defaults: defaults)
        store.setAlertsEnabled(true)
        let first = try quote("BTC", price: 100, second: 0)
        store.recordMovement(first, receivedAt: first.date)
        store.removeCoin("DOGE")
        store.stop()
        let second = try quote("BTC", price: 101, second: 1)
        store.recordMovement(second, receivedAt: second.date)
        XCTAssertEqual(store.latestAlert?.symbol, "BTC")
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
