# M1 应用壳交付说明（v0.1.0）

> 日期：2026-11-17　｜　对应 PRD v1.2、设计文档 v1.0（含 ADR-02~05）  
> 状态：**可运行**。M1 出口场景 S-01（阅读技术文档）、S-03（轻量修改）已走通并经端到端自检验证。

---

## 一、怎么构建与运行

```bash
# 构建（debug 迭代用，release 出包用）
./Scripts/build-app.sh debug
./Scripts/build-app.sh release

# 运行
open build/SwiftDown.app

# 用某个文件启动
open -a "$PWD/build/SwiftDown.app" PATH/TO/file.md

# 端到端自检（无头，打印 PASS/FAIL）
./build/SwiftDown.app/Contents/MacOS/SwiftDown --selftest SwiftDown-PRD.md
```

**不需要装 Xcode**：本机 Command Line Tools 的 macOS SDK 含 SwiftUI/AppKit，  
`Scripts/build-app.sh` 完成「SPM 编译 → 组装 .app → ad-hoc 签名」。  
细则与限制见设计文档 ADR-02。

---

## 二、工程结构

```
Packages/
├── SwiftDownCore/        状态机 + 自动保存 + 冲突仲裁（22 测试）
├── SwiftDownPipeline/    解析（swift-markdown 0.9.0）→ 抽象 
AST（18 测试）
├── SwiftDownEditorKit/   文本缓冲 + 撤销栈 + 语法辅助（25 测试）
└── SwiftDownApp/         可执行 App（本层）
    └── Sources/SwiftDown/
        ├── SwiftDownApp.swift     @main、菜单命令、AppDelegate、文件打开回调
        ├── SelfTest.swift         --selftest 端到端自检
        ├── Model/
        │   ├── DocumentTab.swift  单文档视图模型（状态机投影 + 解析管线 + 监控）
        │   └── Workspace.swift    标签集合、三态布局、冲突/关闭/会话协调
        ├── Infra/
        │   ├── DiskFileStore.swift  原子写 + 编码探测（UTF-8/UTF-16/GB18030）
        │   ├── FileWatcher.swift    vnode + 500ms 防抖 + 自写 hash 去噪
        │   ├── SessionStore.swift   标签会话持久化
        │   ├── AppSettings.swift    主题/字体/字号/行号/最近打开
        │   └── LocalState.swift     替代 @State 的局部状态容器（ADR-02）
        ├── Views/
        │   ├── RootView.swift      布局、横幅、状态栏、空态、拖放
        │   ├── TabBarView.swift    标签栏（切换/关闭/右键/拖拽排序）
        │   ├── OutlineView.swift   大纲（H1–H3，跟随高亮）
        │   ├── PreviewView.swift   AST → SwiftUI 分块渲染
        │   ├── ConflictSheet.swift 冲突三选一
        │   └── Editor/             编辑器（TextKit 2 + 高亮 + 行号）
        └── Render/                 代码高亮、行内节点渲染
```

---

## 三、已实现需求对照

