# SwiftDown — 技术设计文档（TDD）

## 一、文档信息

| 项目 | 内容 |
|------|------|
| 文档版本 | v1.0 |
| 依据 | SwiftDown-PRD v1.2（2026-11-17） |
| 作者 | 研发：吴八哥（Senior Developer Agent） |
| 日期 | 2026-11-17 |
| 评审记录 | 待评审（首轮） |

**覆盖声明**：本文档覆盖 PRD 全部本期需求（FR-01~FR-09）与非功能需求（NFR-01~NFR-06）及异常清单（EX-01~EX-08）的设计决策与实现路径；FR-10（导出 HTML/PDF）为版本池项，不做设计。

---

## 二、总体架构

### 2.1 架构分层

```
┌─────────────────────────────────────────────────────────────┐
│            SwiftUI App Shell（SwiftDownApp）                  │
│   窗口 / 菜单 / 快捷键 / Dock·窗口拖拽入口 / 主题环境注入      │
├──────────────┬──────────────────────┬────────────────────────┤
│  TabManager  │   DocumentSession    │      基础设施层          │
│  标签生命周期  │   （核心域·单文件）    │  FileStore（IO/编码/书签）│
│  会话恢复     │   状态机 + 缓冲 +     │  FileWatcher（防抖监测） │
│  最近打开     │   自动保存调度        │  SessionStore（持久化）  │
│  去重路由     │   外部变更协调        │  LogStore（性能日志）    │
├──────────────┼──────────────────────┼────────────────────────┤
│ EditorView   │  MarkdownPipeline    │   PreviewRenderer       │
│ (AppKit)     │  解析 → AST          │   AST→分块→异步绘制      │
│ TextKit2/降级 │  标题树提取           │   高亮/图片/虚拟化       │
├──────────────┴──────────┬───────────┴────────────────────────┤
│         SyncCoordinator（分屏协调：防抖200ms / 标题对齐同步滚动） │
└─────────────────────────┴─────────────────────────────────────┘
```

### 2.2 分层职责与依赖规则

| 层 | 模块 | 职责 | 依赖方向 |
|----|------|------|----------|
| 表现层 | AppShell / TabBar / EditorView / PreviewView / OutlineView | 纯展示与交互，无业务状态 | ↓ 依赖域层与基础设施 |
| 协调层 | TabManager / SyncCoordinator | 多文档编排、分屏同步 | ↓ 依赖域层 |
| 域层 | DocumentSession | 单文件的唯一事实源：源码缓冲、状态机、保存调度、冲突仲裁 | ↓ 仅依赖基础设施接口 |
| 基础设施 | FileStore / FileWatcher / SessionStore / LogStore | IO、监控、持久化 | ↓ 无上层依赖 |

**铁律**：
1. `DocumentSession` 是每个已打开文件的**唯一事实源**（single source of truth），编辑器、预览、标签栏都只读它或向它提交变更，禁止表现层持有独立文档状态。
2. 依赖单向：表现层 → 协调层 → 域层 → 基础设施；域层对基础设施只依赖协议（`FileStoring` / `FileWatching`），便于测试时注入内存实现。
3. 所有耗时的解析、布局、高亮在后台队列执行，主线程只做提交与绘制（保证 NFR-01 标签切换 ≤50ms 与 NFR-02 大文档流畅）。

### 2.3 进程模型与线程设计

单进程，无网络（entitlements 编译期禁用，见 §10.3）。线程规划：

| 队列 | 用途 | QoS |
|------|------|-----|
| Main | UI 提交、绘制、交互 | userInteractive |
| `render-serial` | Markdown 解析 + AST → 分块布局 | userInitiated |
| `highlight-serial` | 代码块 tree-sitter 高亮 | utility |
| `io-serial` | 文件读写、安全书签解析 | utility |
| `watch-coalesce` | FSEvents 事件合并防抖 | utility |

渲染队列按 `sessionID` 串行（同一文档解析保序，防止旧结果覆盖新输入——每次任务携带自增 `revision`，提交时校验 revision 一致才上屏，实现「预览与源码一致」的 FR-03 验收）。

---

## 三、技术选型决策（细化 PRD 约束）

| 决策点 | 选型 | 理由与 PRD 对齐 |
|--------|------|----------------|
| UI 框架 | SwiftUI（壳/菜单/设置）+ AppKit（编辑器与预览 NSView 桥接） | PRD 允许；SwiftUI 做不了 TextKit 2 深度控制与虚拟化滚动 |
| 解析 | **swift-markdown（Apple 官方）**，Ink 作为压测备选 | 原生 GFM 支持（表格/任务列表/删除线），Swift 结构化 AST 便于分块；M1 第 1 周做 1MB/10MB 基准验证，若 Ink 明显更快则切换（接口协议隔离，见 §4.3） |
| 编辑控件 | **NSTextView 封装直接上**（跳过 SwiftUI TextEditor MVP 阶段）；落地实际运行在 TextKit 2（访问 `layoutManager` 会降级为 TextKit 1），见 ADR-06 | TextEditor 无法做行号/语法高亮细粒度控制；PRD 已预置 AppKit 降级路径，反而 NSTextView 本身就是 PRD 的 AppKit 方案，M2 前专项压测确认（RK-01） |
| 代码高亮 | **tree-sitter 系（swift-syntect 或 SwiftTreeSitter 封装）优先，自研规则高亮兜底** | 覆盖 PRD 要求抽测的 10 种常用语言；若依赖体积/性能不达标，降级自研（仅 10 语言词法规则，成本可控） |
| 渲染 | **自研分块渲染器**：AST → 布局块树（NSAttributedString 分块）→ NSView 虚拟化滚动 | PRD 方案 A 核心成本项；保证 10MB 文档流畅（NFR-02）与内存预算（NFR-01） |
| 文件监控 | DispatchSource `/VNode` + `/Directory` 混合 | 单文件 watch 用 vnode（rename/delete 可感知）；目录级批量变更（git pull）用 kqueue 目录事件合并 |
| 持久化 | UserDefaults（轻量设置）+ 单 JSON 文件（会话与最近打开）+ 安全书签 | 结构向后兼容（§8.2） |

