import AppKit
import Combine
import CryptoTickerCore
import Foundation

@MainActor
final class MarketStore: ObservableObject {
    @Published private(set) var quotes: [String: Quote] = [:]
    @Published private(set) var status = L10n.text("status.connecting")
    @Published private(set) var live = false
    @Published private(set) var now = Date()
    @Published private(set) var selectedWindow: PriceWindow
    @Published private(set) var watchlist: Watchlist {
        didSet {
            defaults.set(watchlist.symbols, forKey: "watchlistSymbols")
            defaults.set(watchlist.pinned, forKey: "pinnedSymbols")
        }
    }
    @Published private(set) var isAdding = false
    @Published private(set) var additionMessage = L10n.text("coin.supported")
    @Published private(set) var additionFailed = false
    @Published private(set) var alertsEnabled: Bool
    @Published private(set) var alertRule: VolatilityRule
    @Published private(set) var latestAlert: MovementAlert?
    let alertEvents = PassthroughSubject<MovementAlert, Never>()
    private var volatilityMonitor = VolatilityMonitor()

    var coins: [Coin] { watchlist.coins }
    var pinned: [String] { watchlist.pinned }

    private let defaults: UserDefaults
    private let session: URLSession
    private var stream: URLSessionWebSocketTask?
    private var connectionTask: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?
    private var receivedAt: Date?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        alertsEnabled = defaults.bool(forKey: "volatilityAlertsEnabled")
        alertRule = VolatilityRule(minutes: defaults.integer(forKey: "volatilityMinutes"),
                                   thresholdPercent: defaults.double(forKey: "volatilityThreshold"))
        selectedWindow = PriceWindow(rawValue: defaults.string(forKey: "priceWindow") ?? "") ?? .day
        watchlist = Watchlist(symbols: defaults.stringArray(forKey: "watchlistSymbols"),
                              pinned: defaults.stringArray(forKey: "pinnedSymbols") ?? ["BTC"])
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    func togglePin(_ symbol: String) {
        volatilityMonitor.resetHistory(for: symbol)
        watchlist.togglePin(symbol)
    }

    func setAlertsEnabled(_ enabled: Bool) {
        alertsEnabled = enabled
        defaults.set(enabled, forKey: "volatilityAlertsEnabled")
        volatilityMonitor.resetHistory()
        if !enabled { latestAlert = nil }
    }

    func setAlertRule(minutes: Int, thresholdPercent: Double) {
        alertRule = VolatilityRule(minutes: minutes, thresholdPercent: thresholdPercent)
        defaults.set(alertRule.minutes, forKey: "volatilityMinutes")
        defaults.set(alertRule.thresholdPercent, forKey: "volatilityThreshold")
        volatilityMonitor.resetHistory()
    }

    func recordMovement(_ quote: Quote, receivedAt date: Date = Date()) {
        guard alertsEnabled, pinned.contains(quote.symbol),
              let alert = volatilityMonitor.record(symbol: quote.symbol, price: quote.price, at: quote.date,
                                                   receivedAt: date, rule: alertRule) else { return }
        latestAlert = alert
        alertEvents.send(alert)
    }

    func selectWindow(_ window: PriceWindow) {
        guard selectedWindow != window else { return }
        selectedWindow = window
        defaults.set(window.rawValue, forKey: "priceWindow")
        // Do not display a previous window's percentage under the new label.
        quotes.removeAll()
        reconnect()
    }

    func removeCoin(_ symbol: String) {
        guard coins.count > 1 else { return }
        watchlist.remove(symbol)
        quotes.removeValue(forKey: symbol)
        reconnect()
    }

    @discardableResult
    func addCoin(_ input: String) async -> Bool {
        guard !isAdding else { return false }
        isAdding = true
        additionFailed = false
        additionMessage = L10n.text("coin.validating")
        defer { isAdding = false }
        do {
            let symbol = try Coin.normalize(input)
            var candidate = watchlist
            try candidate.add(symbol)
            var url = URLComponents(string: "https://data-api.binance.vision/api/v3/exchangeInfo")!
            url.queryItems = [URLQueryItem(name: "symbol", value: symbol + "USDT")]
            let (data, response) = try await session.data(from: url.url!)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            if response.statusCode == 400 { throw WatchlistError.unavailablePair }
            guard response.statusCode == 200 else { throw URLError(.badServerResponse) }
            try Coin.validateExchangeInfo(data, symbol: symbol)
            try watchlist.add(symbol)
            additionMessage = L10n.text("coin.added", symbol)
            reconnect()
            return true
        } catch {
            additionFailed = true
            additionMessage = (error as? WatchlistError)?.localizedDescription ?? L10n.text("coin.validation_failed")
            return false
        }
    }

