import AppKit
import CryptoTickerCore
import Foundation

@main
struct CryptoTickerApplication {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--check-localization") {
            let values = ["language": L10n.language,
                          "bundle": L10n.resourceBundleURL.path,
                          "subtitle": L10n.text("app.subtitle"),
                          "test_title": L10n.text("notification.test_title"),
                          "retry": L10n.text("status.retry", 30),
                          "duplicate_error": WatchlistError.duplicate.localizedDescription]
            let data = try! JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            print(String(decoding: data, as: UTF8.self))
            return
        }
        if CommandLine.arguments.contains("--check-feed") {
            var window = PriceWindow.day
            if let index = CommandLine.arguments.firstIndex(of: "--window") {
                guard CommandLine.arguments.indices.contains(index + 1),
                      let selected = PriceWindow(rawValue: CommandLine.arguments[index + 1]) else {
                    fputs("--window requires 1h, 4h, or 24h\n", stderr)
                    exit(EXIT_FAILURE)
                }
                window = selected
            }
            Task { await checkFeed(window: window) }
            dispatchMain()
        }
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

// Validate the actual public feed without creating a menu bar item.
private func checkFeed(window: PriceWindow) async {
        do {
            let pairs = ["BTCUSDT", "ETHUSDT", "SOLUSDT"]
            let url = try window.snapshotURL(pairs: pairs)
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 15
            config.timeoutIntervalForResource = 20
            let session = URLSession(configuration: config)
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            for quote in try Quote.decodeSnapshot(data, window: window) {
                print("REST [\(window.rawValue)] \(quote.symbol) \(quote.formattedPrice) USDT \(quote.formattedChange)")
            }
            let socket = session.webSocketTask(with: window.streamURL(pairs: pairs))
            socket.resume()
            let deadline = Task {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                if !Task.isCancelled { socket.cancel(with: .goingAway, reason: nil) }
            }
            defer { deadline.cancel(); socket.cancel(with: .normalClosure, reason: nil) }
            var count = 0
            while count < 3 {
                let message = try await socket.receive()
                let payload: Data
                switch message {
                case .string(let text): payload = Data(text.utf8)
                case .data(let bytes): payload = bytes
                @unknown default: continue
                }
                if let quote = try Quote.decodeStream(payload, window: window) {
                    print("WS   [\(window.rawValue)] \(quote.symbol) \(quote.formattedPrice) USDT \(quote.formattedChange)")
                    count += 1
                }
            }
            print("PASS: \(window.rawValue) snapshot + live WebSocket decoding")
            exit(EXIT_SUCCESS)
        } catch {
            fputs("Feed check failed: \(error)\n", stderr)
            exit(EXIT_FAILURE)
        }
}
