import AppKit
import Foundation
import SwiftUI

/// 无头自检（`SwiftDown --selftest <file>`）。
///
/// 存在的理由：本机没有完整 Xcode，也没有可用的屏幕录制权限，无法靠肉眼验收 UI。
/// 这个 harness 用真实视图树 + 真实文件 IO 跑一遍主链路，把「能不能用」变成可断言的输出。
/// 它覆盖 FR-01/03/04/05/06 的核心路径与 NFR-03 的落盘保证。
enum SelfTest {

    /// 自检专用 UserDefaults 域：测试不能污染真实用户的最近打开/快捷键/布局
    static let settingsSuiteName = "dev.swiftdown.app.selftest"

    @MainActor
    static func run(workspace: Workspace, settings: AppSettings, sourcePath: String?) async {
        var failures = 0

        func check(_ name: String, _ condition: Bool, _ detail: String = "") {
            print("\(condition ? "PASS" : "FAIL") | \(name)\(detail.isEmpty ? "" : "  [\(detail)]")")
            if !condition { failures += 1 }
        }

        print("=== SwiftDown 自检开始 ===")

        // 用临时副本，避免污染用户文件
        guard let sourcePath, FileManager.default.fileExists(atPath: sourcePath) else {
            print("FAIL | 未提供可用的自检文件路径")
            print("SELFTEST RESULT: FAILED")
            return
        }
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftdown-selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        // 中途失败 / 卡死也不留垃圾：自检目录含 25MB 大文件样本，长期累积很可观
        defer {
            try? FileManager.default.removeItem(at: tempDirectory)
            // 顺手清掉历史上因崩溃残留的自检目录（只清 1 小时前的，避免误删并发运行）
            let tmp = FileManager.default.temporaryDirectory
            let stale = (try? FileManager.default.contentsOfDirectory(at: tmp,
                                                                      includingPropertiesForKeys: [.contentModificationDateKey]))
                ?? []
            for url in stale where url.lastPathComponent.hasPrefix("swiftdown-selftest-") {
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                    ?? .distantPast
                if Date().timeIntervalSince(date) > 3600 {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
        let testFile = tempDirectory.appendingPathComponent("selftest.md")
        try? FileManager.default.copyItem(at: URL(fileURLWithPath: sourcePath), to: testFile)

        // 1. 打开
        workspace.open(url: testFile)
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        guard let tab = workspace.activeTab else {
            print("FAIL | 打开文件后没有活跃标签")
            print("SELFTEST RESULT: FAILED")
            return
        }
        check("FR-01 打开文件", tab.url.standardizedFileURL == testFile.standardizedFileURL, tab.displayName)
        check("FR-02 解析产出渲染块", !tab.ast.blocks.isEmpty,
              "blocks=\(tab.ast.blocks.count) headings=\(tab.ast.headings.count)")
        check("FR-03 解析耗时已记录", tab.lastParseMilliseconds > 0,
              String(format: "%.1fms / %d 字节", tab.lastParseMilliseconds, tab.text.utf8.count))

        // 重复打开去重
        let before = workspace.tabs.count
        workspace.open(url: testFile)
        check("FR-01 重复打开聚焦不新建", workspace.tabs.count == before, "tabs=\(workspace.tabs.count)")

        // 2. 视图树真实构建（三态全部走一遍）
        for mode in ViewMode.allCases {
            workspace.setViewMode(mode)
            let probe = NSHostingView(rootView: RootView()
                .environmentObject(settings)
                .environmentObject(workspace))
            probe.frame = NSRect(x: 0, y: 0, width: 1180, height: 760)
            probe.layoutSubtreeIfNeeded()
            let hasEditor = !collectTextViews(in: probe).isEmpty
            let expectedEditor = mode != .preview
            check("视图构建 \(mode.label)", probe.frame.width > 0
                  && hasEditor == expectedEditor,
                  "编辑器存在=\(hasEditor) 期望=\(expectedEditor)")
        }
        workspace.setViewMode(.split)

        // 2.5 编辑器真实挂载：视图树里必须存在 NSTextView 且内容与事实源一致
        let host = NSHostingView(rootView: RootView()
            .environmentObject(settings)
            .environmentObject(workspace))
        host.frame = NSRect(x: 0, y: 0, width: 1180, height: 760)
        host.layoutSubtreeIfNeeded()
        let textViews = collectTextViews(in: host)
        check("FR-04 编辑器 NSTextView 已挂载", !textViews.isEmpty, "count=\(textViews.count)")
        if let editor = textViews.first {
            check("FR-04 编辑器内容与事实源一致", editor.string == tab.text,
                  "editor=\(editor.string.utf8.count)B doc=\(tab.text.utf8.count)B")
            check("FR-04 编辑器允许撤销", editor.allowsUndo)
            check("FR-04 编辑器为纯文本模式", !editor.isRichText)
        }
        check("FR-04 行号标尺已创建",
              collectRulers(in: host).contains { $0 is LineNumberRulerView })

        // 2.55 打开第二个文件必须**复用**同一个编辑器视图。
        //      此前 RootView 上挂 `.id(tab.id)`，切换/打开文件时 SwiftUI 会销毁重建
        //      整个 NSViewRepresentable：新建 NSTextView → 全量布局 → 重新高亮，
        //      编辑区先空白再填字，肉眼就是「闪一下」。断言用**实例同一性**兜住，
        //      只看「视图存在」是无效断言（历史教训）。
        let switchFile = tempDirectory.appendingPathComponent("selftest-switch.md")
        try? "# 第二个文件\n\n切换标签不应重建编辑器视图。\n"
            .write(to: switchFile, atomically: true, encoding: .utf8)
        if let editorBefore = textViews.first {
            // 造一条撤销记录（不碰文本，避免把标签改成脏态），验证切文档时会清空
            if let undo = editorBefore.undoManager {
                undo.registerUndo(withTarget: editorBefore) { _ in }
                check("FR-04 切换前撤销栈非空", undo.canUndo)
            }
            workspace.open(url: switchFile)
            host.layoutSubtreeIfNeeded()
            let after = collectTextViews(in: host)
            // 本地强引用保证旧实例存活，`===` 才是有意义的身份比较
            check("FR-04 打开新文件不重建编辑器视图",
                  after.count == 1 && after.first === editorBefore,
                  "count=\(after.count) same=\(after.first === editorBefore)")
            if let switchTab = workspace.activeTab, switchTab.url.standardizedFileURL == switchFile.standardizedFileURL {
                check("FR-04 切换后编辑区内容已更换", after.first?.string == switchTab.text,
                      "editor=\(after.first?.string.count ?? -1) doc=\(switchTab.text.count)")
                check("FR-04 切换后光标回到开头", after.first?.selectedRange().location == 0,
                      "sel=\(after.first?.selectedRange().location ?? -1)")
                // 复用同一个 NSTextView 后撤销栈会跨文档残留：
                // 不清空的话在新文档按 ⌘Z 会把上一篇内容撤回来（串档写坏文件）
                // 行号标尺缓存的是上一篇的行起始表，切换后必须重算
                if let switched = after.first as? MarkdownTextView,
                   let ruler = collectRulers(in: host).compactMap({ $0 as? LineNumberRulerView }).first {
                    if let tlm = switched.textLayoutManager {
                        tlm.ensureLayout(for: tlm.documentRange)
                    }
                    switched.scrollRangeToVisible(NSRange(location: 0, length: 0))
                    let nums = ruler.debugVisibleLineNumbers()
                    check("FR-04 切换文件后行号重算",
                          nums.first == 1 && !nums.isEmpty,
                          "first=\(nums.first ?? -1) count=\(nums.count) lines=\(switched.logicalLineCount)")
                }
                check("FR-04 切换后撤销栈已清空",
                      after.first?.undoManager?.canUndo != true,
                      "canUndo=\(after.first?.undoManager?.canUndo == true)")
            } else {
                check("FR-04 打开新文件后成为活跃标签", false, "active=\(workspace.activeTab?.displayName ?? "nil")")
            }
            // 回到第一个标签：后续断言仍针对 tab。
            // activate 通过 objectWillChange 触发更新，SwiftUI 在下一个 runloop 才重算视图，
            // 因此这里要让出一次主线程再断言（直接 layout 会读到上一帧内容）。
            workspace.activate(tab)
            try? await Task.sleep(nanoseconds: 150_000_000)
            host.layoutSubtreeIfNeeded()
            let backEditor = collectTextViews(in: host).first
            check("FR-04 切回标签内容正确",
                  backEditor?.string == tab.text,
                  "editor=\(backEditor?.string.count ?? -1) doc=\(tab.text.count) "
                  + "active=\(workspace.activeTab?.displayName ?? "nil") "
                  + "tabs=\(workspace.tabs.map { $0.displayName })")
            if let switchTab = workspace.tabs.first(where: { $0.url.standardizedFileURL == switchFile.standardizedFileURL }) {
                workspace.requestClose(switchTab)
                host.layoutSubtreeIfNeeded()
            }
            check("FR-04 关闭标签后编辑器仍复用",
                  collectTextViews(in: host).first === editorBefore)
        }

        // 2.6 行号「真的画出来了」——而且必须在**生产引擎**下验证。
        //     教训：上一版这里写的是 `editor.layoutManager?.ensureLayout(...)`，
        //     而访问 layoutManager 会把 TextKit 2 视图静默降级为 TextKit 1，
        //     于是自检一直跑在兼容分支上，生产分支（每行都算成第 1 行）从未被覆盖。
        if let editor = textViews.first as? MarkdownTextView,
           let ruler = collectRulers(in: host).compactMap({ $0 as? LineNumberRulerView }).first {
            if let textLayoutManager = editor.textLayoutManager {
                textLayoutManager.ensureLayout(for: textLayoutManager.documentRange)
            }
            editor.scrollRangeToVisible(NSRange(location: 0, length: 0))
            check("FR-04 自检覆盖生产排版引擎", ruler.debugLayoutEngineName == "TextKit2",
                  ruler.debugLayoutEngineName)
            let numbers = ruler.debugVisibleLineNumbers()
            check("FR-04 行号实际产生编号", !numbers.isEmpty,
                  "count=\(numbers.count) lines=\(editor.logicalLineCount)")
            check("FR-04 行号自 1 连续递增",
                  numbers.first == 1 && numbers == Array(1...max(1, numbers.count)),
                  "first=\(numbers.first ?? -1) last=\(numbers.last ?? -1)")
            check("FR-04 行号不超过逻辑行数",
                  (numbers.last ?? 0) <= editor.logicalLineCount,
                  "last=\(numbers.last ?? 0) lines=\(editor.logicalLineCount)")

            // 2.7 行号定位开销（滚动同步每帧都要用，必须是 O(log n)）
            let middle = editor.string.utf16.count / 2
            let locateStart = Date()
            var sink = 0
            for _ in 0..<2000 { sink &+= editor.lineNumber(atUTF16Offset: middle) }
            let locateMS = Date().timeIntervalSince(locateStart) * 1000
            check("NFR-02 行号定位 2000 次 ≤ 40ms", locateMS < 40,
                  String(format: "%.2fms sink=%d", locateMS, sink))
        }

        // 2.6.1 回退引擎（TextKit 1）同样正确：独立实例 + 显式降级，不影响上面的视图树
        do {
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 420))
            let legacy = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 420))
            scroll.documentView = legacy
            legacy.string = tab.text
            let ruler = LineNumberRulerView(scrollView: scroll, textView: legacy,
                                            theme: EditorTheme(fontSize: 13.5, family: .sfMono))
            scroll.verticalRulerView = ruler
            scroll.hasVerticalRuler = true
            _ = legacy.layoutManager   // 访问即降级
            if let container = legacy.textContainer {
                legacy.layoutManager?.ensureLayout(for: container)
            }
            let fallback = ruler.debugVisibleLineNumbers()
            check("FR-04 回退引擎行号同样连续",
                  fallback.first == 1 && fallback == Array(1...max(1, fallback.count)),
                  "engine=\(ruler.debugLayoutEngineName) count=\(fallback.count)")
        }

