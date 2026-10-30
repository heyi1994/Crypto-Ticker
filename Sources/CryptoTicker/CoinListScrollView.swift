import AppKit
import SwiftUI

/// A native scroll surface keeps the document's full height and receives wheel
/// events directly, even while SwiftUI updates the live quote rows.
struct CoinListScrollView<Content: View>: NSViewRepresentable {
    /// Change this whenever rows are added, removed, or resized. Other updates skip measuring.
    let layoutKey: AnyHashable
    let content: Content

    init(layoutKey: AnyHashable, @ViewBuilder content: () -> Content) {
        self.layoutKey = layoutKey
        self.content = content()
    }

    func makeNSView(context: Context) -> CoinListScrollSurface {
        CoinListScrollSurface(content: AnyView(content), layoutKey: layoutKey)
    }

    func updateNSView(_ view: CoinListScrollSurface, context: Context) {
        view.update(content: AnyView(content), layoutKey: layoutKey)
    }
}

final class CoinListScrollSurface: NSScrollView {
    private let hostingController: NSHostingController<AnyView>
    private var content: AnyView
    private var layoutKey: AnyHashable
    // The visible size and layout key of the last measurement.
    private var measured: (visible: NSSize, key: AnyHashable)?
    private var measuring = false

    init(content: AnyView, layoutKey: AnyHashable) {
        self.content = content
        self.layoutKey = layoutKey
        hostingController = NSHostingController(rootView: content)
        super.init(frame: NSRect(x: 0, y: 0, width: 390, height: 354))
        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        scrollerStyle = .overlay
        verticalScroller?.controlSize = .small
        horizontalScrollElasticity = .none
        verticalScrollElasticity = .none
        hostingController.sizingOptions = []
        documentView = hostingController.view
        updateDocument(contentChanged: true)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(content: AnyView, layoutKey: AnyHashable) {
        self.content = content
        self.layoutKey = layoutKey
        updateDocument(contentChanged: true)
    }

    override func layout() {
        super.layout()
        updateDocument(contentChanged: false)
    }

    private func updateDocument(contentChanged: Bool) {
        guard !measuring else { return }
        let visible = contentView.bounds.size
        let width = max(1, visible.width)
        let needsMeasure = measured.map { $0.visible != visible || $0.key != layoutKey } ?? true
        guard contentChanged || needsMeasure else { return }
        measuring = true
        defer { measuring = false }
        hostingController.rootView = AnyView(content.frame(width: width).fixedSize(horizontal: false, vertical: true))
        // A price update only re-renders rows; measuring the whole list is for size changes.
        guard needsMeasure else { return }
        measured = (visible, layoutKey)
        let origin = contentView.bounds.origin
        let fitting = hostingController.sizeThatFits(in: NSSize(width: width, height: 100_000))
        let height = max(visible.height, ceil(fitting.height))
        let size = NSSize(width: width, height: height)
        if hostingController.view.frame.size != size { hostingController.view.setFrameSize(size) }

        // Preserve the user's position through price updates and additions. Only
        // clamp when removing rows makes the old offset fall beyond the document.
        let y = min(max(0, origin.y), max(0, height - contentView.bounds.height))
        if origin.x != 0 || origin.y != y {
            contentView.scroll(to: NSPoint(x: 0, y: y))
        }
        reflectScrolledClipView(contentView)
    }
}