| 需求         | 落地方式                                                                         | 验证手段                         |
| ---------- | ---------------------------------------------------------------------------- | ---------------------------- |
| FR-01 打开   | ⌘O 面板 / 拖放 / Finder 关联（Info.plist 注册 md/markdown/mdown/mkd）；同路径去重聚焦；>20MB 只读 | 自检：打开、去重、24MB 只读             |
| FR-02 渲染   | GFM 全量块：标题/段落/列表/任务/表格/引用/代码块/水平线/HTML 块降级；10+ 语言高亮；相对路径图片；远程图片不加载（零网络）      | 90 块 / 34 标题真实文档渲染           |
| FR-03 分屏   | 三态 ⌘1 / ⌘⇧1 / ⌘2；200ms 防抖解析；按标题节点对齐滚动                                        | 自检：三态视图构建、解析耗时               |
| FR-04 编辑   | TextKit 2、Markdown 语法高亮、行号标尺、⌘B/⌘I 包裹、列表回车续行、无上限撤销、2s 自动保存 + 失焦/退出强制落盘       | 自检：脏态、2s 落盘、clean 回正、编辑器内容一致 |
| FR-05 标签   | 切换 / 关闭 / 关闭其他 / 全部 / 拖拽排序 / 会话恢复 / 未保存拦截；溢出可配单行滚动（两侧箭头）或多行换行（≤3 行，超出栏内滚动） | 自检：切换 0.08ms、会话恢复 2 标签、箭头/换行判定与两种模式渲染快照 |
| FR-06 外部变更 | vnode 500ms 防抖、hash 自写去噪、clean 静默重载、dirty → 冲突三选一、删除 → 失联 + 重定位              | 自检：静默重载、冲突、冲突期不写盘            |
| FR-07 主题   | 跟随系统 / 白天 / 黑夜（落地到 `NSApp.appearance`，编辑器与菜单同步）；4 种等宽字体；字号 ⌘+/⌘−；行号开关；持久化    | 菜单项 + 设置页 + 自检断言外观名          |
| FR-08 最近打开 | 20 条去重置顶，失效置灰保留，菜单 + 空态列表                                                    | 空态列表可见                       |
| FR-09 大纲   | 侧栏 H1–H3，点击双向跳转，跟随光标高亮                                                       | 视图构建验证                       |

---

## 四、自检基线（`--selftest`，65 项全 PASS）

```
FR-01 打开文件 / 重复打开聚焦不新建                    PASS
FR-02 解析产出渲染块  blocks=90 headings=34            PASS
FR-03 解析耗时  8.7ms / 21104 字节                     PASS
视图构建  仅源码 / 分屏 / 仅预览（含编辑器存在性断言）  PASS
FR-04 编辑器 NSTextView 已挂载 / 内容一致 / 可撤销      PASS
FR-04 行号标尺已创建                                   PASS
FR-04 行号实际产生编号  count=25 lines=291             PASS
FR-04 行号自 1 连续递增 / 不超过逻辑行数               PASS
NFR-02 行号定位 2000 次 0.55ms（二分，O(log n)）        PASS
FR-05 复制文件路径 / 复制所在文件夹路径                 PASS
FR-04 编辑→脏 / 2s 落盘 / 回正 clean                   PASS
FR-06 静默重载 / 冲突 / 冲突期编辑冻结 / 内存不丢        PASS
FR-06 冲突期自动保存不写盘 / 状态不被改写               PASS
FR-06 采用磁盘版→clean + 正文取磁盘内容                 PASS
FR-05 二标签打开 / 切换生效 / 切换 0.08ms / 关闭        PASS
FR-05 会话恢复标签数 + 路径 + 活跃标签                   PASS
FR-01 超 20MB 进入只读（24MB）                          PASS
FR-09 大纲随解析完成自动刷新  首帧=0 → 最终=60          PASS
FR-09 大纲标题数与 AST 一致  60 / 60                    PASS
FR-07 默认快捷键 ⌘O / 冲突可检出 / 自身不冲突            PASS
FR-07 快捷键改动可持久化 / 单项与全部恢复默认            PASS
FR-07 设置里的默认布局生效  仅预览                       PASS
```

自检跑在独立 UserDefaults 域（`dev.swiftdown.app.selftest`）里，  
结束后清空——真实用户的最近打开、快捷键、布局不会被测试污染。

真实启动验证：`open build/SwiftDown.app` → 屏幕出现 1180×760 单窗口；  
`open -a ... SwiftDown-PRD.md` → 会话文件记录该文件为活跃标签；无崩溃报告。

`--snapshot` 可额外把当前界面离屏渲染为 `/tmp/swiftdown-selftest.png`，  
用于人工核对排版与行号对齐（自检证明结构对，证明不了观感）。

---

## 五、过程中修掉的 4 个真缺陷

1. **冲突期在途自动保存覆盖磁盘**（Core 语义缺陷，最严重）  
   `dirty` → `conflict` 后，此前排定的 2s 自动保存仍会执行并把内存版写入磁盘，静默丢弃他人版本——直接违反 FR-06。  
   修复：`saveNow` 在 conflict 态直接拒绝；`flushBeforeDeactivation` 同样不写盘；写盘唯一入口收敛为内部 `writeToDisk()`，仅 `resolveConflict(.keepMine)` 可调用。已补 2 条回归单测。