---

## 四、模块详细设计

### 4.1 DocumentSession（核心域 — 状态机实现）

PRD §九 状态机的直接实现。**每个标签对应一个 DocumentSession 实例**。

```swift
// 状态枚举（对应 PRD 状态流转表，禁止回跳）
enum DocState: Equatable {
    case clean                    // 已加载（干净）
    case dirty                    // 脏（未保存）
    case conflict(DiskVersion)    // 冲突待决（磁盘版本快照）
    case missing                  // 失联
    case placeholder(String)      // 会话恢复时文件缺失（EX-06）
}

struct DiskVersion { let content: String; let mtime: Date }

@MainActor
final class DocumentSession: ObservableObject {
    let id: UUID
    @Published private(set) var state: DocState
    let buffer: EditorBuffer          // 源码缓冲（见 §4.2）
    private let saver: AutoSaveScheduler
    private var fileRevision: Int = 0 // 预览一致性校验用
    // 提交编辑（编辑器唯一写入口）
    func applyEdit(_ edit: TextEdit)          // → state = .dirty, 触发 saver
    // 外部变更事件（FileWatcher 回调，已防抖去噪）
    func externalChange(_ event: WatchEvent)  // 状态机仲裁，见下表
    // 冲突三选一 / 失联重定位 的用户决策入口
    func resolveConflict(_ choice: ConflictChoice)   // .keepMine/.useDisk/.saveCopy
    func relocate(to url: URL)                       // 失联重定位
}
```

**状态迁移仲裁表**（`externalChange` 内部逻辑，对应 PRD FR-06 / EX-04 / EX-05）：

| 当前态 | 事件 | 动作 | 次态 |
|--------|------|------|------|
| clean | 内容变更 | 后台读盘 → 校验 hash → 静默替换 buffer → 重渲染 | clean |
| dirty | 内容变更 | 暂存 DiskVersion 快照 → 主线程弹三选一 | conflict |
| clean/dirty | rename/move（vnode watch 报告） | 尝试重解析新路径（FSEvents 提供 rename 目标）成功则更新 URL 保持态；失败 | missing |
| missing | 用户 relocate | 校验新路径 hash 一致则接管 | clean（或 dirty，若内存有修改且选择保留） |

**编辑丢失防护（NFR-03 的设计保证）**：
1. `applyEdit` 同步写入 buffer（内存），自动保存调度器 2s 静默落盘；
2. 前台失焦（`NSApplication.willResignActiveNotification`）、标签切换、关闭标签、窗口关闭 → **强制同步 flush**（阻塞主线程最长 500ms，超时走 EX-03 保存失败弹窗）；
3. 保存失败：弹窗 + **内存副本绝不丢弃**，提供「另存为」（EX-03）；
4. 自动保存写入采用 **原子写**（`Data.write(options: .atomic)`，临时文件 + rename），避免半写损坏。

### 4.2 EditorBuffer 与撤销栈

```swift
final class EditorBuffer {
    private var rope: Rope                 // 见 §6.1 大文档设计
    private(set) var undoStack: [TextEdit] // 无上限（FR-04），内存上限保护见下
    private(set) var redoStack: [TextEdit]
}
```

> **实现说明（ADR-01，2026-11-17）**：`Rope` 落地为 **`TextBuffer`（分块行索引，每块 ≤512 行）**。理由：编辑器侧 NSTextStorage 本身已是文档模型，本层只需 ① UTF-16 偏移精确定位（与 NSRange 对齐）、② 与文本等长的 O(1) COW 快照（Swift String 值语义）、③ 与 NSTextStorage 增量编辑同步。分块行索引代码量约为 Rope 的 1/4，且 10MB 实测达标（见下表）。若 M2 压测不达标再升级为 Rope，`TextBuffer` 接口不变。
>
> **10MB 实测基线**（20 万行，Apple Silicon / Release）：构建 166ms、单次中间插入 0.35ms（远低于 16ms 按键预算）、行号定位 0.13ms。已固化为 `EditorKitTests` 性能用例。

撤销无上限直至会话结束（PRD FR-04）。内存保护：`undoStack` 单项为差量（range + 替换文本），1MB 文档全量撤销栈最坏场景内存远小于重复存储全文；仍设置软上限 2000 步，超过时合并最旧两条**相邻**差量（相邻判定用 `lowerBound + inserted.utf16.count`，因插入的 range 是空区间）；不相邻时保守丢弃最旧一条。合并后仍可撤销回会话起点（已单测验证）。

### 4.3 MarkdownPipeline（解析）

```swift
protocol MarkdownParsing {
    func parse(_ source: String) throws -> MarkdownAST
    func headings(in ast: MarkdownAST) -> [HeadingNode]  // H1-H3，大纲与同步滚动共用
}

enum MarkdownParseError: Error { case crashed(Error) }   // EX-08：捕获后降级纯文本
```

- swift-markdown 与 Ink 均实现 `MarkdownParsing`，选型切换零上层改动（PRD 依赖分级表要求 M1 第 1 周完成验证）。
- **降级规则（FR-02）**：不支持的语法节点在 AST→布局转换时落入 `FallbackBlock(sourceText)`，按等宽原样渲染——「原样显示源文本，不报错」。
- 标题树单次解析同时产出：① 大纲视图数据（FR-09）；② 源码行号 ↔ 预览块的映射表（SyncCoordinator 双向滚动依据，见 §5）。

### 4.4 PreviewRenderer（渲染 — 本项目最大自研项）

**渲染管线（三阶段，前两阶段后台）**：

```
源码 String
  → [render-serial] 阶段1：parse → MarkdownAST
  → [render-serial] 阶段2：AST → [LayoutBlock] （NSAttributedString 分块 + 几何高度估算）
  → [Main]          阶段3：虚拟化视口绘制（仅可见块 ± 屏幕高度预渲染）
```

