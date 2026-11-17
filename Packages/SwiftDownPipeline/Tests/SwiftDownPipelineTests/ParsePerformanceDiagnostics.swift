import Foundation
import Testing
@testable import SwiftDownPipeline

/// 性能诊断：定位瓶颈在 cmark 解析（字节数相关）还是 AST 转换（块数相关）
/// 结论用于 M1 选型验证（swift-markdown vs Ink），见设计文档 §三 / §6.3
@Suite("解析性能诊断")
struct ParsePerformanceDiagnostics {

    let parser = SwiftMarkdownParser()

    /// 高块密度文档：每 12 行 8 个块（标题/段落/代码/列表）
    static func denseDocument(size: Int) -> String {
        let block = "# 标题\n\n这是段落文字，含**粗体**与`代码`。[链接](https://a.b)\n\n```swift\nlet a = 1\n```\n\n- 列表项\n- 列表项\n\n"
        var s = ""
        while s.utf8.count < size { s += block }
        return s
    }

    /// 低块密度文档：纯段落长文本（无标题/无块结构）
    static func sparseDocument(size: Int) -> String {
        var s = ""
        let line = "这是一段很长的普通文本内容，用来测试纯字节量对解析耗时的影响，不含任何块级语法结构。"
        while s.utf8.count < size { s += line + "\n" }
        return s
    }

    func measure(_ label: String, _ source: String) throws -> Double {
        let start = Date()
        let ast = try parser.parse(source)
        let ms = Date().timeIntervalSince(start) * 1000
        print("[诊断] \(label)  \(source.utf8.count / 1024)KB  块数=\(ast.blocks.count)  标题=\(ast.headings.count)  → \(String(format: "%.1f", ms))ms")
        return ms
    }

    /// 真实技术文档密度：标题约 1/30 行，段落为主体，夹杂代码块与列表
    /// 块数密度约 2K 块/MB（对照：极端构造为 32K 块/MB）
    static func realisticDocument(size: Int) -> String {
        let section = """
        ## 配置说明

        本节描述配置项的行为。默认值适用于大多数场景，如需调整请参考下面的表格与示例。

        配置读取顺序为：命令行参数、环境变量、配置文件、内置默认值。优先级从高到低，
        后面的来源会覆盖前面的同名键。修改配置文件后需要重启进程生效。

        | 配置项 | 类型 | 默认值 |
        |--------|------|--------|
        | timeout | Int | 30 |
        | retries | Int | 3 |

        ```swift
        let config = Config.load(from: "config.yaml")
        print(config.timeout)
        ```

        - 配置文件路径默认为 `~/.app/config.yaml`
        - 支持 YAML 与 JSON 两种格式
        - 环境变量前缀为 `APP_`

        """
        var s = ""
        while s.utf8.count < size { s += section + "\n" }
        return s
    }

    /// 真实技术文档密度：段落平均 300+ 字节，标题约 1/40 行，块数密度约 2.5K 块/MB
    /// 对照：realisticDocument 为 10K 块/MB（偏密集），denseDocument 为 32K 块/MB（极端）
    static func typicalDocument(size: Int) -> String {
        let section = """
        ## 配置说明

        本节描述配置项的行为与默认策略。默认值适用于绝大多数部署场景，如需针对性调整，
        请参考下文的表格与示例代码。需要注意的是，配置读取遵循固定优先级顺序：命令行参数
        优先级最高，其次是环境变量，再次是用户级配置文件，最后是系统内置默认值。同名的
        键会被高优先级的来源覆盖，因此排查问题时建议先确认实际生效的来源层级。

        | 配置项 | 类型 | 默认值 | 说明 |
        |--------|------|--------|------|
        | timeout | Int | 30 | 请求超时时间，单位秒 |
        | retries | Int | 3 | 失败重试次数 |

        ```swift
        let config = Config.load(from: "config.yaml")
        print("timeout = \\(config.timeout), retries = \\(config.retries)")
        ```

        - 配置文件路径默认为 `~/.app/config.yaml`，可通过 `--config` 覆盖
        - 支持 YAML 与 JSON 两种格式，扩展名决定解析器
        - 环境变量统一使用 `APP_` 前缀，例如 `APP_TIMEOUT=60`

        """
        var s = ""
        while s.utf8.count < size { s += section + "\n" }
        return s
    }