2. **FileWatcher 重启监听时误关新 fd**  
   取消处理器闭包捕获 `self.fileDescriptor`，而重启时该字段已指向新 fd，导致新监听被自己关掉、后续外部变更全部漏报。  
   修复：cancel handler 捕获创建时的局部 `fd`。
3. **会话写盘异步导致退出丢最后一次状态**  
   `SessionStore.save` 用后台队列写，退出时进程先死会让最后的标签集合丢失。  
   修复：改为同步原子写（几百字节，<1ms）。
4. **视图模型状态滞后一帧**  
   Core 通过事件异步投递，用户动作后的 UI 反馈晚一个事件循环。修复：用户主动触发的迁移在同步路径上补 `syncState()`。

---

## 五之二、第一轮人工验收后修掉的问题

### 1. 行号一个都不显示（根因：假定错了 TextKit 版本）

当时判断 `MarkdownTextView` 走的是 TextKit 1 构造路径（`textLayoutManager` 为 `nil`），  
而行号标尺只实现了 TextKit 2 取行路径，于是返回空数组——标尺画了背景和分隔线，却一个数字都不画。  
自检当时只断言「`NSRulerView` 子视图存在」，没断言内容，所以漏了。

> 注：这个判断本身是错的（现代 macOS 上 `NSTextView(frame:)` 默认给 TextKit 2），  
> 真相与后续修正见 §五之四 和 ADR-06。

修复（`LineNumberRulerView`）：

- 按视图实际引擎分流：有 `textLayoutManager` 走 TextKit 2，否则走 `layoutManager.enumerateLineFragments`；
- 自检新增「行号实际产生编号 / 自 1 连续递增 / 不超过逻辑行数」三条内容断言。

**教训**：断言图表对象存在 ≠ 断言它画出了东西。凡是「渲染类」功能，断言必须落到内容或像素。

### 2. 滚动发「僵」（三处真实开销）

| 位置                               | 原实现                            | 问题                   | 修复                                                   |
| -------------------------------- | ------------------------------ | -------------------- | ---------------------------------------------------- |
| `topVisibleLine` / `currentLine` | 每次从文档起点 `while` 数换行            | 每帧 O(n)，大文档必卡        | 编辑器内缓存逻辑行起始表 + 二分，O(log n)；2000 次定位实测 0.55ms         |
| 行号绘制                             | 每次从文档起点枚举全部行片段                 | 每帧 O(全文)，滚动越深越慢      | 改用 `glyphRange(forBoundingRect: visibleRect)` 只枚举可见行 |
| 滚动通知                             | `Task { @MainActor }` 二次派发     | 主队列堆积大量任务            | 通知本身已在主队列，直接同步处理                                     |
| 滚动 → `focusedLine`               | 每变化一行就写 `@Published`           | 触发 SwiftUI 整树重算，每帧一次 | 80ms 节流合并；光标移动不节流                                    |
| `EditorTheme`                    | `updateNSView` 每帧新建（含 3 次字体构造） | 吃掉帧预算                | `ThemeCache.theme(fontSize:family:)` 缓存              |

### 3. 状态栏右下角模式切换改为可点

原来是纯文本 `分屏`。改为三个图标按钮（仅源码 / 分屏 / 仅预览），当前态高亮，  
tooltip 带快捷键（⌘1 / ⌘⇧1 / ⌘2），与「视图」菜单共用 `Workspace.setViewMode`。

### 4. 标签右键新增路径复制

新增 `复制文件路径` / `复制所在文件夹路径`，同时写入字符串与 `fileURL` 两种剪贴板类型  
（前者可粘到终端，后者能被访达与 Xcode 识别）。已加自检项。

---

## 五之三、第二轮人工验收后修掉的问题 + 新增设置

### 1. 首次打开大纲不显示（根因：视图没观察文档对象）

