import AppKit
import ApplicationServices

/// 通过辅助功能（AX）枚举菜单栏状态项。
///
/// 背景：macOS 26 上所有状态栏图标的窗口都归 ControlCenter 所有，CGWindowList 拿不到图标属于哪个 App。
/// AX 走的是 UI 层级而不是窗口列表，能拿到标题，而且 AXPress 是直接给元素发动作，
/// 不要求图标当前显示在屏幕上——被挤出菜单栏的图标也能触发。
enum MenuBarItems {

    struct Item: Identifiable {
        let id = UUID()
        let element: AXUIElement
        let pid: pid_t
        let title: String
        let owner: String
        let frame: CGRect
        let onScreen: Bool

        /// 列表主标题：控制中心自带的项用它自己的标题（电池、时钟…），
        /// 第三方 App 用应用名——它们的 AX 标题经常是未读数这类没用的东西。
        var primary: String {
            let clean = Item.collapse(title)
            if owner == "控制中心" || owner == "ControlCenter" {
                return clean.isEmpty ? owner : clean
            }
            return owner
        }

        /// 副标题：AX 标题里确实有信息时才显示
        var secondary: String {
            let clean = Item.collapse(title)
            guard !clean.isEmpty, clean != primary, clean.count > 1,
                  Double(clean) == nil else { return "" }
            return String(clean.prefix(60))
        }

        var isControlCenter: Bool { owner == "控制中心" || owner == "ControlCenter" }

        /// 控制中心的项（电池/时钟/Wi‑Fi…）没有独立应用图标，按标题映射到 SF Symbol
        var symbolName: String? {
            guard isControlCenter else { return nil }
            let t = primary
            if t.contains("电池") || t.lowercased().contains("battery") { return "battery.100" }
            if t.contains("时钟") || t.contains("日期") || t.contains("时间") { return "clock" }
            if t.contains("Wi") || t.contains("无线") { return "wifi" }
            if t.contains("蓝牙") || t.lowercased().contains("bluetooth") { return "dot.radiowaves.right" }
            if t.contains("音量") || t.contains("声音") { return "speaker.wave.2" }
            if t.contains("专注") || t.contains("勿扰") { return "moon" }
            if t.contains("镜像") || t.contains("显示器") || t.contains("屏幕") { return "rectangle.on.rectangle" }
            if t.contains("输入") || t.contains("键盘") { return "keyboard" }
            if t.contains("电池") { return "battery.100" }
            return "switch.2"
        }

        private static func collapse(_ text: String) -> String {
            let s = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            return s == "（无标题）" ? "" : s
        }
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    // MARK: - 枚举

    /// 先问 ControlCenter，再遍历各 App 自己的 AXExtrasMenuBar。
    /// 宽度为 0 的是控制中心面板内部的模块（不在菜单栏上），丢掉；QuickKit 自己也不列。
    static func all(candidates apps: [AppRef]) -> [Item] {
        let ranges = visibleRanges()

        return apps
            .flatMap { items(ofPID: $0.pid, owner: $0.name) }
            .filter { $0.frame.width > 0 }
            .map { item in
                Item(element: item.element, pid: item.pid, title: item.title, owner: item.owner,
                     frame: item.frame, onScreen: isVisible(item.frame, in: ranges))
            }
            .sorted { $0.frame.minX < $1.frame.minX }
    }

    /// CGWindowList 才知道哪些图标真的画在了屏幕上；AX 只给坐标。
    /// 两边按 x 坐标对上，就能判断某一项是不是被折叠了。
    private static func visibleRanges() -> [ClosedRange<CGFloat>] {
        guard let list = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return list.compactMap { window in
            guard (window[kCGWindowLayer as String] as? Int) == 25,
                  (window[kCGWindowIsOnscreen as String] as? Bool) == true,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let width = bounds["Width"],
                  width > 0, (bounds["Height"] ?? 0) >= 20 else { return nil }
            return x...(x + width)
        }
    }

