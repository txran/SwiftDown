# SwiftDown 0.1.3

本轮只解决一件事：**应用运行中从访达再打开一个 `.md`，窗口不再闪一下**。

## 根因

不是编辑器视图重建，也不是应用激活过渡。调用栈实测（`Thread.callStackSymbols`）指向 SwiftUI 自己：

```
-[NSWindow _close]
  ← SwiftUI.AppWindowsController.activateWindowForExternalEvent(matching:handler:)
  ← SwiftUI.AppWindowsController.open(urls:)
  ← SwiftUI.AppDelegate.application(_:open:)
```

SwiftUI 在收到「外部打开文稿」事件时，认为当前窗口不匹配这个事件，先关掉窗口、再为文档激活窗口。
窗口 `isVisible` 从 1 掉到 0 又回到 1，屏幕上就是那一闪——用户描述为「像关掉又重开」，而 PID 不变。

## 修法

在 Apple Event 层接管 `kAEOpenDocuments`（`applicationWillFinishLaunching` 里注册），
SwiftUI 收不到这个事件，文件直接进 Workspace 走标签。窗口全程不被关闭。

验证（`--trace` 探针，逐帧采样窗口属性）：

| 场景 | 修复前 | 修复后 |
|---|---|---|
| 运行中打开另一个 md，窗口 `isVisible` 掉到 0 | 是（约 2ms） | **否**（0 次） |
| 连续打开 3 个文件 | 每次都掉 | 每次都 0 次 |
| 冷启动打开文件 | — | 正常，内容立即显示 |

## 顺带修掉

- **`/tmp` 下的文件会写进会话**：路径过滤原先只比对 `NSTemporaryDirectory()`（`/var/folders/…/T`），
  漏掉了 `/tmp`。打开过 `/tmp/*.md` 之后，下次启动会恢复出几个已不存在的标签（幽灵标签）。
  现在 `/tmp` 与 `/private/tmp` 一并视为临时路径。
- 探针（`--trace`）输出改为可写文件，便于在「由系统启动 app」的真实场景里复现问题；
  正常启动是零开销的空操作。

## 自检

74 项全 PASS。新增两条：

- `FR-05 已接管打开文稿事件` —— 防的是「接管被删掉」：删了它功能看起来依旧（文件还能打开），
  但闪一下会原样回来。已反向验证：把接管去掉，这条立即 FAIL。
- `FR-05 /tmp 下的路径同样视为临时` —— 防幽灵标签回归。

## 安装

下载 `SwiftDown-0.1.3-arm64.dmg`，打开后拖进「应用程序」。首次打开若提示无法验证开发者，
右键 → 打开，或执行 `xattr -dr com.apple.quarantine /Applications/SwiftDown.app`。

仍仅支持 Apple Silicon（本机只有 Command Line Tools，x86_64 链接缺 SwiftUI 符号）。
