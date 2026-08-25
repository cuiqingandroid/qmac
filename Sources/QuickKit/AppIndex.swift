import AppKit

/// 本机应用索引，供快速搜索使用。
/// 扫描常见的应用目录，缓存结果；面板每次打开时如果缓存过期就在后台重建。
struct AppEntry: Identifiable, Sendable {
    let id: String          // bundle 路径
    let name: String        // 显示名
    let bundleID: String
    let url: URL
    let initials: String    // 名字里每个词的首字母，支持 "vsc" 命中 Visual Studio Code

    var path: String { url.path }
}

actor AppIndex {
    static let shared = AppIndex()

    private var entries: [AppEntry] = []
    private var lastScan: Date?
    private let ttl: TimeInterval = 120

    private let roots = [
        "/Applications",
        "/System/Applications",
        "/System/Applications/Utilities",
        "/Applications/Utilities",
        NSHomeDirectory() + "/Applications",
        "/System/Library/CoreServices/Applications"
    ]

    func all() -> [AppEntry] {
        if let lastScan, Date().timeIntervalSince(lastScan) < ttl, !entries.isEmpty {
            return entries
        }
        entries = scan()
        lastScan = Date()
        return entries
    }

    /// 主动刷新（比如刚装了新 App）
    func invalidate() { lastScan = nil }

    private func scan() -> [AppEntry] {
        let fm = FileManager.default
        var found: [String: AppEntry] = [:]

        for root in roots {
            guard let items = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for item in items {
                let path = root + "/" + item
                if item.hasSuffix(".app") {
                    if let entry = makeEntry(URL(fileURLWithPath: path)) { found[entry.id] = entry }
                } else if !item.hasPrefix("."),
                          (try? fm.contentsOfDirectory(atPath: path)) != nil {
                    // 再往下一层，覆盖 /Applications/Xxx/Yyy.app 这种分组目录
                    for sub in (try? fm.contentsOfDirectory(atPath: path)) ?? [] where sub.hasSuffix(".app") {
                        if let entry = makeEntry(URL(fileURLWithPath: path + "/" + sub)) { found[entry.id] = entry }
                    }
                }
            }
        }
        return found.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func makeEntry(_ url: URL) -> AppEntry? {
        guard let bundle = Bundle(url: url) else { return nil }
        let info = bundle.localizedInfoDictionary ?? bundle.infoDictionary ?? [:]
        let name = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return AppEntry(id: url.path,
                        name: name,
                        bundleID: bundle.bundleIdentifier ?? "",
                        url: url,
                        initials: AppIndex.initials(of: name))
    }

    private static func initials(of name: String) -> String {
        // "Visual Studio Code" -> "vsc"；也把驼峰拆开："QuickTime" -> "qt"
        var out = ""
        var previousWasLower = false
        for (index, char) in name.enumerated() {
            if index == 0 || !previousWasLower && char.isUppercase {
                if char.isLetter || char.isNumber { out.append(Character(char.lowercased())) }
            }
            if char == " " || char == "-" || char == "_" { previousWasLower = false; continue }
            previousWasLower = char.isLowercase
        }
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" })
        let wordInitials = words.compactMap { $0.first }.map { String($0).lowercased() }.joined()
        return out.count >= wordInitials.count ? out : wordInitials
    }

    /// 打分匹配：前缀 > 首字母缩写 > 词首 > 子串
    nonisolated static func score(_ entry: AppEntry, query: String) -> Int? {
        let q = query.lowercased()
        guard !q.isEmpty else { return nil }
        let name = entry.name.lowercased()

        if name == q { return 1000 }
        if name.hasPrefix(q) { return 900 - entry.name.count }
        if entry.initials.hasPrefix(q) { return 800 - entry.name.count }
        if name.split(whereSeparator: { $0 == " " || $0 == "-" }).contains(where: { $0.hasPrefix(q) }) {
            return 700 - entry.name.count
        }
        if name.contains(q) { return 600 - entry.name.count }
        if entry.bundleID.lowercased().contains(q) { return 400 - entry.name.count }
        return nil
    }
}
