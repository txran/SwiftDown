import AppKit

/// 探针输出通道。
///
/// 为什么需要写文件：探针测试必须让系统（LaunchServices）正常启动 app，
/// 这样「从访达打开文件」的事件才会真正投递；而从终端直接跑二进制虽然能拿到 stderr，
/// 进程却不是 LS 管理的会话，`open -a` 会给它发事件失败（-1712 超时），复现不了真实场景。
enum TraceLog {

    /// 探针开关：一个标记文件。为什么用文件而不是参数/环境变量——
    /// 复现「从访达打开文件」必须让 LaunchServices 启动 app，而 `open --args` 在这里不可靠、
    /// `launchctl setenv` 又需要特权。放一个标记文件是最稳的方式，用完删掉即彻底关闭。
    nonisolated static let switchPath = "/tmp/swiftdown-trace.on"

    /// 启动时判一次就缓存，避免每次视图求值都做文件系统检查
    nonisolated static let isOn: Bool = FileManager.default.fileExists(atPath: switchPath)

    nonisolated static let filePath: String? = {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--trace-file"), args.count > index + 1 {
            return args[index + 1]
        }
        if let env = ProcessInfo.processInfo.environment["SWIFTDOWN_TRACE_FILE"] { return env }
        if isOn { return "/tmp/swiftdown-trace.log" }
        return nil
    }()

    nonisolated static func write(_ text: String) {
        let data = Data(text.utf8)
        guard let path = filePath else {
            FileHandle.standardError.write(data)
            return
        }
        let url = URL(fileURLWithPath: path)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}

/// 打开文件期间的「事件级」探针：窗口排序、应用激活、窗口尺寸/屏幕变化。
///
/// 帧像素采样（OpenTrace）能看出「有没有白帧」，但看不出**窗口是不是被移出再放回**。
/// 「像关闭又重开」这种观感，最直接的证据是窗口收到 didOrderOffScreen / didOrderOnScreen，
/// 或者窗口被重新 makeKey 且伴随 frame 变化。这里只订阅通知，不改任何状态。
///
/// 仅 `--trace` / `SWIFTDOWN_TRACE=1` 时安装，正常使用零开销。
@MainActor
enum TraceEvents {

    nonisolated static let enabled: Bool =
        ProcessInfo.processInfo.environment["SWIFTDOWN_TRACE"] == "1"
        || CommandLine.arguments.contains("--trace")
        || CommandLine.arguments.contains("--trace-open")
        || TraceLog.isOn

    private static var installed = false

    static func install() {
        guard enabled, !installed else { return }
        installed = true
        log("install")

        let nc = NotificationCenter.default
        let pairs: [(Notification.Name, String)] = [
            (NSWindow.didBecomeKeyNotification, "window didBecomeKey"),
            (NSWindow.didResignKeyNotification, "window didResignKey"),
            (NSWindow.didBecomeMainNotification, "window didBecomeMain"),
            (NSWindow.didResignMainNotification, "window didResignMain"),
            (NSWindow.didChangeScreenNotification, "window didChangeScreen"),
            (NSWindow.didChangeOcclusionStateNotification, "window occlusion"),
            (NSApplication.didBecomeActiveNotification, "app didBecomeActive"),
            (NSApplication.didResignActiveNotification, "app didResignActive"),
            (NSApplication.didHideNotification, "app didHide"),
            (NSApplication.didUnhideNotification, "app didUnhide"),
        ]
        for (name, label) in pairs {
            nc.addObserver(forName: name, object: nil, queue: .main) { note in
                MainActor.assumeIsolated {
                    var extra = ""
                    if let w = note.object as? NSWindow {
                        extra = String(format: " win#%d %@ alpha=%.2f key=%d vis=%d",
                                       w.windowNumber,
                                       NSStringFromRect(w.frame),
                                       w.alphaValue,
                                       w.isKeyWindow ? 1 : 0,
                                       w.isVisible ? 1 : 0)
                        // 窗口被移出屏幕的瞬间抓调用栈：定位是谁做的 orderOut
                        if w.isVisible == false {
                            extra += "\n" + Thread.callStackSymbols.prefix(28).joined(separator: "\n")
                        }
                    }
                    log(label + extra)
                }
            }
        }
    }

    /// 统一带上单调时钟，便于和 OpenTrace 的 mark 对齐
    nonisolated static func log(_ message: String) {
        guard enabled else { return }
        let line = String(format: "[event] %8.2fms %@\n", CACurrentMediaTime() * 1000, message)
        TraceLog.write(line)
    }
}