```swift
struct LayoutBlock: Identifiable {
    let id: UUID
    let sourceRange: Range<String.Index>  // 行号映射，双向滚动用
    let headingAnchor: HeadingID?         // 标题对齐锚点
    let content: BlockContent             // .text(NSAttributedString) / .image / .fallback ...
    let estimatedHeight: CGFloat
}
```

**关键设计**：
1. **分块粒度**：块级元素（段落/表格/代码块）各自成块；超长代码块按 ~500 行二次切分（防单个 10k 行代码块拖垮一次布局）。
2. **虚拟化**：自定义 `NSView` 滚动容器，只实例化视口内块；滚动时复用块视图。分块高度先估算（快）后精确测量（惰性），高度修正期间以估算值定位，修正后平滑调整 —— 这是 10MB 文档丢帧率 <5%（NFR-02）的主要手段。
3. **异步增量更新**：编辑触发重渲染时做 **AST 级 diff**（swift-markdown 支持 COW 结构遍历），未变更块直接复用 `NSAttributedString`，只重新生成受影响块——「增量更新」是 ≤200ms 防抖目标的硬保障。
4. **代码高亮**：代码块派发到 `highlight-serial`，高亮完成后回调主线程替换块内容（先展示无高亮版本，高亮到位后刷新，避免高亮阻塞首帧）。
5. **图片（EX-07）**：相对路径基于 `session.url.deletingLastPathComponent()` 解析（FR-02 业务规则）；加载失败渲染占位块（含路径文本），不阻塞兄弟块。图片按显示尺寸降采样（NSImage cache），防大图撑爆内存。
6. **链接**：渲染为可点击属性，点击 → `NSWorkspace.shared.open`（系统默认浏览器）。

### 4.5 TabManager（标签）

```swift
@MainActor
final class TabManager: ObservableObject {
    @Published var tabs: [TabItem]           // 有序，支持拖拽排序
    @Published var activeID: UUID?
    func open(url: URL)                       // 去重路由（见下）
    func close(_ id: UUID) -> CloseRequest?   // 返回未保存拦截请求
    func reorder(_ ids: [UUID])
    private var renderCache: [UUID: RenderSnapshot]  // ≤50ms 切换的保证
}
```

- **去重（FR-01）**：`open` 以规范化路径（resolveSymlinks + 标准路径）为键查重，命中 → `activeID = 已有标签`；未命中 → 新建 session + 后台加载 + 插入标签。
- **≤50ms 切换（NFR-01）**：每个 tab 保留 `RenderSnapshot`（布局块树 + 估算高度表 + 滚动位置 + 编辑器 undo 光标态）。切换 = 视图树交换 + 快照恢复，不做任何重解析。内存代价：块树的 NSAttributedString 是懒测量保留——对 10 标签 × ≤500KB 的 PRD 口径，快照总体积估算 ≤30MB，落在 100MB 预算内（内存预算见 §7）。
- **失联标签切换**（EX-05）：快照仍在，视图顶部叠加失联横幅（「文件已被移动/删除」+ 重定位按钮），内容只读可复制。
- **关闭拦截（FR-05）**：`close` 检查 `state == .dirty || .conflict` → 弹保存/放弃/取消三选一；取消 = 中止关闭（标签保留）。

### 4.6 FileWatcher（外部变更监测）

**两级监测 + 防抖（RK-05）**：
- 每个打开文件一个 `/VNode` DispatchSource（监测 write/rename/delete）；
- `watch-coalesce` 队列做 **500ms 合并窗口**：同文件多事件折叠为一个 `WatchEvent`；git pull 类批量事件天然被吸收；
- rename 事件：vnode 自身只报 rename，搭配父目录 `/Directory` watch 拿到新文件名，实现「自动跟随移动」（FR-06 失联前的优雅路径）；跟随失败才进 `missing`。
- **自写回环去噪**：保存时记录 `(mtime, size, hash)`，事件到达先比 hash，与自写一致直接丢弃——避免自己保存触发自己重载。

### 4.7 SessionStore（会话与最近打开）

```swift
struct SessionState: Codable {
    var schemaVersion: Int = 1
    var tabs: [TabEntry]        // 顺序 + activeID
    var recents: [RecentEntry]  // 最近 20，去重置顶，失效条目保留
}
struct TabEntry: Codable { let bookmark: Data; let order: Int }  // 安全书签
```

- **安全书签（PRD §十一）**：每次打开/保存成功后 resolve/stale 刷新书签持久化；启动恢复时 startAccessingSecurityScope，解决沙箱外路径授权记忆。
- **写策略**：会话变更（开/关/排/聚焦/最近打开）防抖 1s 原子写 JSON；退出时强制写。崩溃后最多丢 1s 的标签变更（可接受——内容本身由 AutoSave 保证，会话仅是入口列表）。
- **向后兼容（PRD §十）**：`schemaVersion` + 迁移函数链；未知字段忽略不报错。

### 4.8 主题与外观（FR-07）

- SwiftUI 层用 `preferredColorScheme(nil)` 跟随系统 + 设置项锁定（AppStorage）；
- **渲染样式表**：`ThemeTokens`（语义色：标题色/引用条/代码背景…），深浅两套，系统切换通知（`NSApplication.effectiveAppearance` KVO）即时换肤——预览块只存语义标签不存具体色，换肤 = 全量重设 token 后 invalidate 可见块，无需重解析。
- 字体/字号：`ThemeTokens` 持有，持久化 UserDefaults。

### 4.9 大纲视图（FR-09，Should）

- 数据来自 §4.3 标题树（H1-H3）；NSOutlineView（AppKit）或 SwiftUI List 桥接；
- 跟随滚动高亮：SyncCoordinator 滚动事件里查找当前视口首个 `headingAnchor`，高亮同步（节流 100ms）；
- 点击跳转 = 定位到锚点块 → 视口滚动（编辑/预览两侧都跳）。

### 4.10 实现落地记录（ADR-02 ~ ADR-05，M1 实测，2026-11-17）

