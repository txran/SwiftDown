import AppKit
import SwiftDownPipeline
import SwiftUI

extension View {
    /// 两种 `TextSelectability` 是不同类型，三元表达式推不出来，只能分支写
    @ViewBuilder
    func previewTextSelection(enabled: Bool) -> some View {
        if enabled {
            textSelection(.enabled)
        } else {
            textSelection(.disabled)
        }
    }
}

/// 标题字号（预览渲染与就地编辑共用一套，否则点进编辑会「跳号」）
enum PreviewTypography {
    static func headingSize(_ level: Int, bodySize: CGFloat) -> CGFloat {
        switch level {
        case 1: return bodySize + 12
        case 2: return bodySize + 8
        case 3: return bodySize + 4
        case 4: return bodySize + 1
        default: return bodySize
        }
    }
}

/// 渲染预览（FR-02 / FR-03）。
/// 按块渲染 + LazyVStack：只实例化视口内的块，这是 10MB 文档能滚动的关键（NFR-02）。
///
/// **阅读模式就地编辑**：点哪块、光标就落在哪，直接打字。
/// 编辑框里放的是这一块的 **Markdown 原文**，但标记（`**` / `` ` `` / `[..](..)` / `# `）
/// 全部画成透明，内容按渲染样式画——所以打字时看到的就是预览本身，不会「变成源码」。
/// 写回就是整段替换原文——不存在「渲染位置 ↔ 源位置」的映射，也就没有写坏格式的可能。
/// 改样式（加粗、改标题层级、插链接）仍然去源码模式，预览里只改字。
struct PreviewView: View {

    @ObservedObject var tab: DocumentTab
    let bodySize: CGFloat

    /// 悬停在哪一块（块的起始行）。只用来做很轻的底色提示 + I 形光标。
    /// 用 `LocalState` 而不是 `@State`：本机只有 CLT，SwiftUIMacros 插件缺失，`@State` 编不过。
    @StateObject private var hoveredLine = LocalState<Int?>(nil)
    /// 正在就地编辑的块；nil = 正常预览
    @StateObject private var editing = LocalState<EditSession?>(nil)
    /// 草稿放这里而不是编辑框内部：LazyVStack 会把滚出视口的行销毁重建，
    /// 状态若挂在行上，滚一下草稿就没了。
    /// 用不带 `@Published` 的盒子：按键不触发整页重算（见 PreviewDraftBox）。
    @StateObject private var draft = LocalState(PreviewDraftBox())
    /// 编辑框当前高度（由文本视图量出来后回填）
    @StateObject private var editorHeight = LocalState<CGFloat>(20)
    /// 内容区宽度：把点击位置换算成字符下标要用它
    @StateObject private var contentWidth = LocalState<CGFloat>(600)

    @Environment(\.undoManager) private var undoManager

    struct EditSession {
        let line: Int
        /// 要替换的源区间：普通块是整块，代码块是围栏之间
        let range: NSRange
        let appearance: PreviewLiveStyler.Appearance
        let source: String
        let caret: Int
    }

