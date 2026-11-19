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

## 五之七、打开第二个文件时「闪一下」的定位与修复（第七轮，已改代码）

> **后记（第十轮）：本节第七轮的归因也是错的。** 真正的原因是 SwiftUI 在外部打开事件里
> 先 `-[NSWindow _close]` 再激活窗口，见文末「第十轮」。本节的视图复用改动保留（它本身
> 是对的架构），但「这就是闪的来源」这个判断已被帧级探针推翻——换文档全程没有白帧。

现象：应用运行中从访达双击另一个 `.md`，窗口会闪一下。

### 第六轮的误判

第六轮用 `screencapture -l <windowID>` 连拍比对，得出「这是应用激活过渡、前台打开不复现」的结论，并回滚了修复。
这个结论**不成立**：`screencapture` 单帧耗时在百毫秒量级，而一帧空白在 60Hz 上只有 16.7ms，
这个采样率根本抓不到。真正有判别力的是「视图实例是否被销毁」，不是截图。

### 第七轮的定位

直接看视图身份：`RootView` 上 `EditorView` 挂的 `.id(tab.id)` 让每次打开/切换文档都改变视图身份，
SwiftUI 于是销毁整棵编辑区子树并重新创建——`NSScrollView` / `NSTextView` / `NSTextStorage` / 行号标尺
全部重建，且「旧视图移除」与「新视图挂载」跨一个 CA 事务，中间那一帧就是用户看到的空白。

其他编辑器不闪，是因为它们切换文档时**从不销毁编辑器**：TextEdit 换 `attributedString`，
VS Code 换 Monaco 的 model，Typora 同理。这是架构差异，不是绘制性能差异。

### 修复

- 去掉 `.id(tab.id)`；`EditorView.updateNSView` 检测 `tab` 身份变化后调用 `Coordinator.adopt(_:)`：
  替换文本存储、重刷高亮、清空撤销栈、复位选区与滚动，行为与「每份文档一个干净视图」等价。
- 第六轮踩的两个坑都有确定性解法（详见 ADR-13）：
  1. 标尺宽度原本只在 `draw` 里更新，晚于文本区重排 → 新增 `prepareForNewDocument()` 主动算宽度，
     再 `layoutSubtreeIfNeeded()`，最后把 `textView.frame` 贴到 `contentView.frame.width`；
  2. adopt 跑在 SwiftUI 布局期，期间用 `isAdopting` 屏蔽 `boundsDidChange` 与
     `textViewDidChangeSelection` 回写 `focusedLine`，状态重置推到下一轮 runloop。

### 回归方式

自检断言**实例同一性**（切换前后 `NSTextView` 必须 `===`），并覆盖第六轮的两个翻车点：
标尺确实随位数变宽（46 → 50）、文本区宽度 == `clipView` 宽度、切换后行号仍连续。
把 `.id(tab.id)` 加回去，这组断言会立即 FAIL——断言有效性已验证过。

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

### 第八轮：量化「像卡死又重开」

上一轮改完视图复用后仍有反馈。这次改用帧级探针（主 runloop 每次 `beforeWaiting` 采样
窗口属性 + 编辑器实例 + 内容区像素），得到两条硬结论：

1. **视图层是干净的**：打开文件全程 `alpha` 恒为 1、`isVisible` 恒为 1、窗口号不变，
   `NSTextView` 自始至终同一个实例，内容区像素里没有白帧。
2. **主线程被高亮按死**：4.8MB / 330 万字符的文档，`open` 到内容上屏之间**一帧都没有**，
   阻塞 2.5 秒，其中 2548ms 全在 `MarkdownHighlighter.apply` 的全文扫描上。

所以「像关闭又重新打开」= 窗口两秒半不动 + 之后内容一次性换掉，不是窗口真的重建了。

修法与取舍见 ADR-14：大文档只刷可见区（滚动补刷），高亮推迟到上屏之后。
同一份文档 `open → 上屏` 从 2548ms 降到 51ms。

探针保留在 `Infra/OpenTrace.swift`，用法：

```bash
# 模拟「先开 A，运行中再开 B」，打印每阶段耗时与逐帧窗口状态
SwiftDown --trace --start A.md --trace-open B.md
```

正常启动不传这些参数时是空操作，零开销。

