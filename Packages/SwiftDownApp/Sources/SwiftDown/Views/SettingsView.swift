import AppKit
import SwiftUI

// MARK: - 快捷键录制

/// 录制模型：监听下一次按键，转成 `ShortcutBinding`。
/// 用本地事件监视器而不是自绘 NSView 捕获，代码少且天然支持「按 Esc 取消」。
@MainActor
final class ShortcutRecorderModel: ObservableObject {

    @Published private(set) var recordingAction: ShortcutAction?
    @Published private(set) var conflict: String?

    private var monitor: Any?

    func begin(_ action: ShortcutAction, settings: AppSettings) {
        stop()
        conflict = nil
        recordingAction = action

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return event }
                // Esc 取消录制
                if event.keyCode == 53 {
                    self.stop()
                    return nil
                }
                guard let binding = ShortcutBinding.from(event: event) else {
                    NSSound.beep()
                    return nil
                }
                // 不允许裸字符：会抢走编辑器里的正常输入
                guard !binding.modifiers.isEmpty else {
                    self.conflict = "快捷键必须包含 ⌘ / ⌃ / ⌥ / ⇧ 至少一个"
                    NSSound.beep()
                    return nil
                }
                if let owner = settings.conflict(for: binding, excluding: action) {
                    self.conflict = "\(binding.displayString) 已被「\(owner.title)」占用"
                    self.stop()
                    return nil
                }
                settings.setBinding(binding, for: action)
                self.stop()
                return nil
            }
        }
    }

    func stop() {
        recordingAction = nil
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    func clearConflict() {
        conflict = nil
    }
}

// MARK: - 设置根视图

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("通用", systemImage: "gearshape") }
            ShortcutSettingsView()
                .tabItem { Label("快捷键", systemImage: "command") }
            AboutSettingsView()
                .tabItem { Label("关于", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 600)
    }
}

// MARK: - 通用

struct GeneralSettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("主题")
                    Spacer()
                    Picker("主题", selection: $settings.themeMode) {
                        ForEach(ThemeMode.allCases) { mode in
                            Label(mode.label, systemImage: mode.systemImage).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 260)
                }
                Text("即时生效，涵盖编辑器、预览、菜单与设置窗口；跟随系统则随 macOS 外观切换。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } header: {
                Text("外观")
            }

            Section {
                Picker("默认布局", selection: $settings.defaultViewMode) {
                    ForEach(ViewMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                Toggle("启动时恢复上次布局", isOn: $settings.restoreLastLayout)
                Text(settings.restoreLastLayout
                     ? "沿用上次退出前的布局；无记录时用上面的默认布局。"
                     : "每次启动都用上面的默认布局。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } header: {
                Text("启动")
            }

            Section {
                HStack {
                    Text("溢出显示")
                    Spacer()
                    Picker("溢出显示", selection: $settings.tabBarStyle) {
                        ForEach(TabBarStyle.allCases) { style in
                            Text(style.label).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 140)
                }
                Text(settings.tabBarStyle.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } header: {
                Text("标签栏")
            }

            Section {
                Picker("字体", selection: $settings.fontFamily) {
                    ForEach(EditorFontFamily.allCases) { family in
                        Text(family.label).tag(family)
                    }
                }
                HStack {
                    Text("字号")
                    Spacer()
                    HStack(spacing: 8) {
                        Button {
                            settings.fontSize = max(10, settings.fontSize - 0.5)
                        } label: {
                            Image(systemName: "minus")
                                .frame(width: 18, height: 16)
                        }
                        .buttonStyle(.bordered)
                        .disabled(settings.fontSize <= 10)

                        Text(String(format: "%.1f", settings.fontSize))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 36)

                        Button {
                            settings.fontSize = min(28, settings.fontSize + 0.5)
                        } label: {
                            Image(systemName: "plus")
                                .frame(width: 18, height: 16)
                        }
                        .buttonStyle(.bordered)
                        .disabled(settings.fontSize >= 28)
                    }
                }
                Toggle("显示行号", isOn: $settings.showLineNumbers)
            } header: {
                Text("编辑器")
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 4)
    }
}

// MARK: - 快捷键

struct ShortcutSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var recorder = ShortcutRecorderModel()

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(ShortcutAction.groupOrder, id: \.self) { group in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.leading, 2)

                            VStack(spacing: 0) {
                                ForEach(Array(actions(in: group).enumerated()), id: \.element.id) { index, action in
                                    if index > 0 { Divider().padding(.leading, 10) }
                                    row(for: action)
                                }
                            }
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.6)
                            )
                        }
                    }
                }
                .padding(16)
            }

            Divider()

            HStack(spacing: 10) {
                if let conflict = recorder.conflict {
                    Label(conflict, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                } else if recorder.recordingAction != nil {
                    Label("按下新的组合键，Esc 取消", systemImage: "record.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("恢复全部默认") {
                    recorder.stop()
                    recorder.clearConflict()
                    settings.resetAllShortcuts()
                }
                .disabled(!settings.hasCustomizedShortcuts)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .onDisappear { recorder.stop() }
    }

    private func actions(in group: String) -> [ShortcutAction] {
        ShortcutAction.allCases.filter { $0.group == group }
    }

    private func row(for action: ShortcutAction) -> some View {
        let isRecording = recorder.recordingAction == action
        let binding = settings.binding(for: action)

        return HStack(spacing: 10) {
            Text(action.title)
                .font(.system(size: 12))
            Spacer(minLength: 12)

            Button {
                recorder.clearConflict()
                if isRecording {
                    recorder.stop()
                } else {
                    recorder.begin(action, settings: settings)
                }
            } label: {
                Text(isRecording ? "按下组合键…" : binding.displayString)
                    .font(.system(size: 11.5, weight: isRecording ? .regular : .medium))
                    .monospacedDigit()
                    .foregroundStyle(isRecording ? Color.secondary : Color.primary)
                    .frame(minWidth: 92)
                    .padding(.vertical, 3)
                    .padding(.horizontal, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(isRecording
                                  ? Color.accentColor.opacity(0.15)
                                  : Color(nsColor: .windowBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(isRecording ? Color.accentColor : Color(nsColor: .separatorColor),
                                    lineWidth: isRecording ? 1.2 : 0.6)
                    )
            }
            .buttonStyle(.plain)
            .help(isRecording ? "按下组合键，Esc 取消" : "点击修改")

            Button {
                settings.resetBinding(for: action)
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 10))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(settings.isCustomized(action) ? Color.secondary : Color.secondary.opacity(0.3))
            .disabled(!settings.isCustomized(action))
            .help("恢复默认（\(action.defaultBinding.displayString)）")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}

// MARK: - 关于

struct AboutSettingsView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            Text("SwiftDown")
                .font(.system(size: 17, weight: .semibold))
            Text("macOS 本地 Markdown 阅读与轻量编辑器")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text("版本 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1")　·　零网络")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.top, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
