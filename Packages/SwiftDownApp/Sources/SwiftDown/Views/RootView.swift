import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @EnvironmentObject private var workspace: Workspace
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        // 自检进程内绝不挂模态 presentation：
        // sheet / alert 在没有真实前台窗口时会进入 SwiftUI 的重复呈现重试，
        // 表现为进程转圈卡死（曾把 --selftest 卡在第 7 步）；自检只断言模型状态。
        if Workspace.isSelfTest {
            core
        } else {
            core
                .sheet(item: $workspace.pendingConflict) { prompt in
                    ConflictSheet(prompt: prompt)
                }
                .confirmationDialog("「\(workspace.pendingClose?.tab.displayName ?? "")」有未保存的修改",
                                    isPresented: Binding(
                                        get: { workspace.pendingClose != nil },
                                        set: { if !$0 { workspace.pendingClose = nil } }
                                    ),
                                    titleVisibility: .visible) {
                    Button("保存并关闭") {
                        if let prompt = workspace.pendingClose { workspace.confirmCloseSaving(prompt) }
                    }
                    Button("放弃修改", role: .destructive) {
                        if let prompt = workspace.pendingClose { workspace.confirmCloseDiscarding(prompt) }
                    }
                    Button("取消", role: .cancel) { workspace.cancelClose() }
                }
                .alert(item: $workspace.alertMessage) { message in
                    Alert(title: Text(message.title),
                          message: Text(message.detail),
                          dismissButton: .default(Text("好")))
                }
        }
    }

    @ViewBuilder
    private var core: some View {
        VStack(spacing: 0) {
            TabBarView()
            Divider()

            HStack(spacing: 0) {
                if workspace.showOutline {
                    OutlineView()
                        .frame(width: 220)
                    Divider()
                }
                content
            }

            Divider()
            StatusBarView()
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(workspace.activeTab?.displayName ?? "SwiftDown")
        .navigationSubtitle(workspace.activeTab?.url.deletingLastPathComponent().path ?? "")
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let tab = workspace.activeTab {
            VStack(spacing: 0) {
                DocumentBanner(tab: tab)
                HStack(spacing: 0) {
                    if workspace.viewMode != .preview {
                        EditorView(tab: tab,
                                   fontSize: settings.fontSize,
                                   fontFamily: settings.fontFamily,
                                   showLineNumbers: settings.showLineNumbers)
                            .id(tab.id)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    if workspace.viewMode == .split {
                        Divider()
                    }
                    if workspace.viewMode != .editor {
                        PreviewView(tab: tab, bodySize: settings.fontSize + 1)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        } else {
            EmptyStateView()
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in
                        workspace.open(url: url)
                    }
                }
            }
        }
        return handled
    }
}

// MARK: - 状态横幅（失联 / 占位 / 冲突 / 只读）

struct DocumentBanner: View {
    @ObservedObject var tab: DocumentTab
    @EnvironmentObject private var workspace: Workspace

    var body: some View {
        if let banner = bannerContent {
            HStack(spacing: 10) {
                Image(systemName: banner.icon)
                    .foregroundStyle(banner.tint)
                Text(banner.text)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                Spacer()
                ForEach(Array(banner.actions.enumerated()), id: \.offset) { _, action in
                    Button(action.title, action: action.handler)
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(banner.tint.opacity(0.12))
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    private struct Banner {
        let icon: String
        let text: String
        let tint: Color
        let actions: [(title: String, handler: () -> Void)]
    }

    private var bannerContent: Banner? {
        switch tab.state {
        case .placeholder(let reason):
            return Banner(icon: "doc.questionmark",
                          text: "\(reason)：\(tab.displayName)",
                          tint: .orange,
                          actions: [("重新定位", { workspace.relocate(tab) })])
        case .missing:
            return Banner(icon: "doc.badge.ellipsis",
                          text: "文件已失联，内存内容仍可复制",
                          tint: .orange,
                          actions: [
                            ("重新定位", { workspace.relocate(tab) }),
                            ("另存为", { workspace.saveActive() })
                          ])
        case .conflict(let disk):
            return Banner(icon: "exclamationmark.triangle.fill",
                          text: "磁盘内容已被外部修改（\(disk.mtime.formatted(date: .omitted, time: .standard))），存在未保存冲突",
                          tint: .red,
                          actions: [("处理冲突", {
                              workspace.pendingConflict = ConflictPrompt(tab: tab, disk: disk)
                          })])
        case .clean, .dirty:
            if tab.isReadOnly {
                return Banner(icon: "lock.doc",
                              text: "文件超过 20MB，只读源码模式",
                              tint: .secondary,
                              actions: [])
            }
            return nil
        }
    }
}

// MARK: - 状态栏

struct StatusBarView: View {
    @EnvironmentObject private var workspace: Workspace
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        HStack(spacing: 14) {
            if let tab = workspace.activeTab {
                Label(stateText(tab), systemImage: stateIcon(tab))
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(stateColor(tab))
                Text("行 \(tab.focusedLine)/\(tab.lineCount)")
                Text("字数 \(tab.wordCount)")
                Text("字符 \(tab.characterCount)")
                if tab.lastParseMilliseconds > 0 {
                    Text(String(format: "解析 %.0fms", tab.lastParseMilliseconds))
                        .foregroundStyle(tab.lastParseMilliseconds > 300 ? .orange : .secondary)
                }
            } else {
                Text("未打开文件")
            }
            Spacer()
            ViewModeSwitcher()
            Text(settings.fontFamily.label + " \(String(format: "%.1f", settings.fontSize))")
            Text("UTF-8")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func stateText(_ tab: DocumentTab) -> String {
        switch tab.state {
        case .clean: return "已保存"
        case .dirty: return "未保存"
        case .conflict: return "冲突"
        case .missing: return "失联"
        case .placeholder: return "占位"
        }
    }

    private func stateIcon(_ tab: DocumentTab) -> String {
        switch tab.state {
        case .clean: return "checkmark.circle"
        case .dirty: return "circle.fill"
        case .conflict: return "exclamationmark.triangle"
        case .missing: return "questionmark.circle"
        case .placeholder: return "doc.questionmark"
        }
    }

    private func stateColor(_ tab: DocumentTab) -> Color {
        switch tab.state {
        case .clean: return .secondary
        case .dirty: return .orange
        case .conflict: return .red
        case .missing, .placeholder: return .orange
        }
    }
}

// MARK: - 视图模式切换（状态栏右下角，可直接点）

struct ViewModeSwitcher: View {
    @EnvironmentObject private var workspace: Workspace

    var body: some View {
        HStack(spacing: 1) {
            ForEach(ViewMode.allCases) { mode in
                Button {
                    workspace.setViewMode(mode)
                } label: {
                    Image(systemName: mode.systemImage)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(isSelected(mode) ? Color.accentColor : Color.secondary)
                        .frame(width: 24, height: 16)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(isSelected(mode) ? Color.accentColor.opacity(0.16) : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(mode.label)（\(mode.shortcutHint)）")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("视图模式")
    }

    private func isSelected(_ mode: ViewMode) -> Bool {
        workspace.viewMode == mode
    }
}

// MARK: - 空态

struct EmptyStateView: View {
    @EnvironmentObject private var workspace: Workspace
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tertiary)
            Text("SwiftDown")
                .font(.system(size: 20, weight: .semibold))
            Text("拖入 Markdown 文件，或使用 ⌘O 打开")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button("打开文件…") { workspace.presentOpenPanel() }
                    .keyboardShortcut("o", modifiers: .command)
            }

            if !settings.recentPaths.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("最近打开")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    ForEach(settings.recentPaths.prefix(6), id: \.self) { path in
                        Button {
                            workspace.open(url: URL(fileURLWithPath: path))
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: AppSettings.exists(path) ? "doc.text" : "doc.questionmark")
                                    .foregroundStyle(AppSettings.exists(path) ? .secondary : .tertiary)
                                Text(URL(fileURLWithPath: path).lastPathComponent)
                                    .lineLimit(1)
                                Text(URL(fileURLWithPath: path).deletingLastPathComponent().path)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            }
                            .font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: 420, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}