本节记录「设计 → 落地」过程中被实测推翻或补强的决策，避免文档与代码脱节。

**ADR-02 构建方式：CLT-only 可用 SPM + 手工 .app 组装**
本机仅有 Command Line Tools（无完整 Xcode）。实测确认：CLT 的 macOS SDK 含 SwiftUI/AppKit 框架，`swift build` 可编译带 `@main` 的 SwiftUI 应用，并通过「拷贝可执行文件 + Info.plist + ad-hoc 签名」组装出可双击启动的 `.app`。因此 **M1 不因缺 Xcode 而阻塞**，`Scripts/build-app.sh` 固化该流程。
代价与约束：
- SPM 必须在 `--disable-sandbox` 下运行（本机 sandbox-exec 不可用）；
- 测试宏插件需显式 `-Xswiftc -plugin-path .../host/plugins/testing`；
- **`@State` 不可用**（`SwiftUIMacros` 插件随 Xcode 提供）。替代方案：`@StateObject` + 引用类型 `LocalState<T>` 持有局部状态，或把临时状态上提到 `Workspace`/`DocumentTab` 等引用类型。`@ObservedObject / @StateObject / @EnvironmentObject / @Environment` 均不受影响。

**ADR-03 预览渲染：SwiftUI `LazyVStack` 分块而非自研 NSView 虚拟化**
设计 §4.4 原计划自研滚动容器。M1 落地为 `ScrollView + LazyVStack` + 每块 `.id("b-<sourceLine>")`：
- 惰性实例化视口内块，天然满足「只渲染可见块」；
- 块 id 直接复用 AST 的 `sourceLine`，滚动同步与大纲跳转无需额外锚点表；
- 代价：无法精确控制「估算高度 → 精确实测」的修正过程，超长文档可能出现滚动跳动。**M2 若 10MB 实测丢帧 >5%，再按 §4.4 切自研容器**（渲染层已隔离在 `PreviewView`，替换面可控）。

**ADR-04 代码高亮：M1 用词法扫描，不上 tree-sitter**
`CodeHighlighter` 用「单条正则 + 语言关键字表」区分 关键字/字符串/注释/数字 四类着色，覆盖 swift/python/js/ts/java/go/rust/c/cpp/shell/json。理由：M1 目标是「可读」，不是语法精确；tree-sitter 的二进制体积（>15MB）与构建复杂度留到 M2 评估（对应 PRD 依赖表「代码高亮库」并行项）。

**ADR-05 撤销栈：交给 NSTextView 而非自研 UndoStack**
设计 §4.2 计划 `EditorBuffer` 自研撤销栈（已实现并单测通过，25 绿）。M1 的编辑器实为 NSTextView，其 `undoManager` 与文本系统深度耦合（选区恢复、输入法组合、分组），自研栈替换它反而引入行为差异。落地为：`allowsUndo = true` + `levelsOfUndo = 0`（无上限），**EditorKit 的 UndoStack 保留给非 NSTextView 场景与单测基线**。这是「PRD 要求无上限且行为正确」与「工程上不重复造轮子」的折中，若 M2 需要跨会话撤销再切回自研栈。

**补充约束（设计漏洞修正）：冲突态禁止任何自动/手动落盘**
M1 端到端自检发现一个设计文档未覆盖的竞态：`dirty` 态发生外部变更进入 `conflict` 后，**此前排定的 2s 自动保存仍会触发并覆盖磁盘**，等于静默丢弃他人版本，直接违反 FR-06。
修正（已落到 Core 并有回归单测）：`saveNow` 守卫 `conflict` 态直接拒绝；`flushBeforeDeactivation` 在 conflict/missing/placeholder 态不落盘；唯一合法写盘路径是用户决策后的 `resolveConflict(.keepMine)` 走内部 `writeToDisk()`。对应状态机补一行语义：**冲突待决是「写入冻结」态，不只是「编辑冻结」态**。

**ADR-06 文本引擎：以视图当前实际引擎为准，行号/滚动逻辑必须引擎无关**（人工验收后两次修正）
设计 §4.4 计划「TextKit 2 直接上」。第一轮验收发现行号**一个数字都不画**：当时误判 `NSTextView(frame:)` 建的是 TextKit 1（`textLayoutManager` 恒为 `nil`），而标尺只实现了 TextKit 2 取行路径。第二轮验收后查明更准确的事实：`NSTextView(frame:)` 在现代 macOS 上**默认就是 TextKit 2**，只有「有人访问过 `layoutManager`」才会被静默降级为 TextKit 1——也就是说真实运行在 TextKit 2，坏的是 TextKit 2 分支（把 `NSTextLineFragment.characterRange` 这个**元素相对**偏移当成全文偏移，导致每行都算成第 1 行）。
修正：
- `LineNumberRulerView` 按视图**当前实际**引擎分流——有 `textLayoutManager` 走 TextKit 2，否则走 `layoutManager.enumerateLineFragments`；
- TextKit 2 分支用 `layoutManager.offset(from: documentRange.location, to: fragment.rangeInElement.location)` 换算元素起点，再叠加行片段在元素内的偏移；
- 两种路径都只枚举**可见范围**片段（TextKit 2 从「可见顶部上方 4 行」起枚举、越过可见底部即停），禁止从文档起点全量枚举（这是滚动卡顿的直接原因）；
- 行号定位改为「编辑器内缓存逻辑行起始表 + 二分」，O(log n)，实测 2000 次 0.4ms。
**ADR-10 模态 presentation 不得进入自检路径；冲突决策的落点是标签**（第四轮反馈后补）
`--selftest` 是在真实视图树上跑的真实进程。`RootView` 上挂的 `.sheet` / `.alert` / `.confirmationDialog`
在无前台焦点时会进入 SwiftUI 的重复呈现重试，主线程原地打转（表现为应用转圈假死），
且会把自检彻底挂住（第 7 步之后不再前进）。规则：
- 自检进程内 `RootView` 不挂任何模态 presentation（`Workspace.isSelfTest` 分流），自检只断言模型字段；
- 模型层的「决策入口」必须以目标对象为参数（`resolveConflict(_:for:)`），不能以 `pendingXxx` 弹窗状态为守卫——
  否则「横幅入口、批处理、自检」这些不弹窗的路径调用进来全是空操作；
