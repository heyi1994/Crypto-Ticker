import Foundation
import XCTest
@testable import CryptoTickerCore

final class MarketTests: XCTestCase {
    private let event = #"{"stream":"btcusdt@ticker","data":{"e":"24hrTicker","E":1793269256004,"s":"BTCUSDT","c":"80116.19","P":"-1.735","h":"81788.56","l":"79710.00"}}"#

    func testStreamDecodesCorrectFieldsAndMilliseconds() throws {
        let quote = try XCTUnwrap(Quote.decodeStream(Data(event.utf8)))
        XCTAssertEqual(quote.symbol, "BTC")
        XCTAssertEqual(quote.price, 80116.19)
        XCTAssertEqual(quote.changePercent, -1.735)
        XCTAssertEqual(quote.high, 81788.56)
        XCTAssertEqual(quote.low, 79710)
        XCTAssertEqual(quote.date.timeIntervalSince1970, 1793269256.004, accuracy: 0.001)
        XCTAssertEqual(quote.formattedChange, "-1.74%")
    }

    func testSnapshotAndStreamProduceSameQuote() throws {
        let snapshot = #"[{"symbol":"BTCUSDT","lastPrice":"80116.19","priceChangePercent":"-1.735","highPrice":"81788.56","lowPrice":"79710.00","closeTime":1793269256004}]"#
        XCTAssertEqual(try Quote.decodeSnapshot(Data(snapshot.utf8)).first,
                       try Quote.decodeStream(Data(event.utf8)))
    }

    func testInvalidNumbersAndUnexpectedQuoteCurrencyAreRejected() {
        for (old, new) in [("80116.19", "NaN"), ("80116.19", "-1"),
                           ("80116.19", "0"), ("-1.735", "Infinity"), ("BTCUSDT", "BTCUSDC")] {
            let payload = event.replacingOccurrences(of: old, with: new)
            XCTAssertThrowsError(try Quote.decodeStream(Data(payload.utf8)))
        }
    }

    func testControlEventDoesNotBecomeAQuote() throws {
        let data = Data(#"{"stream":"!serverShutdown","data":{"e":"serverShutdown","E":1793269256004}}"#.utf8)
        XCTAssertNil(try Quote.decodeStream(data))
        XCTAssertTrue(Quote.isServerShutdown(data))
    }

    func testStalenessBoundary() throws {
        let quote = try XCTUnwrap(Quote.decodeStream(Data(event.utf8)))
        XCTAssertFalse(quote.isStale(at: quote.date.addingTimeInterval(20)))
        XCTAssertTrue(quote.isStale(at: quote.date.addingTimeInterval(20.01)))
    }

    func testFormattingPreservesSmallCoinPrices() {
        XCTAssertEqual(PriceFormat.price(80116.19), "80,116.19")
        XCTAssertEqual(PriceFormat.price(0.12345), "0.1235")
        XCTAssertEqual(PriceFormat.price(0.00001234), "0.00001234")
    }
}
