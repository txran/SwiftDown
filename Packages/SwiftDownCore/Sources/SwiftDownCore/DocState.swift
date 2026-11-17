import Foundation

/// 文档标签状态机（PRD §九）。迁移单向，禁止回跳。
public enum DocState: Equatable {
    /// 会话恢复时文件缺失的占位标签（EX-06），reason 为展示文案
    case placeholder(reason: String)
    /// 已加载，内存与磁盘一致
    case clean
    /// 内存与磁盘不一致（未保存）
    case dirty
    /// 冲突待决：内存脏 + 外部磁盘变更（FR-06 / EX-04），携带磁盘版本快照
    case conflict(DiskVersion)
    /// 失联：文件被移动/删除（EX-05），内存副本保留
    case missing
}

/// 磁盘版本快照：冲突三选一时「采用磁盘版」的数据源
public struct DiskVersion: Equatable {
    public let content: String
    public let hash: String
    public let mtime: Date

    public init(content: String, hash: String, mtime: Date = Date()) {
        self.content = content
        self.hash = hash
        self.mtime = mtime
    }
}
