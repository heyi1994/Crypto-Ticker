import AppKit
import Combine
import CryptoTickerCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let store = MarketStore()
    private let notifier = AlertNotifier()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private lazy var hostingController = NSHostingController(rootView: TickerView(store: store, notifier: notifier))
    private var updates: AnyCancellable?
    private var alerts: AnyCancellable?
    private var statusUpdatePending = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            button.cell?.usesSingleLineMode = true
            button.cell?.lineBreakMode = .byTruncatingTail
            button.target = self
            button.action = #selector(togglePopover)
        }
        popover.behavior = .transient
        popover.delegate = self
        // Measure before showing: the hosting view otherwise starts at its default size,
        // and resizing an already-positioned popover can push its top above the screen.
        hostingController.sizingOptions = []
        popover.animates = false
        sizePopover()
        popover.contentViewController = hostingController
        updates = store.objectWillChange.sink { [weak self] _ in
            guard let self, !self.statusUpdatePending else { return }
            self.statusUpdatePending = true
            // ObservableObject publishes before mutation; read the value on the next run loop,
            // folding changes that arrive before then into one refresh.
            DispatchQueue.main.async {
                self.statusUpdatePending = false
                self.updateStatus()
            }
        }
        alerts = store.alertEvents.sink { [weak self] alert in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.notifier.deliver(alert, ifEnabled: { [weak self] in self?.store.alertsEnabled == true })
            }
        }
        Task { await notifier.refreshPermission() }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willSleep),
            name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification, object: nil)
        updateStatus()
        store.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    private func updateStatus() {
        guard let button = statusItem.button else { return }
        let title = store.menuTitle
        var toolTip = L10n.text("menu.tooltip", store.selectedWindow.rawValue, store.status)
        if store.alertsEnabled, let alert = store.latestAlert {
            toolTip.append("\n" + L10n.text("menu.latest_alert", alert.summary))
        }
        let label = title + " USDT · " + store.status
        // Most quotes are for coins outside the menu bar; skip redundant redraws.
        if button.title != title { button.title = title }
        if button.toolTip != toolTip { button.toolTip = toolTip }
        if button.accessibilityLabel() != label { button.setAccessibilityLabel(label) }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            sizePopover(for: button.window?.screen)
            NSApp.activate(ignoringOtherApps: true)
            // The popover follows its status button. Keep that anchor's width
            // unchanged while open, including when a new window briefly shows
            // shorter loading text. Restore automatic sizing after dismissal.
            statusItem.length = button.frame.width
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            if !popover.isShown { statusItem.length = NSStatusItem.variableLength }
            if let window = popover.contentViewController?.view.window {
                window.initialFirstResponder = nil
                window.makeKey()
                // AppKit otherwise focuses the first editable control on open,
                // or restores the text field's previous editing session.
                window.makeFirstResponder(nil)
            }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        statusItem.length = NSStatusItem.variableLength
    }

    private func sizePopover(for screen: NSScreen? = nil) {
        // Keep the header and controls visible while an arbitrary watchlist scrolls.
        let availableHeight = (screen ?? NSScreen.main)?.visibleFrame.height ?? 800
        hostingController.rootView = TickerView(store: store, notifier: notifier,
                                               listHeight: min(354, max(80, availableHeight - 450)))
        let size = hostingController.sizeThatFits(in: NSSize(width: 390, height: 10_000))
        let contentSize = NSSize(width: 390, height: ceil(size.height))
        hostingController.view.setFrameSize(contentSize)
        hostingController.preferredContentSize = contentSize
        popover.contentSize = contentSize
    }

    @objc private func willSleep() { store.stop() }
    @objc private func didWake() { store.reconnect() }
}
