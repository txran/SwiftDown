import Foundation

/// 标签会话持久化（FR-05：退出保存标签列表与路径，下次启动恢复）
struct PersistedSession: Codable, Equatable {
    var tabPaths: [String]
    var activePath: String?
    /// 上次退出时每篇文档的视图模式（全文同一模式，M1 简化）
    var viewMode: String?

    static let empty = PersistedSession(tabPaths: [], activePath: nil, viewMode: nil)
}

final class SessionStore {

    private let fileURL: URL

    /// - Parameter directory: 自定义存放目录。自检传临时目录——否则跑一次自检就会把
    ///   用户真实的会话文件替换成临时路径，下次启动「恢复上次会话」全部指向已删除的文件。
    init(directory: URL? = nil) {
        let dir: URL
        if let directory {
            dir = directory
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                   in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            dir = support.appendingPathComponent("SwiftDown", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("session.json")
    }

    func load() -> PersistedSession {
        guard let data = try? Data(contentsOf: fileURL) else { return .empty }
        return (try? JSONDecoder().decode(PersistedSession.self, from: data)) ?? .empty
    }

    func save(_ session: PersistedSession) {
        // 同步原子写：会话文件只有几百字节，写入 <1ms；
        // 改成后台异步会引入「退出时进程先死、最后一次状态丢失」的竞态（FR-05 会话恢复）。
        guard let data = try? JSONEncoder().encode(session) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