    private static func isVisible(_ frame: CGRect, in ranges: [ClosedRange<CGFloat>]) -> Bool {
        guard frame.width > 0 else { return false }
        let center = frame.midX
        return ranges.contains { $0.contains(center) }
    }

    /// 候选 App（pid + 名字）。NSWorkspace 在主线程取，AX 查询留给后台。
    struct AppRef: Sendable {
        let pid: pid_t
        let name: String
    }

    @MainActor
    static func candidates() -> [AppRef] {
        let mine = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { app in
                guard app.processIdentifier != mine else { return false }
                // ControlCenter 是纯后台进程（activationPolicy == .prohibited），
                // 但电池、时钟、Wi‑Fi 这些都挂在它下面，必须带上
                if app.bundleIdentifier == "com.apple.controlcenter" { return true }
                return app.activationPolicy != .prohibited
            }
            .map { AppRef(pid: $0.processIdentifier, name: $0.localizedName ?? "?") }
    }

    static func fromControlCenter() -> [Item] {
        guard let cc = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.controlcenter").first else { return [] }
        return items(ofPID: cc.processIdentifier, owner: cc.localizedName ?? "控制中心")
    }

    static func items(ofPID pid: pid_t, owner: String) -> [Item] {
        let app = AXUIElementCreateApplication(pid)
        // 没有超时的话，一个卡住的 App 能把整个枚举拖上好几秒
        AXUIElementSetMessagingTimeout(app, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &value) == .success,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return [] }
        let bar = value as! AXUIElement

        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(bar, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement] else { return [] }

        return children.map { child in
            Item(element: child,
                 pid: pid,
                 title: describe(child),
                 owner: owner,
                 frame: frame(of: child),
                 onScreen: true)   // 真正的可见性在 all() 里用 CGWindowList 交叉判断
        }
    }

    // MARK: - 触发

    @discardableResult
    static func press(_ item: Item) -> Bool {
        AXUIElementPerformAction(item.element, kAXPressAction as CFString) == .success
    }

    // MARK: - 细节

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    private static func describe(_ element: AXUIElement) -> String {
        string(element, kAXTitleAttribute as String)
            ?? string(element, kAXDescriptionAttribute as String)
            ?? string(element, kAXHelpAttribute as String)
            ?? string(element, kAXIdentifierAttribute as String)
            ?? "（无标题）"
    }

    private static func frame(of element: AXUIElement) -> CGRect {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        var origin = CGPoint.zero
        var size = CGSize.zero
        if AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
           CFGetTypeID(positionValue) == AXValueGetTypeID() {
            AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin)
        }
        if AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
           CFGetTypeID(sizeValue) == AXValueGetTypeID() {
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        }
        return CGRect(origin: origin, size: size)
    }

    /// 把诊断报告写到 Application Support 下，方便排查
    /// （从 shell 直接跑二进制时 TCC 会把终端当成责任进程，权限查出来是错的，
    ///   所以诊断必须由 App 自己在正常启动的进程里生成。）
    static func writeProbeReport() {
        let url = ClipboardStore.shared.baseURL.appendingPathComponent("menubar-probe.txt")
        let text = "生成时间 \(Date())\n" + probeReport() + "\n"
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// 诊断输出，用来确认 macOS 26 上 AX 到底能看到什么
    static func probeReport() -> String {
        var lines: [String] = []
        lines.append("辅助功能权限：\(isTrusted ? "已授权" : "未授权（下面多半全是空的）")")

        let items = all(candidates: MainActor.assumeIsolated { candidates() })
        lines.append("\n菜单栏状态项：\(items.count) 个，其中被折叠 \(items.filter { !$0.onScreen }.count) 个")
        for item in items {
            lines.append(String(format: "  x=%5.0f w=%3.0f %@ %@ %@",
                                item.frame.minX, item.frame.width,
                                item.onScreen ? "可见  " : "被折叠",
                                item.primary,
                                item.secondary.isEmpty ? "" : "· \(item.secondary)"))
        }
        return lines.joined(separator: "\n")
    }
}
