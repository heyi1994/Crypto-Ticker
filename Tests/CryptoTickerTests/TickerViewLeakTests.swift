import AppKit
import CryptoTickerCore
import SwiftUI
import XCTest
@testable import CryptoTicker

final class TickerViewLeakTests: XCTestCase {
    /// Live Observation registrars in this process, or nil when heap(1) cannot report them.
    private func observationRegistrars() -> Int? {
        let heap = Process()
        heap.executableURL = URL(fileURLWithPath: "/usr/bin/heap")
        heap.arguments = [String(getpid())]
        let output = Pipe()
        heap.standardOutput = output
        heap.standardError = Pipe()
        guard (try? heap.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        heap.waitUntilExit()
        let line = String(decoding: data, as: UTF8.self).split(separator: "\n")
            .first { $0.contains("ObservationRegistrar.(State") && $0.contains("LockedBuffer") }
        return line.flatMap { $0.split(separator: " ").first }.flatMap { Int($0) }
    }

    @MainActor
    func testQuoteUpdatesDoNotLeakObservationRecords() throws {
        let suite = "CryptoTickerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MarketStore(defaults: defaults)
        _ = NSApplication.shared
        let host = NSHostingView(rootView: TickerView(store: store, notifier: AlertNotifier()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 390, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        var eventTime = Date().timeIntervalSince1970 * 1000
        func sendQuotes(_ count: Int) throws {
            for index in 0..<count {
                eventTime += 1000
                let frame = #"{"stream":"x","data":{"e":"24hrTicker","E":\#(eventTime),"s":"BTCUSDT","c":"\#(80000 + index)","P":"1","h":"90000","l":"1"}}"#
                try store.handleFrame(Data(frame.utf8), window: .day)
                RunLoop.main.run(mode: .default, before: Date())
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
            }
        }
        try sendQuotes(20)
        guard let before = observationRegistrars() else { throw XCTSkip("heap(1) cannot inspect this process") }
        try sendQuotes(100)
        let after = try XCTUnwrap(observationRegistrars())
        // With the segmented picker inline, macOS 26 leaked two records per quote here.
        XCTAssertLessThan(after - before, 20)
    }
}
