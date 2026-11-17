import Foundation
import Testing
@testable import SwiftDownCore

// MARK: - 测试替身

/// 手动触发的调度器：验证 AutoSave 时序（注入 fake clock，见设计文档 §11）
final class FakeScheduler: AutoSaveScheduling {
    var pending: (() -> Void)?
    var lastDelay: TimeInterval?
    var scheduleCount = 0
    var cancelCount = 0

    func schedule(delay: TimeInterval, action: @escaping () -> Void) {
        pending = action
        lastDelay = delay
        scheduleCount += 1
    }
    func cancel() {
        pending = nil
        cancelCount += 1
    }
    func fire() {
        let action = pending
        pending = nil
        action?()
    }
}

/// 保存必失败的存储：验证 EX-03 内存不丢
final class FailingSaveStore: FileStoring {
    var files: [URL: String] = [:]
    var saveCallCount = 0

    init(initial: String, at url: URL) {
        files[url] = initial
    }
    func load(from url: URL) throws -> String {
        guard let c = files[url] else { throw CoreError.loadFailed(reason: "missing") }
        return c
    }
    func save(_ content: String, to url: URL) throws {
        saveCallCount += 1
        throw CoreError.saveFailed(reason: "磁盘已满(测试)")
    }
}

// MARK: - 状态机迁移表（PRD §九逐行覆盖）

@Suite("DocumentSession 状态机")
struct DocumentSessionTests {

    let url = URL(fileURLWithPath: "/tmp/docs/note.md")

    func makeStore() -> MemoryFileStore {
        let store = MemoryFileStore()
        store.seed("# Hello", at: url)
        return store
    }

    func makeSession(store: MemoryFileStore, scheduler: FakeScheduler) throws -> DocumentSession {
        store.seed("# Hello", at: url)
        return try DocumentSession(url: url, store: store, scheduler: scheduler, autoSaveDelay: 2.0)
    }

    // PRD 状态表行1：clean + 编辑 → dirty
    @Test("clean + 编辑 → dirty")
    func clean_edit_becomes_dirty() throws {
        let scheduler = FakeScheduler()
        let s = try makeSession(store: makeStore(), scheduler: scheduler)
        #expect(s.state == .clean)
        s.applyEdit("# Hello World")
        #expect(s.state == .dirty)
        #expect(s.requiresCloseConfirmation)
    }

    // 状态表行2：dirty + 保存成功 → clean
    @Test("dirty + 保存成功 → clean")
    func dirty_manual_save_becomes_clean() throws {
        let scheduler = FakeScheduler()
        let store = makeStore()
        let s = try makeSession(store: store, scheduler: scheduler)
        s.applyEdit("v2")
        s.saveNow(trigger: .manual)
        #expect(s.state == .clean)
        #expect(store.content(at: url) == "v2")
    }

    // 状态表行3：dirty + 外部变更 → conflict
    @Test("dirty + 外部变更 → conflict，内存不丢")
    func dirty_external_change_becomes_conflict() throws {
        let scheduler = FakeScheduler()
        let s = try makeSession(store: makeStore(), scheduler: scheduler)
        s.applyEdit("my edit")
        s.externalChange(.contentChanged(DiskVersion(content: "disk edit", hash: "h2")))
        guard case .conflict(let disk) = s.state else {
            Issue.record("应为 conflict，实际: \(s.state)")
            return
        }
        #expect(disk.content == "disk edit")
        #expect(s.buffer == "my edit", "决策前内存副本不丢（FR-06 验收）")
        #expect(!s.isEditable, "冲突期间应冻结编辑")
    }

    // 状态表行4：clean + 外部变更 → clean（静默重载）
    @Test("clean + 外部变更 → 静默重载")
    func clean_external_change_silent_reload() throws {
        let scheduler = FakeScheduler()
        let s = try makeSession(store: makeStore(), scheduler: scheduler)
        var reloaded = false
        s.onEvent = { if $0 == .reloadedSilently { reloaded = true } }
        s.externalChange(.contentChanged(DiskVersion(content: "disk v2", hash: "h2")))
        #expect(s.state == .clean)
        #expect(s.buffer == "disk v2")
        #expect(reloaded, "应发出静默重载事件（无弹窗路径）")
    }

