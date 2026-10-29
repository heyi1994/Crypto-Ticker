import Foundation

public enum PriceWindow: String, CaseIterable, Identifiable, Sendable {
    case oneHour = "1h"
    case fourHours = "4h"
    case day = "24h"

    public var id: String { rawValue }

    public var eventName: String {
        self == .day ? "24hrTicker" : rawValue + "Ticker"
    }

    public func streamURL(pairs: [String]) -> URL {
        let suffix = self == .day ? "@ticker" : "@ticker_" + rawValue
        var url = URLComponents(string: "wss://data-stream.binance.vision/stream")!
        url.queryItems = [URLQueryItem(name: "streams", value: pairs.map { $0.lowercased() + suffix }.joined(separator: "/"))]
        return url.url!
    }

    public func snapshotURL(pairs: [String]) throws -> URL {
        let endpoint = self == .day ? "ticker/24hr" : "ticker"
        var url = URLComponents(string: "https://data-api.binance.vision/api/v3/" + endpoint)!
        let symbols = try JSONEncoder().encode(pairs)
        url.queryItems = [URLQueryItem(name: "symbols", value: String(decoding: symbols, as: UTF8.self))]
        if self != .day { url.queryItems?.append(URLQueryItem(name: "windowSize", value: rawValue)) }
        return url.url!
    }
}
