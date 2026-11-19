# macOS 开发踩坑总结（Swift / SwiftUI / AppKit）

> 项目：SwiftDown（macOS Markdown 阅读器 / 编辑器）
> 技术栈：Swift 6 + SwiftUI + AppKit（NSTextView / TextKit 2）+ SPM
> 环境约束：只有 Command Line Tools，无完整 Xcode
> 版本区间：0.1.0 → 0.1.6，2026-11-17 ~ 11-19
>
> 本文只记录**真实踩到并且被验证过**的坑。每条尽量给出：症状 → 当时的误判 → 真因 → 处置 → 判据。
> 没有判据的结论一律标注为「未验证」，不写进来冒充经验。

---

## 零、怎么用这份文档

这份文档有三种读法，按你现在的处境选一种，不要从头读到尾。

| 你的处境 | 读哪里 | 预计耗时 |
|---|---|---|
| 准备开一个新 macOS 项目 | [macOS-应用起步清单.md](macOS-应用起步清单.md) —— 立项时该定的 20 个决策 | 20 分钟 |
| 正在被某个具体现象卡住 | [十、速查表](#十速查表) —— 按症状反查 | 1 分钟 |
| 想知道某个选择为什么这么做 | 对应章节正文 | 按需 |

### 先判断哪些跟你有关

本项目踩的坑**不是每个都通用**。照抄别人的结论而不照抄前提，是最容易新造的坑。先看这张表：

| 章节 | 对谁有用 | 什么情况下**可以跳过** |
|---|---|---|
| 一、环境与构建 | 只有 Command Line Tools、或在 CI 里构建 macOS 应用 | 有完整 Xcode 且用 `.xcodeproj` |
| 二、SwiftUI ↔ AppKit | 任何在 SwiftUI 里嵌 AppKit 视图（`NSViewRepresentable`）的项目 | 纯 SwiftUI，不碰 `NSView` |
| 三、TextKit | 做编辑器、长文渲染、带行号/高亮的文本视图 | 不用 `NSTextView` |
| 四、性能 | 处理大文件、长列表、高频滚动 | 数据量在几千行以内 |
| 五、窗口与事件 | 要自己接管文件打开、要做自定义鼠标交互 | 用标准 `NSDocument` 架构（系统已代管打开事件） |
| 六、启动与进程 | 启动阶段要做 IO、或要排查「卡住」类问题 | 启动只是显示一个空窗口 |
| 七、应用身份 | 同一台机器上同时装开发版和正式版 | 只产出一个构建 |
| 八、自检方法论 | 需要无 GUI 的自动化验证 | 已有完整 XCUITest 且愿意维护 |
| 九、文件一致性 | 有外部变更监控、自动保存、冲突处理 | 纯只读应用 |

**最通用的三条**（不管你做什么 macOS 应用都成立）：二、七、八。

### 这份文档帮不到你的地方

诚实说明边界：

- **它不能替代「自己加探针」**。每个项目的卡点不一样，本文的价值是告诉你「该往哪看」，不是替你量。
- **它的结论有保质期**。SwiftUI 的内部行为（比如 5.1 那个自己关窗口）属于未公开实现，系统升级后可能变。凡依赖这类行为的改动，都要留一条反向验证的断言。
- **它的样本只有一个项目**。编辑器类应用的经验（TextKit、大文档）迁移性最好；文档没覆盖的领域（多窗口、Sandbox、App Store 审核、国际化）是空白。

---

## 目录

- [零、怎么用这份文档](#零怎么用这份文档)
- [一、环境与构建：没有 Xcode 怎么办](#一环境与构建没有-xcode-怎么办)
- [二、SwiftUI ↔ AppKit 互操作](#二swiftui--appkit-互操作)
- [三、TextKit：这个坑最多](#三textkit这个坑最多)
- [四、性能：先量数字再改结构](#四性能先量数字再改结构)
- [五、窗口与鼠标事件](#五窗口与鼠标事件)
- [六、启动、进程与主线程](#六启动进程与主线程)
- [七、应用身份与部署（图标出现两个那种事）](#七应用身份与部署图标出现两个那种事)
- [八、自检与测试方法论](#八自检与测试方法论)
- [九、文件读写与数据一致性](#九文件读写与数据一致性)
- [十、速查表](#十速查表)

---

## 一、环境与构建：没有 Xcode 怎么办

### 1.1 CLT-only 可以做完整的 macOS GUI 应用

**结论**：只有 Command Line Tools 时，`swift build` 能编译带 `@main` 的 SwiftUI 应用，再手工组装 `.app`（可执行文件 + `Info.plist` + ad-hoc 签名）就能双击启动。不需要 Xcode。

代价是三个必须手动补的东西：

| 项 | 现象 | 处置 |
|---|---|---|
| SPM 沙箱 | 编译直接失败 | `swift build --disable-sandbox` |
| 测试宏插件 | 找不到 `Testing` 宏 | `-Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing` |
| 资源目录 | 无 `Assets.car` | 图标走传统 `.icns`，塞进 `Contents/Resources/` |

### 1.2 `@State` 不可用（最容易卡住的一条）

**症状**：写 `@State private var foo = false` 编译报错，提示找不到 `State` 宏。

**真因**：`@State` 由 `SwiftUIMacros` 插件实现，该插件随完整 Xcode 提供，CLT 里没有。

**处置**（三种，按场景选）：

```swift
// ① 局部状态用引用类型 + @StateObject
final class LocalState<T>: ObservableObject {
    @Published var value: T
    init(_ value: T) { self.value = value }
}
@StateObject private var expanded = LocalState(false)

// ② 需要改的值上提到已有的引用类型（Workspace / DocumentTab）
// ③ 纯派生值用计算属性，根本不需要存储
```

**能用与不能用**：`@ObservedObject` / `@StateObject` / `@EnvironmentObject` / `@Environment` 都正常；只有 `@State`（以及基于宏的 `@Bindable` 之类）不行。

---

## 二、SwiftUI ↔ AppKit 互操作

### 2.1 视图必须自己订阅「真正持有状态的那个对象」

**症状**：首次打开文档，大纲面板一片空白；切一下视图模式（重建 SwiftUI 树）标题就冒出来了。

**误判**：以为是 AST 解析慢或线程问题。

**真因**：`OutlineView` 只 `@ObservedObject` 了 `workspace`，标题数据却直接读 `tab.ast`。AST 是后台异步解析完写回 `DocumentTab` 的，`workspace` 没有任何变化 → 视图不重算。

**处置**：把渲染子树抽成 `OutlineList`，自己 `@ObservedObject var tab`，外层只负责取 `activeTab`。

```swift
// 错：外层观察 workspace，内层直接读 tab.ast
struct OutlineView: View {
    @ObservedObject var workspace: Workspace
    var body: some View { list(workspace.activeTab?.ast) }
}

// 对：读谁的状态就观察谁
struct OutlineView: View {
    @ObservedObject var workspace: Workspace
    var body: some View { if let tab = workspace.activeTab { OutlineList(tab: tab) } }
}
struct OutlineList: View {
    @ObservedObject var tab: DocumentTab
    ...
}
```

**通用约束**：SwiftUI 里任何读取 `ObservableObject` 属性的视图，必须自己声明对该对象的观察。**不能指望「底层对象变了会顺带刷新我」**。异步管道（解析、文件监控、落盘）越多，这条越致命。

**怎么回归**：光断言「AST 有 60 个标题」抓不到——数据一直是对的。要加渲染探针，记录 body 的**实际求值次数与当时的标题数**，按原时序复现：先建视图（AST 为空）→ 等解析完成 → 断言最终渲染出 60 条。输出形如 `首帧=0 最终=60 重算次数=68`。

### 2.2 主题只设 `.preferredColorScheme` 不管用

**症状**：设置里切「黑夜」，SwiftUI 画的界面变了，编辑器、行号标尺、菜单、右键菜单、打开面板全是白的。

**真因**：`.preferredColorScheme` 只影响 SwiftUI 自己渲染的子树。`NSTextView` / `NSScrollView` / `NSRulerView` / `NSMenu` 是 AppKit 视图，看的是 `NSApp.appearance`。

**处置**：

```swift
enum AppAppearance {
    static func apply(_ mode: ThemeMode) {
        switch mode {
        case .system: NSApp.appearance = nil
        case .light:  NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:   NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
```

两个必须注意的点：

1. 落地位置收敛到 `AppSettings.themeMode.didSet` 一处，菜单 / 设置面板 / 恢复默认三条入口都走它。
2. **`didSet` 在 `init` 阶段不触发**。所以 `AppEnvironment.init` 里要显式再 `apply()` 一次，否则「重开应用才生效」。

### 2.3 无头自检进程里不能挂模态 presentation

**症状**：跑 `--selftest`，进程弹出冲突面板，然后整个应用转圈假死，自检停在第 7 步不再前进。

**真因**：`RootView` 上的 `.sheet` / `.alert` / `.confirmationDialog` 在没有前台焦点时会进入 SwiftUI 的**重复呈现重试**，主线程原地打转。

**处置**：自检模式下 `RootView` 只渲染核心内容，不挂任何模态；自检改为断言模型字段（`pendingConflict == nil`）。

**顺带暴露的第二个坑**：`resolveConflict(_:)` 的守卫写成了 `guard let prompt = pendingConflict`，而为了「不自动弹窗」把 `pendingConflict` 的自动赋值去掉了 → 通过模型直接调用永远是空操作，冲突解不掉、标签一直冻结。修法是让决策入口以**目标对象**为参数：

```swift
// 坏：以弹窗状态为守卫，不弹窗的调用路径全是空操作
func resolveConflict(_ choice: ConflictChoice) { guard let p = pendingConflict else { return } }

// 好：落点是标签，弹窗只是其中一个调用者
func resolveConflict(_ choice: ConflictChoice, for tab: DocumentTab) { ... }
```

### 2.4 布局期写 `@Published` 会把布局打回循环

**症状**：换文档时窗口 `alpha` 卡在 0（窗口可见但全透明），或者界面卡住不动。

**真因**：`boundsDidChange` / `textViewDidChangeSelection` 里同步回写 `tab.focusedLine`（`@Published`），而换文档的代码正跑在 SwiftUI 布局期 → 触发重算 → 再次布局 → 死循环。

**处置**：换文档期间置 `isAdopting` 标志，两个回调早退；需要重置的值推到下一轮 runloop。

```swift
private var isAdopting = false

func adopt(_ tab: DocumentTab) {
    isAdopting = true
    defer { isAdopting = false }
    // ...替换文本、复位选区与滚动
}
```

### 2.5 只想占个位，却把整行撑高了：`Color` 是两轴贪婪的

需要一个「和别处等宽的空白」来对齐两行输入框，最容易写成：

```swift
// ✗ 宽度定住了，高度没定。Color 在两个轴上都可扩展，
//   于是这一行被撑到填满可用空间，同行控件按 .center 垂直居中，
//   整行浮到容器中间，还顶出一大块空白。
Color.clear.frame(width: 160)

// ✓ Spacer 只在所属栈的主轴（这里是水平）上伸展，不参与高度分配。
Spacer().frame(width: 160)
```

被撑高的不只是这一行：它在 `VStack` 里成了贪婪子视图，会把剩余垂直空间全吃掉，
上下两行之间被拉开几百点。同样的陷阱适用于 `Rectangle()`、`Circle()` 等纯形状。

**注意**：这个 bug **单看该组件的截图是看不出来的**——截图时给 host 写死的高度正好把它盖住。
必须渲整窗图才看得见（见 8.6）。

---

## 三、TextKit：这个坑最多

### 3.1 `NSTextView(frame:)` 默认就是 TextKit 2

**症状**：行号一个数字都不画，只画了背景和分隔线。

**当时的误判**：认定 `NSTextView(frame:)` 走 TextKit 1（`textLayoutManager == nil`），只实现了 TextKit 1 取行路径。

**真因**（第二轮才查准）：现代 macOS 上它**默认是 TextKit 2**。只有**有人访问过 `layoutManager`**（哪怕只是读一下）才会被静默降级成 TextKit 1。

**约束**：行号、滚动、选区的实现必须**引擎无关**，按视图当前实际引擎分流：

```swift
if let tlm = textView.textLayoutManager {      // TextKit 2
    // 用 tlm 枚举行片段
} else if let lm = textView.layoutManager {     // TextKit 1（被降级过）
    lm.enumerateLineFragments(forGlyphRange: visibleGlyphRange) { ... }
}
```

### 3.2 `NSTextLineFragment.characterRange` 是「元素内偏移」，不是全文偏移

**症状**：修完上一条，实机变成**每一行都显示 1**。

**真因**：TextKit 2 的 `NSTextLineFragment.characterRange.location` 是**相对于该文本元素（段落）**的偏移。每个段落的第一个字符偏移都是 0 → 全部算成第 1 行，而「0 是逻辑行首」恒真，于是每行画一个 "1"。

**处置**：元素起点要用 `layoutManager.offset(from:to:)` 从文档起点换算，再叠加行片段在元素内的偏移：

```swift
let elementStart = tlm.offset(from: tlm.documentRange.location,
                              to: fragment.rangeInElement.location)
let lineStart = elementStart + fragment.characterRange.location
```

**这是 TextKit 2 最反直觉的一处**：同名属性在 TextKit 1 的 `NSLayoutManager` 语义下是全文 glyph 偏移，到 TextKit 2 变成了元素相对偏移，编译器不会提醒你。

### 3.3 TextKit 2 首次写布局属性有一次性全局索引开销

**实测**：对 8218 字符的文本 `setAttributes` 首次 **223ms**，同范围第二次只要 **0.04ms**。不是线性成本，是第一次建立全局索引。

**影响**：语法高亮如果放在「换文档的同步路径」里，用户看到的就是几秒白屏或卡死。

**处置**：正文先上屏，高亮扔到下一轮主队列：

```swift
textStorage.setAttributedString(plain)          // 先上屏（约 15ms）
DispatchQueue.main.async { highlighter.apply(...) }  // 颜色紧跟上
```

### 3.4 行号 / 滚动一律只枚举可见范围

**症状**：文档越长滚动越卡，滚到后面几乎拖不动。

**真因**：`topVisibleLine`、`currentLine`、行号绘制都从文档起点开始枚举。

**处置**：

| 位置 | 原实现 | 改法 |
|---|---|---|
| 行号绘制 | 从文档起点枚举全部行片段 | TextKit 2 从「可见顶部上方 4 行」起、越过可见底部即停；TextKit 1 用 `glyphRange(forBoundingRect: visibleRect)` |
| 当前行 / 顶部行 | 每帧从头 `while` 数换行 | 编辑器内缓存「逻辑行起始表」+ 二分查找，O(log n) |

2000 次定位实测约 0.5ms。

### 3.5 标尺宽度必须「先算宽、再布局、最后贴 view」

**症状**：换文档时文本区横向抖一下；或者首行被行号标尺压住。

**真因**：`ruleThickness` 原本只在 `drawHashMarksAndLabels` 里更新，于是「标尺变宽」比「文本区重排」晚一帧。位数从 2 变 4 时就能看到跳动。

**处置**：换内容后主动重算，顺序不能错：

```swift
ruler.prepareForNewDocument()          // ① 先按新文本算标尺宽度
scrollView.layoutSubtreeIfNeeded()     // ② 让布局按新标尺跑一遍
let clipWidth = scrollView.contentView.frame.width   // ③ 再取 clip 宽度
textView.frame.size.width = clipWidth  // ④ 最后贴 textView
```

把 ① 挪到 ② 后面就翻车：clip 宽度按旧标尺算（464），标尺随后变 50，文本区超宽 50pt 压住首行。这个顺序错误被自检的「`textView` 宽度 == clipView 宽度」当场抓到。

### 3.6 换文档要复用编辑器实例，不重建视图

**症状**：切换标签 / 打开第二个文件时「闪一下」。

**第一版误判**：`.id(tab.id)` 让 SwiftUI 销毁并重建整棵编辑区子树，两帧之间漏出空白。

**后续证明**：这个归因**没有证据支持**——帧级探针显示换文档全程 `alpha=1`、`isVisible=1`、内容区没有白帧（见 5.1）。但复用本身仍然是对的做法，理由换成它本来的那个：不该为了换文本重建 `NSScrollView` / `NSTextView` / `NSTextStorage` / 标尺，也不该让两套状态机靠重建来对齐。

**复用要显式处理的四件事**（视图重建时这些都是自然的，复用后全得自己补）：

1. 标尺宽度重算（见 3.5）
2. 布局期回写 `@Published` 的抑制（见 2.4）
3. **撤销栈必须按文档清空**：`undoManager.removeAllActions()`，否则 ⌘Z 跨文档串档
4. 选区、滚动位置复位

**回归方式**：断言**实例同一性**——切换前后 `NSTextView` 必须 `===`。把 `.id(tab.id)` 加回去这条会 FAIL（已反向验证）。

### 3.7 查找高亮不能写进 textStorage；替换必须走 `insertText`

做查找替换时，最直觉的写法是「把命中区间的背景色写进 `textStorage`」。三个后果：

1. **污染撤销栈**——用户按 ⌘Z 撤销的不是自己的编辑；
2. **触发 `didChangeText`** → 回写模型 → 触发自动保存，搜索把文档变脏；
3. **被语法高亮整段覆盖**——两套属性互相盖，表现是高亮闪一下就没了。

正解是用引擎的**渲染/临时属性层**，只影响绘制、不进文本、不进撤销栈：

```swift
if let tlm = textLayoutManager {            // 顺序不能反：先问 TK2
    tlm.addRenderingAttribute(.backgroundColor, value: color, for: textRange)
} else if let lm = layoutManager {          // 先访问 layoutManager 会静默降级
    lm.setTemporaryAttributes([.backgroundColor: color], forCharacterRange: range)
}
```

替换同理，必须走标准编辑入口：

```swift
insertText(text, replacementRange: range)   // 撤销注册、委托通知、选区维护都由它完成
```

绕过它直接改 textStorage，撤销栈就接不上，「⌘Z 撤不回来」是最难查的一类 bug。
批量替换要**倒序**执行（偏移大的先改，否则前面的区间会被推歪），外面套
`undoManager.beginUndoGrouping()` / `endUndoGrouping()`，N 次替换算 1 步撤销。

另一个细节：跳转**不要 `makeFirstResponder`**，否则用户打完一个字就被踢出输入框；
而且跳转必须推迟一个 runloop——在 SwiftUI 的 `updateNSView`（布局阶段）里同步调
`setSelectedRange` 会写 `@Published`，形成布局循环（实测窗口 `alpha` 卡在 0，见 2.4）。

### 3.8 正则 `^` 默认不按行锚定

`NSRegularExpression` 默认按**整段文本**解释 `^` / `$`：`^` 只匹配全文开头。
想让 `^` 匹配每一行行首，必须显式加 `.anchorsMatchLines`：

```swift
NSRegularExpression(pattern: "^dog", options: [.anchorsMatchLines, .caseInsensitive])
```

容易漏是因为多数语言（Python / JS / Ruby）的 `^` 默认就按行。Cocoa 这里正好相反。
**判据**：任何用户可输入正则的地方，留一条「`^` 能命中第 2 行行首」的断言——
这条断言挡住的不是崩溃，而是「明明有却搜不到」。

---

## 四、性能：先量数字再改结构

### 4.1 4.8MB 文档「像卡死又重开」：2548ms → 51ms

**先量**（不是猜）：

| 阶段 | 耗时 |
|---|---|
| 读盘 + 建 `DocumentSession` | 11ms |
| `DocumentTab` 构造 | 84ms |
| `replaceEntireText` | 7ms |
| **全文语法高亮** | **2548ms** |
| 行号索引 + 布局 | 45ms |

瓶颈单一且明确。三条改法：

1. **超过 20 万字符只高亮可见区**，滚动停下 120ms 后按需补刷。
2. **高亮不在换文档的同步路径里**（见 3.3），正文先上屏。
3. **判「进没进代码围栏」原本从文档头扫到目标偏移** —— 单独就是一秒。改成只回溯最近 256KB。

代价：大文档首次滚动有一次约 200ms 的着色延迟，之后走缓存索引。这是「可交互」与「立刻有色」的取舍，选了前者。

### 4.2 滚动路径上五个「看起来无害」的开销

| 位置 | 问题 | 改法 |
|---|---|---|
| 滚动通知 | `Task { @MainActor }` 二次派发 | 通知本身已在主队列，直接同步处理 |
| 滚动 → `focusedLine` | 每变化一行就写 `@Published`，触发整树重算 | 80ms 节流合并；光标移动不节流 |
| `EditorTheme` | `updateNSView` 里每帧新建（含 3 次字体构造） | `ThemeCache.theme(fontSize:family:)` 缓存 |
| 行号绘制 | 每帧 O(全文) | 只枚举可见片段 |
| 当前行计算 | 每帧 O(n) 数换行 | 行起始表 + 二分 |

### 4.3 断言要取值快照，不要存复用对象的引用

**坑**：自检里存了 `ruler` 引用，等到断言时再读 `ruleThickness`，拿到的已经是切换后的值——断言恒真。

**处置**：断言前把要比较的值先取出来存成局部常量。

---

## 五、窗口与鼠标事件

### 5.1 外部双击文件「闪一下」：SwiftUI 自己关了一次窗口

**症状**：应用已在前台，从访达双击另一个 `.md`，窗口闪一下像关闭又重开，但 PID 不变。

**两次误判（记录下来避免重走）**：

| 轮次 | 判断 | 依据 | 为什么错 |
|---|---|---|---|
| 第六轮 | macOS 应用激活过渡，前台打开不复现 | `screencapture -l <windowID>` 连拍 | 单帧百毫秒级，抓不到 16.7ms 的空帧，**工具没有判别力** |
| 第七轮 | `.id(tab.id)` 重建视图漏出空白帧 | 代码推理 | 帧级探针显示全程无白帧，**推理没有验证** |

**真因**：事件级探针订阅 `NSWindow` 通知，发现 `isVisible` 在打开瞬间 1 → 0 → 1（约 2ms），并在 `isVisible == false` 的瞬间打印调用栈：

```
-[NSWindow _close]
  ← SwiftUI.AppWindowsController.activateWindowForExternalEvent(matching:handler:)
  ← SwiftUI.AppWindowsController.open(urls:)
  ← SwiftUI.AppDelegate.application(_:open:)
```

SwiftUI 收到外部打开事件后，认为当前窗口不匹配该事件，**先关掉窗口再为文档激活窗口**。在「单窗口 + 自管标签」的结构里这一步纯属多余，且必然表现为一闪。

**处置**：在 `applicationWillFinishLaunching` 里用 `NSAppleEventManager` 接管 `kAEOpenDocuments`，自己解析文件 URL。

```swift
func applicationWillFinishLaunching(_ notification: Notification) {
    NSAppleEventManager.shared().setEventHandler(
        self,
        andSelector: #selector(handleOpenDocuments(_:withReplyEvent:)),
        forEventClass: AEEventClass(kCoreEventClass),
        andEventID: AEEventID(kAEOpenDocuments)
    )
}
```

三个必须注意的点：

1. **必须装在 `willFinishLaunching`**。AppKit 在启动阶段就分发 open 事件，装晚了第一份文件仍走 SwiftUI 那条路。
2. **必须回 reply**，否则发送方（访达 / `open -a`）等 30 秒超时报 **-1712**。接管之后 AppKit 的默认处理不再执行，没人回复就一直等：

```swift
// 回一个空列表 = 全部接收成功（真失败了才往列表里放失败项）
private func acknowledge(_ reply: NSAppleEventDescriptor) {
    // typeNull 时不能碰 reply，直接返回
    guard reply.descriptorType != typeNull else { return }
    reply.setDescriptor(NSAppleEventDescriptor.list(), forKeyword: keyDirectObject)
}

// 顺序也很关键：先回 reply，再干活
acknowledge(reply)
Task { @MainActor in env.workspace.open(urls: urls) }
```

3. **试过但无效的两条路**（别重复踩）：
   - `.handlesExternalEvents(matching:)`：只对 `WindowGroup` 生效，单 `Window` 场景是空操作
   - `window.isRestorable = false`：不是原因，实测仍闪

**效果**：运行中打开另一个 md，`isVisible` 掉到 0 的次数 **1 → 0**；连续打开 3 个文件 **3 → 0**。

### 5.2 `hitTest` 里读 `NSApp.currentEvent` 是 nil

**需求**：鼠标中键点标签关闭。SwiftUI 没有中键手势。

**网上最常见写法**：叠一层视图，在 `hitTest` 里判断 `NSApp.currentEvent` 是不是中键。

**实测不成立**：

| 调用方式 | hitTest 被调用 | 期间 `NSApp.currentEvent` |
|---|---|---|
| `NSWindow.sendEvent(leftMouseDown)` | 1 次 | **nil** |
| `NSApplication.sendEvent(leftMouseDown)` | 1 次 | **nil** |

拿不到「正在分发的是哪个键」，判定永远为假 → 功能**静默失效**（点下去毫无反应，不报错不崩溃，这种失效最难发现）。

**处置**：覆盖层完全不参与命中测试 + 窗口级本地监听器。

```swift
// ① 覆盖层让出命中测试，左键/右键/拖拽/滚轮全部穿透
final class MiddleClickZone: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// ② 窗口级监听，只认「中键抬起」
NSEvent.addLocalMonitorForEvents(matching: .otherMouseUp) { event in
    guard event.buttonNumber == 2 else { return event }
    // 落点用当场算出的窗口矩形，不缓存坐标
    ...
    return event
}
```

**为什么落点必须当场算**：单行模式下标签在 `ScrollView` 里横向滚动，缓存坐标必然过期；多行模式换行、窗口缩放同理。

**顺带两个坑**：
- `NSEvent.mouseEvent(with:...)` **没有 `buttonNumber` 参数**，构造不出中键事件
- `CGEvent` 合成的事件 `windowNumber` 恒为 0

所以这条没法靠合成事件做自检。改用「真实 `NSWindow` + `NSView` 构造几何，直接断言 `target(type:buttonNumber:window:point:)` 的返回值」，6 条断言覆盖「中键 + 抬起 + 落在标签内」的合取条件。

---

## 六、启动、进程与主线程

### 6.1 跑在主线程上的探针，观测不到主线程卡死

**症状**：冷启动日志出现 29 秒空档，期间 `open -a` 报 -1712。既有探针（帧采样、通知订阅）**全部跑在主线程**——主线程一卡，它们自己也不出字，日志里只剩一个无法归因的空洞。

**处置**：`LaunchProbe`，两个设计点：

1. **时间基准取内核记录的进程启动时刻**（`proc_pidinfo` 的 `pbi_start_tvsec`），不是静态初始化时刻。这样才能把「exec 之后到第一行 Swift 代码」也算进时间线。
2. **心跳看门狗跑在独立线程**：每 100ms 往主队列投一次往返；判定卡住后用 `thread_get_state` 从另一个线程读主线程 PC，再 `dladdr` 反查符号。

```swift
// 从别的线程读主线程 PC
// THREAD_STATE64 = 6：头文件里的宏在某些 SDK 组合下没被导入，直接用数值更稳
var state = arm_thread_state64_t()      // Apple Silicon；Intel 用 x86_thread_state64_t
var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: state) / 4)
let kr = thread_get_state(mainThread, thread_state_flavor_t(6),
                          withUnsafeMutablePointer(to: &state) {
                              $0.withMemoryRebound(to: natural_t.self, capacity: Int(count)) { $0 }
                          }, &count)
guard kr == KERN_SUCCESS else { return }
let pc = UInt(state.__pc)               // Intel 上是 state.__rip
```

### 6.2 冷启动时 6KB 文件的 `open(2)` 花了 5327ms

**实测**：经 LaunchServices 启动、二进制首次执行时，一个 6KB 的 md 读盘 **5327ms**，看门狗 47 次采样全部落在 `libsystem_kernel.dylib:__open`。同一个文件从终端直接读 **0.2ms**。

**结论**：卡的不是自己的代码，是特定上下文下系统的文件打开动作。会话恢复有几个文件就是几个这样的坑，全压在主线程的启动阶段 → `didFinishLaunching` 迟迟不返回 → 访达投递的打开事件 30 秒等不到应答（-1712 的来源）。

**两条结构性修法**：

1. **读盘离开主线程**（示意，实际返回 `DiskLoad` 枚举）：

```swift
/// nonisolated async 不继承调用者的 actor（SE-0338），天然跑在协作线程池上
nonisolated static func loadFromDisk(_ url: URL) async -> DiskLoad {
    let store = DiskFileStore()
    let bytes = DiskFileStore.fileSize(at: url)
    do { return .loaded(text: try store.load(from: url), bytes: bytes) }
    catch { return .failed(reason: ...) }
}

func performOpen(_ url: URL) async -> DocumentTab? {
    guard !openingPaths.contains(url.path) else { return nil }   // 同路径并发去重
    openingPaths.insert(url.path)
    defer { openingPaths.remove(url.path) }

    switch await Self.loadFromDisk(url) {          // 后台读
    case .loaded(let text, let bytes):
        return makeTab(url: url, content: text, size: bytes)   // 主线程只装配
    ...
    }
}
```

`DocumentSession` 要提供 `init(url:content:store:)`，**构造过程不碰文件系统**。多选打开在一个 Task 里逐个 `await`，标签顺序不变。

2. **会话恢复两段式**：
   - `prepareSessionRestore()` 只读元信息（几百字节 JSON，<1ms）——布局必须在首帧前定，否则窗口会先按默认布局画一遍再跳
   - `performSessionRestore()` 等首帧（首个 `NSWindow.didUpdate`，1s 兜底）之后再执行，文档内容在后台读

**效果**：`didFinishLaunching` +388 → **+329ms**，首帧 +498 → **+366ms**，运行中打开 77–86ms。

**判别力验证**（这一步不能省）：把「打开一个没有写端的 FIFO」当输入，`open(2)` 会永久阻塞。此时再打开另一个文件仍然 **95ms 返回**，看门狗零次阻塞。同一个看门狗在旧构建上抓到过 5474ms 阻塞——证明它测得出问题，不是「没报警所以没事」。

### 6.3 启动阶段用户点开的文件会被会话恢复抢走

**症状**：双击一个 md 启动，窗口出来后显示的是「上次退出时那份」。

**坑**：判据不能写「恢复开始时 tabs 是否为空」——用户那份可能正好在读盘中，快照里还是空的。

**处置**：恢复前记录 `preExisting`（当前已存在的标签 id 集合），恢复结束后把恢复出来的排前面、用户点的那份顺延到最后并保持活跃。

### 6.4 `launchctl setenv` / `open --args` 传环境变量不可靠

**症状**：探针开关（环境变量）有时生效有时不生效。

**处置**：改成**标记文件**——存在 `/tmp/xxx-trace.on` 就开，日志写 `/tmp/xxx-trace.log`。简单、可靠、可远程开关。

---

## 七、应用身份与部署（图标出现两个那种事）

这一节是踩得最久、误判最多的地方，单独说清。

### 7.1 判据是文件系统，不是 LaunchServices 表

**症状**：`/Applications` 里明明只有一个 `SwiftDown.app`，系统里却显示两个（其中一个带 dev 标签）。

**核心事实**：macOS 认应用靠磁盘上**存不存在这个 bundle**，不看它在哪、叫什么、是否隐藏。只要存在第二份，LaunchServices 就认为「同一个应用的两份拷贝」。

### 7.2 同一个 `CFBundleIdentifier` = 同一个应用的两份

**症状**：「应用程序」里两个同名同图标入口；⌘Tab 两个；「打开方式」指向不确定的那一份。

**真因**：两个 `.app` 共用 `CFBundleIdentifier`。

**处置**：开发构建换身份。

```bash
# build-app.sh：开发产物
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier dev.swiftdown.app.dev" \
                        -c "Set :CFBundleDisplayName SwiftDown Dev" Info.plist

# package-app.sh：发行产物保持正式身份
SWIFTDOWN_DIST=1 ./Scripts/package-app.sh
```

副作用（预期的）：开发版换 id 后 `UserDefaults` 是新的域，主题、最近打开不继承。若继续共用域，系统又会把它当成同一个应用。

### 7.3 藏起来 + 注销，都挡不住 mds 回填

**三个被证否的假设**：

| 假设 | 检查 | 结论 |
|---|---|---|
| Dock 里固定了两份 | `defaults read com.apple.dock persistent-apps` 里 SwiftDown 出现 0 次 | 不是 Dock 固定项 |
| 废纸篓副本被 Spotlight 收录 | `mdfind` 只返回 `/Applications` 那一份 | 不影响显示 |
| 藏进隐藏目录就够 | `build/.dev` 已是隐藏目录，仍出现 | 隐藏目录不是充分条件 |

**实测到的机制**：

- `lsregister -u` 注销后，**25～40 秒被 mds 回填**
- `.metadata_never_index` 对**已经建立过索引**的目录无效
- 删掉指向它的符号链接，也阻止不了回填
- 更直接的一条：**运行一次开发版，注册数立刻 0 → 1**（`open -a` 之后查 `lsregister -dump` 就能看到）

**结论**：靠「注销 + 藏起来」只能短暂压住。唯一稳定的做法是**磁盘上不留第二份 bundle**。

```bash
# 调试构建完就清（脚本新增的子命令）
./Scripts/build-app.sh clean        # 注销注册 → 删 build/.dev → 重启 Dock
```

配套的体检脚本：

```bash
./Scripts/doctor-app.sh             # 列出所有游离副本与身份冲突，只报不改
./Scripts/doctor-app.sh --fix       # 注销游离注册 + 删 /private/tmp 测试副本 + 重注册 + 刷新 Dock
```

它只删 `/private/tmp`、`/tmp` 下的测试产物；废纸篓等用户目录只注销注册、**不删文件**。

### 7.4 LaunchServices 会累积僵尸注册

实测见过 **108 条**注册记录（多轮复制 + `lsregister -f` 测试留下，含指向已删除路径的僵尸条目）。

- `lsregister -kill -r -domain ...` 会重建整个数据库，太重，已从脚本移除
- 改 `lsregister -u <path>` 逐条注销
- `-u` 对某些路径需要精确路径，批量时要逐条跑

### 7.5 `ditto` 对符号链接只打链接本身

**症状**：打包出来的 zip 里，`SwiftDown.app` 是个空壳。

**真因**：`build/SwiftDown.app` 是指向 `build/.dev/SwiftDown.app` 的符号链接，`ditto` 只复制链接本身。

**处置**：打包脚本一律用真实路径 `build/.dev/SwiftDown.app`。

### 7.6 shell 里变量紧跟全角括号会被当成变量名

```bash
echo "  快捷路径：$APP_LINK（符号链接）"     # ✗ bash 把「（」并入变量名 → unbound variable
echo "  快捷路径：${APP_LINK}（符号链接）"   # ✓
```

中文注释 + 中文标点是这个项目里的高频踩点，脚本里一律用 `${VAR}`。

### 7.7 自检必须隔离用户数据

跑一次 `--selftest` 就清空用户的「上次打开的标签」、污染「最近打开」列表——都真实发生过：

| 污染 | 处置 |
|---|---|
| 删了真实 `session.json` | `SessionStore(directory:)` 可注入，自检落临时目录 |
| 临时文件路径写进「最近打开」 | `noteOpened` 过滤临时路径 |
| `UserDefaults` 串到真实域 | `--selftest` 注入独立的 `UserDefaults(suiteName:)` |
| 崩溃残留 24MB 大文件样本（积了 5 个共 120MB） | `defer` 清理 + 顺带清 1 小时前残留 |

---

## 八、自检与测试方法论

这一节不是坑，是「怎么不踩第二次坑」。

### 8.1 断言必须落到内容，不能落到对象存在

- ✗ 「`NSRulerView` 子视图存在」→ 行号一个数字都没画，测试照样绿
- ✓ 「行号实际产生编号 / 自 1 连续递增 / 不超过逻辑行数」
- ✓ 「切换前后 `NSTextView` 必须 `===`」（实例同一性）
- ✓ 「`textView` 宽度 == clipView 宽度」

渲染类能力还要加**像素**判据：截内容区若干点，比对颜色。

### 8.2 自检不得改动被测对象的内部状态

最惨的一次：自检里一句 `editor.layoutManager?.ensureLayout(for:)` 把 TextKit 2 视图**降级成 TextKit 1**，于是自检一直跑兼容分支、全绿，生产分支从没被覆盖，功能一直是坏的（行号全是 1）。

**约束**：凡是「按引擎 / 模式分流」的代码，自检第一步先断言**自己跑在哪个分支**，再断言内容。兼容分支另起独立实例、显式降级后单独验一遍。

### 8.3 改回去必须 FAIL（反向验证）

新增的防线要验证它真的在防：

- 「已接管 `kAEOpenDocuments`」这条断言看似很弱，它防的不是逻辑错误，而是**这个接管被后人删掉**。删掉后文件照样能打开、功能看起来一切正常，只有闪一下会悄悄回来。已反向验证：去掉接管，立即 FAIL。
- 「读盘不在主线程同步完成」——改回同步，立即 FAIL。
- 「编辑器实例复用」——把 `.id(tab.id)` 加回去，立即 FAIL。

### 8.4 工具的判别力要先证明

`screencapture` 抓不到 16.7ms 的空帧，用它判断「有没有闪」必然得出「没闪」。**先问「这个工具测得出来吗」，再问「测出来是什么」。**

### 8.5 推理不等于验证

同一个问题两次误判都发生在「看起来很有道理」的推理上：

| 误判 | 推理 | 被什么推翻 |
|---|---|---|
| 激活过渡 | 其他应用不闪，所以是激活流程 | 截屏连拍（无判别力，等于没验） |
| 视图重建漏白帧 | `.id` 会改变身份，重建跨 CA 事务，中间必有一帧 | 帧级探针：全程 alpha=1、无白帧 |

正确顺序：**先加探针 → 拿到矛盾的数字或调用栈 → 再改结构**。

### 8.6 布局类快照必须带完整上下文

单控件快照只证明「控件自身排对了」，证明不了「它在真实布局里在哪、多大」。
更麻烦的是**截图时给 host 写死的高度会把尺寸错误盖住**：本项目实测过，查找栏的替换行
浮在编辑区半空、顶出一大块空白，但单渲查找栏的图里两行挨得整整齐齐——因为高度是外部写死的。
把查找栏放回真实窗口渲整窗图，一眼就看出不对（对应 2.5 的 `Color` 陷阱）。

三层配合才够：

| 层 | 能证明 | 不能证明 |
|---|---|---|
| 单控件快照 | 控件内部排版、文字截断 | 在真实布局里的位置与尺寸 |
| 整窗快照 | 上下关系、间距、遮挡 | 精确像素 |
| 固有尺寸断言（`fittingSize`） | 高度/宽度是不是该有的量级 | 视觉观感 |

新做一个可展开的界面块，至少交出一张整窗图 + 一条固有尺寸断言。

### 8.7 像素断言要能「分档」

「高亮画出来了」这类结论，只有像素说得清。但只数「有多少彩色像素」还不够——
用户真正要的是「我当前在第几处」，所以要把像素按**饱和度分档**（当前处实色 vs 其余淡色），
两档都对得上，才证明层级也画到屏幕上了：

| 状态 | 实色 px | 淡色 px |
|---|---|---|
| 未查找 | 0 | 0 |
| 1 处命中 | 298 | 0 |
| 3 处命中（当前 = 第 1 处） | 298 | 569 |
| 清除后 | 0 | 0 |

`298×3 ≈ 298+569`，实色恰好等于「一处」的量——一次证明三件事：每处都画了、
当前处与其余处层级分得开、清除是干净的。引擎的兼容分支（TextKit 1）要另跑一遍，数字应一致。

---

## 九、文件读写与数据一致性

### 9.1 原子写会换掉 inode，监听器随即失效

**症状**：自己保存一次之后，外部再改动文件就检测不到了。

**真因**：原子写（写临时文件 + `rename`）会替换 inode，而 `DispatchSourceFileSystemObject` 绑的是旧 inode。

**处置**：自写落盘后三步——更新已知 hash、重建监听、开一个静默窗丢弃紧随而来的自己触发的事件。

```swift
// 自写之后：先记下「这就是我写的内容」，再重建监听，最后静默一小段
knownHash = FileHash.of(content)
suppressUntil = Date().addingTimeInterval(0.3)
restartWatching()          // 原子写换了 inode，旧 source 已经绑在废 inode 上
```

### 9.2 cancel handler 捕获 `self.fileDescriptor` 会误关新 fd

**症状**：重启监听后，后续所有外部变更全部漏报（没有任何报错）。

**真因**：`stop()` 里 `source.cancel()`，而 cancel handler 里写的是 `close(self.fileDescriptor)`。此时该字段**已经指向新 fd**，晚到的 handler 把新 fd 关掉了。

**处置**：cancel handler 捕获创建时的局部 `fd`，不要读实例字段。

```swift
let fd = open(path, O_EVTONLY)
source.setCancelHandler { close(fd) }    // 捕获局部值，不是 self.fileDescriptor
```

### 9.3 冲突态是「写入冻结」，不只是「编辑冻结」

**症状**：进入冲突后，此前排定的 2 秒自动保存仍会触发，把内存版写进磁盘，**静默丢弃他人版本**。

**真因**：状态机只把 `conflict` 当成「禁止编辑」，没有把它当成「禁止写盘」。在途的定时保存不属于「编辑」，绕过了守卫。

**处置**：写盘唯一入口收敛成一个内部方法，只有用户决策 `resolveConflict(.keepMine)` 能调用它。

```swift
private func writeToDisk() throws { ... }    // 唯一写盘出口

func saveNow() {
    guard state == .dirty else { return }    // conflict / missing / placeholder 一律拒绝
    try writeToDisk()
}
```

**教训**：做状态机时，每一个「冻结」态都要分别问「冻结读？冻结写？冻结编辑？」——只写一个 `isEditable = false` 必然漏。

### 9.4 需要持久化的退出状态不要异步写

**症状**：退出后重开，最后一次的标签集合丢了。

**真因**：`SessionStore.save` 走后台队列，进程先死。

**处置**：这类「几百字节、退出前必须落地」的数据直接同步原子写（<1ms），不要图省事丢给后台队列。

---

## 十、速查表

| 症状 | 最可能的原因 | 处置 |
|---|---|---|
| 编译报找不到 `State` 宏 | CLT 无 `SwiftUIMacros` | 改 `@StateObject` + 引用类型，或状态上提 |
| 首次打开某面板空白，切一下就出现 | 视图没 `@ObservedObject` 真正的数据持有者 | 抽子视图，观察真正持有者 |
| 切主题只有 SwiftUI 部分变色 | 只设了 `.preferredColorScheme` | 写 `NSApp.appearance`，并在 `init` 显式应用一次 |
| 行号一个都不画 | 只实现了 TextKit 1 路径 | 按 `textLayoutManager` 是否存在分流 |
| 行号全是 1 | 把 `characterRange.location` 当全文偏移 | 用 `offset(from:to:)` 换算元素起点 |
| 文档越长滚动越卡 | 从文档起点枚举 / 每帧 O(n) | 只枚举可见范围 + 行起始表二分 |
| 大文档打开像卡死 | 全文语法高亮在同步路径 | 只刷可见区 + 推迟到上屏后 + 围栏回溯限长 |
| 换文档首行被压住 / 横向抖 | 标尺宽度更新晚一帧 | 算宽 → 布局 → 取 clip 宽 → 贴 textView |
| 换文档后 ⌘Z 跨文档串档 | 复用实例没清撤销栈 | `undoManager.removeAllActions()` |
| 窗口可见但全透明 / 界面卡住 | 布局期写 `@Published` | `isAdopting` 抑制回写 |
| 双击文件「闪一下」 | SwiftUI 在 open 事件里先关窗口 | 接管 `kAEOpenDocuments`（装在 `willFinishLaunching`） |
| `open -a` 报 -1712 | 打开事件没回 reply / 启动阶段卡住 | 回空错误列表；读盘移出启动阶段 |
| `hitTest` 里读不到当前按键 | `NSApp.currentEvent` 为 nil | 覆盖层 `hitTest → nil` + 窗口级 local monitor |
| 启动恢复多标签时长时间无响应 | 文件 I/O 压在主线程 | `nonisolated` 后台读盘 + 会话恢复两段式 |
| 「应用程序」里两个图标 | 磁盘上有第二份同 id 的 bundle | 换开发版 id + 调试完 `build-app.sh clean` |
| 注销注册后又自己回来 | mds 扫描回填 | 只能删掉第二份 bundle |
| 打包出的 zip 里 app 是空壳 | `ditto` 复制了符号链接 | 用真实路径打包 |
| 自检弹窗后转圈假死 | 无头进程挂了模态 presentation | 自检模式不挂 modal |
| 跑完自检用户标签没了 | 自检操作了真实会话/偏好 | 注入临时目录 + 独立 `UserDefaults` 域 |
| 自己保存一次后，外部改动检测不到 | 原子写换了 inode，监听器绑在旧 inode | 自写后重建监听 + hash 比对 + 静默窗 |
| 重启监听后事件全丢 | cancel handler 关了新 fd | 捕获创建时的局部 fd |
| 冲突期磁盘被内存版覆盖 | 在途定时保存绕过了编辑守卫 | 写盘唯一出口，仅 `keepMine` 可调 |
| 退出后最后一次状态丢失 | 会话写盘走了后台队列 | 几百字节的状态改同步原子写 |
| 某一行浮在容器中间、顶出一大块空白 | 占位用了 `Color.clear.frame(width:)`，高度贪婪 | 换 `Spacer().frame(width:)` |
| 正则 `^` 只命中全文开头 | `NSRegularExpression` 默认不按行锚定 | options 加 `.anchorsMatchLines` |
| 查找高亮闪一下就没了 / ⌘Z 撤不回来 | 写进了 `textStorage` / 绕过了 `insertText` | 走渲染属性层 + 标准编辑入口 |
| 快照看着正常，真机位置全错 | 只渲控件本身、还写死了高度 | 补整窗图 + 固有尺寸断言 |

---

## 附：一句话结论

1. **macOS 认应用看磁盘，不看注册表。** 想让系统只认一个，磁盘上就只留一个。
2. **TextKit 2 的偏移是元素相对的**，这是最容易写错又最不容易发现的一处（表现是「全是 1」而不是崩溃）。
3. **SwiftUI 与 AppKit 的状态边界要自己划清**：观察谁就声明谁，主题写 `NSApp.appearance`，布局期不要写 `@Published`。
4. **渲染类问题先加探针拿数字，别靠截图和推理。** 工具的判别力要先自证。
5. **凡是「引擎/模式分流」的代码，自检第一步断言分支。** 否则测试全绿、功能全坏。
