import AppKit
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
                // 中键关闭（与 Safari / VS Code 一致）。SwiftUI 没有中键手势，
                // 这层 AppKit 只在鼠标中键事件上参与命中，其余一律穿透。
                .overlay(
                    MiddleClickCatcher(tabID: tab.id) { workspace.requestClose(tab) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                )
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

// MARK: - 中键关闭

/// 中键点击标签 = 关闭标签（与 Safari / VS Code 一致）。
///
/// SwiftUI 没有中键手势，AppKit 也没有「既不抢左键、又能收到中键」的钩子：
/// - `onTapGesture` 只认左键，`contextMenu` 只认右键；
/// - 叠一层视图并在 `hitTest` 里判断 `NSApp.currentEvent` 是网上常见写法，但实测
///   `NSApplication.sendEvent` / `NSWindow.sendEvent` 期间 `currentEvent` 都是 nil，
///   拿不到「正在分发的是哪个键」，这条路不可靠。
///
/// 改成两半：叠一层**完全不参与命中测试**的透明视图（`hitTest → nil`，左键/右键/拖拽/
/// 滚轮全部照常穿透），再用窗口级本地监听器收中键抬起，落点用视图当场算出的窗口矩形判断。
/// 矩形每次事件现算，滚动、换行、窗口缩放都不会过期。
@MainActor
enum MiddleClickCenter {

    private struct Entry {
        weak var view: NSView?
        var action: () -> Void
    }

    private static var entries: [UUID: Entry] = [:]
    private static var monitor: Any?

    static func register(id: UUID, view: NSView, action: @escaping () -> Void) {
        entries[id] = Entry(view: view, action: action)
        installMonitorIfNeeded()
    }

    static func unregister(id: UUID) {
        entries[id] = nil
    }

    /// 这次事件该关闭哪个标签。抽成纯判定是为了让自检能用合成事件直接断言，
    /// 不必真的动鼠标。`point` 用窗口坐标。
    static func target(type: NSEvent.EventType,
                       buttonNumber: Int,
                       window: NSWindow?,
                       point: NSPoint) -> UUID? {
        guard type == .otherMouseUp, buttonNumber == 2, let window else { return nil }
        for (id, entry) in entries {
            guard let view = entry.view, view.window === window else { continue }
            if view.convert(view.bounds, to: nil).contains(point) { return id }
        }
        return nil
    }

    private static func installMonitorIfNeeded() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseUp]) { event in
            MainActor.assumeIsolated {
                guard let id = target(type: event.type,
                                      buttonNumber: event.buttonNumber,
                                      window: event.window,
                                      point: event.locationInWindow)
                else { return event }
                entries[id]?.action()
                return nil      // 命中标签就吞掉，别让下层再把它当别的手势
            }
        }
    }
}

/// 标签上的透明覆盖层：只登记自己，不参与任何鼠标事件。
final class MiddleClickZone: NSView {

    var tabID: UUID?
    var action: (() -> Void)?

    /// 永远让路：左键点击、右键菜单、拖拽、滚轮都直接穿到下层 SwiftUI 视图
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let tabID else { return }
        if window == nil {
            MiddleClickCenter.unregister(id: tabID)
        } else if let action {
            MiddleClickCenter.register(id: tabID, view: self, action: action)
        }
    }
}

struct MiddleClickCatcher: NSViewRepresentable {
    let tabID: UUID
    let action: () -> Void

    func makeNSView(context: Context) -> MiddleClickZone {
        let view = MiddleClickZone()
        view.tabID = tabID
        view.action = action
        return view
    }

    func updateNSView(_ view: MiddleClickZone, context: Context) {
        view.action = action
        // 闭包必须重登记，否则里面还是旧的 tab
        if view.window != nil {
            MiddleClickCenter.register(id: tabID, view: view, action: action)
        }
    }
}
