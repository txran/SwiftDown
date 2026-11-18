# SwiftDown 0.1.4

## 新增：鼠标中键点击标签即关闭

和 Safari / Chrome / VS Code 一致：中键（滚轮键）点哪个标签就关哪个，不用先切过去再找 ✕。
脏文件照样弹保存确认，不会静默丢改动。

### 为什么不是一行 SwiftUI 代码

SwiftUI 没有中键手势：`onTapGesture` 只认左键，`contextMenu` 只认右键。网上常见的写法是叠一层
透明视图、在 `hitTest` 里读 `NSApp.currentEvent` 判断是不是中键——实测这条路不可靠：
`NSApplication.sendEvent` / `NSWindow.sendEvent` 期间 `NSApp.currentEvent` 都是 `nil`，
拿不到「正在分发的是哪个键」。

改成两半：

1. 每个标签叠一层**完全不参与命中测试**的透明视图（`hitTest → nil`），左键点击、右键菜单、
   拖拽排序、滚轮滚动一律照常穿透，现有交互一个都不动；
2. 窗口级本地事件监听只收 `otherMouseUp` + `buttonNumber == 2`，落点用覆盖层**当场算出**的
   窗口矩形判断（`convert(bounds, to: nil)`）——滚动、换行、窗口缩放都不会让位置过期。

## 顺带修复

- **打开文件的 Apple Event 现在会回复发送方**。接管 `kAEOpenDocuments` 之后 AppKit 的默认处理
  不再执行，不回复会让 `open -a` / 访达一直等到超时（实测 `-1712`）。

## 自检

80 项全 PASS。新增 6 条，全部落在「几何 + 事件」两个要素上（不依赖真实鼠标）：

- 中键抬起、落点在标签矩形内 → 命中该标签
- 落点在标签外 → 不命中
- 左键 / 右键抬起 → 不触发
- 中键按下（不是抬起）→ 不触发
- 覆盖层不参与命中测试（`hitTest` 返回 `nil`，保证不抢左键 / 右键 / 拖拽）
- 注销后不再命中

## 安装

下载 `SwiftDown-0.1.4-arm64.dmg`，拖进「应用程序」。首次打开若提示无法验证开发者，
右键 → 打开，或执行 `xattr -dr com.apple.quarantine /Applications/SwiftDown.app`。

仍仅支持 Apple Silicon。若你的鼠标没有中键（触控板 / 单键鼠标），中键关闭无效，
用标签上的 ✕ 或 ⌘W 即可。
