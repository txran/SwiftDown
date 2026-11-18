import Foundation

/// 保存/IO 错误（EX-03 场景），UI 层负责弹窗。Core 层保证错误时内存副本不丢。
public enum CoreError: Error, Equatable {
    case saveFailed(reason: String)   // 磁盘满/权限失效
    case loadFailed(reason: String)   // 读取失败
    case invalidTransition            // 防御：非法迁移被拒绝
}

/// 会话对外事件（UI 桥接层订阅，用于弹窗/重渲染/日志）
public enum SessionEvent: Equatable {
    case stateChanged(DocState)
    case reloadedSilently             // 静默重载完成（FR-06）
    case error(CoreError)
    case saved                        // 落盘成功

    public static func == (lhs: SessionEvent, rhs: SessionEvent) -> Bool {
        switch (lhs, rhs) {
        case (.stateChanged(let a), .stateChanged(let b)): return a == b
        case (.reloadedSilently, .reloadedSilently): return true
        case (.saved, .saved): return true
        case (.error(let a), .error(let b)): return a == b
        default: return false
        }
    }
}

/// 单文件事实源（设计文档 §4.1）。
/// 纯逻辑无 UI 依赖；App 层用 ObservableObject 包装此实例。
///
/// 状态迁移仲裁表（PRD §九，禁止回跳）：
///   clean  + 编辑          → dirty
///   dirty  + 保存成功       → clean
///   dirty  + 外部变更       → conflict
///   clean  + 外部变更       → clean（静默重载）
///   任意   + 移动/删除      → missing（内存副本保留）
///   conflict/missing + 用户决策 → clean / dirty
public final class DocumentSession {

    public let id: UUID
    public private(set) var url: URL
    public private(set) var state: DocState

    /// 源码缓冲（M1 为 String 后端；Rope 优化在 EditorKit 落地，接口不变）
    public private(set) var buffer: String

    /// 失联前是否有未保存修改（决定 relocate 后落点）
    private var hasUnsavedEdits: Bool

    private let store: FileStoring
    private let scheduler: AutoSaveScheduling
    private let autoSaveDelay: TimeInterval

    /// 事件订阅（UI 桥接）。主线程调用。
    public var onEvent: ((SessionEvent) -> Void)?

    /// 自动保存静默窗口（FR-04：2s）
    private static let defaultAutoSaveDelay: TimeInterval = 2.0

    public init(url: URL,
                store: FileStoring,
                scheduler: AutoSaveScheduling = DispatchAutoSaveScheduler(),
                autoSaveDelay: TimeInterval = 2.0) throws {
        self.id = UUID()
        self.url = url
        self.store = store
        self.scheduler = scheduler
        self.autoSaveDelay = autoSaveDelay
        let content = try store.load(from: url)
        self.buffer = content
        self.state = .clean
        self.hasUnsavedEdits = false
    }

    /// 内容已经读出来的构造路径（异步读盘专用）。
    ///
    /// 为什么单独开门：`init(url:store:)` 会在构造过程中读盘，调用方若在主线程调用，
    /// 就把文件系统阻塞搬到了 UI 线程上——实测冷启动时一次 `open(2)` 能被系统拖到 5 秒以上。
    /// 把读盘交给调用方的后台队列，这里**不碰文件系统**，主线程只负责装配对象。
    public init(url: URL,
                content: String,
                store: FileStoring,
                scheduler: AutoSaveScheduling = DispatchAutoSaveScheduler(),
                autoSaveDelay: TimeInterval = 2.0) {
        self.id = UUID()
        self.url = url
        self.store = store
        self.scheduler = scheduler
        self.autoSaveDelay = autoSaveDelay
        self.buffer = content
        self.state = .clean
        self.hasUnsavedEdits = false
    }

    /// 会话恢复时文件缺失 → 占位标签（EX-06）
    public static func placeholder(url: URL, reason: String) -> DocumentSession {
        DocumentSession(url: url, buffer: "", state: .placeholder(reason: reason))
    }