    // 状态表行5：任意 + 删除 → missing，内存副本保留
    @Test("删除 → missing，内存副本保留（EX-05）")
    func any_delete_becomes_missing_memory_kept() throws {
        let scheduler = FakeScheduler()
        let s = try makeSession(store: makeStore(), scheduler: scheduler)
        s.applyEdit("unsaved memory")
        s.externalChange(.deleted)
        #expect(s.state == .missing)
        #expect(s.buffer == "unsaved memory")
    }

    // 状态表行6a：conflict + useDisk → clean
    @Test("冲突决策 useDisk → clean")
    func conflict_resolve_useDisk() throws {
        let scheduler = FakeScheduler()
        let s = try makeSession(store: makeStore(), scheduler: scheduler)
        s.applyEdit("my edit")
        s.externalChange(.contentChanged(DiskVersion(content: "disk edit", hash: "h2")))
        s.resolveConflict(.useDisk)
        #expect(s.state == .clean)
        #expect(s.buffer == "disk edit")
    }

    // 状态表行6b：conflict + keepMine → 落盘后 clean
    @Test("冲突决策 keepMine → 覆盖磁盘 → clean")
    func conflict_resolve_keepMine_overwrites_disk() throws {
        let scheduler = FakeScheduler()
        let store = makeStore()
        let s = try makeSession(store: store, scheduler: scheduler)
        s.applyEdit("my edit")
        s.externalChange(.contentChanged(DiskVersion(content: "disk edit", hash: "h2")))
        s.resolveConflict(.keepMine)
        #expect(s.state == .clean)
        #expect(store.content(at: url) == "my edit", "保留我的 = 内存版覆盖磁盘")
    }

    // 状态表行6c：conflict + saveCopy → 副本落盘，会话重定向 → clean
    @Test("冲突决策 saveCopy → 重定向 → clean")
    func conflict_resolve_saveCopy_redirects() throws {
        let scheduler = FakeScheduler()
        let store = makeStore()
        let s = try makeSession(store: store, scheduler: scheduler)
        s.applyEdit("my edit")
        s.externalChange(.contentChanged(DiskVersion(content: "disk edit", hash: "h2")))
        let copyURL = URL(fileURLWithPath: "/tmp/docs/note-copy.md")
        s.resolveConflict(.saveCopy(copyURL))
        #expect(s.state == .clean)
        #expect(s.url == copyURL, "会话应重定向到副本路径")
        #expect(store.content(at: copyURL) == "my edit")
        #expect(store.content(at: url) == "# Hello", "原文件不被触碰")
    }

    // 禁止回跳：conflict 期间再次外部变更，维持 conflict 且更新快照
    @Test("冲突期间磁盘再变 → 维持 conflict 更新快照（禁止回跳）")
    func conflict_no_backjump_on_repeated_change() throws {
        let scheduler = FakeScheduler()
        let s = try makeSession(store: makeStore(), scheduler: scheduler)
        s.applyEdit("mine")
        s.externalChange(.contentChanged(DiskVersion(content: "disk1", hash: "h1")))
        s.externalChange(.contentChanged(DiskVersion(content: "disk2", hash: "h2")))
        guard case .conflict(let disk) = s.state else {
            Issue.record("应维持 conflict")
            return
        }
        #expect(disk.content == "disk2", "快照应更新为最新磁盘版")
        #expect(s.buffer == "mine", "内存版不被覆盖")
    }

    // 非法迁移：非 conflict 态调用 resolveConflict 被拒绝
    @Test("非冲突态 resolveConflict 被拒绝")
    func resolve_conflict_rejected_when_not_conflicting() throws {
        let scheduler = FakeScheduler()
        let s = try makeSession(store: makeStore(), scheduler: scheduler)
        s.resolveConflict(.useDisk)
        #expect(s.state == .clean, "clean 态不应受 resolveConflict 影响")
    }

    // MARK: - FR-04 自动保存时序

    @Test("自动保存：静默 2s 落盘，编辑重设防抖")
    func autosave_flushes_after_2s_silence() throws {
        let scheduler = FakeScheduler()
        let store = makeStore()
        let s = try makeSession(store: store, scheduler: scheduler)
        s.applyEdit("a")
        #expect(scheduler.lastDelay == 2.0)
        s.applyEdit("ab")
        s.applyEdit("abc")
        #expect(scheduler.scheduleCount == 3, "每次编辑都应重设调度")
        #expect(s.state == .dirty, "静默窗口内不落盘")
        scheduler.fire()
        #expect(s.state == .clean)
        #expect(store.content(at: url) == "abc", "最终以最后一次输入为准")
    }