### 第九轮：为什么「应用程序」里有两次 SwiftDown

反馈：`/Applications` 里只有一个 app，但应用列表里出现两个图标。

排查顺序（先看系统怎么看，而不是先看文件夹）：

```bash
ls -ld /Applications/SwiftDown*.app                    # 只有一个
mdfind "kMDItemCFBundleIdentifier == 'dev.swiftdown.app'"
#   /Users/txran/Documents/LearningSpace/SwiftDown/build/SwiftDown.app
#   /Applications/SwiftDown.app
```

两条命中，版本都是 0.1.2、bundle id 一模一样、图标一样。原因不在文件夹，而在**身份**：
两个 bundle 共用同一个 `CFBundleIdentifier`，LaunchServices 把它们当成同一个应用的两份。
另外 `lsregister -dump` 显示积累过 108 条注册记录（历史测试反复复制、`lsregister -f` 留下，含指向已删路径的僵尸项）。

修法与实测依据：

| 措施 | 验证 |
|---|---|
| 开发构建改身份 `dev.swiftdown.app.dev` / 名「SwiftDown Dev」 | `PlistBuddy` 核对两个产物 id 不同 |
| 产物移入 `build/.dev/` | `mdimport` 后 `mdfind -onlyin build/.dev` 为空；同目录下的普通目录对照组有结果 |
| `build/SwiftDown.app` 改为符号链接 | 链接路径同样不被索引，`open` / `--selftest` 走链接一切正常 |
| `package-app.sh` 传 `SWIFTDOWN_DIST=1` | 打包产物仍是正式身份，装到「应用程序」只覆盖那一份 |
| 删除 `/tmp` 测试副本 + `lsregister -u` 注销失效路径 | `mdfind` 只剩 `/Applications` 一条 |

脚本上踩到一个坑：`echo "…$APP_LINK（符号链接…）"` 里变量紧跟全角括号，bash 把 `（` 当成变量名的一部分，
报 `APP_LINK?: unbound variable`。写成 `${APP_LINK}` 或让括号不紧跟变量。

自检仍为 72 项全 PASS（开发版走新身份、走符号链接路径都能通过）。

### 第十轮：闪一下的真因 —— SwiftUI 自己关了一次窗口

反馈：「已经一个应用了，但打开 app 的情况下再打开其他 md 还是会闪一下，像关闭重开，可 PID 没变。」
PID 不变这一句把范围压到了「画面被重置」，而不是进程重启。

前两轮的两次误判，写在这里当反面教材：

| 轮次 | 结论 | 依据 | 为什么错 |
|---|---|---|---|
| 第六轮 | macOS 应用激活过渡 | `screencapture -l` 连拍 | 单帧百毫秒级，抓不到 16.7ms 的帧，工具本身没有判别力 |
| 第七轮 | `.id(tab.id)` 重建视图漏白帧 | 代码推理 | 帧级探针显示全程 `alpha=1`、`vis=1`、像素无白帧，推理没被验证 |

本轮做法：事件级探针（新文件 `Infra/TraceEvents.swift`）订阅窗口/应用通知，并在
`isVisible == false` 的瞬间打印 `Thread.callStackSymbols`。栈很干脆：

```
-[NSWindow _close]
  ← SwiftUI.AppWindowsController.activateWindowForExternalEvent(matching:handler:)
  ← SwiftUI.AppWindowsController.open(urls:)
  ← SwiftUI.AppDelegate.application(_:open:)
```

**SwiftUI 在处理外部打开事件时，会先把当前窗口关掉，再为文档激活窗口。**
单窗口 + 自管标签的结构里这步纯属多余，屏幕上的表现就是一闪。

试过但无效：

- `.handlesExternalEvents(matching: ["*"])` —— 只对 `WindowGroup` 生效，单 `Window` 上是空操作，实测照样闪。
- `window.isRestorable = false` —— 不是原因，实测照样闪。

采用：`AppDelegate.applicationWillFinishLaunching` 里用 `NSAppleEventManager` 接管
`kAEOpenDocuments`，自己解析 `keyDirectObject` 塞给 `Workspace`。SwiftUI 收不到事件，也就没得关。
必须装在 `willFinishLaunching`：AppKit 在启动阶段就分发 open 事件，装晚了第一份文件还是走 SwiftUI。

