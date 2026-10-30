import AppKit
import CryptoTickerCore
import SwiftUI

struct TickerView: View {
    @ObservedObject var store: MarketStore
    @ObservedObject var notifier: AlertNotifier
    var listHeight: CGFloat = 354
    @State private var newSymbol = ""
    @State private var isManaging = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "chart.xyaxis.line")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 40, height: 40)
                    .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Crypto Ticker").font(.system(size: 17, weight: .semibold))
                    Text(L10n.text("app.subtitle")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Text("USDT").font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(.primary.opacity(0.06), in: Capsule())
            }.padding(20)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    TextField(L10n.text("coin.placeholder"), text: $newSymbol)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addCoin)
                        .disabled(store.isAdding)
                        .accessibilityLabel(L10n.text("coin.input_label"))
                    Button(action: addCoin) {
                        Text(L10n.text(store.isAdding ? "coin.checking" : "coin.add")).frame(width: 66)
                    }
                    .disabled(store.isAdding || newSymbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text(store.additionMessage)
                    .font(.system(size: 10))
                    .foregroundStyle(store.additionFailed ? Color.red : Color.secondary)
                    .lineLimit(2)
                    .frame(height: 27, alignment: .topLeading)
            }.padding(.horizontal, 20).padding(.bottom, 8)

            HStack {
                Text(L10n.text("coin.column")).font(.system(size: 10, weight: .medium))
                Spacer()
                WindowPicker(store: store, selection: store.selectedWindow)
                Text(L10n.text(isManaging ? "coin.remove" : "coin.pin")).font(.system(size: 10, weight: .medium)).frame(width: 42)
            }.foregroundStyle(.secondary).padding(.horizontal, 20).padding(.bottom, 7)

            CoinListScrollView(layoutKey: store.watchlist.symbols) {
                VStack(spacing: 0) {
                    ForEach(store.coins) { coin in
                        coinRow(coin)
                        if coin.symbol != store.watchlist.symbols.last {
                            Divider().padding(.horizontal, 20)
                        }
                    }
                }
            }
            .frame(height: listHeight)

            HStack(spacing: 5) {
                Image(systemName: "pin.fill").font(.system(size: 9))
                Text(L10n.text("coin.pin_hint"))
                    .font(.system(size: 10))
                Spacer()
                Button(L10n.text(isManaging ? "coin.done" : "coin.manage")) { isManaging.toggle() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
            }.foregroundStyle(.secondary).padding(.horizontal, 20).padding(.vertical, 13)

            Divider()
            alertSettings
            Divider()
            HStack(spacing: 6) {
                Circle().fill(store.live ? Color.green : Color.orange).frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.status).font(.system(size: 10, weight: .medium))
                    Text(L10n.text("market.source", store.selectedWindow.rawValue)).font(.system(size: 9)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { store.reconnect() } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 26, height: 26)
                }.buttonStyle(.borderless).help(L10n.text("market.reconnect"))
                Button { NSApplication.shared.terminate(nil) } label: {
                    Image(systemName: "power").frame(width: 26, height: 26)
                }.buttonStyle(.borderless).help(L10n.text("market.quit"))
            }.padding(.horizontal, 20).padding(.vertical, 14)
                .background(.primary.opacity(0.025))
        }
        .frame(width: 390)
    }

    private var alertSettings: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle(L10n.text("alerts.toggle"), isOn: Binding(get: { store.alertsEnabled }, set: { enabled in
                    store.setAlertsEnabled(enabled)
                    if enabled { Task { await notifier.requestPermission() } }
                }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.system(size: 11, weight: .medium))
                .disabled(notifier.requestingPermission)
                Spacer()
                Button(L10n.text("alerts.test")) {
                    Task { await notifier.sendTest(ifEnabled: { store.alertsEnabled }) }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 10))
                .disabled(!store.alertsEnabled || notifier.requestingPermission)
            }
            HStack(spacing: 5) {
                Text(L10n.text("alerts.over"))
                Picker(L10n.text("alerts.duration"), selection: Binding(get: { store.alertRule.minutes }, set: {
                    store.setAlertRule(minutes: $0, thresholdPercent: store.alertRule.thresholdPercent)
                })) {
                    ForEach(VolatilityRule.minuteOptions, id: \.self) { minutes in
                        Text(L10n.text("alerts.minutes", minutes)).tag(minutes)
                    }
                }.labelsHidden().frame(width: 78)
                Text(L10n.text("alerts.change"))
                Picker(L10n.text("alerts.threshold"), selection: Binding(get: { store.alertRule.thresholdPercent }, set: {
                    store.setAlertRule(minutes: store.alertRule.minutes, thresholdPercent: $0)
                })) {
                    ForEach(VolatilityRule.thresholdOptions, id: \.self) { threshold in
                        Text(threshold.formatted() + "%").tag(threshold)
                    }
                }.labelsHidden().frame(width: 75)
                Spacer(minLength: 0)
            }.font(.system(size: 10)).controlSize(.small)
            Text(L10n.text("alerts.scope"))
                .font(.system(size: 9)).foregroundStyle(.secondary)
            Text(store.alertsEnabled ? notifier.hint : L10n.text("alerts.disabled"))
                .font(.system(size: 9)).foregroundStyle(.secondary)
                .lineLimit(1).help(notifier.hint)
            Text(store.latestAlert.map { $0.summary + " · " + $0.date.formatted(date: .omitted, time: .shortened) }
                 ?? L10n.text("alerts.empty"))
                .font(.system(size: 10))
                .foregroundStyle(store.latestAlert == nil ? Color.secondary : Color.orange)
                .lineLimit(1)
        }.padding(.horizontal, 20).frame(height: 140)
    }

    private func coinRow(_ coin: Coin) -> some View {
        let quote = store.quotes[coin.symbol]
        let isStale = store.isStale(coin.symbol, at: store.now)
        let isPinned = store.pinned.contains(coin.symbol)
        let disabled = isPinned ? store.pinned.count == 1 : store.pinned.count >= 3
        let tint: Color = coin.symbol == "BTC" ? .orange : coin.symbol == "ETH" ? .indigo : .secondary
        return HStack(spacing: 11) {
            Text(coin.mark).font(.system(size: 21, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.1), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(coin.symbol).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(coin.name).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }.frame(width: 65, alignment: .leading).help(coin.symbol)
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 4) {
                Text(quote?.formattedPrice ?? "—")
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isStale ? .secondary : .primary)
                if let quote {
                    Text(isStale ? L10n.text("market.stale") : L10n.text("market.updated", quote.date.formatted(date: .omitted, time: .standard)))
                        .font(.system(size: 8)).foregroundStyle(.tertiary)
                } else {
                    Text(L10n.text("market.waiting")).font(.system(size: 8)).foregroundStyle(.tertiary)
                }
            }
            Text(quote?.formattedChange ?? "—")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(isStale ? Color.secondary : (quote?.changePercent ?? 0) >= 0 ? Color.green : Color.red)
                .frame(width: 66, height: 25)
                .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
            if isManaging {
                Button { store.removeCoin(coin.symbol) } label: {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(Color.red)
                        .frame(width: 26, height: 30)
                }
                .buttonStyle(.borderless)
                .disabled(store.coins.count == 1)
                .help(L10n.text("coin.remove_help", coin.symbol))
                .accessibilityLabel(L10n.text("coin.remove_label", coin.symbol))
            } else {
                Button { store.togglePin(coin.symbol) } label: {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                        .foregroundStyle(isPinned ? Color.orange : Color.secondary)
                        .frame(width: 26, height: 30)
                }
                .buttonStyle(.borderless)
                .disabled(disabled)
                .help(L10n.text(isPinned ? "coin.unpin_help" : "coin.pin_help"))
                .accessibilityLabel(L10n.text(isPinned ? "coin.unpin_label" : "coin.pin_label", coin.symbol))
            }
        }.padding(.horizontal, 20).padding(.vertical, 12)
    }

    private func addCoin() {
        guard !store.isAdding else { return }
        let input = newSymbol
        Task {
            if await store.addCoin(input) { newSymbol = "" }
        }
    }
}

/// On macOS 26, each re-evaluation of a segmented Picker leaks SwiftUI observation
/// records, so the panel grew slower the longer the app ran. As its own view with
/// unchanged inputs, the picker is skipped when quotes update the panel.
private struct WindowPicker: View {
    let store: MarketStore
    let selection: PriceWindow

    var body: some View {
        Picker(L10n.text("window.label"), selection: Binding(get: { selection }, set: { store.selectWindow($0) })) {
            ForEach(PriceWindow.allCases) { window in
                Text(window.rawValue).tag(window)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(width: 144)
        .help(L10n.text("window.help", selection.rawValue))
    }
}