- 自检必须能覆盖生产分支：本轮 `resolveConflict` 失效正是因为自检改走无弹窗路径才暴露出来。

**ADR-11 标签栏溢出：单行滚动 + 箭头 / 多行 flow 布局，两模式共用一套标签视图**（第五轮反馈后补）
PRD 只写了「标签栏支持多标签」，没规定溢出行为。实现上不做第三套方案：
- 单行用 `ScrollView(.horizontal)` + 两侧箭头，`scrollTo` 由游标驱动，切标签自动居中；
- 多行用自研 `TabFlowLayout`（`Layout` 协议）而不是 `LazyVGrid`：标签宽度随文件名变化，网格会强行等宽；
- 栏高**封顶 3 行**（102pt），超出转栏内纵向滚动——不封顶时开 30 个文件会把编辑区挤到不可用；
- 两种模式共用同一个 `tabItems` 视图，右键菜单/拖拽/关闭只有一份实现，避免两套逻辑漂移。
布局判断抽成纯函数（`TabBarMetrics.needsArrows` / `wrappedRowCount`），自检用数字断言，
渲染结果再用离屏快照兜住观感——这是「能断言的别靠肉眼」的延续。

**ADR-13 换文档靠「复用同一个编辑器实例」，不重建视图**（第七轮修正，推翻第六轮的「不做」结论）

第六轮曾尝试去掉 `.id(tab.id)` 做原地换文档，失败后写下了「这条路不可行」。第七轮重新定位后判定：
**当时的两个障碍不是结构性的，是可解的**，而「闪一下」的真正来源恰恰就是 `.id(tab.id)`——它让 AppKit
视图跨一个 CA 事务「先拆后装」，中间必然漏出一帧未挂载的空白。其他编辑器（TextEdit / VS Code / Typora）
之所以不闪，是因为它们切换文档时**从不销毁编辑器**，只替换文本存储。

现在 `RootView` 不再给 `EditorView` 挂 `.id`，切换由 `EditorView.updateNSView` 的 `tabChanged` 分支
调用 `Coordinator.adopt(_:)` 完成。第六轮的两个坑及其解法：

- **标尺宽度晚一帧**：`ruleThickness` 原本只在 `drawHashMarksAndLabels` 里更新，于是「标尺变宽」比
  「文本区重排」晚，换文档（位数 2 → 4）时能看到横向跳动。新增 `LineNumberRulerView.prepareForNewDocument()`，
  在换内容后**主动**重算宽度，再 `scrollView.layoutSubtreeIfNeeded()`，最后把 `textView.frame` 贴到
  `contentView.frame.width`。不做最后一步，文本视图会保持旧宽度被标尺压住首行（第六轮的真实翻车点）。
- **布局期写 @Published**：`boundsDidChange` 与 `textViewDidChangeSelection` 都会同步读位置回写
  `tab.focusedLine`，而 adopt 正跑在 SwiftUI 布局期，这会把布局打回循环（第六轮就是这样让窗口 alpha 卡在 0）。
  现在 adopt 期间置 `isAdopting`，两个回调都早退；`focusedLine` 的重置推到下一轮 runloop。
- **撤销栈必须按文档清空**：旧实现靠视图重建天然清空，复用后必须显式 `removeAllActions()`，否则 ⌘Z 跨文档串档。
- 其余瞬态状态（选区、滚动位置）在 adopt 里一并复位，行为与「每份文档一个干净视图」等价。

自检不再靠肉眼，而是断言**实例同一性**：切换前后 `NSTextView` 必须 `===`（把 `.id(tab.id)` 加回去会
FAIL，已验证断言有效），并配「标尺随位数变宽 46→50」「文本区宽度 == clipView 宽度」「切换后行号仍连续」
三条，把第六轮那两个翻车点变成可回归的断言。

**ADR-14 大文档只做可见区高亮，且推迟到内容上屏之后**（第八轮，实测驱动）

打开大文件「像卡死又重开」的量化结论（4.8MB / 330 万字符）：

| 阶段 | 耗时 |
|---|---|
| 读盘 + 建 `DocumentSession` | 11ms |
| `DocumentTab` 构造 | 84ms |
| `replaceEntireText` | 7ms |
| **`MarkdownHighlighter.apply` 全文** | **2548ms** |
| 行号索引 + 布局 | 45ms |

瓶颈单一且明确：高亮全文扫描。据此定两条规则：

1. **超过 `fullScanThreshold`（20 万字符）只高亮可见区**，滚动停下 120ms 后按需补刷
   （`Coordinator.scheduleVisibleRefreshIfNeeded`）。20 万字符以下仍全文刷，结果一致、耗时 <10ms。
2. **高亮不在换文档的同步路径里做**。TextKit 2 对超长文本**首次写布局属性**有一次性索引开销
   （实测 8218 字符的 `setAttributes` 要 223ms，同范围第二次只要 0.04ms——说明是全局索引，不是线性成本）。
   这一步放到 `DispatchQueue.main.async`，正文先上屏（约 15ms），用户看到「内容立刻出现 → 语法色紧跟上」。
   同一个文件从 `open` 到上屏：**2548ms → 51ms**。
3. 顺带修掉 `fenceStateBefore` 的隐性 O(全文)：判「进没进代码围栏」原本从文档头扫到目标偏移，
   大文档滚到末尾时单独就是一秒。现在只回溯最近 256KB。

代价：大文档滚动时会有一次约 200ms 的着色延迟（首次），之后走缓存索引很快。
这是「可交互」与「立刻有色」之间的取舍，选了前者。

---

**ADR-15 开发产物用独立身份，并放进隐藏目录**（第九轮，用户反馈「应用程序里出现两个图标」）

