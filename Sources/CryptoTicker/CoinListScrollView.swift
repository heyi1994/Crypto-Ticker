import AppKit
import SwiftUI

/// A native scroll surface keeps the document's full height and receives wheel
/// events directly, even while SwiftUI updates the live quote rows.
struct CoinListScrollView<Content: View>: NSViewRepresentable {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeNSView(context: Context) -> CoinListScrollSurface {
        CoinListScrollSurface(content: AnyView(content))
    }

    func updateNSView(_ view: CoinListScrollSurface, context: Context) {
        view.update(content: AnyView(content))
    }
}

final class CoinListScrollSurface: NSScrollView {
    private let hostingController: NSHostingController<AnyView>
    private var content: AnyView
    private var measuring = false

    init(content: AnyView) {
        self.content = content
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
        updateDocument()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(content: AnyView) {
        self.content = content
        updateDocument()
    }

    override func layout() {
        super.layout()
        updateDocument()
    }

    private func updateDocument() {
        guard !measuring else { return }
        measuring = true
        defer { measuring = false }
        let origin = contentView.bounds.origin
        let width = max(1, contentView.bounds.width)
        hostingController.rootView = AnyView(content.frame(width: width).fixedSize(horizontal: false, vertical: true))
        let measured = hostingController.sizeThatFits(in: NSSize(width: width, height: 100_000))
        let height = max(contentView.bounds.height, ceil(measured.height))
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
