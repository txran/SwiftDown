import AppKit
import SwiftDownPipeline
import SwiftUI

/// 渲染预览（FR-02 / FR-03）。
/// 按块渲染 + LazyVStack：只实例化视口内的块，这是 10MB 文档能滚动的关键（NFR-02）。
struct PreviewView: View {

    @ObservedObject var tab: DocumentTab
    let bodySize: CGFloat

    /// 悬停在哪一块（块的起始行）。只有悬停的块才显示右上角的铅笔。
    /// 用 `LocalState` 而不是 `@State`：本机只有 CLT，SwiftUIMacros 插件缺失，`@State` 编不过。
    @StateObject private var hoveredLine = LocalState<Int?>(nil)
    /// 正在就地编辑的块；nil = 正常预览
    @StateObject private var editing = LocalState<EditingBlock?>(nil)
    /// 草稿放在这里而不是 `BlockSourceEditor` 内部：LazyVStack 会把滚出视口的行
    /// 销毁重建，状态若挂在行上，滚一下草稿就没了。
    @StateObject private var draft = LocalState("")

    @Environment(\.undoManager) private var undoManager

    private struct EditingBlock: Equatable {
        let line: Int
        let range: NSRange
        let label: String
        let original: String
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
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
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

    private func nextBlock(after index: Int) -> BlockNode? {
        let blocks = tab.ast.blocks
        let next = index + 1
        return blocks.indices.contains(next) ? blocks[next] : nil
    }

    // MARK: - 一块：正常渲染 / 就地编辑

    @ViewBuilder
    private func blockRow(_ block: BlockNode, next: BlockNode?) -> some View {
        if let active = editing.value, active.line == block.sourceLine {
            BlockSourceEditor(label: active.label,
                              fontSize: max(11, bodySize - 1),
                              draft: $draft.value,
                              onCommit: commitEdit,
                              onCancel: { editing.value = nil })
        } else {
            BlockView(block: block,
                      baseDirectory: tab.url.deletingLastPathComponent(),
                      bodySize: bodySize)
                .overlay(alignment: .topTrailing) { editAffordance(block, next: next) }
                .onHover { inside in
                    if inside {
                        hoveredLine.value = block.sourceLine
                    } else if hoveredLine.value == block.sourceLine {
                        hoveredLine.value = nil
                    }
                }
        }
    }

    @ViewBuilder
    private func editAffordance(_ block: BlockNode, next: BlockNode?) -> some View {
        if tab.canEdit, editing.value == nil, hoveredLine.value == block.sourceLine {
            Button {
                beginEdit(block, next: next)
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color(nsColor: .controlBackgroundColor)))
                    .overlay(Circle().stroke(Color(nsColor: .separatorColor), lineWidth: 0.6))
            }
            .buttonStyle(.plain)
            .help("编辑这一块（从第 \(block.sourceLine) 行起的 Markdown 源码）")
            .padding(2)
        }
    }

    // MARK: - 轻量编辑

    private func beginEdit(_ block: BlockNode, next: BlockNode?) {
        let map = PreviewSourceMap(text: tab.text)
        guard let range = map.range(startLine: block.sourceLine,
                                    nextBlockLine: next?.sourceLine) else { return }
        let source = map.text(in: range)
        draft.value = source
        editing.value = EditingBlock(line: block.sourceLine,
                                     range: range,
                                     label: map.lineLabel(for: range),
                                     original: source)
        hoveredLine.value = nil
    }

    private func commitEdit() {
        guard let active = editing.value else { return }
        editing.value = nil
        guard draft.value != active.original else { return }

        let inserted = draft.value
        let original = active.original
        let range = active.range

        // 编辑期间正文可能被别处改过（拆分模式下用户能同时在左侧敲字）。
        // 区间处的原文若已不是当初那一份，宁可放弃写入，也不要把别人的改动冲掉。
        let ns = tab.text as NSString
        guard NSMaxRange(range) <= ns.length,
              ns.substring(with: range) == original else { return }

        guard tab.replaceText(in: range, with: inserted) else { return }

        // 纯预览模式没有编辑器，`NSTextView` 不会替我们登记撤销，自己补一步。
        // 拆分模式下走的是 `insertText(_:replacementRange:)`，撤销已由编辑器处理。
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

    var body: some View {
        switch block {
        case .heading(let level, let inlines, _):
            Text(InlineRenderer.attributed(inlines, size: headingSize(level)))
                .fontWeight(.bold)
                .padding(.top, level <= 2 ? 10 : 4)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .paragraph(let inlines, _):
            ParagraphView(inlines: inlines, baseDirectory: baseDirectory, bodySize: bodySize)

        case .codeBlock(let language, let code, _):
            CodeBlockView(language: language, code: code, bodySize: bodySize)

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

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return bodySize + 12
        case 2: return bodySize + 8
        case 3: return bodySize + 4
        case 4: return bodySize + 1
        default: return bodySize
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
                          inset: codeInset)
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
