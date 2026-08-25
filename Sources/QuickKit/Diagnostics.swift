import AppKit

/// 把 App 自己视角的状态写到文件。
/// 从终端直接跑二进制时 TCC 会把终端当成责任进程，权限查出来是错的；
/// 必须由正常启动的这个进程自己写，外面才读得到真实情况。
@MainActor
enum Diagnostics {
    static var reportURL: URL {
        ClipboardStore.shared.baseURL.appendingPathComponent("diagnostics.txt")
    }

    static func write(hotKeys: [(action: String, combo: HotKeyCombo, ok: Bool)], statusItemOK: Bool) {
        var lines: [String] = []
        lines.append("生成时间 \(Date())")
        lines.append("可执行文件 \(Bundle.main.bundlePath)")
        lines.append("辅助功能权限 \(AXIsProcessTrusted() ? "已授权" : "未授权")")
        lines.append("菜单栏图标创建 \(statusItemOK ? "成功" : "失败")")
        lines.append("")
        lines.append("全局快捷键注册：")
        for entry in hotKeys {
            lines.append("  \(entry.action) \(entry.combo.display) → \(entry.ok ? "成功" : "失败")")
        }
        lines.append("")
        let started = Date()
        let report = MenuBarItems.probeReport()
        lines.append(String(format: "菜单栏枚举耗时 %.0f ms", Date().timeIntervalSince(started) * 1000))
        lines.append(report)
        try? (lines.joined(separator: "\n") + "\n").write(to: reportURL, atomically: true, encoding: .utf8)
    }
}
