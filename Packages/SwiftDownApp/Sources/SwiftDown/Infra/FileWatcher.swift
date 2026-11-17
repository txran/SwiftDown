import Foundation
import SwiftDownCore

/// 文件外部变更监控（设计文档 §5.2）：
/// vnode 监听 → 500ms 合并防抖 → 读盘算 hash → 与「已知版本」比对去噪 → 投递 WatchEvent。
///
/// 去噪必要性：本应用自己的原子写会替换 inode，触发 delete/rename 事件；
/// 通过「自写后重建监听 + 已知 hash 比对」双重手段，避免自写被误判为外部变更。
final class FileWatcher {

    /// 诊断日志：SWIFTDOWN_DEBUG=1 或 --selftest 时开启
    static let debugEnabled = CommandLine.arguments.contains("--selftest")
        || ProcessInfo.processInfo.environment["SWIFTDOWN_DEBUG"] == "1"

    private static func log(_ message: String) {
        guard debugEnabled else { return }
        print("[watcher] \(message)")
    }

    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var debounceWork: DispatchWorkItem?

    private(set) var url: URL
    private let onChange: (WatchEvent) -> Void
    private let store = DiskFileStore()

    /// 已知磁盘内容 hash（自写后更新，用于区分「我的写」与「别人的写」）
    private var knownHash: String
    /// 自写后的静默窗，窗口内事件直接丢弃
    private var suppressUntil = Date.distantPast
    /// 合并防抖窗口：500ms（PRD FR-06 要求 ≤1s 内重载）
    private let debounceInterval: TimeInterval = 0.5

    init(url: URL, content: String, onChange: @escaping (WatchEvent) -> Void) {
        self.url = url
        self.onChange = onChange
        self.knownHash = FileHash.of(content)
        startWatching()
    }

    deinit {
        source?.cancel()
        if fileDescriptor >= 0 { close(fileDescriptor) }
    }

    func stop() {
        debounceWork?.cancel()
        debounceWork = nil
        // fd 由 cancel handler 负责关闭（它捕获了创建时的局部 fd）。
        // 这里绝不能直接 close(self.fileDescriptor)——重启监听时该字段已指向新 fd，
        // 晚到的 cancel handler 会把新 fd 一起关掉，导致后续事件全部丢失。
        if let src = source {
            source = nil
            if !src.isCancelled { src.cancel() }
        }
        fileDescriptor = -1
    }

    /// 自写落盘后调用：更新已知 hash + 重建监听（原子写会换 inode）+ 开启静默窗
    func noteSelfWrite(content: String) {
        Self.log("自写落盘，更新已知 hash")
        knownHash = FileHash.of(content)
        suppressUntil = Date().addingTimeInterval(0.4)
        restart()
    }

    /// 会话重定向（另存副本/重定位）后重建监听
    func retarget(url newURL: URL, content: String) {
        url = newURL
        knownHash = FileHash.of(content)
        suppressUntil = Date().addingTimeInterval(0.4)
        restart()
    }

    // MARK: - 监听

    private func startWatching() {
        stop()
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            Self.log("open 失败：\(url.path)")
            return  // 文件已不存在，等下一次 retarget
        }
        fileDescriptor = fd
        Self.log("开始监听 \(url.lastPathComponent) fd=\(fd)")

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename, .attrib],
            queue: .main
        )
        src.setEventHandler { [weak self] in
            guard let self, let src = self.source else { return }
            let flags = src.data
            Self.log("收到事件 flags=\(flags.rawValue)")
            if flags.contains(.delete) || flags.contains(.rename) {
                // 原子写也会走到这里：延迟到防抖窗后再判定文件是否真的没了
                self.scheduleResolve(expectContentChange: true)
            } else {
                self.scheduleResolve(expectContentChange: true)
            }
        }
        // 关闭的是本 source 创建时的 fd（局部捕获），与后续重启无关
        src.setCancelHandler {
            close(fd)
        }
        source = src
        src.resume()
    }

    private func restart() {
        startWatching()
    }

    private func scheduleResolve(expectContentChange: Bool) {
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.resolve()
        }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    private func resolve() {
        guard Date() >= suppressUntil else {
            Self.log("静默窗内，忽略")
            return
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            // 文件不见了：先尝试在父目录找同内容迁移（重命名/移动）
            if let moved = findRenamedSibling() {
                url = moved
                restart()
                onChange(.renamed(to: moved))
            } else {
                stop()
                Self.log("→ 投递 deleted")
                onChange(.deleted)
            }
            return
        }

        guard let content = try? store.load(from: url) else {
            Self.log("读取失败")
            return
        }
        let hash = FileHash.of(content)
        Self.log("resolve hash=\(hash) known=\(knownHash)")
        guard hash != knownHash else {
            // 内容没变（自写事件的尾随 / 仅属性变更）：重建监听即可
            restart()
            return
        }

        knownHash = hash
        restart()
        Self.log("→ 投递 contentChanged")
        onChange(.contentChanged(DiskVersion(content: content,
                                             hash: hash,
                                             mtime: fileModificationDate() ?? Date())))
    }

    private func fileModificationDate() -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// 重命名/移动兜底解析：父目录内找同大小 + 同内容 hash 的 .md 文件
    private func findRenamedSibling() -> URL? {
        let directory = url.deletingLastPathComponent()
        let originalSize = DiskFileStore.fileSize(at: url)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        for candidate in entries where candidate != url {
            let ext = candidate.pathExtension.lowercased()
            guard ["md", "markdown", "mdown", "mkd", "txt"].contains(ext) else { continue }
            guard let size = try? candidate.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size == originalSize else { continue }
            guard let content = try? store.load(from: candidate) else { continue }
            if FileHash.of(content) == knownHash { return candidate }
        }
        return nil
    }
}
