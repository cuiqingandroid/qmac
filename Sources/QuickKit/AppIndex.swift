import AppKit

/// 本机应用索引，供快速搜索使用。
/// 扫描常见的应用目录，缓存结果；面板每次打开时如果缓存过期就在后台重建。
struct AppEntry: Identifiable, Sendable {
    let id: String          // bundle 路径
    let name: String        // 展示用：Finder 里看到的本地化名字
    /// 所有可搜的名字（本地化名 + 英文名 + 文件名），小写去重。
    /// 只认 CFBundleName 的话，「预览」「微信」这类本地化名字会搜不到。
    let searchNames: [String]
    let bundleID: String
    let url: URL
    let initialsList: [String]   // 每个名字对应的首字母缩写，支持 vsc → Visual Studio Code

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
        let localized = bundle.localizedInfoDictionary ?? [:]
        let info = bundle.infoDictionary ?? [:]
        let fileName = url.deletingPathExtension().lastPathComponent

        // Finder 显示的名字（会跟随系统语言，「预览」「计算器」都靠它）
        let displayName = FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")

        let candidates = (AppIndex.localizedNames(bundle: bundle, url: url)
            + [displayName]
            + [
                localized["CFBundleDisplayName"] as? String,
                localized["CFBundleName"] as? String,
                info["CFBundleDisplayName"] as? String,
                info["CFBundleName"] as? String,
                fileName
            ].compactMap { $0 }
        ).filter { !$0.isEmpty }

        var seen = Set<String>()
        let names = candidates.filter { seen.insert($0.lowercased()).inserted }
        guard let primary = names.first else { return nil }

        return AppEntry(id: url.path,
                        name: primary,
                        searchNames: names.map { $0.lowercased() },
                        bundleID: bundle.bundleIdentifier ?? "",
                        url: url,
                        initialsList: names.map { AppIndex.initials(of: $0) })
    }

    /// 取应用在当前系统语言下的名字。
    /// - Apple 的系统应用把本地化名字放在 Contents/Resources/InfoPlist.loctable（按 zh_CN 这类 key 分组）
    /// - 第三方应用放在 <lang>.lproj/InfoPlist.strings
    /// Bundle.localizedInfoDictionary 在我们这种没有本地化资源的进程里会退回英文，所以直接读文件。
    nonisolated static func localizedNames(bundle: Bundle, url: URL) -> [String] {
        var out: [String] = []
        let preferences = Locale.preferredLanguages

        // loctable 顶层混着别的类型（有一份 locale → 1 的清单），只能逐 key 取
        let loctable = url.appendingPathComponent("Contents/Resources/InfoPlist.loctable")
        if let table = NSDictionary(contentsOf: loctable) as? [String: Any] {
            for key in preferences.flatMap(localeCandidates) {
                guard let entry = table[key] as? [String: Any] else { continue }
                if let name = (entry["CFBundleDisplayName"] ?? entry["CFBundleName"]) as? String {
                    out.append(name)
                }
                break
            }
        }

        let localizations = Bundle.preferredLocalizations(from: bundle.localizations,
                                                          forPreferences: preferences)
        if let language = localizations.first,
           let path = bundle.path(forResource: "InfoPlist", ofType: "strings",
                                  inDirectory: nil, forLocalization: language),
           let table = NSDictionary(contentsOfFile: path) as? [String: String],
           let name = table["CFBundleDisplayName"] ?? table["CFBundleName"] {
            out.append(name)
        }
        return out
    }

    /// "zh-Hans-CN" → ["zh-Hans-CN", "zh_Hans_CN", "zh-Hans", "zh_Hans", "zh-CN", "zh_CN", "zh"]
    nonisolated static func localeCandidates(_ tag: String) -> [String] {
        let parts = tag.split(separator: "-").map(String.init)
        var out: [String] = []
        func add(_ value: String) {
            for variant in [value, value.replacingOccurrences(of: "-", with: "_")] where !out.contains(variant) {
                out.append(variant)
            }
        }
        add(tag)
        if parts.count >= 2 { add(parts[0] + "-" + parts[1]) }
        if parts.count >= 3 { add(parts[0] + "-" + parts[2]) }
        if let first = parts.first, !out.contains(first) { out.append(first) }
        return out
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

    /// 打分匹配：全等 > 前缀 > 首字母缩写 > 词首 > 子串 > bundle id。
    /// 每个可搜名字都算一遍，取最高分。
    nonisolated static func score(_ entry: AppEntry, query: String) -> Int? {
        let q = query.lowercased()
        guard !q.isEmpty else { return nil }

        var best: Int?
        func offer(_ value: Int) { best = max(best ?? Int.min, value) }

        for (index, name) in entry.searchNames.enumerated() {
            let penalty = name.count
            if name == q { offer(1000 - penalty) }
            else if name.hasPrefix(q) { offer(900 - penalty) }
            else if entry.initialsList.indices.contains(index),
                    entry.initialsList[index].hasPrefix(q) { offer(800 - penalty) }
            else if name.split(whereSeparator: { $0 == " " || $0 == "-" }).contains(where: { $0.hasPrefix(q) }) {
                offer(700 - penalty)
            }
            else if name.contains(q) { offer(600 - penalty) }
        }
        if best == nil, entry.bundleID.lowercased().contains(q) { offer(400) }
        return best
    }
}