实测（发行版二进制 + `--trace` 逐帧采样）：

| 场景 | `vis=0` 次数 |
|---|---|
| 运行中打开另一个 md | 1 → **0** |
| 连续打开 3 个文件 | 3 → **0** |
| 冷启动打开文件 | 内容正常（启动期窗口尚未上屏，不计） |

同时修掉一个测试中暴露的真实小洞：`isTemporaryPath` 只比对 `NSTemporaryDirectory()`
（`/var/folders/…/T`），漏了 `/tmp`。打开过 `/tmp/*.md` 之后这些路径会写进 `session.json`，
下次启动恢复出几个已不存在的标签——就是之前处理过的「幽灵标签」。现在 `/tmp` 与 `/private/tmp` 一并算临时。

自检 72 → **74 项全 PASS**，新增两条：`FR-05 已接管打开文稿事件`（反向验证：去掉接管立即 FAIL）、
`FR-05 /tmp 下的路径同样视为临时`。

探针用法（正常启动零开销，标记文件删掉即彻底关闭）：

```bash
touch /tmp/swiftdown-trace.on                 # 打开探针，日志写 /tmp/swiftdown-trace.log
open -a /Applications/SwiftDown.app a.md      # 由系统启动，才能复现「访达打开」事件
open -a Finder && open -a /Applications/SwiftDown.app b.md
rm /tmp/swiftdown-trace.on
```

### 第十一轮：中键点击标签关闭

需求：鼠标中键点标签就关（Safari / VS Code 的手感），不改动现有的左键切换、右键菜单、拖拽排序。

SwiftUI 没有中键手势。先试了「叠一层视图，在 `hitTest` 里读 `NSApp.currentEvent` 判断是哪个键」——
这是网上最常见的写法，但**实测不成立**：

```swift
// 探针：NSWindow + 自定义 NSView，记录 hitTest 期间能否读到 currentEvent
win.sendEvent(leftMouseDown)   → hitTest 次数=1, currentEvent=nil
app.sendEvent(leftMouseDown)   → hitTest 次数=1, currentEvent=nil
```

`NSApplication.sendEvent` / `NSWindow.sendEvent` 期间 `currentEvent` 都是 nil，拿不到按键号。
（另外 `NSEvent.mouseEvent(with:…)` 没有 `buttonNumber` 参数，合成事件永远是左键；
要造真实按键号得走 `CGEvent(mouseButton: .center)` → `NSEvent(cgEvent:)`，
但那条路 `windowNumber` 恒为 0，投不进任何窗口。）

最终实现分两半：

| 组件 | 职责 | 关键点 |
|---|---|---|
| `MiddleClickZone`（NSView） | 每个标签叠一层 | `hitTest → nil`，**完全不参与命中测试**，左键/右键/拖拽/滚轮照常穿透 |
| `MiddleClickCenter` | 窗口级本地监听 + 落点判定 | 只收 `otherMouseUp` 且 `buttonNumber == 2`；矩形用 `view.convert(view.bounds, to: nil)` **当场算**，滚动/换行/缩放都不会过期 |

矩形不缓存是刻意的：单行模式下标签在 `ScrollView` 里横向滚动，缓存的坐标必然过期；
`convert(bounds, to: nil)` 每次给的都是当前窗口坐标。

顺带修掉一个 0.1.3 引入的问题：接管 `kAEOpenDocuments` 之后 AppKit 的默认处理不再执行，
**没人回复发送方**。实测连续 `open -a` 会报 `-1712`（Apple Event 超时）。现在解析完 URL 先回一个
空错误列表（`descriptorType == typeNull` 时不能碰 reply），再异步打开。

自检 74 → **80 项全 PASS**，新增 6 条：中键抬起 + 落在标签内才命中、落在外不命中、
左键/右键不命中、中键按下（非抬起）不命中、覆盖层 `hitTest` 必须返回 nil、注销后不再命中。
断言用真实 `NSWindow` + `NSView` 几何，不依赖真实鼠标。

已知限制：触控板与单键鼠标没有中键，该功能对其无效（可用 ✕ 或 ⌘W）。

---

