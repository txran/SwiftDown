import Foundation

/// 自检专用渲染探针。
///
/// 背景：用户报过「首次打开大纲不显示」，根因是视图没观察 `DocumentTab`，
/// AST 异步解析完成后不重算。这类缺陷用「数据对不对」断言抓不到——
/// 数据一直是对的，错的是「视图没被重新求值」。
/// 所以这里记录视图 body 的真实求值次数与内容，仅在 `--selftest` 下写入。
@MainActor
enum DebugProbe {

    /// 每次大纲视图求值时记录的标题数
    private(set) static var outlineRenders: [Int] = []

    static var isEnabled: Bool {
        CommandLine.arguments.contains("--selftest")
    }

    static func recordOutline(_ headingCount: Int) {
        guard isEnabled else { return }
        // 防爆：异常情况下也不会累积到失控
        if outlineRenders.count > 500 { outlineRenders.removeFirst(250) }
        outlineRenders.append(headingCount)
    }

    static func resetOutline() {
        outlineRenders.removeAll()
    }

    static var lastOutlineRender: Int? { outlineRenders.last }

    /// 是否出现过「有标题」的渲染
    static var didRenderNonEmptyOutline: Bool {
        outlineRenders.contains { $0 > 0 }
    }
}