    var body: some View {
        Group {
            if tab.isReadOnly {
                hint("该文件超过 20MB，已进入只读源码模式", systemImage: "doc.text.magnifyingglass")
            } else if !tab.canPreview {
                hint("文档较大（>2MB），已暂停实时预览以保证编辑流畅", systemImage: "speedometer")
            } else if tab.parseFailed {
                hint("渲染失败，已降级为源码展示", systemImage: "exclamationmark.triangle")
            } else if tab.ast.blocks.isEmpty {
                hint("空白文档", systemImage: "doc")
            } else {
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .onDisappear { commitActive() }
    }

    private var content: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(tab.ast.blocks.enumerated()), id: \.offset) { index, block in
                        blockRow(block, next: nextBlock(after: index))
                            .id(Self.anchor(for: block))
                    }
                }
                .background(widthReader)
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
                // 可编辑时把系统选择层关掉：它会盖在正文上方把点击吃掉。
                // 只读文档反过来——没法就地编辑，就把选中复制能力还给它。
                .previewTextSelection(enabled: !tab.canEdit)
            }
            .onChange(of: tab.focusedLine) { newLine in
                align(proxy: proxy, toLine: newLine, animated: true)
            }
            .onChange(of: tab.scrollRequestToken) { _ in
                align(proxy: proxy, toLine: tab.scrollRequestLine, animated: true)
            }
            .onChange(of: tab.revision) { _ in
                tab.lastAlignedAnchorLine = -1
            }
        }
    }

    private var widthReader: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { contentWidth.value = proxy.size.width }
                .onChange(of: proxy.size.width) { width in contentWidth.value = width }
        }
    }

    private func isCodeBlock(_ block: BlockNode) -> Bool {
        if case .codeBlock = block { return true }
        return false
    }

    private func nextBlock(after index: Int) -> BlockNode? {
        let blocks = tab.ast.blocks
        let next = index + 1
        return blocks.indices.contains(next) ? blocks[next] : nil
    }

    // MARK: - 一块：渲染 / 就地编辑

    @ViewBuilder
    private func blockRow(_ block: BlockNode, next: BlockNode?) -> some View {
        if let session = editing.value, session.line == block.sourceLine {
            LivePreviewEditor(
                text: draft.value.text,
                appearance: session.appearance,
                caretIndex: session.caret,
                onTextChange: { draft.value.text = $0 },
                onSubmit: { commitActive() },
                onCancel: { cancelActive() },
                onEndEditing: { commitActive() },
                onHeightChange: { height in editorHeight.value = max(18, height) }
            )
            .frame(height: max(18, editorHeight.value))
            // 不铺底色、不加边框：铺了就一眼看出「切进了编辑模式」。
            // 编辑态要看起来和渲染态是同一个东西，只是多了个光标。
            // 上留白必须和 BlockView 里的标题一致，否则点下去整页会往上跳一截。
            .padding(.top, topSpacing(for: block))
        } else {
            BlockView(block: block,
                      baseDirectory: tab.url.deletingLastPathComponent(),
                      bodySize: bodySize,
                      onEditRequest: tab.canEdit ? { caret in
                          beginEdit(block, next: next, point: nil, caretOverride: caret)
                      } : nil)
                .background(rowHighlight(block))
                // 代码块不给点击层：里面挂的是真 NSTextView（要能选中、要能横向滚），
                // 盖一层就都废了；它靠双击进入编辑（见 CodeTextViewModel）。
                .overlay {
                    if !isCodeBlock(block) {
                        PreviewClickLayer(isInteractive: tab.canEdit,
                                          onTap: { point in handleTap(block, next: next, at: point) },
                                          onHover: { inside in handleHover(inside, block: block) })
                    }
                }
        }
    }

    /// 很轻的悬停底色：告诉用户「这一块能点进去改」，但不要跳出一个按钮
    @ViewBuilder
    private func rowHighlight(_ block: BlockNode) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.accentColor.opacity(tab.canEdit && hoveredLine.value == block.sourceLine ? 0.06 : 0))
            .padding(.horizontal, -8)
            .padding(.vertical, -2)
    }

    /// 渲染态块的额外上留白（目前只有标题有）。编辑态照抄一份，块高才不会跳。
    private func topSpacing(for block: BlockNode) -> CGFloat {
        if case .heading(let level, _, _) = block {
            return level <= 2 ? 10 : 4
        }
        return 0
    }

    private func handleHover(_ inside: Bool, block: BlockNode) {
        if inside {
            hoveredLine.value = block.sourceLine
            if tab.canEdit { NSCursor.iBeam.set() }
        } else {
            if hoveredLine.value == block.sourceLine { hoveredLine.value = nil }
            NSCursor.arrow.set()
        }
    }

    // MARK: - 进入编辑

    private func handleTap(_ block: BlockNode, next: BlockNode?, at point: CGPoint) {
        if let session = editing.value, session.line == block.sourceLine { return }

        // 点在链接上就打开链接，别把人拽进编辑态
        if let target = linkTarget(block: block, next: next, at: point) {
            if let url = URL(string: target) { NSWorkspace.shared.open(url) }
            return
        }
        beginEdit(block, next: next, point: point)
    }

    private func linkTarget(block: BlockNode, next: BlockNode?, at point: CGPoint) -> String? {
        let map = PreviewSourceMap(text: tab.text)
        guard contentWidth.value > 40,
              let blockRange = map.range(startLine: block.sourceLine, nextBlockLine: next?.sourceLine)
        else { return nil }
        let source = map.text(in: blockRange)
        let inline = PreviewInlineMap.build(source)
        guard !inline.links.isEmpty else { return nil }

        let attributed = PreviewLiveStyler.attributed(inline, appearance: appearance(for: block))
        let index = PreviewTextMetrics.caretIndex(attributed, width: contentWidth.value, at: point)
        return inline.links.first { NSLocationInRange(index, $0.range) }?.url
    }

    private func beginEdit(_ block: BlockNode,
                           next: BlockNode?,
                           point: CGPoint?,
                           caretOverride: Int? = nil) {
        guard tab.canEdit else { return }
        if let session = editing.value, session.line == block.sourceLine { return }
        commitActive()

        let map = PreviewSourceMap(text: tab.text)
        guard let blockRange = map.range(startLine: block.sourceLine,
                                         nextBlockLine: next?.sourceLine) else { return }
        let blockSource = map.text(in: blockRange)
        guard !blockSource.isEmpty else { return }

        var appearance = appearance(for: block)
        var source = blockSource
        var targetRange = blockRange

        if case .codeBlock(let language, _, _) = block,
           let inner = PreviewSourceMap.codeInnerRange(in: blockSource) {
            // 代码块只编辑围栏之间：围栏留着，删行、回车都不会把它挤走
            appearance.language = language
            source = (blockSource as NSString).substring(with: inner)
            targetRange = NSRange(location: blockRange.location + inner.location,
                                  length: inner.length)
        }

        var caret = 0
        if let caretOverride {
            caret = caretOverride
        } else if let point, contentWidth.value > 40 {
            let inline = PreviewInlineMap.build(source)
            let attributed = PreviewLiveStyler.attributed(inline, appearance: appearance)
            caret = PreviewTextMetrics.caretIndex(attributed, width: contentWidth.value, at: point)
        }
        caret = min(max(0, caret), (source as NSString).length)

        let measured = PreviewLiveStyler.attributed(PreviewInlineMap.build(source),
                                                    appearance: appearance)
        editorHeight.value = max(18, PreviewTextMetrics.height(measured, width: contentWidth.value))
        draft.value.text = source
        hoveredLine.value = nil
        editing.value = EditSession(line: block.sourceLine,
                                    range: targetRange,
                                    appearance: appearance,
                                    source: source,
                                    caret: caret)
    }

    // MARK: - 提交 / 取消

    private func commitActive() {
        guard let session = editing.value else { return }
        editing.value = nil
        guard draft.value.text != session.source else { return }

        let inserted = draft.value.text
        let original = session.source
        let range = session.range

        // 编辑期间正文可能被别处改过（拆分模式下用户能同时在左侧敲字）。
        // 区间处的原文若已不是当初那一份，宁可放弃写入，也不要把别人的改动冲掉。
        let ns = tab.text as NSString
        guard NSMaxRange(range) <= ns.length,
              ns.substring(with: range) == original else { return }

        guard tab.replaceText(in: range, with: inserted) else { return }

        // 纯预览模式没有编辑器，`NSTextView` 不会替我们登记撤销，自己补一步。
        // 拆分模式下走的是编辑器自己的编辑路径，撤销已由它处理。
        if tab.editorBridge == nil, let undoManager {
            let newRange = NSRange(location: range.location,
                                   length: (inserted as NSString).length)
            undoManager.registerUndo(withTarget: tab) { target in
                Task { @MainActor in
                    _ = target.replaceText(in: newRange, with: original)
                }
            }
            undoManager.setActionName("编辑预览")
        }
    }

    private func cancelActive() {
        editing.value = nil
        hoveredLine.value = nil
    }

    // MARK: - 外观

    private func appearance(for block: BlockNode) -> PreviewLiveStyler.Appearance {
        switch block {
        case .heading(let level, _, _):
            return .init(fontSize: PreviewTypography.headingSize(level, bodySize: bodySize), bold: true)
        case .codeBlock(let language, _, _):
            return .init(fontSize: max(10, bodySize - 1), mono: true, language: language, lineSpacing: 0)
        case .blockQuote:
            return .init(fontSize: bodySize, secondary: true)
        case .table, .htmlBlock, .fallback:
            return .init(fontSize: max(10, bodySize - 1), mono: true, lineSpacing: 0)
        default:
            return .init(fontSize: bodySize)
        }
    }

    /// FR-03：滚动位置按标题节点对齐——找到光标/视口上方最近的标题，滚到它
    private func align(proxy: ScrollViewProxy, toLine line: Int, animated: Bool) {
        guard let target = headingAnchorLine(for: line), target != tab.lastAlignedAnchorLine else { return }
        tab.lastAlignedAnchorLine = target
        let action = { proxy.scrollTo("b-\(target)", anchor: .top) }
        if animated {
            withAnimation(.easeOut(duration: 0.18)) { action() }
        } else {
            action()
        }
    }

    private func headingAnchorLine(for line: Int) -> Int? {
        let headings = tab.ast.headings
        guard !headings.isEmpty else { return nil }
        var best: Int?
        for heading in headings where heading.sourceLine <= line {
            if best == nil || heading.sourceLine > best! { best = heading.sourceLine }
        }
        // 光标在第一个标题之前 → 对齐文档顶部
        return best ?? tab.ast.blocks.first?.sourceLine ?? 1
    }

    private func hint(_ text: String, systemImage: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
    }

    static func anchor(for block: BlockNode) -> String {
        "b-\(block.sourceLine)"
    }
}

