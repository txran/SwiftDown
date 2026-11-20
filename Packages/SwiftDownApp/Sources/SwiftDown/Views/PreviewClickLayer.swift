import AppKit
import SwiftUI

/// 预览块的「点击进入编辑」层。
///
/// **为什么不用 SwiftUI 的 `SpatialTapGesture`**：
/// 一是 `.textSelection(.enabled)` 会在正文上方盖一个选择层（`SelectionOverlay`），
/// 鼠标事件被它先吃掉，块上的手势收不到；二是这个手势在自检环境里没法用合成事件验证
/// （`window.sendEvent` 驱动不了 SwiftUI 的手势识别，同一份代码在小程序里能响应、
/// 在应用里不响应，验不出结论）。
///
/// 换成一层透明的 `NSView`：`mouseDown` 是 AppKit 本身的行为，事件肯定到得了；
/// 自检里直接对这个视图调 `mouseDown(with:)` 就能走完整的真实入口，不需要模拟器。
/// 代价是这层会盖住正文，所以文字选中改到「点进编辑态」里做（那里是真文本视图）。
final class PreviewClickLayerView: NSView {

    var onTap: ((CGPoint) -> Void)?
    var onHoverChange: ((Bool) -> Void)?
    var isInteractive = true

    private var trackingArea: NSTrackingArea?

    /// 与 SwiftUI 同为「左上原点」，省掉一层 y 翻转换算
    override var isFlipped: Bool { true }

    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // 不可交互时（比如只读文档）把事件让出去，别防碍选中复制
        guard isInteractive else { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        onTap?(point)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChange?(false)
    }

    /// 竖向滚轮要交还给外层页面：这层盖在正文上，
    /// 不转发的话「鼠标停在文字上就滚不动」（这个坑在代码块上踩过一次）。
    override func scrollWheel(with event: NSEvent) {
        var current = superview
        while let view = current {
            if let scrollView = view as? NSScrollView {
                scrollView.scrollWheel(with: event)
                return
            }
            current = view.superview
        }
        nextResponder?.scrollWheel(with: event)
    }
}

struct PreviewClickLayer: NSViewRepresentable {

    let isInteractive: Bool
    let onTap: (CGPoint) -> Void
    let onHover: (Bool) -> Void

    func makeNSView(context: Context) -> PreviewClickLayerView {
        let view = PreviewClickLayerView()
        view.onTap = onTap
        view.onHoverChange = onHover
        view.isInteractive = isInteractive
        return view
    }

    func updateNSView(_ view: PreviewClickLayerView, context: Context) {
        view.onTap = onTap
        view.onHoverChange = onHover
        view.isInteractive = isInteractive
    }
}