    @Test("手动保存后取消挂起的自动保存")
    func manual_save_cancels_pending_autosave() throws {
        let scheduler = FakeScheduler()
        let store = makeStore()
        let s = try makeSession(store: store, scheduler: scheduler)
        s.applyEdit("x")
        s.saveNow(trigger: .manual)
        #expect(scheduler.cancelCount == 1)
        #expect(scheduler.pending == nil, "手动保存后不应再有挂起的自动保存")
    }

    // MARK: - EX-03 保存失败：状态不变，内存不丢

    @Test("保存失败：状态不变，内存不丢（EX-03）")
    func save_failure_keeps_state_and_memory() throws {
        let scheduler = FakeScheduler()
        let failStore = FailingSaveStore(initial: "origin", at: url)
        let s = try DocumentSession(url: url, store: failStore, scheduler: scheduler)
        s.applyEdit("important edit")
        scheduler.fire()
        #expect(s.state == .dirty, "保存失败不得迁移状态")
        #expect(s.buffer == "important edit", "内存副本必须保留（禁止静默丢失）")
        #expect(failStore.saveCallCount == 1)
    }

    @Test("失焦强制落盘（FR-04）")
    func flush_before_deactivation_saves_dirty() throws {
        let scheduler = FakeScheduler()
        let store = makeStore()
        let s = try makeSession(store: store, scheduler: scheduler)
        s.applyEdit("before switch")
        #expect(s.flushBeforeDeactivation())
        #expect(s.state == .clean)
        #expect(store.content(at: url) == "before switch")
    }

    @Test("干净会话 flush 无副作用")
    func flush_clean_session_is_noop() throws {
        let scheduler = FakeScheduler()
        let s = try makeSession(store: makeStore(), scheduler: scheduler)
        #expect(s.flushBeforeDeactivation())
        #expect(s.state == .clean)
    }

    // MARK: - rename 自动跟随 + 失联重定位

    @Test("rename 自动跟随：更新路径，状态保持")
    func rename_follows_url_state_preserved() throws {
        let scheduler = FakeScheduler()
        let s = try makeSession(store: makeStore(), scheduler: scheduler)
        s.applyEdit("dirty content")
        let newURL = URL(fileURLWithPath: "/tmp/docs/moved.md")
        s.externalChange(.renamed(to: newURL))
        #expect(s.url == newURL)
        #expect(s.state == .dirty, "跟随移动不改保存状态")
    }

    @Test("失联重定位：内容一致 → clean（EX-05）")
    func missing_relocate_identical_content_clean() throws {
        let scheduler = FakeScheduler()
        let store = makeStore()
        let s = try makeSession(store: store, scheduler: scheduler)
        s.externalChange(.deleted)
        let newURL = URL(fileURLWithPath: "/tmp/docs/found.md")
        store.seed("# Hello", at: newURL)
        try s.relocate(to: newURL)
        #expect(s.state == .clean)
        #expect(s.url == newURL)
    }

    @Test("脏失联重定位：磁盘内容不同 → 保留内存 dirty")
    func missing_relocate_dirty_memory_kept() throws {
        let scheduler = FakeScheduler()
        let store = makeStore()
        let s = try makeSession(store: store, scheduler: scheduler)
        s.applyEdit("my unsaved work")
        s.externalChange(.deleted)
        let newURL = URL(fileURLWithPath: "/tmp/docs/found-different.md")
        store.seed("different on disk", at: newURL)
        try s.relocate(to: newURL)
        #expect(s.state == .dirty)
        #expect(s.buffer == "my unsaved work")
    }

    // MARK: - EX-06 占位标签

    @Test("占位标签：不可编辑，激活后 clean（EX-06）")
    func placeholder_state_and_activation() throws {
        let store = makeStore()
        let s = DocumentSession.placeholder(url: url, reason: "文件不存在")
        guard case .placeholder = s.state else {
            Issue.record("应为占位态")
            return
        }
        #expect(!s.isEditable)
        s.applyEdit("should be ignored")
        #expect(s.buffer.isEmpty, "占位态不接受编辑")

        let newURL = URL(fileURLWithPath: "/tmp/docs/restored.md")
        store.seed("restored content", at: newURL)
        try s.activate(url: newURL, store: store)
        #expect(s.state == .clean)
        #expect(s.buffer == "restored content")
    }

