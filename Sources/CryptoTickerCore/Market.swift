import Foundation

public struct Coin: Identifiable, Equatable, Sendable {
    public let symbol: String
    public let name: String
    public let mark: String
    public var id: String { symbol }
    public var pair: String { symbol + "USDT" }

    public init(symbol: String) {
        let known = Self.all.first { $0.symbol == symbol }
        self.symbol = symbol
        self.name = known?.name ?? symbol
        self.mark = known?.mark ?? String(symbol.prefix(1))
    }

    private init(symbol: String, name: String, mark: String) {
        self.symbol = symbol
        self.name = name
        self.mark = mark
    }

    public static func normalize(_ input: String) throws -> String {
        // Compatibility mapping turns fullwidth input such as "ＡＤＡ" into ASCII.
        var symbol = input.precomposedStringWithCompatibilityMapping
            .trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if symbol.hasSuffix("/USDT") {
            symbol.removeLast(5)
        } else if symbol.hasSuffix("USDT"), symbol.count > 4 {
            symbol.removeLast(4)
        }
        guard !symbol.isEmpty, symbol.count <= 32,
              symbol.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.alphanumerics.contains($0) }) else {
            throw WatchlistError.invalidSymbol
        }
        return symbol
    }

    public static func validateExchangeInfo(_ data: Data, symbol: String) throws {
        let info = try JSONDecoder().decode(ExchangeInfo.self, from: data)
        guard info.symbols.contains(where: {
            $0.symbol == symbol + "USDT" && $0.baseAsset == symbol &&
            $0.quoteAsset == "USDT" && $0.status == "TRADING" && $0.isSpotTradingAllowed
        }) else { throw WatchlistError.unavailablePair }
    }

    public static let all: [Coin] = [
        .init(symbol: "BTC", name: "Bitcoin", mark: "₿"),
        .init(symbol: "ETH", name: "Ethereum", mark: "Ξ"),
        .init(symbol: "SOL", name: "Solana", mark: "◎"),
        .init(symbol: "BNB", name: "BNB", mark: "B"),
        .init(symbol: "XRP", name: "XRP", mark: "X"),
        .init(symbol: "DOGE", name: "Dogecoin", mark: "Ð")
    ]
}

public enum WatchlistError: LocalizedError {
    case invalidSymbol, duplicate, limitReached, unavailablePair

    public var errorDescription: String? {
        switch self {
        case .invalidSymbol: return L10n.text("error.invalid_symbol")
        case .duplicate: return L10n.text("error.duplicate")
        case .limitReached: return L10n.text("error.limit")
        case .unavailablePair: return L10n.text("error.unavailable_pair")
        }
    }
}

public struct Watchlist: Equatable, Sendable {
    public private(set) var symbols: [String]
    public private(set) var pinned: [String]
    public var coins: [Coin] { symbols.map(Coin.init(symbol:)) }

    public init(symbols: [String]? = nil, pinned: [String] = ["BTC"]) {
        var restored: [String] = []
        for input in symbols ?? Coin.all.map(\.symbol) {
            if let symbol = try? Coin.normalize(input), !restored.contains(symbol), restored.count < 50 {
                restored.append(symbol)
            }
        }
        self.symbols = restored.isEmpty ? Coin.all.map(\.symbol) : restored
        var restoredPins: [String] = []
        for symbol in pinned where self.symbols.contains(symbol) && !restoredPins.contains(symbol) && restoredPins.count < 3 {
            restoredPins.append(symbol)
        }
        self.pinned = restoredPins.isEmpty ? [self.symbols[0]] : restoredPins
    }

    public mutating func add(_ input: String) throws {
        let symbol = try Coin.normalize(input)
        try checkCanAdd(symbol)
        symbols.append(symbol)
    }

    /// Checks a normalized symbol against duplicates and the size limit without adding it.
    public func checkCanAdd(_ symbol: String) throws {
        guard !symbols.contains(symbol) else { throw WatchlistError.duplicate }
        guard symbols.count < 50 else { throw WatchlistError.limitReached }
    }

    public mutating func remove(_ symbol: String) {
        guard symbols.count > 1, symbols.contains(symbol) else { return }
        symbols.removeAll { $0 == symbol }
        pinned.removeAll { $0 == symbol }
        if pinned.isEmpty { pinned = [symbols[0]] }
    }

