import Foundation
import XCTest
@testable import CryptoTickerCore

final class PriceWindowTests: XCTestCase {
    func testSnapshotRequestsUseTheSelectedWindowAndKeepCustomCoins() throws {
        let pairs = ["BTCUSDT", "FLOKIUSDT"]
        for window in PriceWindow.allCases {
            let components = try XCTUnwrap(URLComponents(url: window.snapshotURL(pairs: pairs), resolvingAgainstBaseURL: false))
            let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            let symbols = try XCTUnwrap(query["symbols"])
            XCTAssertEqual(try JSONDecoder().decode([String].self, from: Data(symbols.utf8)), pairs)
            XCTAssertEqual(components.path, window == .day ? "/api/v3/ticker/24hr" : "/api/v3/ticker")
            XCTAssertEqual(query["windowSize"], window == .day ? nil : window.rawValue)
        }
    }

    func testStreamsAndPercentagesMatchSelectedWindow() throws {
        for window in PriceWindow.allCases {
            let url = window.streamURL(pairs: ["BTCUSDT", "FLOKIUSDT"])
            let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            let suffix = window == .day ? "@ticker" : "@ticker_" + window.rawValue
            XCTAssertEqual(components.queryItems?.first?.value, "btcusdt\(suffix)/flokiusdt\(suffix)")
            let payload = """
            {"stream":"btcusdt\(suffix)","data":{"e":"\(window.eventName)","E":1793269256004,"s":"BTCUSDT","c":"100.50","P":"1.250","h":"101","l":"99"}}
            """
            let data = Data(payload.utf8)
            let quote = try XCTUnwrap(Quote.decodeStream(data, window: window))
            XCTAssertEqual(quote.window, window)
            XCTAssertEqual(quote.formattedChange, "+1.25%")
            for other in PriceWindow.allCases where other != window {
                XCTAssertNil(try Quote.decodeStream(data, window: other), "A previous window must not become the current percentage")
            }
        }
    }

    func testRollingSnapshotRetainsWindow() throws {
        let payload = Data(#"[{"symbol":"BTCUSDT","lastPrice":"100.5","priceChangePercent":"-0.75","highPrice":"101","lowPrice":"99","closeTime":1793269256004}]"#.utf8)
        for window in PriceWindow.allCases {
            let quote = try XCTUnwrap(Quote.decodeSnapshot(payload, window: window).first)
            XCTAssertEqual(quote.window, window)
            XCTAssertEqual(quote.formattedChange, "-0.75%")
        }
    }
}