    // MARK: - FR-05 关闭拦截

    @Test("关闭拦截：clean 可关，dirty/conflict 必须拦截")
    func close_confirmation_logic() throws {
        let scheduler = FakeScheduler()
        let store = makeStore()
        let s = try makeSession(store: store, scheduler: scheduler)
        #expect(!s.requiresCloseConfirmation, "clean 态可直接关闭")
        s.applyEdit("edited")
        #expect(s.requiresCloseConfirmation, "dirty 态必须拦截")
        s.saveNow()
        #expect(!s.requiresCloseConfirmation)
        s.applyEdit("edited again")
        s.externalChange(.contentChanged(DiskVersion(content: "d", hash: "h")))
        #expect(s.requiresCloseConfirmation, "冲突态必须拦截")
    }

    // MARK: - FR-06 冲突期禁止落盘（回归：在途自动保存曾静默覆盖磁盘）

    @Test("冲突期间自动保存必须被拒绝，磁盘不被覆盖（FR-06）")
    func autosave_is_blocked_during_conflict() throws {
        let scheduler = FakeScheduler()
        let store = makeStore()
        let s = try makeSession(store: store, scheduler: scheduler)

        s.applyEdit("my version")
        // 外部在这 2s 窗口内改了文件 → 进入冲突
        s.externalChange(.contentChanged(DiskVersion(content: "their version", hash: "h2")))
        guard case .conflict = s.state else {
            Issue.record("应进入冲突态")
            return
        }

        // 在途的自动保存此刻触发：绝不能写盘
        scheduler.fire()

        #expect(store.content(at: url) == "# Hello", "冲突期磁盘必须保持原样，不得被静默覆盖")
        guard case .conflict = s.state else {
            Issue.record("自动保存不得改变冲突态")
            return
        }
        #expect(s.buffer == "my version", "内存副本不得丢失")

        // 手动保存同样必须被拒绝
        #expect(s.saveNow(trigger: .manual) == false)
        #expect(store.content(at: url) == "# Hello")

        // 失焦强制落盘也必须被拒绝
        #expect(s.flushBeforeDeactivation() == false)
        #expect(store.content(at: url) == "# Hello")

        // 唯一合法路径：用户选择「保留我的」
        s.resolveConflict(.keepMine)
        #expect(store.content(at: url) == "my version", "用户决策后才允许写盘")
        #expect(s.state == .clean)
    }

    @Test("冲突期自动保存静默失败，不产生错误事件（避免弹窗风暴）")
    func autosave_failure_is_silent_during_conflict() throws {
        let scheduler = FakeScheduler()
        let store = makeStore()
        let s = try makeSession(store: store, scheduler: scheduler)

        s.applyEdit("my version")
        s.externalChange(.contentChanged(DiskVersion(content: "their version", hash: "h2")))
        guard case .conflict = s.state else {
            Issue.record("应进入冲突态")
            return
        }

        var errors: [CoreError] = []
        s.onEvent = { event in
            if case .error(let error) = event { errors.append(error) }
        }

        // 自动保存每 2s 触发一次：若每次都 emit 错误，UI 会不停重建弹窗（实测会卡死窗口）
        _ = s.saveNow(trigger: .auto)
        #expect(errors.isEmpty, "冲突期自动保存应静默失败，不得产生错误事件")

        // 用户显式保存仍然要报错，否则按 ⌘S 会「毫无反应」
        _ = s.saveNow(trigger: .manual)
        #expect(errors.count == 1, "手动保存撞冲突必须报错")
    }

    @Test("冲突期间「采用磁盘版」丢弃我的修改并回到 clean")
    func resolve_conflict_use_disk() throws {
        let scheduler = FakeScheduler()
        let store = makeStore()
        let s = try makeSession(store: store, scheduler: scheduler)

        s.applyEdit("mine")
        s.externalChange(.contentChanged(DiskVersion(content: "theirs", hash: "h3")))
        s.resolveConflict(.useDisk)

        #expect(s.buffer == "theirs")
        #expect(s.state == .clean)
        #expect(!s.requiresCloseConfirmation)
    }
}
