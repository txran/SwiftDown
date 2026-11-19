import Foundation

/// 查找栏的状态机：查什么、搜哪、命中多少、当前第几处。
///
/// 它**不**负责真正扫描文本（那需要访问标签集合，属于 Workspace 的职责），
/// 也不负责跳转与高亮（那需要访问编辑器）。它只持有状态，并在用户改变
/// 查询/范围/选项时通过 `onChange` 请求重算 —— 这样它可以在自检里
/// 脱离视图独立驱动。
@MainActor
final class SearchController: ObservableObject {

    // MARK: - 用户输入

    @Published var isPresented = false
    /// 是否展开替换行
    @Published var showsReplace = false

    @Published var query = "" {
        didSet { if query != oldValue { onChange?() } }
    }
    @Published var replacement = ""
    @Published var scope: SearchScope = .document {
        didSet { if scope != oldValue { onChange?() } }
    }
    @Published var options = SearchOptions() {
        didSet { if options != oldValue { onChange?() } }
    }

    // MARK: - 计算结果

    @Published private(set) var documentMatches: [SearchMatch] = []
    @Published private(set) var tabResults: [TabSearchResult] = []
    @Published private(set) var currentIndex = 0
    @Published private(set) var patternError: String?

    /// 查询/范围/选项变化 → 请求 Workspace 重算（注入，避免反向持有 Workspace）
    var onChange: (() -> Void)?
    /// 游标移动 → 请求 Workspace 把视图跳到该处
    var onJump: ((SearchMatch) -> Void)?

    /// 上次应用结果时的查询串：用来判断「是换了关键词」还是「同一关键词下结果刷新」
    private var lastAppliedQuery: String?

    var currentMatch: SearchMatch? {
        guard documentMatches.indices.contains(currentIndex) else { return nil }
        return documentMatches[currentIndex]
    }

    /// 空串不算查询（但空格算，用户可能真想找空格）
    var hasQuery: Bool { !query.isEmpty }

    var totalAllTabs: Int {
        tabResults.reduce(0) { $0 + $1.matches.count }
    }

    // MARK: - 游标

    func next() {
        guard !documentMatches.isEmpty else { return }
        currentIndex = (currentIndex + 1) % documentMatches.count
        if let match = currentMatch { onJump?(match) }
    }

    func previous() {
        guard !documentMatches.isEmpty else { return }
        currentIndex = (currentIndex - 1 + documentMatches.count) % documentMatches.count
        if let match = currentMatch { onJump?(match) }
    }

    // MARK: - 结果

    func apply(documentMatches: [SearchMatch],
               tabResults: [TabSearchResult],
               error: String?) {
        patternError = error
        let queryChanged = lastAppliedQuery != query
        lastAppliedQuery = query

        self.documentMatches = documentMatches
        self.tabResults = tabResults

        if queryChanged {
            currentIndex = 0
        } else if currentIndex >= documentMatches.count {
            // 替换之后命中会变少，游标要能落到最后一个合法位置
            currentIndex = max(0, documentMatches.count - 1)
        }
    }

    func reset() {
        query = ""
        replacement = ""
        scope = .document
        options = SearchOptions()
        documentMatches = []
        tabResults = []
        currentIndex = 0
        patternError = nil
        lastAppliedQuery = nil
    }
}
