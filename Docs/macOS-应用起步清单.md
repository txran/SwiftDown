# macOS 应用起步清单（Swift / SwiftUI / AppKit）

> 用途：新开一个 macOS 应用时，**在写第一行业务代码之前**把这 20 条过一遍。
> 每一条都是「事后返工代价很高、事前决定几乎零成本」的决策点。
>
> 配套文档：[macOS-Swift-踩坑总结.md](macOS-Swift-踩坑总结.md)（每条都标了对应的章节）
>
> 来源：SwiftDown 项目 0.1.0 → 0.1.5 的实际返工记录。本文的每条「踩错了会怎样」都是真实发生过的。

---

## 怎么用

- **不要 20 条全做**。标 ⭐ 的 6 条是地基，做错要返工；其余是「做到就省事」。
- 每条给三样东西：**默认选择**（大多数项目适用）、**什么时候该换**（例外条件）、**踩错了会怎样**（返工代价）。
- 决定完把结论写进项目的 `README` 或 `Docs/decisions.md`，别只留在脑子里。

---

## A. 工程骨架

### 1. ⭐ 构建方式：Xcode 工程，还是 SPM + 脚本？

| | 默认选择 | 什么时候换 |
|---|---|---|
| 有完整 Xcode | 标准 `.xcodeproj`（或 Tuist / XcodeGen 生成） | — |
| 只有 Command Line Tools | SPM 编译 + 手工组装 `.app` + ad-hoc 签名 | — |

**CLT-only 的最小可用组合**（缺一个都编不过）：

```bash
swift build --disable-sandbox -c release \
  -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing

# 组装 .app：拷贝可执行文件 + Info.plist + PkgInfo + 图标，再 ad-hoc 签名
codesign --force --deep --sign - MyApp.app
```

