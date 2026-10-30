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
    private var snapshotTask: Task<Void, Never>?
    // The last frame or pong on the current socket.
    private var lastActivity: Date?
    private var pinging = false
    // Local receive times. Exchange timestamps come from a different clock.
    private var quoteReceivedAt: [String: Date] = [:]

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
        quoteReceivedAt.removeAll()
        reconnect()
    }

    func removeCoin(_ symbol: String) {
        guard coins.count > 1 else { return }
        watchlist.remove(symbol)
        quotes.removeValue(forKey: symbol)
        quoteReceivedAt.removeValue(forKey: symbol)
        volatilityMonitor.resetHistory(for: symbol)
        reconnect()
    }

    func isStale(_ symbol: String, at date: Date) -> Bool {
        quoteReceivedAt[symbol].map { date.timeIntervalSince($0) > 20 } ?? true
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
            let stale = !live || isStale(symbol, at: now)
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
                self.checkConnection()
            }
        }
    }

    func stop() {
        connectionTask?.cancel()
        clockTask?.cancel()
        snapshotTask?.cancel()
        stream?.cancel(with: .goingAway, reason: nil)
        connectionTask = nil
        clockTask = nil
        snapshotTask = nil
        stream = nil
        lastActivity = nil
        live = false
        status = L10n.text("status.paused")
    }

    func reconnect() {
        stop()
        status = L10n.text("status.reconnecting")
        start()
    }

    /// Applies one stream frame. Only a server shutdown ends the connection;
    /// a frame that fails to decode is skipped.
    func handleFrame(_ data: Data, window: PriceWindow, receivedAt date: Date = Date()) throws {
        if Quote.isServerShutdown(data) { throw URLError(.networkConnectionLost) }
        markAlive(at: date)
        guard window == selectedWindow,
              let quote = try? Quote.decodeStream(data, window: window),
              apply(quote, receivedAt: date) else { return }
        recordMovement(quote, receivedAt: date)
    }

    @discardableResult
    private func apply(_ quote: Quote, receivedAt date: Date) -> Bool {
        guard watchlist.symbols.contains(quote.symbol),
              quotes[quote.symbol].map({ $0.date <= quote.date }) ?? true else { return false }
        quotes[quote.symbol] = quote
        quoteReceivedAt[quote.symbol] = date
        return true
    }

    private func markAlive(at date: Date = Date()) {
        lastActivity = date
        live = true
        status = L10n.text("status.live")
    }

    // A quiet watchlist can go 20 s without a ticker, so silence alone is not a disconnect.
    // Ping instead, and drop the socket only when no pong comes back.
    private func checkConnection() {
        guard let socket = stream, !pinging, let lastActivity,
              Date().timeIntervalSince(lastActivity) > 20 else { return }
        pinging = true
        let deadline = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled, let self, self.stream === socket else { return }
            self.live = false
            self.status = L10n.text("status.stale")
            socket.cancel(with: .goingAway, reason: nil)
        }
        socket.sendPing { [weak self] error in
            let alive = error == nil
            Task { @MainActor [weak self] in
                deadline.cancel()
                guard let self, self.stream === socket else { return }
                self.pinging = false
                if alive { self.markAlive() } else { socket.cancel(with: .goingAway, reason: nil) }
            }
        }
    }

    private func connectLoop() async {
        var failures = 0
        while !Task.isCancelled {
            let window = selectedWindow
            let socket = session.webSocketTask(with: window.streamURL(pairs: coins.map(\.pair)))
            stream = socket
            // Starting the clock here also covers a socket that never delivers its first frame.
            lastActivity = Date()
            pinging = false
            socket.resume()
            let snapshot = Task<Void, Never> { [weak self] in await self?.loadSnapshot(window: window) }
            snapshotTask = snapshot
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
                    try handleFrame(data, window: window)
                    failures = 0
                }
            } catch {}
            snapshot.cancel()
            socket.cancel(with: .goingAway, reason: nil)
            if stream === socket { stream = nil }
            guard !Task.isCancelled else { return }
            live = false
            failures += 1
            let delay = min(pow(2, Double(min(failures, 5))), 30)
            status = L10n.text("status.retry", Int(delay))
            try? await Task.sleep(nanoseconds: UInt64((delay + Double.random(in: 0...0.5)) * 1_000_000_000))
        }
    }

    private func loadSnapshot(window: PriceWindow) async {
        let snapshot = await fetchSnapshot(window: window, pairs: coins.map(\.pair))
        guard !Task.isCancelled, window == selectedWindow else { return }
        let date = Date()
        for quote in snapshot { apply(quote, receivedAt: date) }
    }

    // The stream owns connection status; a snapshot failure must not hide live data.
    private func fetchSnapshot(window: PriceWindow, pairs: [String]) async -> [Quote] {
        do {
            let (data, response) = try await session.data(from: window.snapshotURL(pairs: pairs))
            let code = (response as? HTTPURLResponse)?.statusCode
            if code == 200 { return try Quote.decodeSnapshot(data, window: window) }
            // One unknown pair makes Binance reject the whole batch, so retry pair by pair.
            guard code == 400, pairs.count > 1 else { return [] }
        } catch {
            return []
        }
        return await withTaskGroup(of: [Quote].self) { group in
            for pair in pairs {
                group.addTask { await self.fetchSnapshot(window: window, pairs: [pair]) }
            }
            return await group.reduce(into: []) { $0 += $1 }
        }
    }
}
