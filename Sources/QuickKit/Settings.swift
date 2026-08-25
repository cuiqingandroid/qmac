import AppKit
import Carbon.HIToolbox
import Combine
import ServiceManagement

/// 用户设置，落在 UserDefaults。
final class Settings: ObservableObject {
    static let shared = Settings()

    enum LockMethod: String, CaseIterable, Identifiable {
        case auto, cgsession, keystroke, sleep
        var id: String { rawValue }

        var title: String {
            switch self {
            case .auto: return "自动（推荐）"
            case .cgsession: return "切到登录窗口"
            case .keystroke: return "模拟 ⌃⌘Q"
            case .sleep: return "立即息屏"
            }
        }

        var detail: String {
            switch self {
            case .auto: return "依次尝试登录窗口 → ⌃⌘Q → 息屏，哪个能用用哪个"
            case .cgsession: return "切换到登录窗口，不需要额外权限，最稳"
            case .keystroke: return "模拟系统自带的 ⌃⌘Q，需要「辅助功能」权限"
            case .sleep: return "立即关闭屏幕，是否上锁取决于系统「睡眠后要求输入密码」的设置"
            }
        }
    }

    @Published var clipboardHotKey: HotKeyCombo { didSet { persist(clipboardHotKey, "hotkey.clipboard") } }
    @Published var searchHotKey: HotKeyCombo { didSet { persist(searchHotKey, "hotkey.search") } }
    @Published var lockHotKey: HotKeyCombo { didSet { persist(lockHotKey, "hotkey.lock") } }
    @Published var menuBarHotKey: HotKeyCombo { didSet { persist(menuBarHotKey, "hotkey.menubar") } }

    @Published var maxHistory: Int { didSet { defaults.set(maxHistory, forKey: "maxHistory") } }
    @Published var pollInterval: Double { didSet { defaults.set(pollInterval, forKey: "pollInterval") } }
    @Published var watchImages: Bool { didSet { defaults.set(watchImages, forKey: "watchImages") } }
    @Published var autoPaste: Bool { didSet { defaults.set(autoPaste, forKey: "autoPaste") } }
    @Published var ignorePatterns: [String] { didSet { defaults.set(ignorePatterns, forKey: "ignorePatterns") } }
    @Published var lockMethod: LockMethod { didSet { defaults.set(lockMethod.rawValue, forKey: "lockMethod") } }

    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != isLoginItemEnabled else { return }
            applyLaunchAtLogin(launchAtLogin)
        }
    }

    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            "maxHistory": 300,
            "pollInterval": 0.7,
            "watchImages": true,
            "autoPaste": true,
            "ignorePatterns": [String]()
        ])

        func read(_ key: String, fallback: HotKeyCombo) -> HotKeyCombo {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let combo = try? JSONDecoder().decode(HotKeyCombo.self, from: data) else { return fallback }
            return combo
        }

        clipboardHotKey = read("hotkey.clipboard",
                               fallback: HotKeyCombo(keyCode: 9, modifiers: UInt32(cmdKey | shiftKey)))   // ⌘⇧V
        searchHotKey = read("hotkey.search",
                            fallback: read("hotkey.calc",                                                 // 兼容旧键名
                                           fallback: HotKeyCombo(keyCode: 49, modifiers: UInt32(optionKey))))  // ⌥Space
        lockHotKey = read("hotkey.lock",
                          fallback: HotKeyCombo(keyCode: 37, modifiers: UInt32(cmdKey | optionKey)))      // ⌘⌥L
        menuBarHotKey = read("hotkey.menubar",
                             fallback: HotKeyCombo(keyCode: 46, modifiers: UInt32(cmdKey | shiftKey)))    // ⌘⇧M

        maxHistory = defaults.integer(forKey: "maxHistory")
        pollInterval = defaults.double(forKey: "pollInterval")
        watchImages = defaults.bool(forKey: "watchImages")
        autoPaste = defaults.bool(forKey: "autoPaste")
        ignorePatterns = defaults.stringArray(forKey: "ignorePatterns") ?? []
        lockMethod = LockMethod(rawValue: defaults.string(forKey: "lockMethod") ?? "auto") ?? .auto
        launchAtLogin = Settings.readLoginItemState()
    }

    private func persist(_ combo: HotKeyCombo, _ key: String) {
        guard let data = try? JSONEncoder().encode(combo) else { return }
        defaults.set(data, forKey: key)
    }

    func restoreDefaults() {
        for key in ["hotkey.clipboard", "hotkey.search", "hotkey.calc", "hotkey.lock", "hotkey.menubar", "maxHistory", "pollInterval",
                    "watchImages", "autoPaste", "ignorePatterns", "lockMethod"] {
            defaults.removeObject(forKey: key)
        }
        clipboardHotKey = HotKeyCombo(keyCode: 9, modifiers: UInt32(cmdKey | shiftKey))
        searchHotKey = HotKeyCombo(keyCode: 49, modifiers: UInt32(optionKey))
        lockHotKey = HotKeyCombo(keyCode: 37, modifiers: UInt32(cmdKey | optionKey))
        menuBarHotKey = HotKeyCombo(keyCode: 46, modifiers: UInt32(cmdKey | shiftKey))
        maxHistory = 300
        pollInterval = 0.7
        watchImages = true
        autoPaste = true
        ignorePatterns = []
        lockMethod = .auto
    }

    // MARK: - 开机自启

    private var isLoginItemEnabled: Bool { Settings.readLoginItemState() }

    private static func readLoginItemState() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("[QuickKit] 设置开机自启失败: \(error.localizedDescription)")
            DispatchQueue.main.async { self.launchAtLogin = Settings.readLoginItemState() }
        }
    }

    var compiledIgnorePatterns: [NSRegularExpression] {
        ignorePatterns.compactMap { try? NSRegularExpression(pattern: $0) }
    }
}
