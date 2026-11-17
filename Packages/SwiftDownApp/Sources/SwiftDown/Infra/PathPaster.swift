import AppKit

/// 路径复制（标签右键菜单）。
/// 同时写入字符串与 fileURL 两种类型：前者可直接粘贴到终端/编辑器，
/// 后者能被访达、Xcode 等接受为文件引用。
enum PathPaster {

    static func copyFileURL(_ url: URL) {
        write([.string: url.path, .fileURL: url.absoluteString])
    }

    static func copyFolderPath(_ url: URL) {
        write([.string: url.deletingLastPathComponent().path])
    }

    private static func write(_ items: [NSPasteboard.PasteboardType: String]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.declareTypes(Array(items.keys), owner: nil)
        for (type, value) in items {
            pasteboard.setString(value, forType: type)
        }
    }
}
