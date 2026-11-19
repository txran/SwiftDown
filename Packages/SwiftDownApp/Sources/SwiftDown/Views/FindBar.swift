import SwiftUI

/// 查找/替换栏。⌘F 唤出，⌘⌥F 展开替换行。
///
/// 两种范围：
/// - **当前文档**：全文查找（不是只查可见区），带命中计数与上下跳转，可替换
/// - **所有标签**：跨已打开文件列出结果，点击跳转（替换只对当前文档开放）
struct FindBar: View {
    @EnvironmentObject private var workspace: Workspace
    @ObservedObject var search: SearchController
    @FocusState private var focusedField: Field?

    private enum Field { case query, replacement }

    var body: some View {
        VStack(spacing: 0) {
            topRow
            if search.showsReplace {
                Divider()
                replaceRow
            }
            if search.scope == .allTabs, !search.tabResults.isEmpty {
                Divider()
                resultsList
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onAppear { focusedField = .query }
        .onChange(of: search.showsReplace) { showsReplace in
            if showsReplace { focusedField = .replacement }
        }
        .onChange(of: search.isPresented) { presented in
            if presented { focusedField = .query }
        }
        // Esc 关闭。放在容器上而不是输入框上：输入框聚焦时 Esc 会沿响应链
        // 冒泡到这里，两种焦点状态都能关掉。
        .onExitCommand { workspace.closeFind() }
    }

    // MARK: - 主行

    private var topRow: some View {
        HStack(spacing: 8) {
            Picker(selection: $search.scope) {
                ForEach(SearchScope.allCases) { scope in
                    Text(scope.label).tag(scope)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: scopeWidth)
            .help("搜索范围：当前文档全文，或所有已打开的标签")

            searchField
            countLabel

            HStack(spacing: 2) {
                iconButton("chevron.up", help: "上一处（⇧⏎）") { workspace.findPrevious() }
                iconButton("chevron.down", help: "下一处（⏎）") { workspace.findNext() }
            }
            .disabled(search.documentMatches.isEmpty)

            HStack(spacing: 2) {
                optionToggle("Aa", help: "区分大小写：只找与输入完全同大小写的（默认不区分）",
                             isOn: search.options.caseSensitive) {
                    search.options.caseSensitive.toggle()
                }
                optionToggle("W", help: "整词匹配：只找完整单词，cats 不算 cat（中文整词按相邻字符判断）",
                             isOn: search.options.wholeWord) {
                    search.options.wholeWord.toggle()
                }
                optionToggle(".*", help: "正则表达式：支持 ^ $ \\d 等写法，例如 ^# 找所有一级标题",
                             isOn: search.options.regex) {
                    search.options.regex.toggle()
                }
            }

            Spacer(minLength: 0)

            iconButton(search.showsReplace ? "arrow.2.squarepath" : "arrow.left.arrow.right",
                       help: search.showsReplace ? "收起替换" : "展开替换（⌘⌥F）") {
                search.showsReplace.toggle()
            }
            iconButton("xmark", help: "关闭（Esc）") { workspace.closeFind() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            TextField("查找", text: $search.query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($focusedField, equals: .query)
                .onSubmit { workspace.findNext() }

            if !search.query.isEmpty {
                Button {
                    search.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        // 不给死宽度：窗口窄时让输入框让位，而不是把右侧的计数与开关挤出去
        .frame(minWidth: 180, idealWidth: 250, maxWidth: 340)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(search.patternError == nil ? Color(nsColor: .separatorColor) : Color.orange,
                        lineWidth: 0.6)
        )
    }

    @ViewBuilder
    private var countLabel: some View {
        Group {
            if let error = search.patternError {
                Text(error).foregroundStyle(.orange)
            } else if search.scope == .allTabs {
                Text(search.hasQuery ? "\(search.tabResults.count) 文件 · \(search.totalAllTabs) 处" : "")
                    .foregroundStyle(.secondary)
            } else if search.hasQuery, search.documentMatches.isEmpty {
                Text("无结果").foregroundStyle(.secondary)
            } else if search.hasQuery {
                Text("\(search.currentIndex + 1)/\(search.documentMatches.count)")
                    .foregroundStyle(.secondary)
            } else {
                Text("")
            }
        }
        .font(.system(size: 11))
        .monospacedDigit()
        .lineLimit(1)
        .frame(minWidth: 58, alignment: .leading)
    }

    // MARK: - 替换行

    private var replaceRow: some View {
        HStack(spacing: 8) {
            // 与上一行的范围选择器同宽，让两行的输入框左边缘对齐。
            //
            // 用 Spacer 而不是 `Color.clear`：Color 在**两个**轴向上都可扩展，
            // 只 `.frame(width:)` 固定宽度的话高度仍然贪婪，会把整行撑到填满可用空间，
            // 同行控件被垂直居中，整条替换栏就浮到编辑区中间去（整窗快照里抓到的）。
            // Spacer 只在所属栈的主轴（这里是水平）上伸展，不参与高度分配。
            Spacer().frame(width: scopeWidth)

            HStack(spacing: 5) {
                Image(systemName: "arrow.2.squarepath")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                TextField("替换为", text: $search.replacement)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($focusedField, equals: .replacement)
                    .onSubmit { workspace.replaceCurrentMatch() }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .frame(minWidth: 180, idealWidth: 250, maxWidth: 340)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.6)
            )

            Button("替换") { workspace.replaceCurrentMatch() }
                .controlSize(.small)
                .disabled(!canReplace)
            Button("全部替换") { workspace.replaceAllMatches() }
                .controlSize(.small)
                .disabled(!canReplace)

            if search.scope == .allTabs {
                Text("替换仅在「当前文档」范围可用")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            } else if workspace.activeTab?.canEdit == false {
                Text("当前文档不可编辑")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var scopeWidth: CGFloat { 160 }

    private var canReplace: Bool {
        search.scope == .document
            && !search.documentMatches.isEmpty
            && workspace.activeTab?.canEdit == true
    }

    // MARK: - 跨标签结果

    private var resultsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(search.tabResults) { result in
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text(result.name)
                            .font(.system(size: 11, weight: .semibold))
                        Text("\(result.matches.count) 处")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        if result.matches.count > displayLimit {
                            Text("（显示前 \(displayLimit) 处）")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .padding(.bottom, 2)

                    ForEach(Array(result.matches.prefix(displayLimit))) { match in
                        Button {
                            workspace.jumpToResult(tabID: result.id, match: match)
                        } label: {
                            HStack(spacing: 8) {
                                Text("\(match.line)")
                                    .font(.system(size: 10).monospacedDigit())
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 34, alignment: .trailing)
                                Text(match.preview)
                                    .font(.system(size: 11))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.bottom, 6)
        }
        .frame(maxHeight: 200)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
    }

    private let displayLimit = 50

    // MARK: - 小组件

    private func iconButton(_ name: String,
                            help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }

    private func optionToggle(_ title: String,
                              help: String,
                              isOn: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                // fixedSize：".*" 这种两字符标签在 22pt 框里会被截成 "."
                .fixedSize()
                .frame(width: 26, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isOn ? Color.accentColor.opacity(0.20) : Color.clear)
                )
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// 只在查找栏展开时占位，避免 RootView 里到处写条件
struct FindBarHost: View {
    @ObservedObject var search: SearchController

    var body: some View {
        if search.isPresented {
            VStack(spacing: 0) {
                FindBar(search: search)
                Divider()
            }
        }
    }
}
