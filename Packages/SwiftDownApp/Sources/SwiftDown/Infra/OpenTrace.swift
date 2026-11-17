import AppKit

/// 打开文件时的帧级探针。
///
/// 只在 `SWIFTDOWN_TRACE=1` 时启用，正常使用零开销、零副作用（只读视图属性）。
/// 采样点是主 runloop 每次 `beforeWaiting`，即「本帧事务已提交、线程即将睡眠」的稳定点，
/// 天然对齐帧边界，比定时器可靠。
///
/// 用来回答一个具体问题：打开文件时那一下「像关闭又重开」的观感，
/// 到底是 ①窗口本身被重新 order front（alpha/visible/isKey 变化），
/// ②编辑器视图被销毁重建（NSTextView 指针变化 / 脱离 window），
/// 还是 ③什么都没变（那就是系统合成层的激活过渡，代码动不了）。
@MainActor
final class OpenTrace {

    static let shared = OpenTrace()

    private var observer: CFRunLoopObserver?
    private var samples: [String] = []
    private var frameCount = 0
    private var t0: CFTimeInterval = 0
    private var label = ""

    private static let maxFrames = 90   // 约 1.5 秒

    var isEnabled: Bool {
        ProcessInfo.processInfo.environment["SWIFTDOWN_TRACE"] == "1"
            || CommandLine.arguments.contains("--trace-open")
            || CommandLine.arguments.contains("--trace")
    }

    func begin(_ name: String) {
        guard isEnabled else { return }
        if observer != nil { return }   // 已在采样
        label = name
        samples.removeAll()
        frameCount = 0
        t0 = CACurrentMediaTime()

        let obs = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, 0
        ) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.samples.append(self.snapshot())
                self.frameCount += 1
                if self.frameCount >= Self.maxFrames { self.finish() }
            }
        }
        observer = obs
        CFRunLoopAddObserver(CFRunLoopGetMain(), obs, .commonModes)
        // 触发点也记一帧，作为「变更前」基准
        samples.append(snapshot())
    }

    private func finish() {
        if let observer {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
        }
        observer = nil
        // 只打印状态确实变了的帧，避免 90 行噪声。
        // 比较时去掉行首时间戳——否则每帧都算「不同」。
        var previousState = ""
        var body: [String] = []
        for (index, line) in samples.enumerated() {
            let state = line.replacingOccurrences(of: #"^\s*[\d.]+ms "#,
                                                 with: "",
                                                 options: .regularExpression)
            if state != previousState {
                body.append("[trace] #\(index) \(line)")
                previousState = state
            }
        }
        let out = """
        [trace] ===== \(label)（共 \(samples.count) 帧，只列变化点）=====
        \(body.joined(separator: "\n"))
        [trace] ===== end \(label) =====

        """
        FileHandle.standardError.write(out.data(using: .utf8) ?? Data())
    }

    // MARK: - 分段计时（排查主线程阻塞用）

    /// 静态只读开关，供非 MainActor 代码（如高亮器）打点用
    nonisolated static let marksEnabled =
        ProcessInfo.processInfo.environment["SWIFTDOWN_TRACE"] == "1"
        || CommandLine.arguments.contains("--trace-open")
        || CommandLine.arguments.contains("--trace")

    nonisolated(unsafe) private static var lastMark: CFTimeInterval = 0

    /// 打一个带相对耗时的点。只在 trace 模式输出，正常路径是空操作。
    nonisolated static func mark(_ label: String) {
        guard marksEnabled else { return }
        let now = CACurrentMediaTime()
        let delta = lastMark == 0 ? 0 : (now - lastMark) * 1000
        lastMark = now
        let line = String(format: "[trace] mark %7.2fms (Δ%7.2fms) %@\n", now, delta, label)
        FileHandle.standardError.write(line.data(using: .utf8) ?? Data())
    }

    // MARK: - 采样

    private func snapshot() -> String {
        let ms = (CACurrentMediaTime() - t0) * 1000
        guard let window = mainWindow() else {
            return String(format: "%6.1fms window=nil active=%d", ms, NSApp.isActive ? 1 : 0)
        }

        let editor = findEditor(in: window.contentView)
        let editorDesc: String
        if let editor {
            editorDesc = "editor=\(Unmanaged.passUnretained(editor).toOpaque())"
                + " inWindow=\(editor.window != nil ? 1 : 0)"
                + " w=\(Int(editor.frame.width))"
                + " chars=\((editor.string as NSString).length)"
        } else {
            editorDesc = "editor=nil"
        }

        return String(
            format: "%6.1fms win#%d alpha=%.2f vis=%d key=%d main=%d occ=%lu frm=%.0fx%.0f active=%d windows=%d px=%@ %@",
            ms,
            window.windowNumber,
            window.alphaValue,
            window.isVisible ? 1 : 0,
            window.isKeyWindow ? 1 : 0,
            window.isMainWindow ? 1 : 0,
            window.occlusionState.rawValue,
            window.frame.width, window.frame.height,
            NSApp.isActive ? 1 : 0,
            NSApp.windows.count,
            centerPixel(window),
            editorDesc
        )
    }

    /// 采样内容区中心与左上角（正文起始处）的像素颜色。
    /// 用来判断「那一帧到底画的是空白，还是已经画上了新文档」——
    /// 窗口属性看不出白闪，只有像素能。
    private func centerPixel(_ window: NSWindow) -> String {
        guard let view = window.contentView, view.bounds.width > 20 else { return "-" }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return "-" }
        view.cacheDisplay(in: view.bounds, to: rep)
        let midX = Int(view.bounds.midX)
        let midY = Int(view.bounds.midY)
        let editorX = min(Int(view.bounds.width * 0.30), Int(view.bounds.width) - 1)
        let editorY = min(Int(view.bounds.height * 0.30), Int(view.bounds.height) - 1)
        let c1 = rep.colorAt(x: midX, y: midY)
        let c2 = rep.colorAt(x: editorX, y: editorY)
        return "\(luma(c1))/\(luma(c2))"
    }

    /// 平均亮度：白闪会表现为 1.00，正常文本背景下约 0.95~0.99（浅色）或 0.1~0.2（深色）
    private func luma(_ color: NSColor?) -> String {
        guard let rgb = color?.usingColorSpace(.deviceRGB) else { return "-" }
        let value = (rgb.redComponent + rgb.greenComponent + rgb.blueComponent) / 3
        return String(format: "%.2f", value)
    }

    private func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.contentView != nil && !($0 is NSPanel) }
    }

    private func findEditor(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let textView = view as? NSTextView { return textView }
        for sub in view.subviews {
            if let found = findEditor(in: sub) { return found }
        }
        return nil
    }
}