        // 2.7.5 离屏快照：把当前界面渲染成 PNG，供人工核对观感
        // （自检只能证明结构正确，排版/对齐仍需肉眼确认）
        if CommandLine.arguments.contains("--snapshot") {
            snapshotView(host, to: "/tmp/swiftdown-selftest.png")
            snapshotView(NSHostingView(rootView: SettingsView().environmentObject(settings)),
                         to: "/tmp/swiftdown-settings-general.png",
                         size: NSSize(width: 560, height: 600))
            snapshotView(NSHostingView(rootView: ShortcutSettingsView()
                                        .environmentObject(settings)
                                        .background(Color(nsColor: .windowBackgroundColor))),
                         to: "/tmp/swiftdown-settings-shortcuts.png",
                         size: NSSize(width: 560, height: 600))
        }

        // 2.8 标签右键「复制文件路径」
        let savedClipboard = NSPasteboard.general.string(forType: .string)
        PathPaster.copyFileURL(testFile)
        check("FR-05 复制文件路径",
              NSPasteboard.general.string(forType: .string) == testFile.path,
              NSPasteboard.general.string(forType: .string) ?? "nil")
        PathPaster.copyFolderPath(testFile)
        check("FR-05 复制所在文件夹路径",
              NSPasteboard.general.string(forType: .string) == testFile.deletingLastPathComponent().path)
        NSPasteboard.general.clearContents()
        if let savedClipboard {
            NSPasteboard.general.setString(savedClipboard, forType: .string)
        }

