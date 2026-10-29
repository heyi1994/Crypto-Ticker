import AppKit
import SwiftUI
import XCTest
@testable import CryptoTicker

final class CoinListScrollTests: XCTestCase {
    @MainActor
    private func rows(_ count: Int, price: String = "100.00") -> AnyView {
        AnyView(VStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { index in
                Text("COIN\(index) \(price)").frame(height: 59)
            }
        })
    }

    @MainActor
    func testAddingRowsAllowsScrollingBackFromBottom() throws {
        _ = NSApplication.shared
        let scroll = CoinListScrollSurface(content: rows(6))
        scroll.layoutSubtreeIfNeeded()
        scroll.update(content: rows(9))
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertGreaterThan(document.frame.height, scroll.contentView.bounds.height)
        XCTAssertTrue(scroll.hasVerticalScroller)
        XCTAssertTrue(scroll.autohidesScrollers)
        XCTAssertEqual(scroll.scrollerStyle, .overlay)

        let bottom = document.frame.height - scroll.contentView.bounds.height
        scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom))
        scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0)

        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 0.1)
    }

    @MainActor
    func testPriceAndWatchlistUpdatesPreservePosition() throws {
        _ = NSApplication.shared
        let scroll = CoinListScrollSurface(content: rows(10))
        scroll.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 100))
        let offset = scroll.contentView.bounds.minY
        XCTAssertGreaterThan(offset, 0)

        scroll.update(content: rows(10, price: "101.00"))
        XCTAssertEqual(scroll.contentView.bounds.minY, offset, accuracy: 0.1)
        scroll.update(content: rows(11))
        XCTAssertEqual(scroll.contentView.bounds.minY, offset, accuracy: 0.1)
        scroll.update(content: rows(2))
        XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 0.1)
    }
}