## 第十二轮：冷启动「29 秒空档 / -1712」排查（0.1.5）

上一轮留下的观察：冷启动恢复多标签时，探针日志出现 29s 空档，与 Apple Event 30s 超时吻合，
期间 `open -a` 报 -1712；运行期打开只要 0.09s。

### 先解决「测不出来」

既有探针（`OpenTrace` 帧采样、`TraceEvents` 通知订阅）都跑在主线程上。主线程一卡住，它们自己
也不出字——日志里只剩一个无法归因的空档，分不清是「主线程被阻塞」「主线程空闲没事件」
还是「进程还没跑到探针安装点」。新增 `LaunchProbe`：

| 设计点 | 做法 | 解决什么 |
|---|---|---|
| 时间基准 | `proc_pidinfo` 取内核记录的进程启动时刻 | 把「exec 之后到第一行 Swift 代码」也算进时间线 |
| 心跳 | 独立线程每 100ms 往主队列投一次往返 | 主线程卡住时它照样能写字 |
| 归因 | `thread_get_state` 从别的线程读主线程 PC，`dladdr` 反查符号 | 直接给出「卡在哪个函数」，不用猜 |

### 实测结果

```
[launch] +  468.3ms  AppEnvironment.init 进入
[trace] mark ... open 开始 M0-技术预研任务书.md 6KB
[trace] mark ... (Δ 5327.23ms) DocumentSession 建立（已读盘）   ← 6KB 文件读了 5.3 秒
[launch] + 5943.0ms ⚠️ 主线程阻塞 5474ms
         热点：libsystem_kernel.dylib:__open×47 | write×1 | os_unfair_lock_lock×1
```

同一个文件从终端直接运行进程读：**0.2ms**。所以慢的不是解析、不是渲染，是特定上下文里
系统的文件打开动作（LS 启动 + 首次执行）。会话恢复有几个文件就是几个这样的坑，
串行压在主线程的启动阶段 → `didFinishLaunching` 迟迟不返回 → 打开事件没人应答（-1712）。

### 两条结构性修法

1. `Workspace.open(url:)` 改异步：`nonisolated static loadFromDisk`（SE-0338，不继承调用者 actor）
   读内容 + 尺寸，主线程只装配。`DocumentSession` 新增 `init(url:content:store:)`，
   构造过程不碰文件系统。`openingPaths` 去重；`open(urls:)` 单 Task 顺序 await 保序。
2. 会话恢复两段式：`prepareSessionRestore()` 只读元信息（几百字节，布局必须在首帧前定），
   `performSessionRestore()` 在首个 `NSWindow.didUpdate` 之后执行（1s 兜底）。

顺带：启动阶段用户主动打开的文件不再被恢复抢走活跃标签（判据不能用「恢复开始时 tabs 是否为空」，
用户那份可能正在读盘、快照里还是空的）。

### 验证

| 场景 | 结果 |
|---|---|
| `didFinishLaunching` | +388 → **+329ms** |
| 窗口首帧 | +498 → **+366ms** |
| 冷启动带文件（4 次） | 95–122ms，无 -1712 |
| 运行中打开 | 77–86ms，窗口 vis 全程 1 |
| **FIFO 永久阻塞读盘** | 阻塞期间另开文件仍 **95ms 返回**，看门狗零次阻塞 |
| 判别力反证 | 同一看门狗在旧构建上抓到 5474ms 阻塞 |

自检 80 → **82 项全 PASS**：新增「读盘不在主线程同步完成」（改回同步立刻 FAIL）、
「启动阶段只读元信息、不读文档」。

**教训**：跑在主线程上的探针观测不到主线程卡死；要测「卡住」，心跳通道必须活在另一个线程上。

---

## 第十三轮：应用图标又变两个（0.1.5 之后）

现象：`/Applications` 里明明只有一份 SwiftDown.app，系统里却还是显示两个。

### 归因链

```
lsregister -dump | grep SwiftDown   → 732 条命中
  ├─ 37 条唯一路径
  │    ├─ /Applications/SwiftDown.app             ← 正式版，v0.1.5
  │    ├─ build/.dev/SwiftDown.app                ← 开发版，id dev.swiftdown.app.dev（安全）
  │    ├─ /private/tmp/sd{2,3,4,5,6,7}.app 等 11 个 ← id 全是 dev.swiftdown.app，v0.1.2~0.1.4
  │    └─ ~/.Trash/ 下 33 份历史构建副本
  └─ 其余为同一条目的多个记录
```