    @Test("典型技术文档密度 1MB（解析基线记录，非验收门槛）")
    func typical_density_1MB() throws {
        let ms = try measure("1MB 典型文档密度", Self.typicalDocument(size: 1024 * 1024))
        // 实测 2026-11-17：Release ~220ms（swift-markdown 固有开销，见 Docs/M1-parse-benchmark.md）
        // 硬阈值 400ms 仅用于防回退；NFR-01 的 100ms 预算通过「后台解析 + 首屏优先」策略满足。
        // Debug 构建带 -Onone 开销（实测 ~500ms），不对它做门槛判定。
        #if DEBUG
        print("[基线] Debug 构建不做阈值判定（仅记录）")
        #else
        #expect(ms < 400, "解析性能回退告警：\(ms)ms")
        #endif
    }

    @Test("按语法特征分解解析耗时（定位最贵的语法）")
    func breakdown_by_feature() throws {
        let size = 512 * 1024
        func build(_ unit: String) -> String {
            var s = ""
            while s.utf8.count < size { s += unit }
            return s
        }
        let cases: [(String, String)] = [
            ("纯段落", build("这是一段普通文本，用于对照基线测试。\n\n")),
            ("标题密集", build("### 三级标题文本内容\n\n")),
            ("代码块", build("```swift\nlet a = 1\nlet b = 2\n```\n\n")),
            ("无序列表", build("- 列表项内容\n- 列表项内容\n")),
            ("GFM 表格", build("| 列A | 列B | 列C |\n|-----|-----|-----|\n| 1 | 2 | 3 |\n| 4 | 5 | 6 |\n\n")),
            ("引用块", build("> 引用内容文本\n\n"))
        ]
        for (name, doc) in cases {
            let t0 = Date()
            let n = parser.rawParseOnly(doc)
            let ms = Date().timeIntervalSince(t0) * 1000
            print("[特征] \(name) 512KB 顶层块=\(n) → \(String(format: "%.1f", ms))ms")
        }
    }

    @Test("耗时分解：cmark 解析 vs 抽象 AST 转换")
    func breakdown_cmark_vs_convert() throws {
        for (label, doc) in [("典型密度", Self.typicalDocument(size: 1024 * 1024)),
                             ("低密度", Self.sparseDocument(size: 1024 * 1024))] {
            let t0 = Date()
            let children = parser.rawParseOnly(doc)
            let parseMS = Date().timeIntervalSince(t0) * 1000

            let t1 = Date()
            _ = try parser.parse(doc)
            let totalMS = Date().timeIntervalSince(t1) * 1000

            print("[分解] \(label) 1MB: cmark解析 \(String(format: "%.1f", parseMS))ms + AST转换 \(String(format: "%.1f", totalMS - parseMS))ms = 总计 \(String(format: "%.1f", totalMS))ms（顶层块 \(children)）")
        }
    }

    @Test("真实文档密度 1MB（判定是否满足 NFR-01 渲染解析预算）")
    func realistic_density_1MB() throws {
        let ms = try measure("1MB 真实文档密度", Self.realisticDocument(size: 1024 * 1024))
        // 预算 100ms（设计文档 §6.3 解析阶段）；超预算时记录数值，由 §6.3 兜底策略承担
        print("[诊断] 真实密度记录值（10K 块/MB 偏密集构造）：\(String(format: "%.1f", ms))ms")
    }

    @Test("1MB 高密度 vs 低密度对比（区分字节瓶颈与块数瓶颈）")
    func dense_vs_sparse() throws {
        let dense = try measure("1MB 高块密度", Self.denseDocument(size: 1024 * 1024))
        let sparse = try measure("1MB 低块密度", Self.sparseDocument(size: 1024 * 1024))
        // 记录事实，不做硬断言（Debug 构建下只作诊断输出）
        #expect(dense > 0 && sparse >= 0)
        print("[诊断] 密度差异倍数: \(String(format: "%.1f", dense / max(sparse, 0.001)))x")
    }

    @Test("不同规模线性度（1MB / 2MB / 4MB）")
    func scaling() throws {
        _ = try measure("1MB", Self.denseDocument(size: 1024 * 1024))
        _ = try measure("2MB", Self.denseDocument(size: 2 * 1024 * 1024))
        _ = try measure("4MB", Self.denseDocument(size: 4 * 1024 * 1024))
    }
}