    /// 失联/占位恢复用（内存副本保留场景），包内构造
    init(url: URL, buffer: String, state: DocState) {
        self.id = UUID()
        self.url = url
        self.buffer = buffer
        self.state = state
        self.hasUnsavedEdits = (state == .dirty)
        self.store = MemoryFileStore()
        self.scheduler = DispatchAutoSaveScheduler()
        self.autoSaveDelay = DocumentSession.defaultAutoSaveDelay
    }

    // MARK: - 编辑（编辑器唯一写入口）

    /// FR-04：编辑输入 → dirty + 防抖自动保存
    public func applyEdit(_ newBuffer: String) {
        guard isEditable else { return }  // conflict/missing/placeholder 期间冻结编辑，等用户决策
        buffer = newBuffer
        hasUnsavedEdits = true
        transition(to: .dirty)
        scheduler.schedule(delay: autoSaveDelay) { [weak self] in
            self?.saveNow(trigger: .auto)
        }
    }

    // MARK: - 保存

    public enum SaveTrigger { case auto, manual, forceFlush }

    /// 手动/自动/强制落盘。成功 → clean；失败 → 保持原状态，内存副本不丢（EX-03）。
    ///
    /// 冲突期间禁止落盘：此时磁盘已有他人版本，任何自动/手动保存都等于静默覆盖一方，
    /// 直接违反 FR-06「禁止静默覆盖任一方」。唯一合法写盘路径是用户做出决策后的
    /// `resolveConflict(.keepMine)`，它走 `writeToDisk()` 绕过本守卫。
    @discardableResult
    public func saveNow(trigger: SaveTrigger = .manual) -> Bool {
        guard !isConflictState else {
            // 冲突期自动保存必然失败，且每 2s 触发一次；若每次都 emit 错误，
            // UI 会不停重建弹窗（实测表现为「弹窗关不掉 + 窗口转圈」）。
            // 冲突本身已有横幅与待决提示，只有用户显式保存才需要报错。
            if case .auto = trigger {
                return false
            }
            emit(.error(.saveFailed(reason: "存在未决的外部修改冲突，请先处理冲突再保存")))
            return false
        }
        return writeToDisk()
    }

    /// 真正写盘的唯一实现（内部使用，调用方负责状态前置判断）
    @discardableResult
    private func writeToDisk() -> Bool {
        guard state != .missing, !isPlaceholderState else {
            emit(.error(.saveFailed(reason: "文件失联，无法保存")))
            return false
        }
        do {
            try store.save(buffer, to: url)
            scheduler.cancel()
            hasUnsavedEdits = false
            transition(to: .clean)
            emit(.saved)
            return true
        } catch {
            // 失败路径：状态不变（dirty/conflict），绝不静默丢内存（NFR-03）
            emit(.error(.saveFailed(reason: String(describing: error))))
            return false
        }
    }

    /// FR-04：切标签/失焦/关闭标签前的强制落盘（App 层在 willResignActive 等时机调用）
    /// 冲突/失联态不做落盘——这些状态下写盘会覆盖他人版本或写到不存在的路径。
    @discardableResult
    public func flushBeforeDeactivation() -> Bool {
        guard hasUnsavedEdits else { return true }
        guard !isConflictState, state != .missing, !isPlaceholderState else { return false }
        return writeToDisk()
    }

    /// 标签关闭拦截判断（FR-05）：true 时 UI 必须弹三选一
    public var requiresCloseConfirmation: Bool {
        hasUnsavedEdits || isConflictState
    }

    private var isConflictState: Bool {
        if case .conflict = state { return true }
        return false
    }

    // MARK: - 外部变更仲裁（FileWatcher 已防抖去噪）