真凶是 `/private/tmp` 下那 11 个副本：**bundle id 与正式版完全相同**。这是前几轮做图标验证、
「全新安装首次启动」验证时复制出来的临时 app，用完没有清理。LaunchServices 按
`CFBundleIdentifier` 认身份，看到磁盘上有第二份同 id 的 .app 就当成「同一个应用的另一个拷贝」，
启动台/聚焦里便呈现多个同名图标——和 `/Applications` 里有几个文件无关。

废纸篓里的 33 份是历史遗留，但 `mdfind` 证实它们不进入 Spotlight 结果集，不影响显示；
`lsregister -u` 注销后还会被 mds 重新加回，不必纠缠。

### 处理

1. 注销并删除 `/private/tmp` 下 11 个临时 app（`lsregister -u` → `rm -rf`）。
2. 注销废纸篓中的失效注册（**不动废纸篓文件**）。
3. `lsregister -f /Applications/SwiftDown.app` 重注册正式版，`killall Dock` 刷新缓存。
4. 新增 `Scripts/doctor-app.sh`：

```bash
./Scripts/doctor-app.sh          # 体检：列出所有游离副本与身份冲突
./Scripts/doctor-app.sh --fix    # 修复：注销游离注册，删除 /private/tmp 下的临时副本，重注册 + 刷新 Dock
```

脚本只删 `/private/tmp`、`/tmp` 下的测试产物，废纸篓等用户目录只注销注册、不删文件。

### 复查

| 检查 | 结果 |
|---|---|
| `lsregister` 中存活的非白名单副本 | 0 |
| `mdfind "SwiftDown.app"` | 仅 `/Applications/SwiftDown.app` |
| `/Applications` 内容 | 仅 `SwiftDown.app`（0.1.5） |

**教训**：验证用的临时 app 必须换 bundle id，或者用完立刻删。只要同 id 的第二份文件在磁盘上
（哪怕在 `/tmp`），系统就会认为应用有两份。以后涉及身份/图标的验证，跑完 `doctor-app.sh` 收尾。

### 第十三轮补记：第二个图标其实是「SwiftDown Dev」

清完 `/private/tmp` 后用户反馈仍有两个，其中一个带 dev 标签 —— 那是开发构建本身。

排查过程里被否定的三个假设：

| 假设 | 证据 | 结论 |
|---|---|---|
| Dock 里被固定了两份 | `defaults read com.apple.dock persistent-apps` 里 SwiftDown 出现 0 次 | 不是 Dock 固定项 |
| 废纸篓副本被 Spotlight 收录 | `mdfind` 只返回 `/Applications/SwiftDown.app` | 不影响显示 |
| 把目录藏起来就够 | `build/.dev` 已是隐藏目录，仍出现 | 隐藏目录不是充分条件 |

真因链条：

1. 只要 `SwiftDown.app` bundle 在磁盘上，mds 扫描就把它登记进 LaunchServices ——
   **运行一次开发版也会立刻重新登记**（`lsregister -u` 后 `open -a` 一次，注册数 0 → 1）。
2. `.metadata_never_index` 对**已经建立过索引**的目录无效，实测注销后 25～40 秒即被回填。
3. 删除 `build/SwiftDown.app` 符号链接也没能阻止回填，所以链接不是元凶、保留即可。

结论：靠「注销 + 藏起来」只能短暂压住，唯一稳定做法是**磁盘上不留第二份 bundle**。
用户当时还同时开着正式版与开发版两个实例（截图菜单栏并排两组「SwiftDown Dev / SwiftDown」），
这也是 Dock 上短暂出现两个图标的原因。

### 最终处理

- `Scripts/build-app.sh clean`：注销注册 → 删除 `build/.dev/SwiftDown.app` → 重启 Dock。
- 构建脚本收尾保留「写 `.metadata_never_index` + 注销注册」，作为构建期间的减害措施，
  但文档明确写：调试完要 `clean`。
- `Scripts/doctor-app.sh` 把「开发版仍注册在 LaunchServices 里」列为告警项，`--fix` 会注销。