// MARK: - 块渲染

struct BlockView: View {
    let block: BlockNode
    let baseDirectory: URL?
    let bodySize: CGFloat
    /// 代码块双击进入编辑用；其它块由外层的手势负责
    var onEditRequest: ((Int?) -> Void)? = nil

    var body: some View {
        switch block {
        case .heading(let level, let inlines, _):
            Text(InlineRenderer.attributed(inlines, size: PreviewTypography.headingSize(level, bodySize: bodySize)))
                .fontWeight(.bold)
                .padding(.top, level <= 2 ? 10 : 4)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .paragraph(let inlines, _):
            ParagraphView(inlines: inlines, baseDirectory: baseDirectory, bodySize: bodySize)

        case .codeBlock(let language, let code, _):
            CodeBlockView(language: language, code: code, bodySize: bodySize,
                          onEditRequest: onEditRequest)

        case .list(let ordered, let start, let items, _):
            ListView(ordered: ordered, start: start, items: items,
                     baseDirectory: baseDirectory, bodySize: bodySize)

        case .table(let header, let rows, _):
            TableView(header: header, rows: rows, bodySize: bodySize)

        case .blockQuote(let blocks, _):
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.accentColor.opacity(0.45))
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, inner in
                        BlockView(block: inner, baseDirectory: baseDirectory, bodySize: bodySize)
                    }
                }
                .foregroundStyle(.secondary)
            }
            .padding(.leading, 2)

        case .thematicBreak:
            Divider().padding(.vertical, 6)

        case .htmlBlock(let html, _):
            VStack(alignment: .leading, spacing: 4) {
                Text("HTML 块（原样显示，不执行）")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Text(html)
                    .font(.system(size: bodySize - 1, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .quaternaryLabelColor).opacity(0.25))
            .clipShape(RoundedRectangle(cornerRadius: 6))

        case .fallback(let source, _):
            Text(source)
                .font(.system(size: bodySize - 1, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - 段落

struct ParagraphView: View {
    let inlines: [InlineNode]
    let baseDirectory: URL?
    let bodySize: CGFloat

    var body: some View {
        let segments = InlineRenderer.segments(inlines, size: bodySize)
        if segments.count == 1, case .text(let attributed) = segments[0] {
            Text(attributed)
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    switch segment {
                    case .text(let attributed):
                        Text(attributed)
                            .lineSpacing(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    case .image(let source, let alt):
                        LocalImageView(source: source, alt: alt, baseDirectory: baseDirectory)
                    }
                }
            }
        }
    }
}

// MARK: - 列表

struct ListView: View {
    let ordered: Bool
    let start: Int
    let items: [ListItem]
    let baseDirectory: URL?
    let bodySize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    marker(index: index, item: item)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(item.blocks.enumerated()), id: \.offset) { _, inner in
                            BlockView(block: inner, baseDirectory: baseDirectory, bodySize: bodySize)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.leading, 4)
    }

    @ViewBuilder
    private func marker(index: Int, item: ListItem) -> some View {
        if let checked = item.checkbox {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .font(.system(size: bodySize - 1))
                .foregroundStyle(checked ? Color.accentColor : Color.secondary)
                .frame(width: 18, alignment: .leading)
        } else if ordered {
            Text("\(start + index).")
                .font(.system(size: bodySize, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(minWidth: 20, alignment: .trailing)
        } else {
            Text("•")
                .font(.system(size: bodySize))
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .leading)
        }
    }
}

// MARK: - 表格

struct TableView: View {
    let header: [[InlineNode]]
    let rows: [[[InlineNode]]]
    let bodySize: CGFloat

    var body: some View {
        let columnCount = max(header.count, rows.map(\.count).max() ?? 0)
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(0..<columnCount, id: \.self) { column in
                    cell(header.indices.contains(column) ? header[column] : [], isHeader: true)
                }
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(0..<columnCount, id: \.self) { column in
                        cell(row.indices.contains(column) ? row[column] : [], isHeader: false)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.7)
        )
        .padding(.vertical, 2)
    }

    private func cell(_ inlines: [InlineNode], isHeader: Bool) -> some View {
        Text(InlineRenderer.attributed(inlines, size: bodySize - 0.5))
            .fontWeight(isHeader ? .semibold : .regular)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isHeader
                        ? Color(nsColor: .quaternaryLabelColor).opacity(0.35)
                        : Color.clear)
            .overlay(
                Rectangle()
                    .stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
            )
    }
}