        // 3. 编辑 + 自动保存（FR-04 / NFR-03）
        let originalText = tab.text
        let marker = "\n\n<!-- selftest-\(Int(Date().timeIntervalSince1970)) -->\n"
        tab.userDidEdit(originalText + marker)
        check("FR-04 编辑后进入脏态", isDirty(tab), stateLabel(tab))
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        var disk = (try? String(contentsOf: testFile, encoding: .utf8)) ?? ""
        check("FR-04 2s 静默自动保存落盘", disk.contains("selftest-"), "disk=\(disk.utf8.count)B")
        check("FR-04 保存成功后回到干净态", isClean(tab), stateLabel(tab))

        // 4. 外部变更 → 静默重载（FR-06）
        try? (disk + "\n\nexternal-change-1\n").write(to: testFile, atomically: true, encoding: .utf8)
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        check("FR-06 干净态外部变更静默重载", tab.text.contains("external-change-1"))

        // 5. 脏 + 外部变更 → 冲突（FR-06 / EX-04）
        tab.userDidEdit(tab.text + "\nlocal-edit\n")
        try? "external-change-2\n".write(to: testFile, atomically: true, encoding: .utf8)
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        check("FR-06 脏态外部变更进入冲突", isConflict(tab), stateLabel(tab))
        check("FR-06 冲突期编辑冻结", !tab.session.isEditable)
        check("FR-06 冲突期内存副本不丢", tab.text.contains("local-edit"))
        check("FR-05 冲突标签拦截关闭", tab.session.requiresCloseConfirmation)