现象：`/Applications` 里明明只有一个 `SwiftDown.app`，「应用程序」（Spotlight 驱动的应用列表）却显示两个同名同图标入口。

实测依据：`mdfind "kMDItemCFBundleIdentifier == 'dev.swiftdown.app'"` 返回两条——
`/Applications/SwiftDown.app` 与项目里的 `build/SwiftDown.app`，版本同为 0.1.2、bundle id 完全相同、图标相同；
LaunchServices 里还累积了 108 条注册记录（多轮复制与 `lsregister` 测试留下，其中数条指向已删除路径）。

结论：两个 `.app` bundle 共用同一个 `CFBundleIdentifier` 时，系统视其为「同一应用的两份」，
应用列表、⌘Tab、「打开方式」都会出现重复项或指向不确定的那一份。

修正分三层：

1. **开发构建换身份**：`dev.swiftdown.app.dev`、显示名「SwiftDown Dev」；`package-app.sh` 传 `SWIFTDOWN_DIST=1`，
   打包产物保持正式身份 `dev.swiftdown.app`。
2. **产物落在 `build/.dev/SwiftDown.app`**。实测确认 Spotlight 跳过以 `.` 开头的目录，也不索引指向它的符号链接；
   `build/SwiftDown.app` 保留为符号链接，README 与既有脚本路径不用改。
3. 清掉测试期遗留的临时副本，并用 `lsregister -u` 注销失效路径。

副作用：开发版换 id 后 UserDefaults 是新的域（主题、最近打开不继承）。这是预期的——
若继续共用域，系统又会把它当成同一个应用。

---

**通用结论**：凡是渲染类能力，自检断言必须落到**内容**（编号数组 / 像素），只断言「视图对象存在」是无效断言；且自检不得改动被测对象的内部状态（见 ADR-09）。
若要手工装配 `NSTextContentStorage` + `NSTextLayoutManager` 而不经 `NSTextView` 默认路径，会牵动高亮层对 `NSTextStorage` 的直接写入，M1 不做，留 M2 评估。

**ADR-07 跨对象数据流：视图必须订阅真正持有状态的那个对象**（人工验收后修正）
`OutlineView` 只观察 `Workspace`，却直接读 `tab.ast`。首开文档时 AST 由后台解析后写回 `DocumentTab`，
`Workspace` 完全没变化 → 大纲不重算，表现为「刚打开是空的，切换视图模式才出现」。
修正：`OutlineList` 单独 `@ObservedObject var tab`；外层只负责取 `activeTab`。
**通用约束**：SwiftUI 里任何读取 `ObservableObject` 属性的视图，必须自己 `@ObservedObject/@EnvironmentObject` 该对象，
不能依赖「某个底层对象变了会顺带刷新我」。异步管道（解析、监控、落盘）越多，这条越致命。

**ADR-08 设置与快捷键：覆写表 + 事件监视录制**（用户追加需求，PRD FR-07 之外）
- 快捷键存「动作 rawValue → 绑定」的**覆写表**而非全量列表：新增动作不会让老配置失效；
- `ShortcutBinding` 统一提供 `KeyEquivalent`/`EventModifiers`，菜单的 `.keyboardShortcut` 全部从设置读取，
  `Commands` 依赖 `@ObservedObject settings` 刷新，改完即时生效；
- 录制用 `NSEvent.addLocalMonitorForEvents`（代码量远小于自绘 NSView + firstResponder 方案），
  规则：必须有修饰键（裸字符会抢编辑器输入）、冲突则拒绝并报出占用者、Esc 取消；
- 启动布局优先级：`恢复上次布局`（默认开）＞ 上次会话记录 ＞ 设置里的默认布局。两个开关都进自检。
- 自检隔离：`--selftest` 时注入独立 `UserDefaults(suiteName:)` 域，否则测试会把临时文件路径写进
  用户真实的「最近打开」列表（第一轮就这样污染过一次）。

**ADR-09 自检必须断言「自己跑在哪个分支」；外观类设置必须落到 `NSApp.appearance`**（第三轮验收后修正）
- 行号「全是 1」修了两轮才收敛，根因不是业务逻辑，而是**自检和生产跑在不同引擎上**：
  自检里一句 `editor.layoutManager?.ensureLayout(for:)` 把 TextKit 2 视图降级成 TextKit 1，
  于是自检一直绿、生产一直是坏的。修正：自检只用生产路径的 API，并显式断言
  「自检覆盖生产排版引擎 = TextKit2」；兼容分支另起独立实例、显式降级后再验一遍。
  **约束**：任何「按引擎/模式分流」的实现，自检第一步先断言分支，再断言内容。
- 主题原先只接了 SwiftUI `.preferredColorScheme`，而编辑器/标尺/菜单/面板都是 AppKit 视图，切了没反应。
  修正：`AppAppearance.apply(_:)` 写 `NSApp.appearance`（`.aqua`/`.darkAqua`/`nil`），
  落地收在 `AppSettings.themeMode.didSet` 一处，`AppEnvironment.init` 再显式应用一次
  （属性观察器在 init 阶段不触发，漏了就会「重开应用才生效」）。文案按用户口径改为 跟随系统/白天/黑夜。



---

## 五、SyncCoordinator（分屏实时预览，FR-03）

**两个职责**：

1. **防抖重渲染**：编辑器 textDidChange → 200ms 防抖（PRD 口径）→ 快照源码 + 自增 revision → 派发 render-serial → 完成时 revision 匹配才提交。持续输入场景天然合并，停顿 200ms 必然触发一次。
2. **双向同步滚动（标题节点对齐）**：
   - 依据：标题树中的 `sourceLine ↔ headingAnchor` 映射（§4.3）；
   - 编辑侧光标移动/滚动 → 找光标所在或上方最近标题 → 预览滚动至对应锚点块（仅当目标不在视口内才滚动，避免抖动）；
   - 预览侧滚动 → 反查当前首个可见锚点 → 编辑侧滚动到对应行；
   - **死锁防护**：同步滚动带方向标记（`isProgrammaticScroll`），程序滚动触发的事件在 150ms 内被忽略；
   - 大文档下用节流（≤10Hz）+ 动画时长 0 保证不抢占输入。

