import AppKit
import SwiftUI

/// 就地编辑用的文本视图：Esc 取消、⌘↩ 提交。
///
/// 刻意关掉所有「智能」替换——这里是 Markdown 源码，
/// 引号被换成弯引号、`--` 被换成破折号，都会直接写坏正文。
final class LivePreviewTextView: NSTextView {

    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?
    /// 刚挂到窗口上时自动取焦点（点进来就能直接打字，不用再点一下）
    var pendingCaret: Int?
    private var didAutoFocus = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !didAutoFocus else { return }
        didAutoFocus = true
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
            let length = (self.string as NSString).length
            self.setSelectedRange(NSRange(location: min(max(0, self.pendingCaret ?? 0), length),
                                          length: 0))
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?(); return }                 // esc
        if event.keyCode == 36 || event.keyCode == 76 {               // return / enter
            if event.modifierFlags.contains(.command) { onSubmit?(); return }
        }
        super.keyDown(with: event)
    }
}

/// 草稿盒子：**故意不做成 `@Published`**。
///
/// 如果每次按键都把草稿写进 SwiftUI 状态，整页 `LazyVStack` 会跟着重算一遍，
/// 长文档里打字就会一顿一顿的。这里只用一个普通引用类型，
/// 编辑器往里写、提交时读，完全绕开视图刷新。
final class PreviewDraftBox {
    var text = ""
}

/// 预览块的「就地编辑器」（`NSViewRepresentable`）。
///
/// 编辑框里的**字符串就是这一块的 Markdown 原文**，只是把标记画成透明、
/// 把内容画成渲染后的样子。写回时直接整段替换，不存在「渲染位置 → 源位置」的映射，
/// 也就没有把用户格式写坏的可能（ADR-22）。
struct LivePreviewEditor: NSViewRepresentable {

    let text: String
    let appearance: PreviewLiveStyler.Appearance
    /// 进入时希望光标落在这里（UTF-16 下标）
    let caretIndex: Int
    let onTextChange: (String) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void
    let onEndEditing: () -> Void
    let onHeightChange: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> LivePreviewTextView {
        let textView = LivePreviewTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.isRichText = true          // 属性由我们统一刷，避免 NSTextView 做任何规范化
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.usesFindBar = false
        textView.importsGraphics = false
        textView.smartInsertDeleteEnabled = false

        textView.onSubmit = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onSubmit()
        }
        textView.onCancel = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onCancel()
        }
        textView.pendingCaret = caretIndex

        context.coordinator.mount(textView)
        return textView
    }

    func updateNSView(_ textView: LivePreviewTextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.sync(textView)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {

        var parent: LivePreviewEditor
        private weak var textView: LivePreviewTextView?
        private var appliedAppearance: PreviewLiveStyler.Appearance?
        private var appliedCaretLine = Int.min
        private var lastReportedHeight: CGFloat = -1
        private var mounted = false
        private var cachedText = ""
        private var cachedMapValue: PreviewInlineMap?
        /// 自己改属性时不要触发 `textDidChange` 的回写
        private var styling = false

        init(_ parent: LivePreviewEditor) {
            self.parent = parent
        }

        func mount(_ view: LivePreviewTextView) {
            textView = view
            view.string = parent.text
            let caret = clamp(parent.caretIndex)
            view.setSelectedRange(NSRange(location: caret, length: 0))
            restyle(caretLocation: caret)
            mounted = true
            reportHeight()
        }

        func sync(_ view: LivePreviewTextView) {
            if view.string != parent.text {
                // 外部改了内容（例如草稿从视图缓存里恢复）
                let selection = view.selectedRange()
                view.string = parent.text
                let length = (view.string as NSString).length
                view.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
                restyle(caretLocation: view.selectedRange().location)
            } else if appliedAppearance != parent.appearance {
                restyle(caretLocation: view.selectedRange().location)
            }
            reportHeight()
        }

        private func clamp(_ index: Int) -> Int {
            min(max(0, index), (parent.text as NSString).length)
        }

        // MARK: 刷新样式

        private func restyle(caretLocation: Int) {
            guard let textView, let storage = textView.textStorage else { return }
            if textView.hasMarkedText() { return }   // 输入法组合中，别动属性

            let map = cachedMap(for: textView.string)
            let caretLine = map.lineIndex(at: min(max(0, caretLocation), max(0, storage.length - 1)))
            let attributed = PreviewLiveStyler.attributed(map,
                                                          appearance: parent.appearance,
                                                          caretLine: caretLine)

            styling = true
            let selection = textView.selectedRange()
            // 属性刷新不能进撤销栈：否则 ⌘Z 会把颜色/字号撤回来，正文却还在
            let undo = textView.undoManager
            let undoWasEnabled = undo?.isUndoRegistrationEnabled ?? false
            undo?.disableUndoRegistration()
            storage.beginEditing()
            storage.setAttributes([:], range: NSRange(location: 0, length: storage.length))
            if attributed.length > 0 {
                attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length),
                                               options: []) { attributes, range, _ in
                    storage.addAttributes(attributes, range: range)
                }
            }
            storage.endEditing()
            if undoWasEnabled { undo?.enableUndoRegistration() }
            if selection.location <= storage.length {
                textView.setSelectedRange(selection)
            }
            textView.typingAttributes = [
                .font: PreviewLiveStyler.baseFont(parent.appearance),
                .foregroundColor: PreviewLiveStyler.baseColor(parent.appearance)
            ]
            styling = false

            appliedAppearance = parent.appearance
            appliedCaretLine = caretLine
        }

        /// 每次按键都要重算，但一次改动里会被问好几遍，按字符串缓存一份
        private func cachedMap(for text: String) -> PreviewInlineMap {
            if text == cachedText, let cachedMapValue { return cachedMapValue }
            let map = PreviewInlineMap.build(text)
            cachedText = text
            cachedMapValue = map
            return map
        }

        private func reportHeight() {
            guard let textView,
                  let container = textView.textContainer,
                  let layoutManager = textView.layoutManager else { return }
            layoutManager.ensureLayout(for: container)
            let height = ceil(layoutManager.usedRect(for: container).height) + 1
            // 必须去重：这里每帧都会被调，不去重就会「设状态 → 重算 → 设状态」无限循环
            guard abs(height - lastReportedHeight) > 0.5 else { return }
            lastReportedHeight = height
            DispatchQueue.main.async { [weak self] in
                self?.parent.onHeightChange(height)
            }
        }

        // MARK: NSTextViewDelegate

        func textDidChange(_ notification: Notification) {
            guard !styling, let textView, textView.hasMarkedText() == false else { return }
            parent.onTextChange(textView.string)
            restyle(caretLocation: textView.selectedRange().location)
            reportHeight()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView, mounted else { return }
            let caret = textView.selectedRange().location
            let line = cachedMap(for: textView.string).lineIndex(at: max(0, caret))
            // 只有换了行才需要重画（光标所在行的标记要显形）
            if line != appliedCaretLine {
                restyle(caretLocation: caret)
            }
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.onEndEditing()
        }
    }
}
