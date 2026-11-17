import SwiftUI
import SwiftDownCore

/// 冲突三选一（FR-06 / EX-04）：禁止静默覆盖任一方
struct ConflictSheet: View {
    let prompt: ConflictPrompt
    @EnvironmentObject private var workspace: Workspace
    @StateObject private var diskPreview = LocalState(false)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("文件已被外部修改")
                        .font(.system(size: 15, weight: .semibold))
                    Text(prompt.tab.displayName)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Text("该文件在磁盘上已被其他程序修改，而你本地也有未保存的修改。选择如何处理——任何一方都不会被静默丢弃。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 16) {
                statCard(title: "我的版本", value: "\(prompt.tab.characterCount) 字符", tint: .accentColor)
                statCard(title: "磁盘版本", value: "\(prompt.disk.content.count) 字符", tint: .orange)
            }

            DisclosureGroup("查看磁盘版本内容", isExpanded: $diskPreview.value) {
                ScrollView {
                    Text(prompt.disk.content.prefix(4000))
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(height: 140)
                .background(Color(nsColor: .quaternaryLabelColor).opacity(0.25))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(.top, 6)
            }
            .font(.system(size: 12))

            Divider()

            HStack {
                Button("稍后处理") { workspace.dismissConflict() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button("另存副本…") { workspace.saveConflictCopy() }
                Button("采用磁盘版") { workspace.resolveConflict(.useDisk) }
                Button("保留我的") { workspace.resolveConflict(.keepMine) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func statCard(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(tint.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}