**三态切换**：`SplitMode: .previewOnly / .sourceOnly / .split`，快捷键（默认 ⌘⌘1/2/3 建议改为 ⌘1/⌘2/⌘⇧1，评审确认），AppStorage 持久化。

---

## 六、性能设计（NFR-01/02 逐项对策）

### 6.1 大文本数据结构：Rope

源码缓冲使用 Rope（叶节点 ≤4KB）。支持：O(log n) 编辑、跨块 O(log n) 行号定位、COW 快照（防抖渲染时 O(1) 拷贝快照给后台线程，避免锁）。10MB 文档内存放大系数约 1.5×（15MB），优于 String 全量拷贝方案。

### 6.2 冷启动 ≤1s（P95，10 标签恢复）

启动关键路径瘦身：
1. `SwiftDownApp.init` 只读 SessionStore JSON（<5KB，同步快）；
2. 标签栏先渲染 **占位 tab（文件名已知，内容懒加载）**，主窗口即刻可交互（满足「可交互」口径计时）；
3. 各文档加载/解析并行派发 render-serial（并发度 = CPU 核数，上限 4），逐个就绪逐个填充；
4. 首屏（上次活跃标签）优先调度。

### 6.3 1MB 渲染 ≤300ms 预算分解

| 阶段 | 预算 | 手段 |
|------|------|------|
| 解析（swift-markdown） | ≤100ms | M1 基准确认；不达标切 Ink |
| AST→布局块（含高亮占位） | ≤150ms | 分块并行（并发 4）、高亮异步后补 |
| 首屏绘制 | ≤50ms | 虚拟化，只画视口 |

> **M1 实测修正（2026-11-17）**：swift-markdown 解析 1MB 典型技术文档实测 **220ms**（预算 100ms 的 2.2 倍），瓶颈是库的 Markup 节点构建（约 2μs/节点），非自研转换层（<30ms），非 cmark 解析（纯文本 1MB 仅 32ms）。详见 `Docs/M1-parse-benchmark.md`。
>
> **结论与对策**：不切换 Ink（同属 Swift 节点树模型，收益未知且失去 GFM 完整性）。改由三项工程手段满足用户感知口径 —— ① 后台解析（主线程零阻塞，冷启动与解析耗时解耦）；② 分块渐进提交（首屏可滚动不等全文解析）；③ 解析结果缓存（标签切换零重解析）。NFR-01「渲染完成可滚动」按**首屏可滚动**口径验收（待产品确认，见 benchmark §三 P-01）。


### 6.4 10 标签常驻内存 ≤100MB 预算

| 项 | 估算 |
|----|------|
| App 基础 + SwiftUI/AppKit 运行时 | ~25MB |
| 10 × Rope 缓冲（单文档 ≤500KB） | ~10MB |
| 10 × RenderSnapshot（块树懒测量） | ~30MB |
| 代码高亮 tree-sitter 语法库（按需加载 10 语言） | ~15MB |
| 图片缓存（LRU 上限 20MB） | ≤20MB（软上限） |
| **合计** | **≤100MB** |

超预算兜底：非活跃标签的 RenderSnapshot 在收到内存压力通知（`OSMemPressure`）时降级丢弃（保留滚动位置），激活时重建。

### 6.5 >20MB 文件（EX-02 / FR-01）

打开前 FileStore stat 检查大小：>20MB → `readOnlySourceOnly` 模式：跳过 Markdown 渲染与编辑，等宽纯文本虚拟化展示 + 提示横幅；二进制嗅探（前 8KB 含 NUL → 二进制）同样走该路径（EX-02）。

---

## 七、文件 IO 与编码（FileStore）

1. **编码（EX-01）**：先假定 UTF-8（`String(contentsOf:encoding:.utf8)`）失败 → CFStringEncoding 探测（GB18030/Big5 优先，`NSString.stringEncodingFor`）→ 转码为 UTF-8 内存表示渲染，落盘仍写原编码（保存时保留探测到的编码，避免破坏用户既有文件生态）；全部失败 → 只读原始文本 + 提示。
2. **原子读改写**：读 = 一次全量 + hash 记录；写 = temp + rename（`Data.write(.atomic)`）。
3. **行尾**：保留原文件行尾风格（探测 LF/CRLF），编辑插入按原风格——避免 git diff 全文件污染（PRD 用户画像是研发，此为隐性刚需）。

---

## 八、数据结构汇总与持久化

### 8.1 内存对象图

```
TabManager
 ├─ TabItem(s) ── DocumentSession ── EditorBuffer(Rope)
 │                                    ├─ AutoSaveScheduler
 │                                    └─ RenderSnapshot(布局块树+锚点+高度表)
 └─ SessionStore(磁盘) ── SessionState{tabs, recents}
FileWatcher（每 session 一 vnode + 父目录 watch，中心防抖）
```

### 8.2 磁盘持久化清单

| 数据 | 位置 | 格式 | 兼容策略 |
|------|------|------|----------|
| 设置（主题/字体/字号/分屏模式） | UserDefaults | 系统键值 | 语义键前缀 `sd.` |
| 会话（标签/顺序/活跃/最近打开） | `~/Library/Application Support/SwiftDown/session.json` | Codable JSON + schemaVersion | 迁移链 |
| 安全书签 | session.json 内嵌（Data Base64） | — | — |
| 开发者日志 | `~/Library/Caches/SwiftDown/`（可选开启） | 行文本 | 滚动清理 7 天 |

### 8.3 埋点

零上报（PRD §十）。LogStore 本地记录：冷启动耗时、单文件渲染耗时、保存失败事件、崩溃时间点，用于 2.3 节指标的本地复测。

---

## 九、交互与快捷键（视图层规范）