        // 5.1 冲突的交互约束（第三轮验收的卡死就是这里破的）：
        //     冲突**不能**自动弹三选一 sheet —— 自动 sheet 会和「保存失败」alert 抢同一层
        //     presentation，SwiftUI 反复重试呈现 → 窗口转圈卡死；冲突改用横幅常驻提示。
        check("FR-06 冲突不自动弹三选一 sheet", workspace.pendingConflict == nil,
              "pending=\(workspace.pendingConflict == nil ? "nil" : "sheet")")
        let alertBeforeConflictSave = workspace.alertMessage?.id
        tab.saveNow()   // 冲突期手动保存：被拒绝，但不应再叠一个弹窗
        check("FR-06 冲突期保存不叠加弹窗", workspace.alertMessage?.id == alertBeforeConflictSave)

        // 再等一个自动保存窗口，确认在途的 2s 自动保存不会覆盖磁盘（FR-06 回归）
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        let conflictDisk = (try? String(contentsOf: testFile, encoding: .utf8)) ?? ""
        check("FR-06 冲突期自动保存不写盘", conflictDisk.contains("external-change-2") && !conflictDisk.contains("local-edit"),
              "\(conflictDisk.utf8.count)B")
        check("FR-06 冲突期状态不被自动保存改写", isConflict(tab), stateLabel(tab))