    public func externalChange(_ event: WatchEvent) {
        switch event {
        case .contentChanged(let disk):
            switch state {
            case .clean:
                // PRD：无未保存编辑 → 静默重载，无弹窗（FR-06 验收）
                buffer = disk.content
                hasUnsavedEdits = false
                emit(.reloadedSilently)
                emit(.stateChanged(.clean))
            case .dirty:
                // 有未保存编辑 → 冲突待决，内存不丢
                transition(to: .conflict(disk))
            case .conflict:
                // 冲突期间磁盘又变：仅更新快照，维持 conflict（禁止回跳/静默决策）
                transition(to: .conflict(disk))
            case .missing, .placeholder:
                break  // 逻辑上不应出现，防御性忽略
            }

        case .renamed(let newURL):
            // 自动跟随移动：更新路径，状态保持（PRD FR-06「移动」的优雅路径）
            url = newURL
            emit(.stateChanged(state))

        case .deleted:
            // 任意态 → 失联；内存副本保留可复制（EX-05）
            transition(to: .missing)
        }
    }

    // MARK: - 用户决策入口

    /// 冲突三选一（FR-06 / EX-04）
    public func resolveConflict(_ choice: ConflictChoice) {
        guard case .conflict(let disk) = state else {
            emit(.error(.invalidTransition))
            return
        }
        switch choice {
        case .useDisk:
            buffer = disk.content
            hasUnsavedEdits = false
            scheduler.cancel()
            transition(to: .clean)
        case .keepMine:
            // 保留我的 = 立即用内存版覆盖磁盘；失败则维持冲突等用户重试
            if writeToDisk() {
                // writeToDisk 内部已迁移 clean
            } else {
                transition(to: .conflict(disk))
            }
        case .saveCopy(let copyURL):
            // 另存副本：内存版写入新路径，会话重定向；原磁盘文件保持不动
            do {
                try store.save(buffer, to: copyURL)
                url = copyURL
                hasUnsavedEdits = false
                scheduler.cancel()
                transition(to: .clean)
                emit(.saved)
            } catch {
                emit(.error(.saveFailed(reason: String(describing: error))))
                transition(to: .conflict(disk))
            }
        }
    }

    /// 失联重定位（EX-05「重新定位文件」入口）
    public func relocate(to newURL: URL) throws {
        guard state == .missing else {
            emit(.error(.invalidTransition))
            return
        }
        let diskContent: String
        do {
            diskContent = try store.load(from: newURL)
        } catch {
            throw CoreError.loadFailed(reason: String(describing: error))
        }
        url = newURL
        if !hasUnsavedEdits || diskContent == buffer {
            // 干净失联 → 接管磁盘版；或内容本就一致
            buffer = diskContent
            hasUnsavedEdits = false
            transition(to: .clean)
        } else {
            // 脏失联 → 保留内存修改，等待保存覆盖
            transition(to: .dirty)
        }
    }

    /// 占位标签被用户重新打开/定位后激活（EX-06）
    public func activate(url newURL: URL, store: FileStoring) throws {
        guard isPlaceholderState else {
            emit(.error(.invalidTransition))
            return
        }
        let content = try store.load(from: newURL)
        url = newURL
        buffer = content
        hasUnsavedEdits = false
        transition(to: .clean)
    }

    // MARK: - 状态判断

    public var isEditable: Bool {
        switch state {
        case .clean, .dirty: return true
        case .conflict, .missing, .placeholder: return false
        }
    }

    private var isPlaceholderState: Bool {
        if case .placeholder = state { return true }
        return false
    }

    // MARK: - 内部

    private func transition(to new: DocState) {
        guard state != new else { return }
        state = new
        emit(.stateChanged(new))
    }

    private func emit(_ event: SessionEvent) {
        onEvent?(event)
    }
}

/// 测试/失联恢复用内存实现
public final class MemoryFileStore: FileStoring {
    private var files: [URL: String] = [:]

    public init() {}

    public func load(from url: URL) throws -> String {
        guard let content = files[url] else {
            throw CoreError.loadFailed(reason: "文件不存在: \(url.path)")
        }
        return content
    }

    public func save(_ content: String, to url: URL) throws {
        files[url] = content
    }

    public func seed(_ content: String, at url: URL) {
        files[url] = content
    }

    public func remove(at url: URL) {
        files.removeValue(forKey: url)
    }

    public func content(at url: URL) -> String? {
        files[url]
    }
}