| 功能 | 快捷键（默认，评审可调） |
|------|--------------------------|
| 打开 | ⌘O；拖拽 Dock/窗口；Finder 双击（注册 Document Type，见 §10.2） |
| 保存（手动） | ⌘S |
| 加粗/斜体 | ⌘B / ⌘I（包裹选区或插入 `**`/`*`） |
| 分屏三态 | ⌘1 预览 / ⌘2 源码 / ⌘⇧1 分屏 |
| 切标签 | ⌘⇧] / ⌘⇧[（系统惯例） |
| 关闭标签 | ⌘W（带拦截）；关闭其他/全部 → 右键菜单 |
| 大纲开关 | ⌘⌥S |

可访问性（NFR-06）：菜单全键盘可达（SwiftUI 默认）；编辑器/预览为 NSTextView 系，VoiceOver 基本朗读免费获得；标签可聚焦可 VoiceOver 报读（`accessibilityLabel` = 文件名 + 状态）。

---

## 十、工程结构与构建

### 10.1 模块划分（SPM 本地包，单 App target 引用）

```
SwiftDown/
├── SwiftDownApp/            # SwiftUI 壳、资源、entitlements
├── Packages/
│   ├── SwiftDownCore/       # DocumentSession、状态机、AutoSave（纯逻辑，可测）
│   ├── SwiftDownPipeline/   # MarkdownParsing 协议 + swift-markdown 实现 + 标题树
│   ├── SwiftDownRender/     # LayoutBlock、PreviewRenderer、虚拟化视图、高亮
│   ├── SwiftDownEditorKit/  # TextKit 2 封装、Rope、语法辅助、撤销
│   └── SwiftDownInfra/      # FileStore、FileWatcher、SessionStore、LogStore
```

SwiftDownCore 不 import 任何 UI 框架 —— 状态机与保存逻辑全部可单元测试（§11）。

### 10.2 Finder 双击关联

Info.plist 声明 `CFBundleDocumentTypes`（`net.daringfireball.markdown` UTI + 扩展 md/markdown），`LSHandlerRank: Alternate`（避免抢占用户已有主关联）。

### 10.3 分发与安全（PRD §十一 对齐）

1. Release 构建 `codesign -s - --deep --timestamp=none`（ad-hoc）；
2. dmg 打包脚本附带生成 `shasum -a 256` 校验值输出；
3. **零网络编译期断言**：entitlements 不含 `com.apple.security.network.client/server`（非沙盒时同样显式不带网络相关 entitlement）；CI 加一个符号级检查脚本（链接表无网络符号引用）作为验收断言；
4. Info.plist `LSMinimumSystemVersion = 13.0`（NFR-04）；Universal Binary（arm64 优先，含 x86_64）。

---

## 十一、测试策略

| 层 | 手段 | 重点 |
|----|------|------|
| SwiftDownCore | **XCTest 全覆盖状态机迁移表**（PRD §九每行一条 case）+ 冲突仲裁 + AutoSave 时序（注入 fake clock） | 状态机禁止回跳、编辑零丢失（NFR-03 的核心保障） |
| Pipeline | 解析快照测试：GFM 全语法 fixture × 深浅主题；降级块行为；标题树正确性 | FR-02 全语法矩阵 |
| Render | 1MB/10MB 基准（XCTest measure）；视口虚拟化正确性（滚动到任意偏移内容正确） | NFR-02 |
| Infra | FileWatcher 用脚本制造 rename/批量写/git checkout 场景；编码探测 fixture（UTF-8/GBK/二进制） | FR-06 / EX-01 |
| 集成手工 | PRD 15.1 RTM 的 7 组测试要点 + EX-01~08 逐条过；强杀进程恢复演练（`kill -9` 后重启） | 发布回归 |

性能基线：按 PRD 2.3 口径出 Instruments 脚本化模板（启动/内存/渲染/切换四张 trace），每版本跑一次沉淀（PRD §十.3）。

---

## 十二、风险与设计应对（对齐 PRD §十四）

| PRD 风险 | 本设计的应对 |
|----------|--------------|
| RK-01 TextKit 2 大文件性能 | §4.2/§6.1：Rope + 差量撤销本就为大文档设计；M2 前专项压测点已在测试策略单列；降级预案 = EditorBuffer 接口不变、替换 TextKit 2 引擎为经典 TextKit 1 NSTextView |
| RK-05 git 批量变更抖动 | §4.6 两级防抖 + hash 比对去噪，500ms 合并窗口 |
| RK-04 GFM 方言差异 | §4.3 FallbackBlock 统一降级通道，任何未知节点不崩不丢 |
| EX-08 渲染引擎崩溃 | Pipeline 顶层 do-catch，crashed → 纯文本降级 + 提示 + 内存副本可导出（「导出内存副本」= 另存为绑定 buffer） |

**遗留决策点（进入开发前需确认）**：
1. 分屏三态快捷键具体键位（§九 建议值待评审）；
2. swift-markdown vs Ink 的 M1 第 1 周基准结论（不阻塞架构，接口已隔离）；
3. 高亮库 tree-sitter 系体积是否可接受（>15MB 则走自研 10 语言规则）。

---

## 十三、里程碑对齐（PRD §十三）

| 里程碑 | 本设计交付物对应 | 出口验证 |
|--------|------------------|----------|
| M1 Alpha | SwiftDownCore + Pipeline + EditorKit + 单文件渲染编辑保存 | 状态机单测全绿；1MB 渲染基准达标；S-01/S-03 演练 |
| M2 Beta | TabManager + FileWatcher + SessionStore + 主题 + SyncCoordinator 全量 | NFR-01 四项指标实测达标；RK-01 压测结论出具 |
| M3 v1.0 | 打包脚本 + 零网络断言 + 性能基线脚本 | EX-01~08 回归 + dmg 安装指引走查 |

---

> 追踪说明：本文档每个设计点均标注了对应 PRD 编号（FR-xx / NFR-xx / EX-xx / RK-xx），评审时请对照 PRD 15.1 RTM 核查无遗漏。