`OutlineView` 只观察 `workspace`，标题树直接读 `tab.ast`。而首次打开文档时 AST 是  
**后台异步解析**的，解析完成只让 `tab` 发 `objectWillChange`——没人订阅，视图不重算。  
切换视图模式会重建整棵 SwiftUI 树，所以「切一下才冒出来」。

修复：抽 `OutlineList`（`@ObservedObject var tab`）专门渲染标题树；外层只负责取 `activeTab`。  
顺带给 `DocumentTab` 补 `isParsing`，解析期间显示「解析中…」而不是「当前文档没有标题」。

**回归测试怎么写的**（这是关键）：光断言「AST 有 60 个标题」抓不到这个 bug——数据一直是对的。  
所以加了 `DebugProbe` 渲染探针，记录大纲视图 body 的**真实求值次数与当时的标题数**，  
并按原时序复现：先建视图（此时 AST 为空）→ 等解析完成 → 断言最终渲染出 60 条。  
自检输出 `首帧=0 最终=60 重算次数=68`，正好证明「空 → 自动补齐」这条路径走通了。

### 2. 新增设置窗口（⌘,）

PRD §FR-07 只要求主题与字体，这里的设置面板属于**用户追加需求**：

| 页   | 内容                                                          |
| --- | ----------------------------------------------------------- |
| 通用  | 外观（跟随系统/白天/黑夜，分段控件置顶）、默认布局（仅源码/分屏/仅预览）、启动时恢复上次布局开关、字体、字号、行号 |
| 快捷键 | 14 个动作的键位绑定，点击即录制（按 Esc 取消）、单项/全部恢复默认、冲突提示                  |
| 关于  | 版本与零网络说明                                                    |

**默认布局的优先级**：`启动时恢复上次布局` 开（默认）→ 沿用上次退出前的布局，  
没有记录时用默认布局；关 → 每次启动都固定用默认布局。  
两条路径都写进了自检。

**快捷键实现要点**：

- `ShortcutBinding`（单字符键位 + 修饰键数组）→ `KeyEquivalent` / `EventModifiers`，菜单里所有  
  `.keyboardShortcut` 都改为从设置读取，改完即时生效；
- 只存「用户改过的动作」的覆写表（JSON），将来新增动作时老配置不会因缺键失效；
- 录制用 `NSEvent.addLocalMonitorForEvents` 捕获下一次按键：禁止裸字符（会抢编辑器输入）、  
  与已有动作冲突则拒绝并提示占用者、Esc 取消；
- 菜单与 `Commands` 通过 `@ObservedObject settings` 联动刷新。

---

## 五之四、第三轮人工验收后修掉的问题

### 1. 行号全是 1（生产引擎与自检引擎不是同一个）

上一轮修完「行号一个都不显示」，实机却变成**每一行都显示 1**。两件事叠加：

- `NSTextView(frame:)` 在现代 macOS 上其实**默认是 TextKit 2**（上一轮文档里的判断是错的）。  
  只有「访问过 `layoutManager`」才会被静默降级成 TextKit 1。生产路径一直跑在 TextKit 2 分支上。
- TextKit 2 分支把 `NSTextLineFragment.characterRange.location` 当成了**全文偏移**。  
  它是**相对文本元素（段落）**&#x7684;偏移，于是每个段落的第一个字符都是 0 → 全部算成第 1 行，  
  而 `isLogicalLineStart(0)` 恒真，所以每行都画了一个 "1"。

顺带暴露了更严重的问题：**自检跑的不是生产路径**。上一版自检里写了  
`editor.layoutManager?.ensureLayout(for:)`，这一句把视图降级成了 TextKit 1，  
于是自检走的是「兼容分支」，生产分支从未被覆盖——测试全绿而功能是坏的。

修复（`LineNumberRulerView`）：

- TextKit 2 分支改为 `元素起点 + 行片段在元素内的偏移`，用  
  `layoutManager.offset(from: documentRange.location, to: fragment.rangeInElement.location)` 换算；