**踩错了会怎样**：以为没有 Xcode 就做不了 GUI 应用，白等环境；或者一路报错不知道为什么（沙箱、宏插件两个坑各卡半天）。详见 [一、环境与构建](macOS-Swift-踩坑总结.md#一环境与构建没有-xcode-怎么办)。

### 2. ⭐ Bundle ID 策略：开发版与正式版从第一天就分开

```
正式：com.yourcompany.yourapp
开发：com.yourcompany.yourapp.dev      # 注意后缀，不要共用
```

**踩错了会怎样**：两个同 ID 的 bundle 在磁盘上，系统认为「同一个应用的两份」——启动台两个图标、⌘Tab 两个、⌘, 打开错的那份设置。清起来要动 LaunchServices。详见 [七](macOS-Swift-踩坑总结.md#七应用身份与部署图标出现两个那种事)。

**连带决策**：开发版是否要继承正式版的偏好？换 ID 后 `UserDefaults` 是新域，主题、最近打开都不继承。若想让开发版读正式版的配置，需要显式用 `UserDefaults(suiteName: "com.yourcompany.yourapp")`。

### 3. ⭐ 开发产物放哪：不要放在会被索引的目录

```bash
build/.dev/MyApp.app        # 隐藏目录 + 构建脚本收尾时注销注册
# 调试完：./Scripts/build-app.sh clean
```

**必须知道的机制**：`.metadata_never_index` 对已建过索引的目录**无效**；`lsregister -u` 注销后 **25–40 秒被 mds 回填**；运行一次开发版就会重新登记。**唯一稳定的做法是磁盘上不留第二份 bundle。**

**踩错了会怎样**：反复「注销→又出现」，误以为是缓存问题，查一整天。详见 [7.3](macOS-Swift-踩坑总结.md#73-藏起来--注销都挡不住-mds-回填)。

### 4. 应用生命周期：`@main App` 还是 `AppDelegate`？

| 默认选择 | 什么时候该换 |
|---|---|
| `@main struct MyApp: App` + `NSApplicationDelegateAdaptor` | 需要接管 Apple Event、自定义 `NSWindow` 行为、控制启动顺序时，**两者都要** |

**关键点**：`App` 协议不给你「启动阶段」的钩子。凡是「必须在第一份文件打开之前装好」的东西（尤其 Apple Event handler），只能放 `applicationWillFinishLaunching`。

```swift
@main
struct MyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene { WindowGroup { RootView() } }
}
```

### 5. 单窗口 + 自管标签，还是多窗口？

| 结构 | 适合 |
|---|---|
| 单 `Window` + 自管标签栏 | 编辑器、阅读器、IDE 类（像 VS Code / Typora） |
| `WindowGroup` + 一份文档一个窗口 | 系统风格文档应用 |

**选「单窗口 + 标签」的代价**：文件打开事件、会话恢复、撤销栈隔离全部要自己管（本文档一半的坑来自这里）。**收益**：状态集中，切换文档不重建视图。

---

## B. 架构边界

### 6. ⭐ SwiftUI 与 AppKit 的边界划在哪？

**默认原则**：状态用 SwiftUI（`ObservableObject`），**重度交互控件用 AppKit 包一层**（`NSViewRepresentable`）。不要试图用 SwiftUI 硬做文本编辑器。

| 需求 | 选择 |
|---|---|
| 普通列表、表单、设置面板 | SwiftUI |
| 文本编辑（高亮、行号、大文档） | `NSTextView` + `NSViewRepresentable` |
| 需要精细鼠标事件的面板 | AppKit 视图 + 覆盖层方案 |
| 大量数据表格 | `NSTableView`（SwiftUI `Table` 在 macOS 上仍受限） |

**踩错了会怎样**：用 SwiftUI `TextEditor` 起步，做到「要行号 / 要高亮 / 要精确控制选区」时全部推倒重来。

### 7. ⭐ 状态归属：谁读谁观察

**规则**：任何 SwiftUI 视图读取了某个 `ObservableObject` 的属性，**必须自己** `@ObservedObject` / `@EnvironmentObject` 它。不能依赖「上层对象变了会顺带刷新我」。

```swift
// 错：外层观察 workspace，内层直接读 tab.ast
struct OutlineView: View {
    @ObservedObject var workspace: Workspace
    var body: some View { list(workspace.activeTab?.ast) }   // 后台解析完成后不刷新
}

// 对：读谁的状态就观察谁
struct OutlineList: View {
    @ObservedObject var tab: DocumentTab
}
```

**踩错了会怎样**：「首次打开空白，切一下视图模式才出现」。而且数据一直是对的，只断言数据抓不到这个 bug，必须加渲染探针。详见 [2.1](macOS-Swift-踩坑总结.md#21-视图必须自己订阅真正持有状态的那个对象)。

### 8. 主题：一开始就写 `NSApp.appearance`

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

三条必须注意：

1. `.preferredColorScheme` **只管 SwiftUI 画的子树**，AppKit 视图（`NSTextView`、`NSMenu`、打开面板）不跟。
2. 落地位置收敛到一处（如 `settings.themeMode.didSet`），别在三个地方各写一遍。
3. **`didSet` 在 `init` 阶段不触发** —— 启动时要显式 `apply()` 一次，否则「重开应用才生效」。

### 9. 文本引擎：先确认你跑在 TextKit 1 还是 2

```swift
if textView.textLayoutManager != nil {
    // TextKit 2：现代 macOS 上 NSTextView(frame:) 的默认
} else {
    // TextKit 1：被人访问过 textView.layoutManager 之后会静默降级
}
```

**两条铁律**：

1. 行号、滚动、选区逻辑**必须引擎无关**，按运行时实际引擎分流。
2. TextKit 2 的 `NSTextLineFragment.characterRange` 是**元素相对偏移**，不是全文偏移。用 `layoutManager.offset(from:to:)` 换算，否则表现是「每行都显示第 1 行」。

**踩错了会怎样**：行号不显示 → 修成「全是 1」→ 再修。三轮。详见 [三](macOS-Swift-踩坑总结.md#三textkit这个坑最多)。

### 10. 撤销栈交给谁？

| 默认选择 | 理由 |
|---|---|
| `NSTextView` 自带的 `undoManager` | 与文本系统深度耦合（选区恢复、输入法组合、分组），自研栈替换它只会引入行为差异 |

配置：`allowsUndo = true`、`levelsOfUndo = 0`（无上限）。

**如果采用「复用编辑器实例切换文档」**：切换时必须 `undoManager.removeAllActions()`，否则 ⌘Z 跨文档串档。

---

## C. 数据与一致性

### 11. ⭐ 自动保存与冲突：分清「冻结编辑」和「冻结写入」

状态机里每一个「冻结」态，都要分别问三遍：冻结读？冻结写？冻结编辑？

```
dirty → conflict 之后：
  ✗ 用户不能编辑
  ✗ 在途的定时保存也必须停 —— 否则把内存版写进磁盘，静默丢弃他人版本
```

**实现方式**：写盘收敛成唯一一个内部方法，只有用户决策 `resolveConflict(.keepMine)` 能调用。

```swift
private func writeToDisk() throws { ... }   // 唯一出口

func saveNow() {
    guard state == .dirty else { return }   // conflict / missing / placeholder 一律拒绝
    try writeToDisk()
}
```

**踩错了会怎样**：数据丢失，而且是最难发现的那种（用户以为自己的改动还在）。详见 [9.3](macOS-Swift-踩坑总结.md#93-冲突态是写入冻结不只是编辑冻结)。

### 12. 文件监控：原子写会换 inode

```swift
// 自写落盘后：更新已知 hash → 开静默窗 → 重建监听
knownHash = FileHash.of(content)
suppressUntil = Date().addingTimeInterval(0.3)
restartWatching()     // 原子写换了 inode，旧 source 已绑在废 inode 上
```

**两个配套坑**：

- cancel handler 必须捕获**创建时的局部 fd**，不能读 `self.fileDescriptor`（重启时它已指向新 fd，会误关）。
- 自己写的内容要能被识别出来（hash 比对），否则「我保存一次」会被当成「外部修改」。

**踩错了会怎样**：保存一次之后，外部改动再也检测不到；或者自己每次保存都弹「文件被外部修改」。

### 13. 会话恢复：拆成「元信息」和「内容」两段

```
启动阶段：只读元信息（几百字节，<1ms）→ 布局必须在首帧前定
首帧之后：读文档内容（可能很慢）→ 补上标签
```

**为什么不能合并**：布局晚定会让窗口先按默认布局画一遍再跳；内容早读会把 IO 压进启动阶段，`didFinishLaunching` 迟迟不返回，文件打开事件 30 秒没人应答（-1712）。

**顺带一个坑**：判断「用户是否在启动阶段自己打开了文件」，不能用「恢复开始时标签列表是否为空」——用户那份可能正在读盘中，快照里还是空的。要用「恢复开始前就存在的标签 id 集合」。

### 14. 需要持久化到退出的状态，不要异步写

几百字节的东西（窗口布局、标签集合）在退出前必须落地，直接同步原子写（<1ms）。后台队列写会让进程先死、数据后到。

---

## D. 质量与发布

### 15. ⭐ 从一开始就建三层探针，而不是出事再补

| 层次 | 观测什么 | 什么时候用 |
|---|---|---|
| 帧级 | 窗口 `alpha` / `isVisible` / `windowNumber` / 内容区像素 | 怀疑「闪」「白屏」「窗口没了」 |
| 事件级 | 订阅 `NSWindow` 通知，状态翻转时打 `Thread.callStackSymbols` | 怀疑「谁动了我的窗口」 |
| 主线程级 | 独立线程心跳 + 读主线程 PC | 怀疑「卡住」 |

**开关用标记文件，不要用环境变量**：

```swift
static var isOn: Bool { FileManager.default.fileExists(atPath: "/tmp/myapp-trace.on") }
// 日志写 /tmp/myapp-trace.log
```

**为什么**：`launchctl setenv` 和 `open --args` 从访达/终端启动时行为不一致，实测不可靠。

**最关键的一条**：**跑在主线程上的探针观测不到主线程卡死**——主线程一卡，探针自己也不出字，你只看到一个无法归因的空洞。心跳通道必须活在另一个线程上。详见 [六](macOS-Swift-踩坑总结.md#六启动进程与主线程)。

### 16. 渲染类断言必须落到内容

| ✗ 无效断言 | ✓ 有效断言 |
|---|---|
| 行号视图存在 | 行号实际产生了编号，自 1 连续递增，不超过逻辑行数 |
| 编辑器视图存在 | 切换前后 `NSTextView` 实例必须 `===` |
| 布局完成 | `textView` 宽度 == `clipView` 宽度 |

**而且要留一条「改回去必须 FAIL」的断言**：新增防线如果删掉后测试仍全绿，它就没在防任何东西。

### 17. 自检不能改动被测对象的状态

最惨的一种情况：自检里一句 `editor.layoutManager?.ensureLayout(for:)` 把 TextKit 2 **降级成 TextKit 1**，于是自检一直跑兼容分支、全绿，生产分支从没被覆盖，功能一直是坏的。

**规则**：凡是「按引擎/模式分流」的代码，自检第一步先断言**自己跑在哪个分支**，再断言内容。

### 18. 自检必须隔离用户数据

跑一次自检就把用户的标签清空、把临时文件写进「最近打开」——这类事故一次就够。

| 污染源 | 隔离方式 |
|---|---|
| `UserDefaults` | 自检注入 `UserDefaults(suiteName: "com.yourcompany.yourapp.selftest")` |
| 会话文件 | 存储层支持注入目录，自检落临时目录 |
| 临时文件 | `defer` 清理 + 启动时清理 1 小时前的历史残留 |
| 偏好写入 | 临时路径不写进「最近打开」 |

### 19. 发布：ad-hoc 签名要提前告知用户

```bash
codesign --force --deep --sign - MyApp.app
```

- 首次打开会被 Gatekeeper 拦一次，右键 → 打开，或 `xattr -dr com.apple.quarantine MyApp.app`
- 这段说明要写进 README / 发行说明，不要等用户来问
- 打包用 `ditto` 时注意：**对符号链接只复制链接本身**，一律用真实路径

### 20. 版本号与产物命名从第一个发行版就规范

```
MyApp-0.1.0-arm64.dmg
MyApp-0.1.0-arm64.zip
```

`CFBundleShortVersionString`（对外版本）和 `CFBundleVersion`（构建号）分开维护。发版前跑一遍自检并记录项数，作为基线（例如「82 项全 PASS」），后续任何改动都要能对得上这个数字。

---

## 附：一页速览

按顺序过，每项打勾：

- [ ] 1. 构建方式定了（Xcode / SPM+脚本），CLT-only 的两个必加参数已知
- [ ] 2. 开发版与正式版 bundle id 从一开始就分开
- [ ] 3. 开发产物不放会被索引的目录；有 `clean` 命令
- [ ] 4. 需要启动阶段钩子的东西，走 `AppDelegate`
- [ ] 5. 窗口结构定了（单窗口+标签 / 多窗口）
- [ ] 6. SwiftUI 与 AppKit 的边界划清（编辑器一定是 AppKit）
- [ ] 7. 每个视图都观察它真正读的对象
- [ ] 8. 主题写 `NSApp.appearance`，且启动时显式应用一次
- [ ] 9. 文本引擎按运行时判定，`characterRange` 做了偏移换算
- [ ] 10. 撤销栈交给 `NSTextView`；换文档时清空
- [ ] 11. 状态机的每个冻结态都问过「冻结读/写/编辑」
- [ ] 12. 文件监控处理了原子写换 inode；cancel handler 用局部 fd
- [ ] 13. 会话恢复拆成元信息 + 内容两段
- [ ] 14. 退出前必须落地的状态同步写
- [ ] 15. 三层探针就位，开关用标记文件
- [ ] 16. 渲染类断言落到内容/像素/实例同一性
- [ ] 17. 分流逻辑的自检先断言分支
- [ ] 18. 自检隔离 UserDefaults / 会话 / 临时文件
- [ ] 19. ad-hoc 签名的 Gatekeeper 说明写进 README
- [ ] 20. 版本号与产物命名规范，自检项数作为基线
