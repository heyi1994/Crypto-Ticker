import Foundation

public struct VolatilityRule: Equatable, Sendable {
    public static let minuteOptions = [1, 5, 15]
    public static let thresholdOptions: [Double] = [0.5, 1, 2, 3, 5, 10]
    public let minutes: Int
    public let thresholdPercent: Double

    public init(minutes: Int = 1, thresholdPercent: Double = 1) {
        self.minutes = Self.minuteOptions.contains(minutes) ? minutes : 1
        self.thresholdPercent = Self.thresholdOptions.contains(thresholdPercent) ? thresholdPercent : 1
    }
}

public struct MovementAlert: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let symbol: String
    public let price: Double
    public let changePercent: Double
    public let minutes: Int
    public let date: Date

    public var title: String { L10n.text(changePercent >= 0 ? "alert.rise" : "alert.drop", symbol) }
    public var summary: String { L10n.text("alert.summary", symbol, minutes, String(format: "%+.2f%%", changePercent)) }
    public var body: String { L10n.text("alert.body", summary, PriceFormat.price(price)) }
}

public struct VolatilityMonitor {
    public static let cooldown: TimeInterval = 300
    private struct Sample {
        let price: Double
        let date: Date
    }
    private var samples: [String: [Sample]] = [:]
    private var lastAlerts: [String: Date] = [:]

    public init() {}

    public mutating func resetHistory(for symbol: String? = nil) {
        if let symbol { samples.removeValue(forKey: symbol) }
        else { samples.removeAll() }
    }

    public mutating func record(symbol: String, price: Double, at date: Date,
                                receivedAt now: Date, rule: VolatilityRule) -> MovementAlert? {
        // `date` is exchange time and `now` is local time. The clocks can disagree, so never compare them.
        guard price.isFinite, price > 0 else { return nil }
        var history = samples[symbol] ?? []
        if let last = history.last {
            guard date > last.date else { return nil }
            // A feed interruption must not look like a fresh price jump.
            if date.timeIntervalSince(last.date) > 20 { history.removeAll() }
        }
        let cutoff = date.addingTimeInterval(-Double(rule.minutes) * 60)
        history.removeAll { $0.date < cutoff }
        let baseline = history.first
        history.append(Sample(price: price, date: date))
        samples[symbol] = history
        guard let baseline else { return nil }
        let change = (price / baseline.price - 1) * 100
        guard change.isFinite, abs(change) + 0.00000001 >= rule.thresholdPercent else { return nil }
        if let last = lastAlerts[symbol], now.timeIntervalSince(last) < Self.cooldown { return nil }
        lastAlerts[symbol] = now
        // Rebase on the alerted price so the same move is not reported again after the cooldown.
        samples[symbol] = [Sample(price: price, date: date)]
        return MovementAlert(symbol: symbol, price: price, changePercent: change,
                             minutes: rule.minutes, date: now)
    }
}