    public mutating func togglePin(_ symbol: String) {
        guard symbols.contains(symbol) else { return }
        if pinned.contains(symbol) {
            if pinned.count > 1 { pinned.removeAll { $0 == symbol } }
        } else if pinned.count < 3 {
            pinned.append(symbol)
        }
    }
}

private struct ExchangeInfo: Decodable {
    let symbols: [ExchangeSymbol]
    struct ExchangeSymbol: Decodable {
        let symbol: String
        let baseAsset: String
        let quoteAsset: String
        let status: String
        let isSpotTradingAllowed: Bool
    }
}

public struct Quote: Equatable, Sendable {
    public let window: PriceWindow
    public let symbol: String
    public let price: Double
    public let changePercent: Double
    public let high: Double
    public let low: Double
    public let date: Date

    public var formattedPrice: String { PriceFormat.price(price) }
    public var formattedChange: String { String(format: "%+.2f%%", changePercent) }

    public static func decodeStream(_ data: Data, window: PriceWindow = .day) throws -> Quote? {
        let envelope = try JSONDecoder().decode(StreamEnvelope.self, from: data)
        // Binance can also send control events, e.g. serverShutdown.
        guard envelope.data.event == window.eventName else { return nil }
        return try envelope.data.quote(window: window)
    }

    public static func decodeSnapshot(_ data: Data, window: PriceWindow = .day) throws -> [Quote] {
        // Skip a bad entry rather than discard the whole watchlist.
        try JSONDecoder().decode([Snapshot].self, from: data).compactMap { try? $0.quote(window: window) }
    }

    /// Classifies a stream frame with a single decode.
    public static func decodeFrame(_ data: Data, window: PriceWindow = .day) -> StreamFrame {
        guard let ticker = try? JSONDecoder().decode(StreamEnvelope.self, from: data).data else { return .ignored }
        if ticker.event == "serverShutdown" { return .serverShutdown }
        guard ticker.event == window.eventName, let quote = try? ticker.quote(window: window) else { return .ignored }
        return .quote(quote)
    }
}

public enum StreamFrame: Equatable, Sendable {
    case quote(Quote)
    case serverShutdown
    /// Other control events, other windows, and frames that fail to decode.
    case ignored
}

public enum PriceFormat {
    public static func price(_ value: Double) -> String {
        let digits = value >= 1 ? 2 : value >= 0.01 ? 4 : 8
        return value.formatted(.number.locale(Locale(identifier: "en_US"))
            .precision(.fractionLength(digits)).rounded(rule: .toNearestOrAwayFromZero))
    }
}

private struct StreamEnvelope: Decodable {
    let data: StreamTicker
}

private struct StreamTicker: Decodable {
    let event: String
    let symbol: String?
    let price: String?
    let change: String?
    let high: String?
    let low: String?
    let timestamp: Double?

    enum CodingKeys: String, CodingKey {
        case event = "e", symbol = "s", price = "c", change = "P"
        case high = "h", low = "l", timestamp = "E"
    }

    func quote(window: PriceWindow) throws -> Quote {
        try makeQuote(symbol: symbol, price: price, change: change,
                      high: high, low: low, timestamp: timestamp, window: window)
    }
}

private struct Snapshot: Decodable {
    let symbol: String?
    let lastPrice: String?
    let priceChangePercent: String?
    let highPrice: String?
    let lowPrice: String?
    let closeTime: Double?

    func quote(window: PriceWindow) throws -> Quote {
        try makeQuote(symbol: symbol, price: lastPrice, change: priceChangePercent,
                      high: highPrice, low: lowPrice, timestamp: closeTime, window: window)
    }
}

private func makeQuote(symbol: String?, price: String?, change: String?,
                       high: String?, low: String?, timestamp: Double?, window: PriceWindow) throws -> Quote {
    guard let symbol, symbol.hasSuffix("USDT"), symbol.count > 4,
          let price = Double(price ?? ""), price.isFinite, price > 0,
          let change = Double(change ?? ""), change.isFinite,
          let high = Double(high ?? ""), high.isFinite, high > 0,
          let low = Double(low ?? ""), low.isFinite, low > 0,
          let timestamp, timestamp.isFinite, timestamp > 0 else {
        throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid ticker values"))
    }
    return Quote(window: window, symbol: String(symbol.dropLast(4)), price: price, changePercent: change,
                 high: high, low: low, date: Date(timeIntervalSince1970: timestamp / 1000))
}