复查（清理后 20 秒）：

| 检查 | 结果 |
|---|---|
| LaunchServices 中存活副本 | 仅 `/Applications/SwiftDown.app` |
| `mdfind` 应用 bundle 查询 | 仅 `/Applications/SwiftDown.app` |
| 运行中实例 | 无 |

**教训**：macOS 认应用看磁盘上有没有 bundle，不看它在哪、叫什么、是否隐藏。
「同一个应用只留一份」的判据是文件系统，不是 LaunchServices 表。

---

## 第十四轮：全局查找与替换（0.1.6）

需求方直接提的：「增加全局搜索和替换功能，并支持在设置中修改快捷键」。
不在 PRD 需求表内（PRD 的 FR-10 是导出 HTML/PDF，仍在版本池），自检里编号记作 **SR**。

### 为什么不能直接用系统查找栏

`NSTextView` 自带查找栏，两个硬伤让它不可用：

1. **快捷键改不了**。系统查找栏的 ⌘F 是 AppKit 内建的，接不进 `ShortcutAction` 体系，
   设置里改完不生效——而「支持在设置中修改快捷键」正是这次明确要求。
2. **搜不到其他标签**。它是单 `NSTextView` 的查找，跨文件搜索得自己来。

所以 `usesFindBar = false`、`isIncrementalSearchingEnabled = false` 全部关掉。
不关会怎样：同一条 ⌘F 同时唤出两套 UI，用户看到的可能是系统那套。

### 分层与关键决策

内核 `FindEngine`（纯函数）/ 状态 `SearchController` / 界面 `FindBar` / 装配 `Workspace` /
渲染 `MarkdownTextView`，五层职责见设计文档 §4.11。

三个决策值得记下来：

1. **高亮写渲染属性层，不写 textStorage**。写 textStorage 会污染撤销栈、触发自动保存、
   还会被语法高亮覆盖。TextKit 2 用 `addRenderingAttribute`，TextKit 1 用 `setTemporaryAttributes`，
   只影响绘制。分流必须先问 `textLayoutManager`——先碰 `layoutManager` 会静默降级（ADR-09 的老坑重演）。
2. **替换走 `insertText(_:replacementRange:)`**。这是 NSTextView 的正规编辑入口，撤销注册与委托通知
   都由它完成。绕过它直接改 textStorage，「⌘Z 撤不回来」。批量替换倒序执行 + 套撤销分组，
   N 次替换算 1 步撤销。
3. **跳转不抢焦点、且推迟一个 runloop**。抢焦点会把用户踢出输入框；在 `updateNSView` 里同步
   `setSelectedRange` 会写 `@Published`、形成布局循环（实测窗口 alpha 卡在 0）。

### 自检：怎么证明「高亮真的画出来了」

这是整个功能里唯一「模型全对、用户可能什么都看不见」的地方，只断言区间不够，必须数像素。
把探针 `NSTextView` 离屏渲成位图，数「偏黄」像素并按饱和度分档：

| 状态 | 实色 px | 淡色 px |
|---|---|---|
| 未查找 | 0 | 0 |
| 1 处命中 | 298 | 0 |
| 3 处命中（当前 = 第 1 处） | 298 | 569 |
| 清除后 | 0 | 0 |

`298×3 ≈ 298+569`，且实色恰等于「一处」的量 —— 同时证明了三处都画了、当前处与其余处层级分得开、清除干净。
TextKit 2 与显式降级后的 TextKit 1 各跑一遍，数字一致。

### 本轮抓到的两个真 bug

| 现象 | 真因 | 修法 |
|---|---|---|
| 正则 `^dog` 搜不到第 2 行行首 | `NSRegularExpression` 默认只认整段文本的首尾，不带 `.anchorsMatchLines` 时 `^` 不匹配每行行首 | 构造 options 时默认加 `.anchorsMatchLines` |
| 替换栏浮在编辑区半空、顶出一大块空白 | 左侧占位用 `Color.clear.frame(width:)`，`Color` 两个轴都贪婪，宽度定住而高度没定，整行被撑满、同行控件垂直居中 | 换 `Spacer().frame(width:)`（只在栈的主轴伸展），并补一条固有高度断言（两行 68pt） |

