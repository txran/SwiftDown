import AppKit
import CoreGraphics
import Foundation
import SwiftDownCore
import SwiftDownPipeline
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

        // 6.0 读盘必须离开主线程——这是「冷启动被拖到几十秒」的根治点。
        //     判据：`open` 返回时标签还没挂上，说明读盘没有同步跑在主线程。
        //     有人改回同步读盘时这条会立刻 FAIL，而那种改动只有在系统刚好卡住文件打开时
        //     才会暴露（一次 5 秒起），平时完全看不出来。
        let asyncFile = tempDirectory.appendingPathComponent("async-open.md")
        try? "# 异步打开\n\n正文。\n".write(to: asyncFile, atomically: true, encoding: .utf8)
        let asyncWorkspace = Workspace(
            settings: settings,
            restoreSessionOnInit: false,
            sessionStore: SessionStore(directory: tempDirectory.appendingPathComponent("async-session"))
        )
        asyncWorkspace.open(url: asyncFile)
        check("FR-01 打开文档的读盘不在主线程同步完成",
              asyncWorkspace.tabs.isEmpty,
              "open 返回后 tabs=\(asyncWorkspace.tabs.count)（同步读盘会立刻变成 1）")
        await asyncWorkspace.openAndWait(url: asyncFile)
        check("FR-01 异步读盘完成后标签已挂上", asyncWorkspace.tabs.count == 1,
              "tabs=\(asyncWorkspace.tabs.count)")

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
        //   第二篇故意做成 1200 行：行号栏位数会从 2 位涨到 4 位，
        //   用来验证「换文档后标尺变宽、文本区必须跟着收窄」这条曾经的翻车点。
        let secondFile = tempDirectory.appendingPathComponent("second.md")
        let secondBody = (1...1200).map { "第 \($0) 行" }.joined(separator: "\n") + "\n"
        try? "# 第二篇\n\n\(secondBody)".write(to: secondFile, atomically: true, encoding: .utf8)

        // 先把编辑器停在短文档上，作为「复用」的基准（标尺此时是窄版）
        let start = Date()
        workspace.activate(tab)
        let switchMS = Date().timeIntervalSince(start) * 1000
        check("FR-05 标签切换生效", workspace.activeTab?.id == tab.id)
        check("FR-05 标签切换耗时 ≤50ms", switchMS < 50, String(format: "%.2fms", switchMS))
        try? await Task.sleep(nanoseconds: 300_000_000)

        // 6.5.0 「运行中从访达打开另一个 md 会闪一下」的真因与防线。
        //
        //   真因不在我们自己的视图层：SwiftUI 的 AppWindowsController.open(urls:)
        //   在处理外部打开事件时会先 `-[NSWindow _close]` 再为文档激活窗口
        //   （调用栈实测确认），窗口 isVisible 掉到 0 再回来，屏幕上就是一闪。
        //   现在由 AppDelegate 在 applicationWillFinishLaunching 里接管 kAEOpenDocuments，
        //   SwiftUI 收不到这个事件，只把文件塞进 Workspace 走标签。
        //
        //   这条断言防的是「接管被删掉」：删了它功能看起来依旧（文件还能打开），
        //   但闪一下会原样回来，没有别的手段能发现。
        check("FR-05 已接管打开文稿事件（否则窗口会被 SwiftUI 先关再开）",
              AppDelegate.didTakeOverOpenDocuments)

        // 6.5.1 切标签必须复用同一个编辑器实例。
        //   曾经在 RootView 上写 `.id(tab.id)` 强制重建整棵编辑区，
        //   AppKit 视图「旧的已拆、新的未挂」之间会漏出一帧空白，
        //   用户侧表现就是「运行中打开另一个 md 会闪一下」。
        //   这里断言的是**实例同一性**——渲染类问题不能用「看着不闪」来验证。
        host.layoutSubtreeIfNeeded()
        let editorBefore = collectTextViews(in: host).first
        // 必须取**数值快照**：复用后 ruler 是同一个对象，
        // 断言执行时再读 ruleThickness 拿到的会是切换之后的值
        let thicknessBefore = collectRulers(in: host)
            .compactMap { $0 as? LineNumberRulerView }.first?.ruleThickness ?? 0
        workspace.open(url: secondFile)
        try? await Task.sleep(nanoseconds: 600_000_000)
        host.layoutSubtreeIfNeeded()
        let editorAfter = collectTextViews(in: host).first
        let rulerAfter = collectRulers(in: host).compactMap { $0 as? LineNumberRulerView }.first
        check("FR-05 切换文档复用同一编辑器实例",
              editorBefore != nil && editorAfter === editorBefore,
              editorBefore == nil ? "切换前无编辑器" : (editorAfter === editorBefore ? "同一实例" : "实例被重建"))
        check("FR-05 切换后编辑器内容为新文档",
              editorAfter?.string == workspace.activeTab?.text,
              "editor=\(editorAfter?.string.utf8.count ?? -1)B doc=\(workspace.activeTab?.text.utf8.count ?? -1)B")
        check("FR-05 切换后撤销栈已按文档隔离",
              editorAfter?.undoManager?.canUndo != true)

        // 复用最容易翻车的地方：标尺宽度变了，文本视图没跟着收窄，首行被行号盖住
        if let editor = editorAfter,
           let clip = editor.enclosingScrollView?.contentView,
           let rulerAfter {
            check("FR-05 行号栏宽度随行数位数变化",
                  thicknessBefore < rulerAfter.ruleThickness,
                  String(format: "%.0f → %.0f（基准文档 %d 行）",
                         thicknessBefore, rulerAfter.ruleThickness,
                         tab.text.components(separatedBy: "\n").count))
            check("FR-05 切换后文本区不吃行号栏宽度（首行不被遮）",
                  abs(editor.frame.width - clip.frame.width) <= 1,
                  String(format: "text=%.1f clip=%.1f", editor.frame.width, clip.frame.width))
            if let md = editor as? MarkdownTextView {
                let numbers = rulerAfter.debugVisibleLineNumbers()
                check("FR-05 切换后行号仍连续（非全 1）",
                      numbers.first == 1 && numbers.count > 1 && numbers == Array(1...max(1, numbers.count)),
                      "count=\(numbers.count) lines=\(md.logicalLineCount)")
            }
        }

        check("FR-05 打开第二个文件", workspace.tabs.count == 2, "tabs=\(workspace.tabs.count)")
        // 切回来同样不能重建（否则「点标签」也会闪）
        host.layoutSubtreeIfNeeded()
        check("FR-05 切回标签仍复用同一编辑器实例",
              collectTextViews(in: host).first === editorBefore)

        // 6.6 会话恢复（FR-05）
        //
        //   恢复拆成两段：`init` 只读会话元信息（布局 + 路径清单），文档内容等首帧之后
        //   才读。原因见 Workspace.performOpen 的注释——冷启动时一次 `open(2)` 能被系统
        //   拖到 5 秒以上，压在启动阶段会把窗口和打开事件一起拖死。这里两段都验：
        //   ① init 之后不应已经有标签（有就说明有人又把读盘搬回了启动路径）；
        //   ② 恢复执行完后标签、路径、活跃项与退出前一致。
        workspace.persistNow()
        let restored = Workspace(settings: settings, restoreSessionOnInit: true)
        check("FR-05 启动阶段只读会话元信息、不读文档",
              restored.tabs.isEmpty,
              "init 后 tabs=\(restored.tabs.count)（应为 0）")
        await restored.restoreNow()
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
        // /tmp 与 NSTemporaryDirectory() 不是同一个路径：只比后者会漏掉手工放 /tmp 的文件，
        // 实测那些路径会写进 session.json，下次启动变成恢复不出来的幽灵标签。
        check("FR-05 /tmp 下的路径同样视为临时（不写进会话）",
              Workspace.isTemporaryPath("/tmp/swiftdown-probe.md")
              && Workspace.isTemporaryPath("/private/tmp/swiftdown-probe.md")
              && !Workspace.isTemporaryPath(realSample))

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
        // 只等「读盘 + 挂标签」：解析仍是挂上之后异步跑的，所以「先建视图、后解析完成」
        // 这个原始时序没有被破坏。
        await outlineWorkspace.openAndWait(url: outlineFile)
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

            // 中键关闭标签：SwiftUI 没有中键手势，靠「透明覆盖层 + 窗口级监听」实现。
            // 断言落到几何与事件两个要素上：中键抬起 + 落点在标签矩形内才关，
            // 且覆盖层绝不能参与命中测试（否则左键点击会被它吃掉）。
            let zoneWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 120),
                                      styleMask: [.titled], backing: .buffered, defer: false)
            let zone = MiddleClickZone(frame: NSRect(x: 10, y: 10, width: 120, height: 30))
            let zoneID = UUID()
            zoneWindow.contentView?.addSubview(zone)
            MiddleClickCenter.register(id: zoneID, view: zone, action: {})
            let zoneRect = zone.convert(zone.bounds, to: nil)
            let insidePoint = NSPoint(x: zoneRect.midX, y: zoneRect.midY)
            let outsidePoint = NSPoint(x: zoneRect.maxX + 40, y: zoneRect.midY)

            check("FR-05 中键抬起落在标签内 → 关闭该标签",
                  MiddleClickCenter.target(type: .otherMouseUp, buttonNumber: 2,
                                           window: zoneWindow, point: insidePoint) == zoneID,
                  "rect=\(NSStringFromRect(zoneRect))")
            check("FR-05 中键落在标签外不关闭",
                  MiddleClickCenter.target(type: .otherMouseUp, buttonNumber: 2,
                                           window: zoneWindow, point: outsidePoint) == nil)
            check("FR-05 左键/右键不会触发中键关闭",
                  MiddleClickCenter.target(type: .leftMouseUp, buttonNumber: 0,
                                           window: zoneWindow, point: insidePoint) == nil
                  && MiddleClickCenter.target(type: .rightMouseUp, buttonNumber: 1,
                                              window: zoneWindow, point: insidePoint) == nil)
            check("FR-05 中键按下不算（抬起才关）",
                  MiddleClickCenter.target(type: .otherMouseDown, buttonNumber: 2,
                                           window: zoneWindow, point: insidePoint) == nil)
            check("FR-05 中键覆盖层不参与命中测试（不抢左键/右键/拖拽）",
                  zone.hitTest(insidePoint) == nil)
            MiddleClickCenter.unregister(id: zoneID)
            check("FR-05 注销后不再命中",
                  MiddleClickCenter.target(type: .otherMouseUp, buttonNumber: 2,
                                           window: zoneWindow, point: insidePoint) == nil)

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

        // 9.6 查找与替换（SR，用户追加需求，⌘F / ⌘⌥F）
        //
        // 编号记作 SR 而不是 FR-xx：PRD 里的 FR-10 是「导出 HTML / PDF」，
        // 查找替换是需求方后来直接提的，不在 PRD 需求表内，复用 FR-10 会让两边串号。
        //
        // 分三层验：内核（纯函数，边界最密）→ 模型（命中表/替换/冻结）→ 编辑器（倒序批替换）。
        // 只断言「能搜到」没有意义：偏移口径、行号、整词边界、上限这些最容易错的地方，
        // 表现恰恰是「能搜到但结果错」，必须对具体数字。

        // 9.6.1 内核：大小写 / 整词 / 行号
        let findSample = "cat cats CAT\ndog cat"
        let insensitive = FindEngine.matches(in: findSample, query: "cat", options: SearchOptions())
        check("SR 默认不区分大小写命中 4 处", insensitive.count == 4, "count=\(insensitive.count)")

        var caseOptions = SearchOptions()
        caseOptions.caseSensitive = true
        let caseSensitive = FindEngine.matches(in: findSample, query: "cat", options: caseOptions)
        check("SR 区分大小写后 3 处（排除 CAT）", caseSensitive.count == 3, "count=\(caseSensitive.count)")

        var wordOptions = SearchOptions()
        wordOptions.wholeWord = true
        let wholeWord = FindEngine.matches(in: findSample, query: "cat", options: wordOptions)
        check("SR 整词匹配排除 cats", wholeWord.count == 3, "count=\(wholeWord.count)")
        check("SR 行号口径正确（末处在第 2 行）",
              insensitive.last?.line == 2, "line=\(insensitive.last?.line ?? -1)")

        // 9.6.2 内核：长偏移必须落到正确行（回归：曾把元素相对偏移当全文偏移，
        // 表现是「全是第 1 行」而不是崩溃）
        let manyLines = (1...200).map { "第 \($0) 行 cat" }.joined(separator: "\n")
        let lastMatch = FindEngine.matches(in: manyLines, query: "cat", options: SearchOptions()).last
        check("SR 第 200 行的命中算出 200", lastMatch?.line == 200, "line=\(lastMatch?.line ?? -1)")

        // 9.6.3 内核：正则 / 非法正则 / 零长匹配 / 上限
        var regexOptions = SearchOptions()
        regexOptions.regex = true
        let regexHits = FindEngine.matches(in: findSample, query: "^dog", options: regexOptions)
        check("SR 正则命中第 2 行行首 1 处", regexHits.count == 1 && regexHits.first?.line == 2,
              "count=\(regexHits.count)")
        check("SR 非法正则被判为错误而不是崩溃",
              FindEngine.validate(query: "[", options: regexOptions) != nil)
        check("SR 非法正则不产生命中",
              FindEngine.matches(in: findSample, query: "[", options: regexOptions).isEmpty)
        check("SR 零长匹配被忽略（避免替换陷入不动点）",
              FindEngine.matches(in: findSample, query: "^", options: regexOptions).isEmpty)
        let manyHits = String(repeating: "a ", count: 800)
        check("SR 命中数被上限截断",
              FindEngine.matches(in: manyHits, query: "a", options: SearchOptions()).count
                == FindEngine.maxMatchesPerTab,
              "limit=\(FindEngine.maxMatchesPerTab)")
        check("SR 空查询返回空结果",
              FindEngine.matches(in: findSample, query: "", options: SearchOptions()).isEmpty)

        // 9.6.4 模型：查找栏状态、命中表、范围切换
        let findWorkspace = Workspace(settings: settings, restoreSessionOnInit: false)
        let findFileA = tempDirectory.appendingPathComponent("find-a.md")
        let findFileB = tempDirectory.appendingPathComponent("find-b.md")
        try? "# 甲\n\nalpha beta alpha\n\ngamma alpha\n".write(to: findFileA, atomically: true, encoding: .utf8)
        try? "# 乙\n\nalpha alpha\n".write(to: findFileB, atomically: true, encoding: .utf8)
        findWorkspace.open(urls: [findFileA, findFileB])
        try? await Task.sleep(nanoseconds: 900_000_000)
        check("SR 查找用双标签就绪", findWorkspace.tabs.count == 2, "tabs=\(findWorkspace.tabs.count)")

        if let firstTab = findWorkspace.tabs.first {
            findWorkspace.activate(firstTab)
        }
        findWorkspace.showFind()
        check("SR 查找栏可展开", findWorkspace.search.isPresented)

        findWorkspace.search.query = "alpha"
        findWorkspace.refreshSearch()   // 同步重算，不等 120ms 节流
        let docMatches = findWorkspace.search.documentMatches
        check("SR 当前文档命中 3 处", docMatches.count == 3, "count=\(docMatches.count)")
        check("SR 命中行号为 [3,3,5]", docMatches.map(\.line) == [3, 3, 5],
              "\(docMatches.map(\.line))")
        check("SR 叠加层拿到全部命中区间",
              findWorkspace.activeTab?.searchOverlay.ranges.count == 3,
              "ranges=\(findWorkspace.activeTab?.searchOverlay.ranges.count ?? -1)")
        check("SR 当前命中落在第一处",
              findWorkspace.activeTab?.searchOverlay.current == docMatches.first?.range)

        // 9.6.4.1 视觉回归：查找栏是最容易「功能对、排版错」的一类界面，
        // 用它自己的真实状态渲染两帧，人工核对一次（纯 SwiftUI 单独托管，不依赖主窗口）。
        // 必须显式设置 host.frame：只给 SwiftUI 根视图 .frame() 时，NSHostingView 自身
        // 仍是零尺寸，layout 会按一个极窄的宽度算，快照里控件全被压扁（实测过一次）。
        findWorkspace.search.showsReplace = true
        findWorkspace.search.replacement = "ZZZ"
        let findBarHost = NSHostingView(rootView: FindBar(search: findWorkspace.search)
            .environmentObject(findWorkspace)
            .environmentObject(settings))
        findBarHost.frame = NSRect(x: 0, y: 0, width: 1180, height: 66)
        findBarHost.layoutSubtreeIfNeeded()
        snapshotView(findBarHost, to: "/tmp/swiftdown-findbar-replace.png",
                     size: NSSize(width: 1180, height: 66))

        findWorkspace.search.scope = .allTabs
        findWorkspace.refreshSearch()
        let findBarGlobalHost = NSHostingView(rootView: FindBar(search: findWorkspace.search)
            .environmentObject(findWorkspace)
            .environmentObject(settings))
        findBarGlobalHost.frame = NSRect(x: 0, y: 0, width: 1180, height: 210)
        findBarGlobalHost.layoutSubtreeIfNeeded()
        snapshotView(findBarGlobalHost, to: "/tmp/swiftdown-findbar-global.png",
                     size: NSSize(width: 1180, height: 210))
        findWorkspace.search.showsReplace = false

        // 9.6.4.2 布局回归：查找栏的固有高度必须紧凑。
        // 踩过一次：替换行用 `Color.clear.frame(width:)` 做左侧占位，Color 两个轴都贪婪，
        // 宽度定住了、高度没定，整行被撑到填满可用空间，同行控件被垂直居中，
        // 结果替换栏浮在编辑区半空中、还顶出一大块空白（整窗快照里才看出来）。
        // 这类「看得见但断言不到」的错，用固有高度兜住。
        findWorkspace.search.scope = .document
        findWorkspace.search.showsReplace = true
        findWorkspace.refreshSearch()
        let intrinsicHost = NSHostingView(rootView: FindBar(search: findWorkspace.search)
            .environmentObject(findWorkspace)
            .environmentObject(settings))
        intrinsicHost.layoutSubtreeIfNeeded()
        let twoRowHeight = intrinsicHost.fittingSize.height
        check("SR 查找栏两行（查找 + 替换）高度紧凑",
              twoRowHeight > 40 && twoRowHeight < 100, "\(Int(twoRowHeight))pt")
        findWorkspace.search.showsReplace = false

        // 9.6.4.3 视觉回归：整窗快照（编辑器 + 查找栏 + 真实高亮）。
        // 单渲查找栏只能证明「控件排对了」，证明不了它压在编辑器上方是不是这个观感，
        // 也证明不了命中高亮在正文里跟排版合不合。整窗渲一张，一次看全。
        // 走离屏渲染而不是真实截图：真机截图要么撞窗口遮挡，要么要辅助功能权限去敲 ⌘F。
        findWorkspace.search.scope = .document
        findWorkspace.search.showsReplace = true
        findWorkspace.refreshSearch()
        let composeHost = NSHostingView(rootView: RootView()
            .environmentObject(settings)
            .environmentObject(findWorkspace)
            .preferredColorScheme(settings.themeMode.colorScheme))
        composeHost.frame = NSRect(x: 0, y: 0, width: 1180, height: 760)
        composeHost.layoutSubtreeIfNeeded()
        snapshotView(composeHost, to: "/tmp/swiftdown-find-window.png",
                     size: NSSize(width: 1180, height: 760))
        findWorkspace.search.showsReplace = false

        findWorkspace.search.scope = .allTabs
        findWorkspace.refreshSearch()
        check("SR 所有标签范围覆盖 2 个文件",
              findWorkspace.search.tabResults.count == 2,
              "files=\(findWorkspace.search.tabResults.count)")
        check("SR 跨文件命中合计 5 处",
              findWorkspace.search.totalAllTabs == 5, "total=\(findWorkspace.search.totalAllTabs)")
        findWorkspace.search.scope = .document
        findWorkspace.refreshSearch()

        // 9.6.5 模型：替换单处 / 全部替换 / 撤销隔离
        // 替换词刻意用 "ZZZ" 而不是 "ALPHA"：默认查找不区分大小写，
        // 用 "ALPHA" 替换后「无残留」会通过，但「命中清零」必然是 3 处（自己判自己）。
        findWorkspace.search.replacement = "ZZZ"
        findWorkspace.replaceCurrentMatch()
        try? await Task.sleep(nanoseconds: 200_000_000)
        let textAfterOne = findWorkspace.activeTab?.text ?? ""
        check("SR 替换单处后旧词少一处",
              textAfterOne == "# 甲\n\nZZZ beta alpha\n\ngamma alpha\n", textAfterOne)

        findWorkspace.replaceAllMatches()
        try? await Task.sleep(nanoseconds: 250_000_000)
        let textAfterAll = findWorkspace.activeTab?.text ?? ""
        check("SR 全部替换后无残留", !textAfterAll.contains("alpha"), textAfterAll)
        check("SR 全部替换后命中清零",
              findWorkspace.search.documentMatches.isEmpty,
              "count=\(findWorkspace.search.documentMatches.count)")
        check("SR 替换后进入未保存态", isDirty(findWorkspace.activeTab!), stateLabel(findWorkspace.activeTab!))

        // 9.6.6 模型：只读/占位标签拒绝替换（冻结语义不能只在按钮上做）
        let orphanURL = tempDirectory.appendingPathComponent("missing.md")
        let orphanSession = DocumentSession.placeholder(url: orphanURL, reason: "文件不存在")
        let orphanTab = DocumentTab(session: orphanSession, settings: settings, isReadOnly: true)
        check("SR 占位标签不可编辑", !orphanTab.canEdit)
        check("SR 占位标签拒绝替换",
              !orphanTab.replaceText(in: NSRange(location: 0, length: 0), with: "x"))

        findWorkspace.closeFind()
        check("SR 关闭查找栏后叠加层清空",
              findWorkspace.activeTab?.searchOverlay.ranges.isEmpty ?? false)
        check("SR 关闭查找栏后查询被重置",
              findWorkspace.search.query.isEmpty && !findWorkspace.search.isPresented)

        // 9.6.7 编辑器：批量替换必须倒序，且只产生一次模型回写
        let replaceProbe = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 260))
        replaceProbe.string = "alpha beta alpha"
        let replaceCount = replaceProbe.replaceMatches(
            ranges: [NSRange(location: 0, length: 5), NSRange(location: 11, length: 5)],
            with: "X"
        )
        check("SR 编辑器批量替换倒序正确", replaceCount == 2 && replaceProbe.string == "X beta X",
              replaceProbe.string)
        replaceProbe.string = "alpha"
        check("SR 编辑器单处替换生效",
              replaceProbe.replaceMatch(range: NSRange(location: 0, length: 5), with: "Y")
                && replaceProbe.string == "Y", replaceProbe.string)

        // 9.6.7.1 编辑器：高亮必须真的「画」出来（像素级，TextKit 2 / 1 各验一遍）
        //
        // 整个查找功能里唯一一处「模型全对、用户却可能什么都看不见」的地方：
        // 高亮走的是渲染属性 / 临时属性，刻意不进 textStorage，
        // 所以前面所有断言（区间、token、数量）都不等于屏幕上有颜色。
        // 唯一可信的判据是把视图渲成位图数黄色像素；顺带确认降级到 TextKit 1 后仍然成立。
        for engine in ["TextKit 2", "TextKit 1"] {
            let probe = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 180))
            probe.appearance = NSAppearance(named: .aqua)   // 固定浅色：深色外观下这条判据不成立
            probe.string = "alpha beta alpha gamma alpha"
            if engine == "TextKit 1" {
                _ = probe.layoutManager    // 访问即降级，此处是有意为之，用来验证兼容分支
            }
            let actual = probe.textLayoutManager != nil ? "TextKit 2" : "TextKit 1"
            check("SR 高亮探针确实跑在 \(engine) 上", actual == engine, actual)

            let size = NSSize(width: 420, height: 180)
            func yellow() -> (strong: Int, faint: Int) {
                probe.layoutSubtreeIfNeeded()
                guard let rep = SnapshotRenderer.capture(probe, size: size) else { return (-1, -1) }
                return yellowPixels(rep)
            }

            let blank = yellow()
            let one = [NSRange(location: 0, length: 5)]
            probe.applySearchHighlights(one, current: one[0])
            let onePainted = yellow()

            let three = [NSRange(location: 0, length: 5),
                         NSRange(location: 11, length: 5),
                         NSRange(location: 23, length: 5)]
            probe.applySearchHighlights(three, current: three[0])
            let threePainted = yellow()
            if engine == "TextKit 2", let rep = SnapshotRenderer.capture(probe, size: size),
               let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: "/tmp/swiftdown-find-highlight.png"))
            }

            probe.clearSearchHighlights()
            let clearedPainted = yellow()

            check("SR \(engine) 未查找时无高亮底色",
                  blank.strong + blank.faint < 80, "\(blank.strong + blank.faint) px")
            check("SR \(engine) 查找后画出高亮底色", onePainted.strong > 200,
                  "\(onePainted.strong) px（实色）")
            check("SR \(engine) 唯一命中全用实色，没有多余淡色", onePainted.faint < 60,
                  "淡色 \(onePainted.faint) px")
            // 「我在哪一处」必须看得出：一处实色 + 两处淡色，像素上要真的分得开
            check("SR \(engine) 三处命中逐处都画（不是只画第一处）",
                  threePainted.strong + threePainted.faint > onePainted.strong + 400,
                  "一处 \(onePainted.strong) → 三处 \(threePainted.strong + threePainted.faint) px")
            check("SR \(engine) 当前命中实色、其余淡色，层级分明",
                  threePainted.strong > 200 && threePainted.faint > threePainted.strong * 3 / 2,
                  "实色 \(threePainted.strong) / 淡色 \(threePainted.faint) px")
            check("SR \(engine) 清除高亮后底色退干净",
                  clearedPainted.strong + clearedPainted.faint <= blank.strong + blank.faint + 80,
                  "\(clearedPainted.strong + clearedPainted.faint) px（基线 \(blank.strong + blank.faint)）")
        }

        // 9.6.7.2 高亮的**机制**约束：写 textStorage 但三条副作用必须被堵住
        //
        // 用户打回来过一次「查找栏有 1/24，正文一片干净」：当时用 TextKit 2 的渲染属性
        // （addRenderingAttribute），属性登记得上、却画不出来，离屏渲染又画得出，所以自检全绿。
        // 改成写 textStorage 才真的落色，于是这里把「为什么可以写」逐条钉住——
        // 撤销栈不能脏、不能回写模型、行内代码原有底色要还原。
        let mechProbe = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 200))
        mechProbe.string = "alpha beta alpha"
        mechProbe.allowsUndo = true
        var textChangeCallbacks = 0
        mechProbe.onTextChange = { _ in textChangeCallbacks += 1 }
        // 模拟行内代码底色：清除时必须还回这个颜色，而不是抹成无背景
        let codeBackground = NSColor(srgbRed: 0.9, green: 0.9, blue: 0.95, alpha: 1)
        mechProbe.textStorage?.addAttribute(.backgroundColor, value: codeBackground,
                                           range: NSRange(location: 6, length: 4))
        mechProbe.undoManager?.removeAllActions()
        let maskProbe = EditMaskProbe()
        mechProbe.textStorage?.delegate = maskProbe

        mechProbe.applySearchHighlights([NSRange(location: 0, length: 5),
                                         NSRange(location: 11, length: 5)],
                                        current: NSRange(location: 0, length: 5))
        let paintedBackground = mechProbe.textStorage?.attribute(.backgroundColor, at: 0,
                                                                 effectiveRange: nil) as? NSColor
        check("SR 高亮真的写进了文本属性（不是只登记在引擎里）", paintedBackground != nil,
              String(describing: paintedBackground))
        // 判别力：谁来一版「用替换文本的方式上高亮」，这条立刻变红
        check("SR 高亮只改属性、不改字符（不会触发 didChangeText / 回写模型）",
              maskProbe.sawCharacterEdit == false,
              maskProbe.sawCharacterEdit ? "出现了 .editedCharacters" : "仅 .editedAttributes")
        check("SR 高亮不回写模型（搜索不会把文档改脏）", textChangeCallbacks == 0,
              "回调 \(textChangeCallbacks) 次")

        mechProbe.clearSearchHighlights()
        let restoredBackground = mechProbe.textStorage?.attribute(.backgroundColor, at: 6,
                                                                  effectiveRange: nil) as? NSColor
        let clearedBackground = mechProbe.textStorage?.attribute(.backgroundColor, at: 0,
                                                                 effectiveRange: nil)
        check("SR 清除高亮后行内代码的原底色被还原", restoredBackground == codeBackground,
              String(describing: restoredBackground))
        check("SR 清除高亮后原位没有残留背景色", clearedBackground == nil,
              String(describing: clearedBackground))

        // 9.6.8 快捷键：默认无冲突 + 可在设置里改
        let defaultSignatures = ShortcutAction.allCases.map { $0.defaultBinding.signature }
        check("快捷键默认组合无重复",
              Set(defaultSignatures).count == defaultSignatures.count,
              "\(defaultSignatures.count) 项")
        check("查找默认绑定为 ⌘F", ShortcutAction.find.defaultBinding.displayString == "⌘F",
              ShortcutAction.find.defaultBinding.displayString)
        check("替换默认绑定为 ⌥⌘F", ShortcutAction.replace.defaultBinding.displayString == "⌥⌘F",
              ShortcutAction.replace.defaultBinding.displayString)
        check("查找动作进入设置分组",
              ShortcutAction.groupOrder.contains(ShortcutAction.find.group))
        settings.setBinding(ShortcutBinding(key: "j", modifiers: [.command, .shift]), for: .find)
        check("查找快捷键可在设置中修改",
              settings.binding(for: .find).displayString == "⇧⌘J",
              settings.binding(for: .find).displayString)
        settings.resetBinding(for: .find)
        check("查找快捷键可恢复默认",
              settings.binding(for: .find).signature == ShortcutAction.find.defaultBinding.signature)

        // 9.6.9 菜单：⌘F 只能有一项（系统自带 Find 与自定义菜单重复时，
        // 按下的可能不是我们这条，表现为「快捷键没反应」）
        var commandFItems: [String] = []
        var keyEquivalentDump: [String] = []
        func walkMenu(_ menu: NSMenu) {
            for item in menu.items {
                let key = item.keyEquivalent
                if !key.isEmpty {
                    let flags = item.keyEquivalentModifierMask
                    let onlyCommand = flags.contains(.command)
                        && !flags.contains(.shift)
                        && !flags.contains(.option)
                        && !flags.contains(.control)
                    let label = "\(menu.title) ▸ \(item.title)"
                    keyEquivalentDump.append("\(label) = \(key)")
                    if key.lowercased() == "f", onlyCommand { commandFItems.append(label) }
                }
                if let submenu = item.submenu { walkMenu(submenu) }
            }
        }
        if let mainMenu = NSApp.mainMenu { walkMenu(mainMenu) }
        check("SR 菜单里 ⌘F 只有一项", commandFItems.count == 1, "\(commandFItems)")
        if commandFItems.count != 1 {
            for line in keyEquivalentDump { print("[menu] \(line)") }
        }

        // 9.6.10 真实路径：**视图已经存在之后**再改查询，编辑器必须收到高亮
        //
        // 这条是被用户打回来才补的。此前只验了「先设查询、再建视图」——
        // 首次 updateNSView 顺带把叠加层应用上去，所以是绿的；
        // 而真实用法是视图早就挂好了，用户才开始打字，走的是另一条分支。
        // 判据照旧落到像素（渲染属性不进 textStorage，断言区间证明不了「画出来」）。
        let liveFile = tempDirectory.appendingPathComponent("sr-live.md")
        try? "# 甲\n\nalpha beta alpha\n\ngamma alpha\n".write(to: liveFile, atomically: true, encoding: .utf8)
        let liveWorkspace = Workspace(settings: settings, restoreSessionOnInit: false)
        liveWorkspace.open(url: liveFile)
        for _ in 0..<30 {
            if liveWorkspace.activeTab?.text.contains("alpha") == true { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let liveHost = NSHostingView(rootView: RootView()
            .environmentObject(settings)
            .environmentObject(liveWorkspace)
            .preferredColorScheme(settings.themeMode.colorScheme))
        let liveSize = NSSize(width: 1180, height: 760)
        liveHost.frame = NSRect(origin: .zero, size: liveSize)
        let liveWindow = NSWindow(contentRect: NSRect(origin: .zero, size: liveSize),
                                  styleMask: [.titled], backing: .buffered, defer: false)
        liveWindow.contentView = liveHost
        liveHost.layoutSubtreeIfNeeded()
        try? await Task.sleep(nanoseconds: 400_000_000)   // 让首次 updateNSView 走完

        func liveYellow() -> Int {
            liveHost.displayIfNeeded()
            guard let rep = SnapshotRenderer.capture(liveHost, size: liveSize) else { return -1 }
            let split = yellowPixels(rep)
            return split.strong + split.faint
        }

        let liveBefore = liveYellow()
        liveWorkspace.showFind()
        try? await Task.sleep(nanoseconds: 200_000_000)
        liveWorkspace.search.query = "alpha"
        try? await Task.sleep(nanoseconds: 400_000_000)   // 等节流 + SwiftUI 更新

        let liveMatches = liveWorkspace.search.documentMatches.count
        check("SR 真实路径：查找栏开着、查询已生效", liveMatches == 3, "matches=\(liveMatches)")
        let livePainted = liveYellow()
        check("SR 真实路径：视图已存在时输入关键词，编辑器随即出现高亮",
              livePainted > liveBefore + 200, "\(liveBefore) → \(livePainted) px")

        // 同一路径再验上下跳转：跳到第 3 处后，当前命中（实色）必须落在第三处
        liveWorkspace.findNext()
        liveWorkspace.findNext()
        try? await Task.sleep(nanoseconds: 400_000_000)
        check("SR 真实路径：下一处把游标推到第 3 处",
              liveWorkspace.search.currentIndex == 2,
              "index=\(liveWorkspace.search.currentIndex)/\(liveMatches)")
        if let textView = collectTextViews(in: liveHost).first {
            let selection = textView.selectedRange()
            let third = liveWorkspace.search.documentMatches.last?.range
            check("SR 真实路径：跳转真的选中了第 3 处",
                  third.map { selection.location == $0.location && selection.length == $0.length } ?? false,
                  "选区 \(selection) / 第 3 处 \(String(describing: third))")
        } else {
            check("SR 真实路径：找得到编辑器文本视图", false, "0 个 NSTextView")
        }
        liveWindow.contentView = nil

        // 9.7 预览增强（PV）：代码块滚轮穿透 + 就地轻量编辑
        //
        // 这两条都是「手感」问题，用户报的原话是「鼠标放到预览代码块上，滚轮就不滑动了」
        // 和「预览模式也支持文字修改」。手感问题不能只靠看代码确认，得跑真事件。

        // 9.7.1 源区间映射：把 AST 的块换算回原文区间，边界必须精确到「不多一行」
        //
        // 多一行的后果很具体：块与块之间的空行会被卷进编辑区，提交时一起重写，
        // 用户只改一个错别字，diff 里凭空多出空行的增删。
        let rangeSample = "# 标题\n\n第一段\n第二行\n\n```swift\nlet a = 1\n```\n\n- 甲\n- 乙\n\n最后一段"
        let rangeMap = PreviewSourceMap(text: rangeSample)
        let rangeBlocks = (try? SwiftMarkdownParser().parse(rangeSample))?.blocks ?? []
        check("PV 源区间：样例解析出 5 个顶层块", rangeBlocks.count == 5, "\(rangeBlocks.count)")

        func sourceSlice(at index: Int) -> String? {
            let next = index + 1 < rangeBlocks.count ? rangeBlocks[index + 1].sourceLine : nil
            guard let range = rangeMap.range(startLine: rangeBlocks[index].sourceLine,
                                             nextBlockLine: next) else { return nil }
            return rangeMap.text(in: range)
        }

        check("PV 源区间：标题只含自己那一行",
              sourceSlice(at: 0) == "# 标题", sourceSlice(at: 0) ?? "nil")
        check("PV 源区间：段落两行都收进来、尾部空行不收",
              sourceSlice(at: 1) == "第一段\n第二行", sourceSlice(at: 1) ?? "nil")
        check("PV 源区间：代码块含上下围栏",
              sourceSlice(at: 2) == "```swift\nlet a = 1\n```", sourceSlice(at: 2) ?? "nil")
        check("PV 源区间：列表覆盖全部子项",
              sourceSlice(at: 3) == "- 甲\n- 乙", sourceSlice(at: 3) ?? "nil")
        check("PV 源区间：最后一块到文末（文件末尾无换行）",
              sourceSlice(at: 4) == "最后一段", sourceSlice(at: 4) ?? "nil")
        if let thirdBlockRange = rangeMap.range(startLine: rangeBlocks[2].sourceLine,
                                                nextBlockLine: rangeBlocks[3].sourceLine) {
            check("PV 源区间：行号标签写的是真实行号",
                  rangeMap.lineLabel(for: thirdBlockRange) == "第 6–8 行",
                  rangeMap.lineLabel(for: thirdBlockRange))
        }

        // 9.7.2 轻量编辑端到端：改一段 → 正文真的变了 → AST 重新解析 → 进未保存态
        let previewFile = tempDirectory.appendingPathComponent("pv-preview.md")
        let longCode = (1...8).map { "let value\($0) = \($0)" }.joined(separator: "\n")
            + "\nlet veryLongLine = \"" + String(repeating: "x", count: 240) + "\""
        let previewSource = """
        # 预览标题

        第一段正文，用来验证就地编辑。

        ```swift
        \(longCode)
        ```

        """ + (1...40).map { "第 \($0) 段填充正文，把文档撑长到外层可以滚动。" }.joined(separator: "\n\n")

        try? previewSource.write(to: previewFile, atomically: true, encoding: .utf8)
        let previewWorkspace = Workspace(settings: settings, restoreSessionOnInit: false)
        previewWorkspace.open(url: previewFile)
        for _ in 0..<40 {
            if let blocks = previewWorkspace.activeTab?.ast.blocks, blocks.count >= 40 { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        guard let previewTab = previewWorkspace.activeTab else {
            check("PV 预览文档打开成功", false, "activeTab 为空")
            return
        }
        check("PV 预览文档打开成功，块数符合预期",
              previewTab.ast.blocks.count >= 40, "\(previewTab.ast.blocks.count) 块")

        // 就地编辑第 2 块（那段正文）：与 UI 里点击铅笔后走的是同一段代码路径
        if previewTab.ast.blocks.count >= 2 {
            let paragraph = previewTab.ast.blocks[1]
            let editMap = PreviewSourceMap(text: previewTab.text)
            let nextLine = previewTab.ast.blocks[2].sourceLine
            if let range = editMap.range(startLine: paragraph.sourceLine, nextBlockLine: nextLine) {
                let original = editMap.text(in: range)
                check("PV 就地编辑：取到的是那一段原文",
                      original == "第一段正文，用来验证就地编辑。", original)
                _ = previewTab.replaceText(in: range, with: "改过之后的正文。")
                try? await Task.sleep(nanoseconds: 400_000_000)
                check("PV 就地编辑：正文被整段替换",
                      previewTab.text.contains("改过之后的正文。") && !previewTab.text.contains("用来验证就地编辑"),
                      previewTab.text.prefix(40).description)
                let reparsed = previewTab.ast.blocks.contains { block in
                    if case .paragraph(let inlines, _) = block {
                        return String(InlineRenderer.attributed(inlines, size: 12).characters)
                            .contains("改过之后的正文")
                    }
                    return false
                }
                check("PV 就地编辑：AST 重新解析后内容同步", reparsed)
                check("PV 就地编辑：改动进入未保存态", isDirty(previewTab), stateLabel(previewTab))
            } else {
                check("PV 就地编辑：算得出该段的源区间", false)
            }
        }

        // 9.7.3 代码块滚轮：竖向事件必须穿透到外层页面
        //
        // 原来的实现是 `ScrollView(.horizontal)` 套在外层竖向 ScrollView 里，用户报「鼠标停到
        // 代码块上滚轮就不动了」，所以改成自建的横向 `NSScrollView` + 显式竖向转发。
        //
        // **这条断言的诚实边界**：它**抓不住**旧实现。用同样的合成事件跑旧代码，外层照样滚
        // （AppKit 对未能消费的滚轮事件本来就会往上层滚动视图传），所以它只是「新实现没把
        // 滚动搞坏」的回归保护，不是「旧实现有 bug」的证据。真实滚轮的手感（连续事件、
        // 惯性、触控板相位）合成不出来，只能实机确认。记在这里，免得下次误以为它证明了一切。
        let pvHost = NSHostingView(rootView: PreviewView(tab: previewTab,
                                                        bodySize: settings.fontSize + 1))
        let pvSize = NSSize(width: 1180, height: 760)
        pvHost.frame = NSRect(origin: .zero, size: pvSize)
        let pvWindow = NSWindow(contentRect: NSRect(origin: .zero, size: pvSize),
                                styleMask: [.titled], backing: .buffered, defer: false)
        pvWindow.contentView = pvHost
        pvHost.layoutSubtreeIfNeeded()
        try? await Task.sleep(nanoseconds: 400_000_000)

        let codeScrolls = Self.collectViews(PreviewCodeScrollView.self, in: pvHost)
        check("PV 代码块用的是可穿透滚轮的容器", codeScrolls.count == 1, "\(codeScrolls.count) 个")
        check("PV 代码块容器里挂的是只读文本视图",
              codeScrolls.first?.documentView is NSTextView && (codeScrolls.first?.documentView as? NSTextView)?.isEditable == false)

        // 判据刻意**不**依赖具体实现，而是走真实命中路径：
        // 先按坐标做 hitTest（这正是 AppKit 派发滚轮事件的方式），再把事件交给命中的视图。
        // 内层容器按「视图树里最外层滚动视图之下的那个」来找，新旧实现都适用——
        // 只有这样才验得出「这条断言到底抓不抓得住原来的 bug」（旧实现下它必须 FAIL）。
        let allScrolls = Self.collectViews(NSScrollView.self, in: pvHost)
        let outerScroll = allScrolls.first { Self.ancestorScrollView(of: $0) == nil }
        if let outer = outerScroll {
            let innerScrolls = allScrolls.filter {
                $0 !== outer && Self.ancestorScrollView(of: $0) === outer
            }
            let outerClip = outer.contentView

            func deliverScrollToCodeBlock(dx: Int32, dy: Int32) -> Bool {
                guard let inner = innerScrolls.first else { return false }
                let pointInInner = NSPoint(x: 8, y: inner.bounds.midY)
                let pointInHost = inner.convert(pointInInner, to: pvHost)
                let pointInParent = pvHost.convert(pointInHost, to: pvHost.superview)
                guard let hit = pvHost.superview?.hitTest(pointInParent),
                      let event = Self.syntheticScrollEvent(dx: dx, dy: dy) else { return false }
                hit.scrollWheel(with: event)
                return true
            }

            check("PV 代码块附近能找到内层滚动容器", innerScrolls.count >= 1, "\(innerScrolls.count) 个")

            let outerBefore = outerClip.bounds.origin.y
            let delivered = deliverScrollToCodeBlock(dx: 0, dy: -80)
            try? await Task.sleep(nanoseconds: 200_000_000)
            let outerAfter = outerClip.bounds.origin.y
            check("PV 竖向滚轮停在代码块上，外层页面照样滚动",
                  delivered && outerAfter > outerBefore + 1,
                  "外层 y \(Int(outerBefore)) → \(Int(outerAfter))")

            let innerClip = innerScrolls.first?.contentView
            let innerXBefore = innerClip?.bounds.origin.x ?? 0
            let outerBeforeHorizontal = outerClip.bounds.origin.y
            _ = deliverScrollToCodeBlock(dx: -120, dy: 0)
            try? await Task.sleep(nanoseconds: 200_000_000)
            check("PV 横向滚动只动代码块自己，不推动页面",
                  (innerClip?.bounds.origin.x ?? 0) > innerXBefore + 1
                    && abs(outerClip.bounds.origin.y - outerBeforeHorizontal) < 1,
                  "内层 x \(Int(innerXBefore)) → \(Int(innerClip?.bounds.origin.x ?? 0))，"
                    + "外层 y \(Int(outerBeforeHorizontal)) → \(Int(outerClip.bounds.origin.y))")
        } else {
            check("PV 找得到代码块外层的页面滚动视图", false)
        }
        pvWindow.contentView = nil

        // 视觉回归：预览整页（代码块 + 长行横向滚动条 + 段落）
        previewTab.requestScroll(toLine: 1)
        let pvSnapshotHost = NSHostingView(rootView: PreviewView(tab: previewTab,
                                                                bodySize: settings.fontSize + 1))
        pvSnapshotHost.frame = NSRect(origin: .zero, size: pvSize)
        pvSnapshotHost.layoutSubtreeIfNeeded()
        snapshotView(pvSnapshotHost, to: "/tmp/swiftdown-preview-blocks.png", size: pvSize)

        // 9.7.5 真实点击：对点击层调 `mouseDown`，走的就是真人点下去的那条入口
        //
        // 上一轮「悬停出现铅笔」就是因为没验这一环，交付时才被用户打回来（点不出来）。
        // 这里不再用合成事件去喂 SwiftUI 手势（实测驱动不了），而是点 AppKit 视图本身。
        let clickFile = tempDirectory.appendingPathComponent("pv-click.md")
        try? "# 标题\n\n点击这一段文字就应该进入编辑。\n".write(to: clickFile,
                                                              atomically: true, encoding: .utf8)
        let clickWorkspace = Workspace(settings: settings, restoreSessionOnInit: false)
        clickWorkspace.open(url: clickFile)
        for _ in 0..<30 {
            if clickWorkspace.activeTab?.ast.blocks.count ?? 0 >= 2 { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if let clickTab = clickWorkspace.activeTab {
            let clickHost = NSHostingView(rootView: PreviewView(tab: clickTab, bodySize: 15))
            let clickSize = NSSize(width: 900, height: 600)
            clickHost.frame = NSRect(origin: .zero, size: clickSize)
            let clickWindow = NSWindow(contentRect: NSRect(origin: .zero, size: clickSize),
                                       styleMask: [.titled], backing: .buffered, defer: false)
            clickWindow.contentView = clickHost
            clickHost.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds: 400_000_000)

            let layers = Self.collectViews(PreviewClickLayerView.self, in: clickHost)
            check("PV 真实点击：每块正文都盖了点击层", layers.count >= 2, "\(layers.count) 个")

            func click(_ layer: PreviewClickLayerView, at point: CGPoint) {
                let inWindow = layer.convert(point, to: nil)
                guard let event = NSEvent.mouseEvent(with: .leftMouseDown,
                                                     location: inWindow,
                                                     modifierFlags: [],
                                                     timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: clickWindow.windowNumber,
                                                     context: nil,
                                                     eventNumber: 0,
                                                     clickCount: 1,
                                                     pressure: 1) else { return }
                layer.mouseDown(with: event)
            }

            if layers.count >= 2 {
                let paragraphLayer = layers[1]
                let hitPoint = CGPoint(x: 30, y: max(3, paragraphLayer.bounds.midY))
                click(paragraphLayer, at: hitPoint)
                try? await Task.sleep(nanoseconds: 500_000_000)
            }

            let editors = Self.collectViews(NSTextView.self, in: clickHost).filter { $0.isEditable }
            check("PV 真实点击：点正文后出现就地编辑器", editors.count == 1, "\(editors.count) 个")
            check("PV 真实点击：编辑器里就是这一段的原文",
                  editors.first?.string == "点击这一段文字就应该进入编辑。",
                  editors.first?.string ?? "nil")

            if let editor = editors.first {
                editor.string = "点进来改成这一句。"
                editor.delegate?.textDidChange?(Notification(name: NSText.didChangeNotification,
                                                             object: editor))
                clickWindow.makeFirstResponder(nil)   // 失焦 = 提交
                try? await Task.sleep(nanoseconds: 500_000_000)
                check("PV 真实点击：改完的字写回了正文",
                      clickTab.text.contains("点进来改成这一句。"),
                      clickTab.text.replacingOccurrences(of: "\n", with: "⏎"))
                check("PV 真实点击：提交后编辑器收起来了",
                      Self.collectViews(NSTextView.self, in: clickHost).allSatisfy { !$0.isEditable },
                      "还有可编辑文本视图")
                check("PV 真实点击：只改了这一段，标题没动",
                      clickTab.text.hasPrefix("# 标题"), clickTab.text.prefix(10).description)
            }
            clickWindow.contentView = nil
        } else {
            check("PV 真实点击：样例文档打开成功", false)
        }

        // 9.7.4 阅读模式就地编辑：标记识别 + 写回不丢格式
        //
        // 设计前提（ADR-22）：编辑框里放的是这一块的**原文**，标记画成透明而已。
        // 所以写回永远是整段替换，不存在映射。这里要证的就是这句话：
        // 排版层认得准（标记藏得掉），而且改字之后原来的格式还在。
        let markupSample = "**粗体** 与 *斜体*，`code` 和 [链接](https://example.com)，还有 snake_case_name。"
        let markupMap = PreviewInlineMap.build(markupSample)

        func styles(of substring: String) -> [PreviewCharStyle] {
            let range = (markupSample as NSString).range(of: substring)
            guard range.location != NSNotFound else { return [] }
            return (range.location..<NSMaxRange(range)).map { markupMap.styles[$0] }
        }

        check("PV 标记识别：`**` 被认成标记",
              styles(of: "**").allSatisfy { $0.contains(.markup) },
              "\(styles(of: "**").map(\.rawValue))")
        check("PV 标记识别：`粗体` 被认成 strong",
              styles(of: "粗体").allSatisfy { $0.contains(.strong) })
        check("PV 标记识别：`斜体` 被认成 emphasis",
              styles(of: "斜体").allSatisfy { $0.contains(.emphasis) })
        check("PV 标记识别：行内代码内容是 code、反引号是标记",
              styles(of: "code").allSatisfy { $0.contains(.code) }
                && markupMap.styles[(markupSample as NSString).range(of: "`code`").location].contains(.markup))
        check("PV 标记识别：链接 label 是 link、地址整段是标记",
              styles(of: "链接").allSatisfy { $0.contains(.link) }
                && markupMap.styles[(markupSample as NSString).range(of: "](https").location].contains(.markup))
        check("PV 标记识别：链接地址被抓出来",
              markupMap.links.first?.url == "https://example.com",
              markupMap.links.first?.url ?? "nil")
        check("PV 标记识别：词内下划线（snake_case）不当强调",
              styles(of: "snake_case_name").allSatisfy { !$0.contains(.emphasis) && !$0.contains(.markup) },
              "\(styles(of: "snake_case_name").map(\.rawValue))")

        // 隐藏 = 换成 0.1pt 字体 + 透明色。不靠负字距：负字距会把后面的字拉过来叠着。
        let plainAppearance = PreviewLiveStyler.Appearance(fontSize: 13)
        let hiddenStyled = PreviewLiveStyler.attributed(markupMap, appearance: plainAppearance, caretLine: 99)
        let hiddenFont = hiddenStyled.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let shownStyled = PreviewLiveStyler.attributed(markupMap, appearance: plainAppearance, caretLine: 0)
        let shownFont = shownStyled.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        check("PV 标记渲染：非光标行把标记压到 0.1pt",
              (hiddenFont?.pointSize ?? 99) < 1, "\(hiddenFont?.pointSize ?? -1)pt")
        check("PV 标记渲染：光标所在行标记重新显形",
              abs((shownFont?.pointSize ?? 0) - 13) < 0.01, "\(shownFont?.pointSize ?? -1)pt")
        check("PV 标记渲染：隐藏不改变字符本身（长度一致）",
              hiddenStyled.length == (markupSample as NSString).length
                && hiddenStyled.string == markupSample,
              "\(hiddenStyled.length) vs \((markupSample as NSString).length)")

        // 块级前缀（`- ` / `# ` / `> `）始终淡显：藏起来会连缩进一起吃掉
        // "- 列表项\n- 第二项" 里，第二个 `-` 在第 6 个位置（前面是 "- 列表项" + 换行）
        let listMap = PreviewInlineMap.build("- 列表项\n- 第二项")
        check("PV 标记渲染：列表符号始终淡显、不隐藏",
              listMap.styles[0].contains(.blockPrefix) && listMap.styles[6].contains(.blockPrefix),
              "\(listMap.styles[0].rawValue) / \(listMap.styles[6].rawValue)")

        // 点击落点 → 光标下标（纯排版计算，不依赖视图）
        let probeText = "abcdef"
        let probeStyled = PreviewLiveStyler.attributed(PreviewInlineMap.build(probeText),
                                                       appearance: plainAppearance,
                                                       caretLine: -1)
        let startIndex = PreviewTextMetrics.caretIndex(probeStyled, width: 400, at: .zero)
        let endIndex = PreviewTextMetrics.caretIndex(probeStyled, width: 400, at: CGPoint(x: 399, y: 1))
        check("PV 光标落点：点在左上角落在行首", startIndex == 0, "\(startIndex)")
        check("PV 光标落点：点在行尾空白处落在行尾",
              endIndex == probeText.utf16.count, "\(endIndex)")

        // 代码块只编辑围栏之间
        let fenceBlock = "```swift\nlet a = 1\nlet b = 2\n```"
        if let inner = PreviewSourceMap.codeInnerRange(in: fenceBlock) {
            check("PV 代码块：就地编辑范围去掉上下围栏",
                  (fenceBlock as NSString).substring(with: inner) == "let a = 1\nlet b = 2",
                  (fenceBlock as NSString).substring(with: inner).debugDescription)
        } else {
            check("PV 代码块：算得出围栏内的区间", false)
        }
        if let unfenced = PreviewSourceMap.codeInnerRange(in: "let a = 1") {
            check("PV 代码块：没围栏时不硬造区间", unfenced.length == 0, "\(unfenced.length)")
        } else {
            check("PV 代码块：没围栏时返回 nil（走整块）", true)
        }

        // 端到端：改一个字，原来的粗体标记必须原样留着
        let boldFile = tempDirectory.appendingPathComponent("pv-bold.md")
        try? "开头一段。\n\n这是 **粗体** 和 `code` 的段落。\n\n结尾一段。".write(to: boldFile,
                                                                 atomically: true, encoding: .utf8)
        let boldWorkspace = Workspace(settings: settings, restoreSessionOnInit: false)
        boldWorkspace.open(url: boldFile)
        for _ in 0..<30 {
            if boldWorkspace.activeTab?.ast.blocks.count ?? 0 >= 3 { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if let boldTab = boldWorkspace.activeTab,
           boldTab.ast.blocks.count >= 3,
           let range = PreviewSourceMap(text: boldTab.text)
            .range(startLine: boldTab.ast.blocks[1].sourceLine,
                   nextBlockLine: boldTab.ast.blocks[2].sourceLine) {
            let source = (boldTab.text as NSString).substring(with: range)
            check("PV 就地编辑：含格式的段落取到完整原文",
                  source == "这是 **粗体** 和 `code` 的段落。", source)
            let edited = source.replacingOccurrences(of: "这是", with: "这里是")
            check("PV 就地编辑：写回成功", boldTab.replaceText(in: range, with: edited))
            try? await Task.sleep(nanoseconds: 300_000_000)
            check("PV 就地编辑：改字之后粗体与行内代码标记原样保留",
                  boldTab.text.contains("这里是 **粗体** 和 `code` 的段落。"),
                  boldTab.text.replacingOccurrences(of: "\n", with: "⏎"))
            check("PV 就地编辑：改完仍是「脏」状态", isDirty(boldTab), stateLabel(boldTab))
        } else {
            check("PV 就地编辑：含格式的样例文档打开成功", false)
        }

        // 视觉回归：就地编辑态的样子（整页快照里编辑态需要点击才出现，单独渲一次）
        let editorProbe = NSHostingView(rootView: LivePreviewEditor(
            text: "正文里的 **粗体** 和 `code` 标记在没光标时会被藏起来\n这一行是光标所在行：**标记** 和 `code` 重新显形",
            appearance: PreviewLiveStyler.Appearance(fontSize: 14),
            caretIndex: 60,
            onTextChange: { _ in },
            onSubmit: {},
            onCancel: {},
            onEndEditing: {},
            onHeightChange: { _ in }
        ))
        editorProbe.frame = NSRect(x: 0, y: 0, width: 760, height: 64)
        editorProbe.layoutSubtreeIfNeeded()
        try? await Task.sleep(nanoseconds: 200_000_000)
        snapshotView(editorProbe, to: "/tmp/swiftdown-preview-editor.png",
                     size: NSSize(width: 760, height: 64))
        let mountedEditors = Self.collectViews(NSTextView.self, in: editorProbe)
        check("PV 就地编辑：编辑态挂上了可编辑文本视图",
              mountedEditors.contains { $0.isEditable && $0.string.hasPrefix("正文里的") },
              "\(mountedEditors.count) 个文本视图")
        check("PV 就地编辑：编辑态有实际排版高度",
              (mountedEditors.first?.frame.height ?? 0) > 10,
              "\(Int(mountedEditors.first?.frame.height ?? 0))pt")

        // 临目录清理交给 defer（中途 return 也会执行）
        // 清掉自检写入的专用设置域与会话目录。
        // 注意：以前这里删的是用户真实的 `Application Support/SwiftDown/session.json`——
        // 跑一次自检就把用户「上次打开的标签」清空，属误伤；现在会话本身也隔离到临时目录。
        UserDefaults.standard.removePersistentDomain(forName: Self.settingsSuiteName)
        try? FileManager.default.removeItem(at: Workspace.selftestSessionDirectory)

        print("=== 自检结束：\("通过 \(failures == 0 ? "全部" : "")，失败 \(failures) 项") ===")
        print("SELFTEST RESULT: \(failures == 0 ? "ALL PASS" : "\(failures) FAILED")")
    }

    /// 构造合成滚轮事件（`wheel1` = 纵向，`wheel2` = 横向）。
    ///
    /// `NSEvent` 没有公开的滚轮构造器，只有 `CGEvent` 能塞进两个轴的偏移。
    /// 拿到事件后直接喂给 `NSView.scrollWheel(with:)`——那是真实滚轮的入口，
    /// 不需要窗口真的显示在屏幕上。
    static func syntheticScrollEvent(dx: Int32, dy: Int32) -> NSEvent? {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let cg = CGEvent(scrollWheelEvent2Source: source, units: .line,
                               wheelCount: 2, wheel1: dy / 20, wheel2: dx / 20, wheel3: 0) else { return nil }
        return NSEvent(cgEvent: cg)
    }

    /// 按类型收集视图树里的所有实例
    @MainActor
    private static func collectViews<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        var result: [T] = []
        if let match = view as? T { result.append(match) }
        for subview in view.subviews {
            result.append(contentsOf: collectViews(type, in: subview))
        }
        return result
    }

    /// 视图树里最近的外层滚动视图（用来验证「滚轮有没有穿透」）
    @MainActor
    private static func ancestorScrollView(of view: NSView) -> NSScrollView? {
        var current = view.superview
        while let candidate = current {
            if let scroll = candidate as? NSScrollView { return scroll }
            current = candidate.superview
        }
        return nil
    }

    /// 构造合成鼠标事件。
    ///
    /// 为什么不用 `NSEvent.mouseEvent(with:…)`：那个接口没有 `buttonNumber` 参数，
    /// 造出来的永远是左键（0），验不出「中键被识别」。绕一层 CGEvent 才有真实的按键号。
    static func syntheticMouseEvent(_ type: CGEventType, button: CGMouseButton) -> NSEvent? {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let cg = CGEvent(mouseEventSource: source, mouseType: type,
                               mouseCursorPosition: .zero, mouseButton: button) else { return nil }
        return NSEvent(cgEvent: cg)
    }

    /// 把视图离屏渲染为 PNG（实现在 `SnapshotRenderer`，与 `--render` 出图共用）
    @MainActor
    private static func snapshotView(_ view: NSView, to path: String, size: NSSize = NSSize(width: 1180, height: 760)) {
        if let pixels = SnapshotRenderer.render(view, to: path, size: size) {
            print("[snapshot] \(path) \(Int(pixels.width))x\(Int(pixels.height))")
        }
    }

    /// 数「偏黄」的像素，并按饱和度分两档，把「高亮画出来了没有」变成可断言的事实。
    ///
    /// 判据故意不用精确色值：当前命中是实色 `findHighlightColor`（实测 sRGB ≈ 1.00/0.98/0.35），
    /// 其余命中压到 35% 透明度后叠在白底上被冲淡（≈ 1.00/0.99/0.79），两者绝对值差得远，
    /// 但都满足「红绿高、蓝明显低」。白底 r−b≈0 落选，深色文字 r 不到 0.85 也落选。
    /// 分档看蓝分量：0.35 与 0.79 之间取 0.55 作界。
    /// 隔行隔列取样：这里要的是量级判断，全量 `colorAt` 在 2x 位图上慢得没有意义。
    @MainActor
    private static func yellowPixels(_ rep: NSBitmapImageRep) -> (strong: Int, faint: Int) {
        var strong = 0
        var faint = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                guard color.redComponent > 0.85,
                      color.greenComponent > 0.80,
                      color.redComponent - color.blueComponent > 0.10 else { continue }
                if color.blueComponent < 0.55 { strong += 1 } else { faint += 1 }
            }
        }
        return (strong, faint)
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

/// 自检里跨闭包计数的最小容器（闭包内直接改局部 var 会触发并发检查）
final class Counter {
    var value = 0
}

/// 观察一次文本编辑「改的是字符还是属性」。
///
/// 查找高亮必须只动属性：一旦 `editedMask` 里出现 `.editedCharacters`，
/// `NSTextView` 会走 `didChangeText` → 回写模型 → 触发自动保存，
/// 表现为「搜一下文档就变脏」。这条断言就是挡这个的。
private final class EditMaskProbe: NSObject, NSTextStorageDelegate {
    private(set) var sawCharacterEdit = false

    func textStorage(_ textStorage: NSTextStorage,
                     didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange,
                     changeInLength delta: Int) {
        if editedMask.contains(.editedCharacters) { sawCharacterEdit = true }
    }
}
