import AppKit
import Darwin

/// 冷启动时间线探针 + 主线程阻塞看门狗。
///
/// 为什么需要它：既有探针（OpenTrace 帧采样 / TraceEvents 通知）都跑在**主线程**上。
/// 主线程一旦卡住，这些探针自己也不出字——日志里只留下一个「空档」，
/// 无法区分以下三种完全不同的情况：
///   ① 主线程真的被阻塞了 N 秒（用户看到的是转圈/无响应）；
///   ② 主线程空闲，只是没有任何事件可记（空档是假象）；
///   ③ 进程还没跑到探针安装点（空档在启动早期，属于 dyld/LaunchServices）。
///
/// 本探针的两个设计要点：
///   1. 时间基准取内核记录的**进程启动时刻**（`proc_pidinfo`），不是静态初始化时刻。
///      这样才能把「进程被 fork 之后到我们第一行代码」那段也算进时间线。
///   2. 看门狗跑在**独立线程**上，用「主队列往返」测心跳；主线程卡住时它照样能写字，
///      并且能从另一个线程读主线程的程序计数器（`thread_get_state`）反查卡在哪个函数。
///
/// 仅在 trace 开关打开时启用，正常使用零开销。
enum LaunchProbe {

    nonisolated static let enabled: Bool = TraceLog.isOn
        || ProcessInfo.processInfo.environment["SWIFTDOWN_TRACE"] == "1"
        || CommandLine.arguments.contains("--trace")
        || CommandLine.arguments.contains("--trace-open")

    /// 进程被 exec 的绝对时刻（墙钟秒）。取自 kernel，而非 `Date()` 首次调用。
    nonisolated static let processStartWall: TimeInterval = {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        let got = proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0,
                               &info, Int32(size))
        guard got == Int32(size) else { return 0 }
        return TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000
    }()

    /// 启动至今毫秒数
    nonisolated static var elapsedMS: Double {
        guard processStartWall > 0 else { return 0 }
        return (Date().timeIntervalSince1970 - processStartWall) * 1000
    }

    nonisolated(unsafe) private static var started = false

    /// 打一个时间点。标签自带「启动后 +Nms」，可以和 shell 侧测到的耗时直接对齐。
    nonisolated static func mark(_ label: String) {
        guard enabled else { return }
        let ms = elapsedMS
        let wall = Date().timeIntervalSince1970
        let line = String(format: "[launch] +%7.1fms t=%.3f %@\n", ms, wall, label)
        TraceLog.write(line)
    }

    // MARK: - 首帧

    nonisolated(unsafe) private static var firstDrawObserver: NSObjectProtocol?

    /// 记下「窗口第一次真正绘制完成」的时刻。这是用户能看见画面的最早时点，
    /// 与它之前的空档意味着「启动慢」，之后的空档才是「启动后卡住」。
    @MainActor
    static func markFirstWindowDraw() {
        guard enabled, firstDrawObserver == nil else { return }
        firstDrawObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification, object: nil, queue: .main
        ) { _ in
            mark("窗口首帧绘制完成")
            if let observer = firstDrawObserver {
                NotificationCenter.default.removeObserver(observer)
                firstDrawObserver = nil
            }
        }
    }

    // MARK: - 看门狗

    nonisolated(unsafe) private static var mainThreadPort: mach_port_t = 0

    /// 必须在主线程调用：记下主线程的 mach port 供跨线程采样
    nonisolated static func startWatchdog() {
        guard enabled, !started else { return }
        started = true
        mainThreadPort = mach_port_t(pthread_mach_thread_np(pthread_self()))

        let thread = Thread {
            // 只观察启动后的前 90 秒：冷启动问题都在这段里
            let deadline = Date().addingTimeInterval(90)
            while Date() < deadline {
                let begin = CACurrentMediaTime()
                let sem = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { sem.signal() }
                if sem.wait(timeout: .now() + 0.4) == .timedOut {
                    var hits: [String: Int] = [:]
                    var waited = 400.0
                    // 主线程真卡住了：持续采样它执行到哪，直到主队列恢复应答
                    while true {
                        hits[sampleMainThreadPC(), default: 0] += 1
                        let probe = DispatchSemaphore(value: 0)
                        DispatchQueue.main.async { probe.signal() }
                        if probe.wait(timeout: .now() + 0.1) == .success { break }
                        waited += 100
                        if waited > 180_000 { break }
                    }
                    let total = (CACurrentMediaTime() - begin) * 1000
                    let top = hits.sorted { $0.value > $1.value }
                        .prefix(4)
                        .map { "\($0.key)×\($0.value)" }
                        .joined(separator: " | ")
                    let line = String(
                        format: "[launch] +%7.1fms ⚠️ 主线程阻塞 %.0fms  热点：%@\n",
                        elapsedMS, total, top
                    )
                    TraceLog.write(line)
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        thread.name = "SwiftDown.LaunchProbe"
        thread.start()
    }

    /// 从后台线程读主线程的 PC，再反查符号。只用于诊断，读不到就返回 unknown。
    nonisolated private static func sampleMainThreadPC() -> String {
        guard mainThreadPort != 0 else { return "unknown" }
        #if arch(arm64)
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<UInt32>.size
        )
        let result = withUnsafeMutablePointer(to: &state) { pointer in
            pointer.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                thread_get_state(mainThreadPort, thread_state_flavor_t(6), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return "unknown(\(result))" }
        let pc = UInt(state.__pc)
        #else
        var state = x86_thread_state64_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<x86_thread_state64_t>.size / MemoryLayout<UInt32>.size
        )
        let result = withUnsafeMutablePointer(to: &state) { pointer in
            pointer.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                thread_get_state(mainThreadPort, thread_state_flavor_t(6), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return "unknown(\(result))" }
        let pc = UInt(state.__rip)
        #endif
        return symbolName(for: pc)
    }

    nonisolated private static func symbolName(for address: UInt) -> String {
        guard let pointer = UnsafeRawPointer(bitPattern: address) else { return "pc=0" }
        var info = Dl_info()
        guard dladdr(pointer, &info) != 0 else { return String(format: "0x%llx", address) }
        let image = info.dli_fname.map { URL(fileURLWithPath: String(cString: $0)).lastPathComponent }
            ?? "?"
        let symbol = info.dli_sname.map { String(cString: $0) } ?? "?"
        return "\(image):\(symbol)"
    }
}