第二个 bug 单看查找栏快照看不出来——那时 host 高度是被写死的，错误被掩盖了。
**是「整窗快照」把它暴露的**：把查找栏放回真实窗口里渲一张，才看见它根本没贴着编辑区。

### 教训

- 快照要带**完整上下文**。单控件快照只证明「控件自身排对了」，证明不了「它在真实布局里在哪、多大」。
- 「画出来才算数」的能力（高亮、行号、光标、指示器），断言要落到像素；
  「布局对不对」的问题，断言要落到固有尺寸或整窗图。
- 需求编号要跟 PRD 对齐。这次把查找替换误标成 FR-10，而 PRD 里 FR-10 是导出 HTML/PDF，
  两处串号——发现后统一改成 `SR`。

---

## 第十五轮：查找高亮在真机上「画不出来」（0.1.6 收尾）

第十四轮交付后，用户的反馈是三条：上下按钮不好使、正文没有高亮、`Aa/W/.*` 悬停没有说明。
前两条是一个原因。

### 现象与自检的反差

查找栏显示 `1/24`，正文一处高亮都没有。自检里那组像素断言是**全绿**的
（离屏渲染 224 px 实色 / 477 px 淡色，位置、层级都对）。

### 查证过程（每一步都留了记录）

在应用里加一个 `SWIFTDOWN_FIND=关键词` 的启动钩子，等价于「⌘F 后逐字输入完」的状态，
再用窗口级截图（`screencapture -l <windowID>`，绕开窗口遮挡）核对：

| 检查 | 结果 | 结论 |
|---|---|---|
| 应用侧日志 | `apply ranges=24 valid=24 tk2=true current={2,9}` | 叠加层送到了编辑器 |
| `enumerateRenderingAttributes` | `NSBackgroundColor` 挂在 `{2,11}` 等区间，共 47 段 | 属性**登记成功** |
| 加属性后 `invalidateLayout` + `ensureLayout` | 屏幕仍无颜色 | 不是「片段缓存」问题 |
| `needsDisplay = true` | 仍无颜色 | 不是重绘问题 |
| 换成 `.systemRed` 打在另一段 | 屏幕出现红块 | API 本身可用 |
| 换回 `.findHighlightColor` | 不出现 | 不是颜色类型问题（具体 sRGB 也不出现） |
| 同一份代码离屏 `cacheDisplay` | 画得出来 | **离屏与真机绘制路径不同** |

结论：TextKit 2 的渲染属性在这个视图上「登记得上、真机不落色」，且离屏渲染会给出假阳性。

### 改法

高亮写回 `textStorage`，把当初担心的三条副作用逐条封堵：

1. **撤销** —— 全程 `undoManager.disableUndoRegistration()`。
2. **回写模型** —— 置 `isApplyingProgrammaticChange`；并在自检里用 `NSTextStorageDelegate`
   断言这次编辑的 `editedMask` **只含 `.editedAttributes`**（一旦有人改成「替换文本上色」立刻红）。
3. **被语法高亮覆盖** —— 上色前记下每段原有 `.backgroundColor`，清除时倒序还原，
   不是一律 `removeAttribute`（行内代码本身有底色，会被抹掉）。

顺带：`Aa / W / .*` 的提示文案补全，并把 `NSInitialToolTipDelay` 压到 0.6 秒
（默认 2–3 秒，短标签按钮基本等不到）。

### 自检策略的修正

这次暴露的是方法论问题：**离屏像素为真 ≠ 真机为真**。补了两类断言：

- **机制断言**：属性真的在 `textStorage` 里、编辑掩码只有属性、清除能还原原底色；
- **真实路径断言**：把整窗 `RootView` 挂进真实 `NSWindow`、跑完首帧，**再**改查询词，
  然后断言编辑器出现高亮、`findNext()` 后选区落在第 3 处。

后者挡住的是「只在『先设查询再建视图』的顺序下才成立」这类假阳性——第一版正是靠首帧
顺带应用叠加层蒙混过关的。自检 134 → 143 项。

**教训**：凡是「渲染层」的断言，必须至少有一条跑在**真实窗口 + 真实操作顺序**上；
离屏渲染只适合验「内容对不对」，不适合验「看不看得见」。