// MARK: - 代码块

struct CodeBlockView: View {
    let language: String?
    let code: String
    let bodySize: CGFloat
    var onEditRequest: ((Int?) -> Void)? = nil

    /// 代码块内边距（横向给滚动留呼吸，纵向与行对齐）
    private var codeInset: NSSize { NSSize(width: 12, height: 10) }
    private var codeFontSize: CGFloat { bodySize - 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let language, !language.isEmpty {
                Text(language)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }
            // 刻意不用 `ScrollView(.horizontal)`：嵌套在外层竖向滚动里会把纵向滚轮吃掉，
            // 鼠标停在代码块上就滚不动页面（见 PreviewCodeView 的说明）。
            CodeBlockText(attributed: CodeHighlighter.highlightedNS(code, language: language,
                                                                  size: codeFontSize),
                          fontSize: codeFontSize,
                          inset: codeInset,
                          onEditRequest: onEditRequest)
                .frame(height: CodeBlockText.height(for: code, fontSize: codeFontSize, inset: codeInset))
        }
        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.22))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 0.6)
        )
    }
}

// MARK: - 本地图片（EX-07）

struct LocalImageView: View {
    let source: String
    let alt: String
    let baseDirectory: URL?

    var body: some View {
        if isRemote {
            placeholder(text: "远程图片不加载（零网络策略）\n\(source)", icon: "globe")
        } else if let image = loadedImage {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 620, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            placeholder(text: "图片缺失：\(source)", icon: "photo.badge.exclamationmark")
        }
    }

    private var isRemote: Bool {
        source.lowercased().hasPrefix("http://") || source.lowercased().hasPrefix("https://")
    }

    private var loadedImage: NSImage? {
        let decoded = source.removingPercentEncoding ?? source
        let url: URL
        if decoded.hasPrefix("/") {
            url = URL(fileURLWithPath: decoded)
        } else if let base = baseDirectory {
            url = base.appendingPathComponent(decoded)
        } else {
            return nil
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return NSImage(contentsOf: url)
    }

    private func placeholder(text: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(.tertiary)
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.25))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