    var menuTitle: String {
        selectedWindow.rawValue + " · " + pinned.map { symbol in
            guard let quote = quotes[symbol] else { return "\(symbol) ···" }
            let stale = !live || quote.isStale(at: now)
            let arrow = stale ? "◌" : quote.changePercent >= 0 ? "↗" : "↘"
            let highlighted = latestAlert.map {
                alertsEnabled && $0.symbol == symbol && now.timeIntervalSince($0.date) < 30
            } ?? false
            return "\(symbol) \(quote.formattedPrice) \(arrow)\(highlighted ? " ⚡" : "")"
        }.joined(separator: "   ")
    }

    func start() {
        guard connectionTask == nil else { return }
        connectionTask = Task { [weak self] in await self?.connectLoop() }
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                self.now = Date()
                if self.live, let receivedAt = self.receivedAt,
                   Date().timeIntervalSince(receivedAt) > 20 {
                    self.live = false
                    self.status = L10n.text("status.stale")
                    self.stream?.cancel(with: .goingAway, reason: nil)
                }
            }
        }
    }

    func stop() {
        connectionTask?.cancel()
        clockTask?.cancel()
        stream?.cancel(with: .goingAway, reason: nil)
        connectionTask = nil
        clockTask = nil
        stream = nil
        receivedAt = nil
        volatilityMonitor.resetHistory()
        live = false
    }

    func reconnect() {
        stop()
        status = L10n.text("status.reconnecting")
        start()
    }

    private func connectLoop() async {
        var failures = 0
        while !Task.isCancelled {
            volatilityMonitor.resetHistory()
            let window = selectedWindow
            let socket = session.webSocketTask(with: window.streamURL(pairs: coins.map(\.pair)))
            stream = socket
            socket.resume()
            // The deadline cancels even a connection that never delivers its first message.
            let watchdog = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard !Task.isCancelled, let self, self.stream === socket else { return }
                if self.receivedAt == nil || Date().timeIntervalSince(self.receivedAt!) > 20 {
                    socket.cancel(with: .goingAway, reason: nil)
                }
            }
            let snapshot = Task { [weak self] in await self?.loadSnapshot(window: window) }
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    try Task.checkCancellation()
                    let data: Data
                    switch message {
                    case .string(let text): data = Data(text.utf8)
                    case .data(let bytes): data = bytes
                    @unknown default: continue
                    }
                    if Quote.isServerShutdown(data) { throw URLError(.networkConnectionLost) }
                    guard window == selectedWindow,
                          let quote = try Quote.decodeStream(data, window: window),
                          watchlist.symbols.contains(quote.symbol) else { continue }
                    if quotes[quote.symbol].map({ $0.date <= quote.date }) ?? true {
                        quotes[quote.symbol] = quote
                        recordMovement(quote)
                    }
                    receivedAt = Date()
                    now = Date()
                    live = true
                    status = L10n.text("status.live")
                    failures = 0
                }
            } catch {
                if !Task.isCancelled {
                    live = false
                    failures += 1
                    let delay = min(pow(2, Double(min(failures, 5))), 30)
                    status = L10n.text("status.retry", Int(delay))
                    socket.cancel(with: .goingAway, reason: nil)
                    watchdog.cancel()
                    snapshot.cancel()
                    try? await Task.sleep(nanoseconds: UInt64((delay + Double.random(in: 0...0.5)) * 1_000_000_000))
                }
            }
            watchdog.cancel()
            snapshot.cancel()
            socket.cancel(with: .goingAway, reason: nil)
        }
    }

    private func loadSnapshot(window: PriceWindow) async {
        do {
            let url = try window.snapshotURL(pairs: coins.map(\.pair))
            let (data, response) = try await session.data(from: url)
            try Task.checkCancellation()
            guard window == selectedWindow, (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            for quote in try Quote.decodeSnapshot(data, window: window) {
                if quotes[quote.symbol].map({ $0.date <= quote.date }) ?? true {
                    quotes[quote.symbol] = quote
                }
            }
        } catch {
            // The stream owns connection status; a snapshot failure must not hide live data.
        }
    }
}