        // 6. 采用磁盘版 → 回到干净
        workspace.resolveConflict(.useDisk, for: tab)
        check("FR-06 采用磁盘版后回到干净", isClean(tab), stateLabel(tab))
        check("FR-06 采用磁盘版后正文取磁盘内容", tab.text.contains("external-change-2"))

        // 6.5 多标签切换（FR-05）
        let secondFile = tempDirectory.appendingPathComponent("second.md")
        try? "# 第二篇\n\n内容\n".write(to: secondFile, atomically: true, encoding: .utf8)
        workspace.open(url: secondFile)
        try? await Task.sleep(nanoseconds: 600_000_000)
        check("FR-05 打开第二个文件", workspace.tabs.count == 2, "tabs=\(workspace.tabs.count)")
        let start = Date()
        workspace.activate(tab)
        let switchMS = Date().timeIntervalSince(start) * 1000
        check("FR-05 标签切换生效", workspace.activeTab?.id == tab.id)
        check("FR-05 标签切换耗时 ≤50ms", switchMS < 50, String(format: "%.2fms", switchMS))

        // 6.6 会话恢复（FR-05）
        workspace.persistNow()
        let restored = Workspace(settings: settings, restoreSessionOnInit: true)
        check("FR-05 会话恢复标签数量", restored.tabs.count == workspace.tabs.count,
              "restored=\(restored.tabs.count)")
        let restoredPaths = Set(restored.tabs.map { $0.url.path })
        let currentPaths = Set(workspace.tabs.map { $0.url.path })
        check("FR-05 会话恢复文件路径一致", restoredPaths == currentPaths)
        check("FR-05 会话恢复聚焦活跃标签", restored.activeTab?.url.path == workspace.activeTab?.url.path,
              restored.activeTab?.displayName ?? "nil")

        // 6.7 会话恢复必须丢掉临时路径：自检残留的 …/selftest.md 曾出现在用户真实标签里，
        //     文件被删后走「外部变更 → 冲突 → 保存失败」，是上一轮卡死的入口。
        let tempSample = NSTemporaryDirectory() + "swiftdown-selftest-demo/selftest.md"
        // 占位路径：只用于「非临时目录」的判断，不要写成真实用户目录（会泄露本机用户名）
        let realSample = "/Users/example/Documents/note.md"
        check("FR-05 恢复会话过滤临时路径",
              Workspace.filterRestorablePaths([tempSample, realSample], dropTemporary: true) == [realSample],
              "过滤后=\(Workspace.filterRestorablePaths([tempSample, realSample], dropTemporary: true))")
        check("FR-05 自检进程内不过滤临时路径（自检文件本就在临时目录）",
              Workspace.filterRestorablePaths([tempSample], dropTemporary: false) == [tempSample])

        // 7. 关闭干净标签
        workspace.requestClose(tab)
        check("FR-05 干净标签直接关闭", !workspace.tabs.contains { $0.id == tab.id },
              "state=\(stateLabel(tab)) closePrompt=\(workspace.pendingClose != nil) "
              + "conflictPrompt=\(workspace.pendingConflict != nil) tabs=\(workspace.tabs.count)")
        // 关闭路径若留下待处理提示会污染后续断言（自检不弹模态，直接清）
        workspace.cancelClose()
        workspace.dismissConflict()

