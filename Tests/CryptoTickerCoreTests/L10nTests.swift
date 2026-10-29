import Foundation
import XCTest
@testable import CryptoTickerCore

final class L10nTests: XCTestCase {
    private func table(_ language: String) throws -> [String: String] {
        let url = L10n.resourceBundleURL.appendingPathComponent("\(language).lproj/Localizable.strings")
        let value = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), options: [], format: nil)
        return try XCTUnwrap(value as? [String: String])
    }

    func testBothLanguagesHaveCompleteMatchingCatalogs() throws {
        let english = try table("en")
        let chinese = try table("zh-Hans")
        XCTAssertEqual(Set(english.keys), Set(chinese.keys))
        XCTAssertGreaterThan(english.count, 50)
        for (key, value) in english {
            XCTAssertFalse(value.isEmpty, key)
            XCTAssertFalse(try XCTUnwrap(chinese[key]).isEmpty, key)
            XCTAssertEqual(L10n.text(key, language: "en"), value)
        }
    }

    func testControlsErrorsAndNotificationsAreTranslated() {
        XCTAssertEqual(L10n.text("coin.add", language: "en"), "Add")
        XCTAssertEqual(L10n.text("coin.add", language: "zh-Hans"), "添加")
        XCTAssertEqual(L10n.text("notification.test_title", language: "en"), "Crypto Ticker test notification")
        XCTAssertEqual(L10n.text("notification.test_title", language: "zh-Hans"), "Crypto Ticker 测试通知")
        XCTAssertEqual(L10n.text("error.duplicate", language: "en"), "This coin is already in your watchlist.")
        XCTAssertEqual(L10n.text("error.duplicate", language: "zh-Hans"), "该币种已在列表中")
    }

    func testDynamicArgumentsKeepSymbolsWindowsAndPercentages() {
        XCTAssertEqual(L10n.text("status.retry", language: "en", 30), "Disconnected. Retrying in 30 seconds")
        XCTAssertEqual(L10n.text("status.retry", language: "zh-Hans", 30), "连接中断，30 秒后重试")
        XCTAssertEqual(L10n.text("alert.rise", language: "en", "BTC"), "BTC sharp rise")
        XCTAssertEqual(L10n.text("alert.summary", language: "en", "BTC", 5, "+1.25%"), "BTC · within 5 min: +1.25%")
        XCTAssertEqual(L10n.text("alert.summary", language: "zh-Hans", "BTC", 5, "+1.25%"), "BTC · 5 分钟内 +1.25%")
        XCTAssertEqual(L10n.text("market.source", language: "en", "4h"), "Binance Spot · USDT · 4h change")
    }
}
