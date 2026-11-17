import Foundation
import SwiftDownCore

/// 磁盘存储实现（FileStoring 生产版）。
/// - 读：多编码探测（EX-01），UTF-8 → UTF-16(BOM/无 BOM) → GB18030 兜底
/// - 写：原子写（同目录临时文件 + fsync + replaceItemAt），避免半截文件
final class DiskFileStore: FileStoring {

    enum LoadFailure: LocalizedError {
        case unreadable(path: String, underlying: String)
        case undecodable(path: String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let path, let underlying):
                return "无法读取文件 \(path)：\(underlying)"
            case .undecodable(let path):
                return "文件编码无法识别（非 UTF-8/UTF-16/GB18030）：\(path)"
            }
        }
    }

    enum SaveFailure: LocalizedError {
        case writeFailed(path: String, underlying: String)

        var errorDescription: String? {
            switch self {
            case .writeFailed(let path, let underlying):
                return "写入失败 \(path)：\(underlying)"
            }
        }
    }

    func load(from url: URL) throws -> String {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw LoadFailure.unreadable(path: url.path, underlying: error.localizedDescription)
        }
        if let text = Self.decode(data) { return text }
        throw LoadFailure.undecodable(path: url.path)
    }

    func save(_ content: String, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let tempURL = directory.appendingPathComponent(".swiftdown-\(UUID().uuidString).tmp")
        do {
            guard let data = content.data(using: .utf8) else {
                throw SaveFailure.writeFailed(path: url.path, underlying: "内容无法编码为 UTF-8")
            }
            try data.write(to: tempURL, options: [])

            // fsync：确保数据真正落盘后再替换，防崩溃丢尾部
            if let handle = try? FileHandle(forWritingTo: tempURL) {
                try? handle.synchronize()
                try? handle.close()
            }

            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
            } else {
                try FileManager.default.moveItem(at: tempURL, to: url)
            }
        } catch let error as SaveFailure {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw SaveFailure.writeFailed(path: url.path, underlying: error.localizedDescription)
        }
    }

    // MARK: - 编码探测

    static func decode(_ data: Data) -> String? {
        if data.isEmpty { return "" }

        // BOM 优先
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(data: data.dropFirst(3), encoding: .utf8)
        }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            if let text = String(data: data, encoding: .utf16) { return text }
        }

        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .utf16) { return text }

        // GB18030 兜底（中文用户历史文件常见）
        let gb18030 = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
        if let text = String(data: data, encoding: String.Encoding(rawValue: gb18030)) { return text }

        return nil
    }

    /// 文件字节大小（用于 >20MB 只读降级判定，FR-01 / EX-02）
    static func fileSize(at url: URL) -> Int {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return values?.fileSize ?? 0
    }
}