- 枚举起点从「可见顶部上方 4 行」开始、越过可见底部即停，避免为了画行号把整篇文档布局一遍；
- y 坐标统一走 `convert(_:from: textView)`，不再手工叠 `originY`（旧写法把 inset 加了两遍）；
- 自检改为 `textLayoutManager.ensureLayout(for:)`，并新增  
  **「自检覆盖生产排版引擎 = TextKit2」** 与 **「TextKit 1 回退路径行号同样连续」** 两条断言。

**教训**：测试若改动了被测对象的内部状态（这里是一次看似无害的 `layoutManager` 访问），  
它测的就不再是生产路径。凡是「引擎/模式分流」的代码，自检要先断言**当前跑在哪个分支**。

### 2. 主题设置要能真正切白天 / 黑夜

设置里本来就有「主题」，但只接了 SwiftUI 的 `.preferredColorScheme`——它只管 SwiftUI 自己画的子树。  
编辑器（NSTextView / NSScrollView）、行号标尺、菜单、右键菜单、打开面板都是 AppKit 视图，不会跟着变。

修复：

- 新增 `AppAppearance.apply(_:)`：把偏好写到 **`NSApp.appearance`**（`.aqua` / `.darkAqua` / `nil`），  
  真正覆盖整窗（含设置窗口、菜单、面板）；
- 落地位置收在 `AppSettings.themeMode` 的 `didSet` 里，菜单/设置/恢复默认三条入口都走同一处；  
  `AppEnvironment.init` 里显式再应用一次（属性观察器在 init 阶段不触发，否则启动时配置不生效）；
- 文案改为**跟随系统 / 白天 / 黑夜**，通用页把「外观」提到第一组，用分段控件（原来藏在第二组容易被忽略）。

### 3. 状态栏行数口径与行号不一致

状态栏用 `\n` 个数 +1，行号标尺不算末尾空行：同一个文件会显示「行 1/17」而标尺最大到 16。  
统一到标尺口径（末尾换行不额外算一行）。

### 4. 自检会误删用户会话（顺手修掉）

自检收尾时删除的是 `~/Library/Application Support/SwiftDown/session.json`——  
用户真实会话文件，跑一次 `--selftest` 就等于清空「上次打开的标签」。  
修为 `SessionStore(directory:)` 可注入，`--selftest` 落到临时目录，收尾只删临时目录。

> 遗留观察：`FR-06 冲突期自动保存不写盘` 曾偶发失败一次（磁盘被写入内存版），  
> 怀疑与 `didResignActive → flushAll()` 在冲突检测窗口内抢先落盘有关；  
> 单跑/并发压测均未能稳定复现，M2 压测时复核。

### 5. 打开就弹「文件已被外部修改」并转圈卡死（第四轮反馈）

现象：跑自检或启动后，窗口弹出一个 `selftest.md` 的冲突三选一面板，随后整个应用转圈点不动。

根因链条有三层：

1. **自检真的会造冲突**：`FR-06` 用例故意在标签变脏后改写磁盘文件，制造外部修改冲突——这是必需的用例，不是脚本写错。
2. **冲突处理入口挂错了**：`resolveConflict(_:)` 的守卫是 `guard let prompt = pendingConflict`，  
   而这次为了「不自动弹窗」把 `pendingConflict` 的自动赋值去掉了 → 通过模型直接调进来永远是空操作，  
   冲突解不掉、标签一直冻结（自检里表现为「采用磁盘版后仍是 conflict」）。  
   修法：新增 `resolveConflict(_:for:)`，落点是**标签**；无参版本只在弹窗场景下转发。
3. **自检进程弹了模态面板**：`RootView` 上的 `.sheet` / `.alert` / `.confirmationDialog` 在无头进程里  
   会进入 SwiftUI 的重复呈现重试，主线程原地打转 → 你看到的转圈。  
   修法：`Workspace.isSelfTest` 时 `RootView` 只渲染 `core` 内容，不挂任何模态 presentation；  
   自检改为断言模型状态（`pendingConflict == nil`）。

同时堵住幽灵标签的来源：