        // 8. 大文档只读判定（FR-01 / EX-02）
        let bigFile = tempDirectory.appendingPathComponent("big.md")
        let bigContent = String(repeating: "# 标题\n\n正文内容正文内容正文内容。\n\n", count: 500_000)
        try? bigContent.write(to: bigFile, atomically: true, encoding: .utf8)
        let bigSize = DiskFileStore.fileSize(at: bigFile)
        if bigSize > 20 * 1024 * 1024 {
            workspace.open(url: bigFile)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            check("FR-01 超 20MB 进入只读", workspace.activeTab?.isReadOnly == true,
                  "\(bigSize / 1024 / 1024)MB")
            if let bigTab = workspace.activeTab {
                workspace.requestClose(bigTab)
            }
        } else {
            print("SKIP | 大文件样本仅 \(bigSize / 1024)KB，未触发只读判定")
        }

        // 8. 大纲首帧刷新（回归：首次打开不显示，切换视图模式才出现）
        //    关键点：这里必须「先建视图、后解析完成」，才能复现原始时序。
        //    用独立 workspace，避免污染主 workspace 的标签计数断言。
        DebugProbe.resetOutline()
        let outlineFile = tempDirectory.appendingPathComponent("outline-fresh.md")
        var outlineSource = ""
        for index in 1...60 {
            outlineSource += "# 章节 \(index)\n\n这是第 \(index) 节的正文，用来拉长解析时间。\n\n"
        }
        try? outlineSource.write(to: outlineFile, atomically: true, encoding: .utf8)

        let outlineWorkspace = Workspace(settings: settings, restoreSessionOnInit: false)
        outlineWorkspace.open(url: outlineFile)
        let outlineTab = outlineWorkspace.activeTab
        let outlineHost = NSHostingView(rootView: RootView()
            .environmentObject(settings)
            .environmentObject(outlineWorkspace))
        outlineHost.frame = NSRect(x: 0, y: 0, width: 1180, height: 760)
        outlineHost.layoutSubtreeIfNeeded()
        let firstOutlineRender = DebugProbe.lastOutlineRender ?? -1
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        outlineHost.layoutSubtreeIfNeeded()
        let finalOutlineRender = DebugProbe.lastOutlineRender ?? -1
        let expectedHeadings = outlineTab?.ast.headings.count ?? -1

        check("FR-09 大纲随解析完成自动刷新",
              DebugProbe.didRenderNonEmptyOutline && finalOutlineRender > 0,
              "首帧=\(firstOutlineRender) 最终=\(finalOutlineRender) 重算次数=\(DebugProbe.outlineRenders.count)")
        check("FR-09 大纲标题数与 AST 一致",
              finalOutlineRender == expectedHeadings,
              "大纲=\(finalOutlineRender) AST=\(expectedHeadings)")

