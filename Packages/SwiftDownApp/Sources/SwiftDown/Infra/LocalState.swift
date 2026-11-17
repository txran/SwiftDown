import Combine
import Foundation

/// 轻量本地状态容器。
///
/// 为什么不用 `@State`：当前构建环境只有 Command Line Tools，
/// SwiftUI 的 `StateMacro` 插件随 Xcode 提供而缺失，`@State` 无法展开。
/// `@StateObject` 不是宏，因此用它 + 引用类型持有局部状态，行为等价
/// （视图重建时状态保持，值变化触发刷新）。
final class LocalState<Value>: ObservableObject {
    @Published var value: Value

    init(_ value: Value) {
        self.value = value
    }

    /// 取反便捷方法（isHovering / isExpanded 这类布尔态高频使用）
    func toggle() where Value == Bool {
        value.toggle()
    }
}
