import SwiftUI
import UniformTypeIdentifiers

/// 顶部标签栏（FR-05）：切换 / 关闭 / 拖拽排序 / 新建。
///
/// 溢出有两种策略（设置 → 标签栏）：
/// - 单行：`ScrollView(.horizontal)`，放不下时两侧出箭头，切换标签自动滚到可见处；
/// - 多行：`TabFlowLayout` 按宽度换行，最多 3 行，超出则栏内上下滚动。
struct TabBarView: View {
    @EnvironmentObject private var workspace: Workspace
    @EnvironmentObject private var settings: AppSettings

    /// 用 `LocalState` 而不是 `@State`：本机只有 CLT，SwiftUIMacros 插件缺失，`@State` 编不过
    @StateObject private var live = LocalState(TabBarLive())

    var body: some View {
        Group {
            if settings.tabBarStyle == .wrap {
                wrapBar
            } else {
                scrollBar
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - 单行 + 箭头

    private var scrollBar: some View {
        HStack(spacing: 0) {
            GeometryReader { geo in
                ScrollViewReader { proxy in
                    HStack(spacing: 0) {
                        if showsArrows(in: geo.size.width) {
                            arrowButton(forward: false, proxy: proxy)
                        }

                        ScrollView(.horizontal, showsIndicators: false) {
                            tabStrip
                                .background(
                                    GeometryReader { inner in
                                        Color.clear.preference(key: TabStripWidthKey.self,
                                                               value: inner.size.width)
                                    }
                                )
                        }

                        if showsArrows(in: geo.size.width) {
                            arrowButton(forward: true, proxy: proxy)
                        }
                    }
                    .onPreferenceChange(TabStripWidthKey.self) { width in
                        guard abs(width - live.value.stripWidth) > 0.5 else { return }
                        live.value.stripWidth = width
                    }
                    .onChange(of: workspace.activeTab?.id) { _ in
                        revealActive(proxy: proxy)
                    }
                }
            }
            .frame(height: TabBarMetrics.rowHeight)

            Divider().frame(height: 22)
            plusButton
        }
        .frame(height: TabBarMetrics.rowHeight)
    }

    private func showsArrows(in containerWidth: CGFloat) -> Bool {
        TabBarMetrics.needsArrows(contentWidth: live.value.stripWidth, containerWidth: containerWidth)
    }

    private func arrowButton(forward: Bool, proxy: ScrollViewProxy) -> some View {
        let atStart = live.value.cursor <= 0
        let atEnd = live.value.cursor >= workspace.tabs.count - 1
        let disabled = forward ? atEnd : atStart

        return Button {
            step(forward ? 1 : -1, proxy: proxy)
        } label: {
            Image(systemName: forward ? "chevron.right" : "chevron.left")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(disabled ? Color(nsColor: .tertiaryLabelColor) : Color.secondary)
                .frame(width: TabBarMetrics.arrowWidth, height: TabBarMetrics.rowHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(forward ? "向右滚动标签" : "向左滚动标签")
        // 箭头压在滚动区之上：给个窗底色，否则滚动中的标签会透到箭头上
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// 箭头一次走一个标签（保证每次点击都有明确位移，不做「翻页」估算）
    private func step(_ delta: Int, proxy: ScrollViewProxy) {
        guard !workspace.tabs.isEmpty else { return }
        let current = live.value.cursor
        let next = min(max(current + delta, 0), workspace.tabs.count - 1)
        guard next != current else { return }
        live.value.cursor = next
        withAnimation(.easeOut(duration: 0.16)) {
            proxy.scrollTo(workspace.tabs[next].id, anchor: .leading)
        }
    }

    /// 切到某个标签时把它带进可见区（从设置/快捷键切标签同样生效）
    private func revealActive(proxy: ScrollViewProxy) {
        guard let activeID = workspace.activeTab?.id,
              let index = workspace.tabs.firstIndex(where: { $0.id == activeID }) else { return }
        live.value.cursor = index
        withAnimation(.easeOut(duration: 0.18)) {
            proxy.scrollTo(activeID, anchor: .center)
        }
    }

    // MARK: - 多行换行

    private var wrapBar: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView(.vertical, showsIndicators: live.value.wrapHeight > TabBarMetrics.maxWrapHeight - 0.5) {
                TabFlowLayout {
                    tabItems
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(
                    GeometryReader { inner in
                        Color.clear.preference(key: TabStripHeightKey.self, value: inner.size.height)
                    }
                )
            }
            .frame(height: live.value.wrapHeight)
            .onPreferenceChange(TabStripHeightKey.self) { height in
                let clamped = min(max(height, TabBarMetrics.rowHeight), TabBarMetrics.maxWrapHeight)
                guard abs(clamped - live.value.wrapHeight) > 0.5 else { return }
                live.value.wrapHeight = clamped
            }

            Divider().frame(height: 22)
            plusButton
                .padding(.top, 3)
        }
    }

    // MARK: - 组成件

    private var tabStrip: some View {
        HStack(spacing: TabBarMetrics.spacing) {
            tabItems
        }
        .padding(.horizontal, 6)
        .frame(height: TabBarMetrics.rowHeight)
    }

    /// 单行与多行共用同一份标签视图，保证右键菜单 / 拖拽排序 / 关闭行为一致
    @ViewBuilder
    private var tabItems: some View {
        ForEach(workspace.tabs) { tab in
            TabItemView(tab: tab, isActive: workspace.activeTab?.id == tab.id)
                .onDrag {
                    workspace.draggingTabID = tab.id
                    return NSItemProvider(object: tab.id.uuidString as NSString)
                }
                .onDrop(of: [.text],
                        delegate: TabDropDelegate(target: tab, workspace: workspace))
                .onTapGesture { workspace.activate(tab) }
                .contextMenu {
                    Button("复制文件路径") { PathPaster.copyFileURL(tab.url) }
                    Button("复制所在文件夹路径") { PathPaster.copyFolderPath(tab.url) }
                    Divider()
                    Button("在访达中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([tab.url])
                    }
                    Divider()
                    Button("关闭") { workspace.requestClose(tab) }
                    Button("关闭其他标签") { workspace.closeOthers(than: tab) }
                    Button("关闭全部标签") { workspace.closeAll() }
                }
        }
    }

    private var plusButton: some View {
        Button {
            workspace.presentOpenPanel()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .help("打开文件（⌘O）")
        .padding(.trailing, 6)
    }
}

// MARK: - 栏内局部状态

private struct TabBarLive {
    /// 单行模式：内容总宽度（判断是否溢出）
    var stripWidth: CGFloat = 0
    /// 多行模式：内容实际高度（决定栏高，封顶 3 行）
    var wrapHeight: CGFloat = TabBarMetrics.rowHeight
    /// 箭头滚动的游标（当前滚到第几个标签）
    var cursor = 0
}

// MARK: - 宽度 / 高度测量

private struct TabStripWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct TabStripHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - 单个标签

private struct TabItemView: View {
    @ObservedObject var tab: DocumentTab
    let isActive: Bool
    @EnvironmentObject private var workspace: Workspace
    @StateObject private var hover = LocalState(false)

    var body: some View {
        HStack(spacing: 6) {
            if isDirty {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 6, height: 6)
            } else if case .missing = tab.state {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
            } else if case .placeholder = tab.state {
                Image(systemName: "doc.questionmark")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
            }

            Text(tab.displayName)
                .font(.system(size: 12))
                .lineLimit(1)
                .foregroundStyle(isActive ? Color.primary : Color.secondary)

            Button {
                workspace.requestClose(tab)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hover.value || isActive ? 1 : 0.35)
            .help("关闭标签")
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .frame(minWidth: 96, maxWidth: 200)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive
                      ? Color(nsColor: .textBackgroundColor)
                      : (hover.value ? Color(nsColor: .quaternaryLabelColor).opacity(0.4) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isActive ? Color(nsColor: .separatorColor) : Color.clear, lineWidth: 0.6)
        )
        .onHover { hover.value = $0 }
        .help(tab.url.path)
    }

    private var isDirty: Bool {
        if case .dirty = tab.state { return true }
        return false
    }
}

private struct TabDropDelegate: DropDelegate {
    let target: DocumentTab
    let workspace: Workspace

    func dropEntered(info: DropInfo) {
        guard let draggingID = workspace.draggingTabID, draggingID != target.id else { return }
        workspace.moveTab(draggingID, before: target.id)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        workspace.draggingTabID = nil
        return true
    }
}
