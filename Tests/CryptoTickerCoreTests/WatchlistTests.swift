import Foundation
import XCTest
@testable import CryptoTickerCore

final class WatchlistTests: XCTestCase {
    func testInputNormalizationAndInvalidInput() throws {
        for input in ["ada", " ADA ", "adausdt", "ADA/USDT"] {
            XCTAssertEqual(try Coin.normalize(input), "ADA")
        }
        XCTAssertEqual(try Coin.normalize("1000sats"), "1000SATS")
        for input in ["", " ", "/USDT", "BTC USDT", "BTC/BTC", "BTC@ticker", "BTC&symbol=ETH"] {
            XCTAssertThrowsError(try Coin.normalize(input), input)
        }
    }

    func testCustomCoinRestoresAndDuplicateInputIsRejected() throws {
        var list = Watchlist()
        try list.add("ada/usdt")
        list.togglePin("ADA")
        let restored = Watchlist(symbols: list.symbols, pinned: list.pinned)
        XCTAssertEqual(restored, list)
        XCTAssertTrue(restored.coins.contains { $0.symbol == "ADA" && $0.pair == "ADAUSDT" })
        XCTAssertThrowsError(try list.add("ADAUSDT"))
    }

    func testDeletingLastPinnedCoinKeepsAValidMenuBarSelection() {
        var list = Watchlist(symbols: ["BTC", "ADA"], pinned: ["ADA"])
        list.remove("ADA")
        XCTAssertEqual(list.symbols, ["BTC"])
        XCTAssertEqual(list.pinned, ["BTC"])
        list.remove("BTC")
        list.togglePin("BTC")
        XCTAssertEqual(list.symbols, ["BTC"])
        XCTAssertEqual(list.pinned, ["BTC"])
    }

    func testRestorationRepairsDuplicatesAndDanglingPins() {
        let list = Watchlist(symbols: ["ADA", "ada", "!", "LINK"], pinned: ["DOGE", "LINK", "LINK"])
        XCTAssertEqual(list.symbols, ["ADA", "LINK"])
        XCTAssertEqual(list.pinned, ["LINK"])
        XCTAssertEqual(Watchlist(symbols: [], pinned: []).pinned, ["BTC"])
    }

    func testWatchlistAndPinLimits() throws {
        var list = Watchlist(symbols: ["A", "B", "C", "D"])
        for symbol in list.symbols { list.togglePin(symbol) }
        XCTAssertEqual(list.pinned.count, 3)
        list.togglePin("UNKNOWN")
        XCTAssertFalse(list.pinned.contains("UNKNOWN"))
        var full = Watchlist(symbols: (0..<50).map { "COIN\($0)" })
        XCTAssertThrowsError(try full.add("ADA"))
        XCTAssertEqual(full.symbols.count, 50)
    }

    func testExchangeValidationRequiresExactActiveSpotPair() throws {
        let valid = #"{"symbols":[{"symbol":"ADAUSDT","baseAsset":"ADA","quoteAsset":"USDT","status":"TRADING","isSpotTradingAllowed":true}]}"#
        XCTAssertNoThrow(try Coin.validateExchangeInfo(Data(valid.utf8), symbol: "ADA"))
        XCTAssertThrowsError(try Coin.validateExchangeInfo(Data(valid.utf8), symbol: "LINK"))
        for (old, new) in [("TRADING", "BREAK"), ("true", "false"), ("\"USDT\"", "\"USDC\"")] {
            let invalid = valid.replacingOccurrences(of: old, with: new)
            XCTAssertThrowsError(try Coin.validateExchangeInfo(Data(invalid.utf8), symbol: "ADA"))
        }
        XCTAssertThrowsError(try Coin.validateExchangeInfo(Data(#"{"symbols":[]}"#.utf8), symbol: "ADA"))
    }
}
