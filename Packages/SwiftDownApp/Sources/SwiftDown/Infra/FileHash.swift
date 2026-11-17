import Foundation

/// 内容指纹（FNV-1a 64）：用于「自写去噪」与冲突比对。
/// 不引入 CryptoKit 是刻意的——这里只需要快速不等式判定，不需要密码学强度。
enum FileHash {
    static func of(_ string: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x1000_0000_01b3
        }
        return String(hash, radix: 16)
    }

    static func of(data: Data) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x1000_0000_01b3
        }
        return String(hash, radix: 16)
    }
}