        // 9. 设置：默认布局 / 快捷键持久化 / 冲突检测（用独立 UserDefaults 域，不污染真实设置）
        let suiteName = "swiftdown.selftest.\(UUID().uuidString)"
        if let testDefaults = UserDefaults(suiteName: suiteName) {
            testDefaults.removePersistentDomain(forName: suiteName)
            let s1 = AppSettings(defaults: testDefaults)
            check("FR-07 默认快捷键为 ⌘O",
                  s1.binding(for: .openFile).displayString == "⌘O",
                  s1.binding(for: .openFile).displayString)

            let custom = ShortcutBinding(key: "p", modifiers: [.command, .shift])
            s1.setBinding(custom, for: .openFile)
            check("FR-07 快捷键冲突可检出",
                  s1.conflict(for: custom, excluding: .saveFile) == .openFile,
                  "conflict=\(s1.conflict(for: custom, excluding: .saveFile)?.title ?? "nil")")
            check("FR-07 同动作自身不算冲突",
                  s1.conflict(for: custom, excluding: .openFile) == nil)

            let s2 = AppSettings(defaults: testDefaults)
            check("FR-07 快捷键改动可持久化",
                  s2.binding(for: .openFile) == custom,
                  s2.binding(for: .openFile).displayString)

            s2.resetBinding(for: .openFile)
            check("FR-07 单项恢复默认",
                  s2.binding(for: .openFile) == ShortcutAction.openFile.defaultBinding)
            s2.resetAllShortcuts()
            check("FR-07 全部恢复默认", !s2.hasCustomizedShortcuts)

            // 主题：不只是存值，必须真的落到 AppKit 外观（编辑器/菜单/面板都吃这一层）
            s2.themeMode = .dark
            check("FR-07 主题落地到 AppKit 外观",
                  NSApp.appearance?.name == .darkAqua,
                  NSApp.appearance?.name.rawValue ?? "nil")
            s2.themeMode = .light
            check("FR-07 白天主题落地",
                  NSApp.appearance?.name == .aqua,
                  NSApp.appearance?.name.rawValue ?? "nil")
            s2.themeMode = .system
            check("FR-07 跟随系统时清空强制外观",
                  NSApp.appearance == nil,
                  NSApp.appearance?.name.rawValue ?? "nil")

            s2.restoreLastLayout = false
            s2.defaultViewMode = .preview
            let layoutWorkspace = Workspace(settings: s2, restoreSessionOnInit: false)
            check("FR-07 设置里的默认布局生效",
                  layoutWorkspace.viewMode == .preview,
                  layoutWorkspace.viewMode.label)

            // 标签栏溢出策略：纯布局判断必须可断言（渲染只能靠肉眼，数学能守住回归）
            check("FR-05 标签放不下才出箭头",
                  TabBarMetrics.needsArrows(contentWidth: 900, containerWidth: 600)
                  && !TabBarMetrics.needsArrows(contentWidth: 400, containerWidth: 600))
            check("FR-05 刚好放得下时不出箭头",
                  !TabBarMetrics.needsArrows(contentWidth: 599, containerWidth: 600)
                  && TabBarMetrics.needsArrows(contentWidth: 601, containerWidth: 600),
                  "临界=600")
            check("FR-05 多行换行行数计算",
                  TabBarMetrics.wrappedRowCount(widths: Array(repeating: 110, count: 12),
                                                containerWidth: 700) == 2
                  && TabBarMetrics.wrappedRowCount(widths: Array(repeating: 110, count: 3),
                                                   containerWidth: 700) == 1,
                  "12×110 / 700 → \(TabBarMetrics.wrappedRowCount(widths: Array(repeating: 110, count: 12), containerWidth: 700)) 行")
            check("FR-05 多行最多 3 行封顶",
                  TabBarMetrics.maxWrapHeight == TabBarMetrics.rowHeight * 3,
                  "maxHeight=\(TabBarMetrics.maxWrapHeight)")

            // 设置项持久化（切模式后重启仍生效）
            check("FR-07 标签栏样式默认单行", s1.tabBarStyle == .scroll, s1.tabBarStyle.label)
            s1.tabBarStyle = .wrap
            let reloaded = AppSettings(defaults: testDefaults)
            check("FR-07 标签栏样式持久化", reloaded.tabBarStyle == .wrap, reloaded.tabBarStyle.label)
            s1.tabBarStyle = .scroll

            testDefaults.removePersistentDomain(forName: suiteName)
        } else {
            check("FR-07 建立独立设置域", false, "UserDefaults(suiteName:) 失败")
        }

        // 9.5 标签栏溢出策略：两种模式各渲染一次（视觉回归）+ 高度断言
        let tabWorkspace = Workspace(settings: settings, restoreSessionOnInit: false)
        for index in 1...12 {
            let file = tempDirectory.appendingPathComponent("tab-\(index).md")
            try? "# 标签 \(index)\n\n正文。\n".write(to: file, atomically: true, encoding: .utf8)
            tabWorkspace.open(url: file)
        }
        try? await Task.sleep(nanoseconds: 800_000_000)
        check("FR-05 多标签全部打开", tabWorkspace.tabs.count == 12, "tabs=\(tabWorkspace.tabs.count)")

