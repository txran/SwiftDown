import Foundation

/// 文件存储协议：域层只依赖此抽象，测试注入内存实现。
/// save 必须原子写（temp + rename），由实现方保证。
public protocol FileStoring: AnyObject {
    /// 读取文件内容。成功返回内容；失败抛错（文件缺失/编码错误等）。
    func load(from url: URL) throws -> String
    /// 原子写入。失败抛错（磁盘满/权限失效，EX-03）。
    func save(_ content: String, to url: URL) throws
}

/// 自动保存调度协议：内容变更后静默 2s 落盘（FR-04）。
/// 生产实现基于 DispatchWorkItem；测试注入手动触发实现。
public protocol AutoSaveScheduling: AnyObject {
    /// 安排/重设 2s 防抖保存
    func schedule(delay: TimeInterval, action: @escaping () -> Void)
    /// 取消未触发的保存（标签关闭、手动保存后）
    func cancel()
}

/// 生产调度器：DispatchQueue 主队列防抖。
public final class DispatchAutoSaveScheduler: AutoSaveScheduling {
    private var workItem: DispatchWorkItem?

    public init() {}

    public func schedule(delay: TimeInterval, action: @escaping () -> Void) {
        workItem?.cancel()
        let item = DispatchWorkItem(block: action)
        workItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    public func cancel() {
        workItem?.cancel()
        workItem = nil
    }
}
