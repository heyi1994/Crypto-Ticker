import Foundation
import XCTest
@testable import CryptoTickerCore

final class VolatilityMonitorTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    private func record(_ monitor: inout VolatilityMonitor, _ price: Double, _ second: Double,
                        symbol: String = "BTC", rule: VolatilityRule = VolatilityRule()) -> MovementAlert? {
        let date = start.addingTimeInterval(second)
        return monitor.record(symbol: symbol, price: price, at: date, receivedAt: date, rule: rule)
    }

    func testFirstSampleDoesNotAlertAndExactThresholdTriggersBothDirections() throws {
        var rising = VolatilityMonitor()
        XCTAssertNil(record(&rising, 100, 0))
        XCTAssertNil(record(&rising, 100.9, 1))
        let up = try XCTUnwrap(record(&rising, 101, 2))
        XCTAssertEqual(up.changePercent, 1, accuracy: 0.00001)
        XCTAssertEqual(up.title, L10n.text("alert.rise", "BTC"))

        var falling = VolatilityMonitor()
        XCTAssertNil(record(&falling, 100, 0))
        let down = try XCTUnwrap(record(&falling, 99, 1))
        XCTAssertEqual(down.changePercent, -1, accuracy: 0.00001)
        XCTAssertEqual(down.title, L10n.text("alert.drop", "BTC"))
    }

    func testSamplesOutsideRollingWindowAreNotUsed() {
        var monitor = VolatilityMonitor()
        XCTAssertNil(record(&monitor, 100, 0))
        XCTAssertNil(record(&monitor, 100.5, 1))
        for second in stride(from: 10, through: 60, by: 10) {
            XCTAssertNil(record(&monitor, 100.5, Double(second)))
        }
        XCTAssertNil(record(&monitor, 101.3, 61))
        XCTAssertNotNil(record(&monitor, 101.6, 62))
    }

    func testCooldownIsPerCoinAndRearmsAfterFiveMinutes() {
        var monitor = VolatilityMonitor()
        XCTAssertNil(record(&monitor, 100, 0))
        XCTAssertNotNil(record(&monitor, 102, 1))
        XCTAssertNil(record(&monitor, 103, 2))
        XCTAssertNil(record(&monitor, 100, 2, symbol: "ETH"))
        XCTAssertNotNil(record(&monitor, 98, 3, symbol: "ETH"))
        for second in stride(from: 10, through: 300, by: 10) {
            XCTAssertNil(record(&monitor, 103, Double(second)))
        }
        XCTAssertNotNil(record(&monitor, 105, 301))
    }

    func testReconnectGapStartsANewBaseline() {
        var monitor = VolatilityMonitor()
        XCTAssertNil(record(&monitor, 100, 0))
        XCTAssertNil(record(&monitor, 110, 30))
        XCTAssertNotNil(record(&monitor, 112, 31))
    }

    func testResettingHistoryDoesNotBypassCooldown() {
        var monitor = VolatilityMonitor()
        XCTAssertNil(record(&monitor, 100, 0))
        XCTAssertNotNil(record(&monitor, 102, 1))
        monitor.resetHistory()
        XCTAssertNil(record(&monitor, 200, 2))
        XCTAssertNil(record(&monitor, 204, 3))
    }

    func testStaleInvalidAndOutOfOrderSamplesDoNotTrigger() {
        var monitor = VolatilityMonitor()
        XCTAssertNil(record(&monitor, 100, 0))
        XCTAssertNil(record(&monitor, .nan, 1))
        XCTAssertNil(record(&monitor, -1, 1))
        XCTAssertNil(record(&monitor, 110, -1))
        XCTAssertNotNil(record(&monitor, 102, 2))
    }

    func testClockSkewBetweenExchangeAndLocalTimeDoesNotBlockAlerts() {
        for skew in [-60.0, 60] {
            var monitor = VolatilityMonitor()
            for (price, second) in [(100.0, 0.0), (101.0, 1.0)] {
                let date = start.addingTimeInterval(second)
                let alert = monitor.record(symbol: "BTC", price: price, at: date,
                                           receivedAt: date.addingTimeInterval(skew), rule: VolatilityRule())
                XCTAssertEqual(alert != nil, price == 101, "skew \(skew)")
            }
        }
    }

    func testDifferentDurationsDetectOnlyMovementWithinTheirWindows() {
        var short = VolatilityMonitor()
        var long = VolatilityMonitor()
        var longAlerts = 0
        for second in stride(from: 0, through: 120, by: 10) {
            let price = 100 + Double(second) / 100
            XCTAssertNil(record(&short, price, Double(second)))
            if record(&long, price, Double(second), rule: VolatilityRule(minutes: 5)) != nil { longAlerts += 1 }
        }
        XCTAssertEqual(longAlerts, 1)
        XCTAssertEqual(VolatilityRule(minutes: -1, thresholdPercent: .nan), VolatilityRule())
    }
}
