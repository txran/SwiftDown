import SwiftUI
import SwiftDownPipeline

/// 大纲侧栏（FR-09）：H1-H3 标题树，点击双向跳转，跟随光标高亮当前章节。
///
/// 注意（踩过的坑）：外层只能观察 `workspace`（拿 activeTab），
/// **标题树本身必须由一个观察 `DocumentTab` 的子视图渲染**。
/// 首次打开文档时 AST 是后台异步解析的，若在这里直接读 `tab.ast`，
/// 解析完成不会触发本视图重算——表现为「刚启动时大纲是空的，
/// 切一下视图模式才冒出来」（切换会重建整棵树）。
struct OutlineView: View {
    @EnvironmentObject private var workspace: Workspace

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("大纲")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    workspace.showOutline = false
                } label: {
                    Image(systemName: "sidebar.leading")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .help("隐藏大纲（⇧⌘L 可在设置中改）")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if let tab = workspace.activeTab {
                OutlineList(tab: tab)
                    .id(tab.id)
            } else {
                Text("未打开文件")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// 标题树（观察 tab，AST 更新即刷新）
private struct OutlineList: View {
    @ObservedObject var tab: DocumentTab

    /// 注意：这里带了自检副作用（记录 body 求值时刻的标题数）。
    /// 放在计算属性里是因为它一定会随 body 求值而被调用，
    /// 能真实反映「视图有没有重新求值」。
    private var headings: [HeadingNode] {
        let all = tab.ast.headings
        DebugProbe.recordOutline(all.filter { $0.level <= 3 }.count)
        return all.filter { $0.level <= 3 }
    }

    var body: some View {
        if headings.isEmpty {
            Text(tab.isParsing ? "解析中…" : "当前文档没有 H1–H3 标题")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(headings) { heading in
                            OutlineRow(heading: heading,
                                       isCurrent: currentHeading(for: tab.focusedLine,
                                                                 headings: headings)?.id == heading.id)
                                .id(heading.id)
                                .onTapGesture {
                                    tab.requestJump(toLine: heading.sourceLine)
                                }
                        }
                    }
                    .padding(.vertical, 6)
                }
                .onChange(of: tab.focusedLine) { line in
                    if let current = currentHeading(for: line, headings: headings) {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(current.id, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    private func currentHeading(for line: Int, headings: [HeadingNode]) -> HeadingNode? {
        var best: HeadingNode?
        for heading in headings where heading.sourceLine <= line {
            if best == nil || heading.sourceLine > best!.sourceLine { best = heading }
        }
        return best
    }
}

private struct OutlineRow: View {
    let heading: HeadingNode
    let isCurrent: Bool
    @StateObject private var hover = LocalState(false)

    var body: some View {
        HStack(spacing: 4) {
            Text(heading.plainText)
                .font(.system(size: fontSize, weight: heading.level == 1 ? .semibold : .regular))
                .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(heading.level - 1) * 12 + 12)
        .padding(.trailing, 10)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isCurrent
                      ? Color.accentColor.opacity(0.14)
                      : (hover.value ? Color(nsColor: .quaternaryLabelColor).opacity(0.35) : Color.clear))
                .padding(.horizontal, 5)
        )
        .onHover { hover.value = $0 }
        .help("第 \(heading.sourceLine) 行")
    }

    private var fontSize: CGFloat {
        switch heading.level {
        case 1: return 12
        case 2: return 11.5
        default: return 11
        }
    }
}
