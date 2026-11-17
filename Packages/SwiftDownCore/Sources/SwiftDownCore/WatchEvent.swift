import Foundation

/// 外部变更事件。FileWatcher（基础设施层）完成防抖合并与 hash 自写去噪后，
/// 将携带完整数据的事件投递给 DocumentSession，Core 层不做 IO。
public enum WatchEvent: Equatable {
    /// 文件内容被外部修改（已去噪：非本应用自写）
    case contentChanged(DiskVersion)
    /// 文件被重命名/移动，Infra 已解析出新路径（PRD「自动跟随移动」）
    case renamed(to: URL)
    /// 文件被删除或移动后无法解析新路径
    case deleted
}

/// 冲突三选一（FR-06）：保留我的 / 采用磁盘版 / 另存副本
public enum ConflictChoice: Equatable {
    case keepMine
    case useDisk
    case saveCopy(URL)
}