- `persistNow()` 写会话前就过滤临时路径（不只在恢复时过滤），真实进程不再把 `…/T/swiftdown-selftest-*/selftest.md` 固化进 `session.json`；
- `AppSettings.noteOpened` 不再把临时路径写进「最近打开」；
- 自检临时目录改 `defer` 清理（中途失败/被杀也不留垃圾），并顺带清理 1 小时前的历史残留  
  （此前每次崩溃留 24MB 大文件样本，实测积了 5 个共 120MB）。

验证：release 版自检 56 项全 PASS、68s 正常退出、临时目录 0 残留；手工构造含幽灵路径的 `session.json` 冷启动，无弹窗、只恢复真实文件。

---

## 五之六、标签栏溢出策略（第五轮反馈）

需求：文件开多了标签放不下，希望能选「多行显示」或「单行 + 滚动箭头」。

实现（`Views/TabBarView.swift` + `Views/TabBarLayout.swift`）：

- 设置 → 通用 → **标签栏 → 溢出显示**：`单行` / `多行`，存 `swiftdown.tabBarStyle`，即时生效。
- **单行**：`ScrollView(.horizontal)` + 两侧 `chevron` 按钮，切换标签自动 `scrollTo` 居中；
  箭头是否出现由 `TabBarMetrics.needsArrows(contentWidth:containerWidth:)` 判定——
  只有内层内容真的宽过容器才出箭头（不做「预留箭头宽度」的保守判断：内容在 ScrollView 里，
  宽度与可视宽度无关，严格比较本身就不会抖）。
- **多行**：自研 `TabFlowLayout`（`Layout` 协议，flow 语义）；标签宽度随文件名变化，
  用 `LazyVGrid` 会做成等宽格子，不合适。栏高由内容高度决定并**封顶 3 行**（102pt），
  超出改为栏内纵向滚动——不做无限长，避免把编辑区挤没。
- 两种模式共用同一份 `tabItems`，右键菜单、拖拽排序、关闭行为完全一致（避免两套实现漂移）。
- 设置窗口高度 460 → 600：加一组后原来要滚动才看得到新设置。

验证：`--selftest` 65 项全 PASS；新增 5 条断言（出箭头阈值、临界值、换行行数计算、3 行封顶、
两种模式离屏渲染高度）+ 快照 `Docs/screenshot-tabbar-scroll.png` / `-wrap.png`。
实机：34 个标签下多行模式 3 行封顶且出现纵向滚动条，单行模式箭头正常。

---

## 六、已知限制（不影响 M1 出口，M2 处理）


| 项 | 现状 | 计划 |
|---|---|---|
| 预览渲染容器 | SwiftUI LazyVStack，超长文档可能滚动跳动 | M2 若 10MB 丢帧 >5% 切自研虚拟化容器（ADR-03） |
| 代码高亮精度 | 词法扫描，语义不准 | M2 评估 tree-sitter 体积/收益（ADR-04） |
| 预览↔源码滚动同步 | 仅「光标/滚动 → 预览按标题对齐」，反向未做 | M2 补预览滚动 → 编辑区对齐 |
| 安全书签 | 未实现（PRD 非沙箱分发，TCC 首次授权即可） | v1.0 打包时按需补 |
| 大文档预览 | >2MB 暂停实时预览（编辑不受影响） | M2 分块渐进提交 |
| 行号 | >2MB 不绘制 | M2 视口行号增量计算 |
| 撤销栈 | 用 NSTextView 原生（会话内无上限），EditorKit 自研栈保留 | 需要跨会话撤销时切换 |
| 窗口记忆 | 未做窗口尺寸/位置记忆 | v1.0 前补 |
| 应用图标 | 无 | v1.0 前补 |
| 拖拽排序 | 已实现但未经人工确认手感 | 需真机验收 |

---

## 七、下一步建议（M1 收尾 → M2）

1. **人工验收**：打开几个真实文档，检查排版观感、行号对齐、高亮是否有误伤（这三项自检无法替代肉眼）。
2. 补「预览 → 源码」反向滚动同步（FR-03 双向要求）。
3. M2 主线：10 标签内存实测、1MB/10MB 滚动丢帧实测（Instruments），据此决定 ADR-03 是否切换渲染容器。