        let originalStyle = settings.tabBarStyle
        var scrollHeight: CGFloat = 0
        var wrapHeight: CGFloat = 0
        for style in [TabBarStyle.scroll, .wrap] {
            settings.tabBarStyle = style
            let host = NSHostingView(rootView: TabBarView()
                .environmentObject(tabWorkspace)
                .environmentObject(settings)
                .frame(width: 620))
            host.layoutSubtreeIfNeeded()
            let fitting = host.fittingSize
            if style == .scroll { scrollHeight = fitting.height } else { wrapHeight = fitting.height }
            snapshotView(host,
                         to: style == .scroll ? "/tmp/swiftdown-tabbar-scroll.png" : "/tmp/swiftdown-tabbar-wrap.png",
                         size: NSSize(width: 620, height: max(34, fitting.height)))
        }
        settings.tabBarStyle = originalStyle
        check("FR-05 单行模式高度固定为一行的行高",
              abs(scrollHeight - TabBarMetrics.rowHeight) < 0.5,
              String(format: "%.1f", scrollHeight))
        check("FR-05 多行模式高度随行数增长且封顶 3 行",
              wrapHeight > TabBarMetrics.rowHeight && wrapHeight <= TabBarMetrics.maxWrapHeight + 0.5,
              String(format: "%.1f / 上限 %.0f", wrapHeight, TabBarMetrics.maxWrapHeight))

        // 临目录清理交给 defer（中途 return 也会执行）
        // 清掉自检写入的专用设置域与会话目录。
        // 注意：以前这里删的是用户真实的 `Application Support/SwiftDown/session.json`——
        // 跑一次自检就把用户「上次打开的标签」清空，属误伤；现在会话本身也隔离到临时目录。
        UserDefaults.standard.removePersistentDomain(forName: Self.settingsSuiteName)
        try? FileManager.default.removeItem(at: Workspace.selftestSessionDirectory)

        print("=== 自检结束：\("通过 \(failures == 0 ? "全部" : "")，失败 \(failures) 项") ===")
        print("SELFTEST RESULT: \(failures == 0 ? "ALL PASS" : "\(failures) FAILED")")
    }

    /// 把视图离屏渲染为 PNG（实现在 `SnapshotRenderer`，与 `--render` 出图共用）
    @MainActor
    private static func snapshotView(_ view: NSView, to path: String, size: NSSize = NSSize(width: 1180, height: 760)) {
        if let pixels = SnapshotRenderer.render(view, to: path, size: size) {
            print("[snapshot] \(path) \(Int(pixels.width))x\(Int(pixels.height))")
        }
    }

    @MainActor
    private static func collectTextViews(in view: NSView) -> [NSTextView] {        var result: [NSTextView] = []
        if let textView = view as? NSTextView {
            result.append(textView)
        }
        for subview in view.subviews {
            result.append(contentsOf: collectTextViews(in: subview))
        }
        return result
    }

    @MainActor
    private static func collectRulers(in view: NSView) -> [NSRulerView] {
        var result: [NSRulerView] = []
        if let scrollView = view as? NSScrollView {
            if let vertical = scrollView.verticalRulerView { result.append(vertical) }
            if let horizontal = scrollView.horizontalRulerView { result.append(horizontal) }
        }
        for subview in view.subviews {
            result.append(contentsOf: collectRulers(in: subview))
        }
        return result
    }

    @MainActor
    private static func stateLabel(_ tab: DocumentTab) -> String {
        switch tab.state {
        case .clean: return "clean"
        case .dirty: return "dirty"
        case .conflict: return "conflict"
        case .missing: return "missing"
        case .placeholder(let reason): return "placeholder(\(reason))"
        }
    }

    @MainActor
    private static func isClean(_ tab: DocumentTab) -> Bool {
        if case .clean = tab.state { return true }
        return false
    }

    @MainActor
    private static func isDirty(_ tab: DocumentTab) -> Bool {
        if case .dirty = tab.state { return true }
        return false
    }

    @MainActor
    private static func isConflict(_ tab: DocumentTab) -> Bool {
        if case .conflict = tab.state { return true }
        return false
    }
}
