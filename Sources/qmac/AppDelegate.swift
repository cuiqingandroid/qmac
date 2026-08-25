import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static private(set) var shared: AppDelegate?

    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var donateWindow: NSWindow?
    private var accessibilityAlertShown = false

    private let clipboardModel = ClipboardViewModel()
    private let searchModel = SearchViewModel()
    private let menuBarModel = MenuBarViewModel()

    private lazy var clipboardPanel: PanelController = {
        let controller = PanelController(content: ClipboardView(model: clipboardModel),
                                         width: 740, height: 540, placement: .centered(topRatio: 0.32))
        controller.onKeyDown = { [weak self] event in self?.clipboardModel.handleKey(event) ?? false }
        controller.onShow = { [weak self] in self?.clipboardModel.reset() }
        return controller
    }()

    private lazy var searchPanel: PanelController = {
        let controller = PanelController(content: SearchView(model: searchModel),
                                         width: 620, height: nil, placement: .centered(topRatio: 0.24))
        controller.onKeyDown = { [weak self] event in self?.searchModel.handleKey(event) ?? false }
        controller.onShow = { [weak self] in self?.searchModel.reset() }
        return controller
    }()

    private lazy var menuBarPanel: PanelController = {
        let controller = PanelController(content: MenuBarView(model: menuBarModel),
                                         width: 520, height: nil, placement: .underNotch)
        controller.onKeyDown = { [weak self] event in self?.menuBarModel.handleKey(event) ?? false }
        controller.onShow = { [weak self] in self?.menuBarModel.reset() }
        return controller
    }()

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        NSApp.setActivationPolicy(.accessory)

        // 已经有一份在跑就把它唤到前面，自己退出。
        // 否则两份实例会抢同一组全局快捷键，后启动的那份注册不上。
        // 诊断模式不受单实例保护限制，否则常驻实例在跑时探测命令会直接退出
        let diagnostic = ["--selftest", "--menubar-probe", "--show-clipboard", "--show-search", "--show-menubar"]
        let isDiagnostic = CommandLine.arguments.contains { diagnostic.contains($0) }
        if !isDiagnostic, let running = otherRunningInstance() {
            running.activate()
            exit(0)
        }

        if CommandLine.arguments.contains("--menubar-probe") {
            if !MenuBarItems.isTrusted { Paster.requestAccessibilityPermission() }
            print(MenuBarItems.probeReport())
            exit(0)
        }

        wireModels()
        setUpStatusItem()
        registerHotKeys()
        ClipboardWatcher.shared.start()

        // 权限可能是启动之后才给的，过一会儿再刷新一次诊断
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            MainActor.assumeIsolated { self.registerHotKeys() }
        }

        // 调试用：qmac.app/Contents/MacOS/qmac --show-clipboard | --show-search | --selftest
        if CommandLine.arguments.contains("--show-clipboard") { showClipboard() }
        if CommandLine.arguments.contains("--show-search") { showSearch() }
        if CommandLine.arguments.contains("--show-menubar") { showMenuBarPanel() }
        if CommandLine.arguments.contains("--selftest") { runSelfTest() }

        // 菜单栏 App 没有 Dock 图标也没有窗口，双击后必须给点看得见的反馈，
        // 否则用户只会觉得「没打开」。开机自启那次除外——那种场景就该安静启动。
        if !isDiagnostic, !launchedByLoginItem {
            let firstRun = !UserDefaults.standard.bool(forKey: "hasLaunchedBefore")
            UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
            openSettings()
            if firstRun {
                DispatchQueue.main.async { MainActor.assumeIsolated { self.showWelcome() } }
            }
        }
    }

    /// 在访达/启动台里双击已经在运行的 App 时打开设置窗口。
    /// 这个 App 没有 Dock 图标，菜单栏图标还可能被系统折叠掉，
    /// 双击必须给一个看得见的落点，否则用户根本不知道它开没开、也找不到入口。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openSettings()
        return true
    }

    /// 区分「开机自启」和「用户主动双击」。
    /// 不能用 XPC_SERVICE_NAME——现代 macOS 所有 GUI 应用都由 launchd 拉起，双击也会带上它。
    /// 真正的判据是启动 AppleEvent 里的 'lgit'（launched as login item）标志，
    /// 它只在 applicationDidFinishLaunching 期间读得到。
    private var launchedByLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == AEEventID(kAEOpenApplication) else { return false }
        let launchedAsLogInItem: UInt32 = 0x6C676974   // 'lgit'
        return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == launchedAsLogInItem
    }

    private func otherRunningInstance() -> NSRunningApplication? {
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first { $0.processIdentifier != me }
    }

    private func showWelcome() {
        let settings = Settings.shared
        let alert = NSAlert()
        alert.messageText = "qmac 已经在菜单栏运行"
        let lines: [String] = [
            "它没有 Dock 图标，看菜单栏右侧的 ⚡ 图标。",
            "",
            "快速搜索　　" + settings.searchHotKey.display,
            "剪贴板历史　" + settings.clipboardHotKey.display,
            "菜单栏图标　" + settings.menuBarHotKey.display,
            "锁屏　　　　" + settings.lockHotKey.display,
            "",
            "快捷键可以在这个设置窗口里重新录制。"
        ]
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotKeyCenter.shared.unregisterAll()
        ClipboardWatcher.shared.stop()
        ClipboardStore.shared.flush()
    }

    private func wireModels() {
        clipboardModel.onHide = { [weak self] in self?.clipboardPanel.hide() }
        clipboardModel.onPasteHide = { [weak self] in self?.clipboardPanel.hideAndPaste() }
        clipboardModel.onOpenSettings = { [weak self] in
            self?.clipboardPanel.hide()
            self?.openSettings()
        }

        menuBarModel.onHide = { [weak self] in self?.menuBarPanel.hide() }
        searchModel.onHide = { [weak self] in self?.searchPanel.hide() }
        searchModel.onCopyAndPaste = { [weak self] (text: String) in
            ClipboardWatcher.shared.writeText(text)
            self?.searchPanel.hideAndPaste()
        }
    }

    // MARK: - 菜单栏

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // 位置由系统和用户的 ⌘ 拖拽决定，autosaveName 至少能让它在重启后回到原位。
        // macOS 没有公开 API 能强制自己不被折叠——菜单栏塞不下时照样会被挤掉。
        item.autosaveName = "qmacStatusItem"
        item.isVisible = true
        item.button?.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "qmac")
        item.button?.image?.isTemplate = true
        item.menu = buildMenu()
        statusItem = item
    }

    private func buildMenu() -> NSMenu {
        let settings = Settings.shared
        let menu = NSMenu()

        func add(_ title: String, key: HotKeyCombo, action: Selector) {
            let item = NSMenuItem(title: "\(title)（\(key.display)）", action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }

        add("快速搜索", key: settings.searchHotKey, action: #selector(showSearch))
        add("剪贴板历史", key: settings.clipboardHotKey, action: #selector(showClipboard))

        // 菜单栏图标做成子菜单：鼠标停上去就直接列出被折叠的图标
        let menuBarItem = NSMenuItem(title: "菜单栏图标（\(settings.menuBarHotKey.display)）",
                                     action: #selector(showMenuBarPanel), keyEquivalent: "")
        menuBarItem.target = self
        let submenu = NSMenu()
        submenu.delegate = self
        menuBarItem.submenu = submenu
        menu.addItem(menuBarItem)

        add("锁屏", key: settings.lockHotKey, action: #selector(lockFromMenu))

        menu.addItem(.separator())

        let donateItem = NSMenuItem(title: "请作者喝杯咖啡…", action: #selector(openDonate), keyEquivalent: "")
        donateItem.target = self
        menu.addItem(donateItem)

        let settingsItem = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let loginItem = NSMenuItem(title: "开机自动启动", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = settings.launchAtLogin ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let about = NSMenuItem(title: "qmac v\(version)", action: nil, keyEquivalent: "")
        about.isEnabled = false
        menu.addItem(about)

        let quit = NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        return menu
    }

    private func refreshMenu() {
        statusItem?.menu = buildMenu()
    }

    // MARK: - 快捷键

    func registerHotKeys() {
        let settings = Settings.shared
        HotKeyCenter.shared.unregisterAll()

        var results: [(action: String, combo: HotKeyCombo, ok: Bool)] = []
        results.append(("剪贴板历史", settings.clipboardHotKey,
                        HotKeyCenter.shared.register(settings.clipboardHotKey) { [weak self] in
                            self?.clipboardPanel.toggle()
                        }))
        results.append(("快速搜索", settings.searchHotKey,
                        HotKeyCenter.shared.register(settings.searchHotKey) { [weak self] in
                            self?.searchPanel.toggle()
                        }))
        results.append(("锁屏", settings.lockHotKey,
                        HotKeyCenter.shared.register(settings.lockHotKey) { [weak self] in
                            self?.lockNow()
                        }))
        results.append(("菜单栏图标", settings.menuBarHotKey,
                        HotKeyCenter.shared.register(settings.menuBarHotKey) { [weak self] in
                            self?.menuBarPanel.toggle()
                        }))

        let failed = results.filter { !$0.ok }.map { "\($0.action) \($0.combo.display)" }
        Diagnostics.write(hotKeys: results, statusItemOK: statusItem?.button != nil)

        refreshMenu()

        guard !failed.isEmpty, !CommandLine.arguments.contains("--selftest") else { return }
        let alert = NSAlert()
        alert.messageText = "部分快捷键没能注册"
        alert.informativeText = failed.joined(separator: "\n") + "\n\n多半是被系统或别的应用占用了，可以在设置里换一组。"
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    // MARK: - 动作

    @objc func showClipboard() { clipboardPanel.show() }
    @objc func showSearch() { searchPanel.show() }
    @objc func showMenuBarPanel() { menuBarPanel.show() }
    @objc private func lockFromMenu() { lockNow() }

    func lockNow() {
        clipboardPanel.hide()
        searchPanel.hide()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            MainActor.assumeIsolated {
                if case .failure(let failure) = LockScreen.lock(using: Settings.shared.lockMethod) {
                    let alert = NSAlert()
                    alert.messageText = "锁屏失败"
                    alert.informativeText = failure.message + "\n\n可以在设置里换一种锁屏方式。"
                    alert.addButton(withTitle: "好")
                    alert.runModal()
                }
            }
        }
    }

    @objc private func toggleLaunchAtLogin() {
        Settings.shared.launchAtLogin.toggle()
        refreshMenu()
    }

    /// 菜单栏图标子菜单：鼠标停上去时才枚举，列出被折叠的那些
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        guard MenuBarItems.isTrusted else {
            let item = NSMenuItem(title: "需要辅助功能权限", action: #selector(requestAccessibility), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            return
        }

        let folded = MenuBarItems.all(candidates: MenuBarItems.candidates()).filter { !$0.onScreen }
        guard !folded.isEmpty else {
            let item = NSMenuItem(title: "菜单栏图标都能看见", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            return
        }

        for barItem in folded {
            let item = NSMenuItem(title: barItem.primary, action: #selector(pressMenuBarItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = barItem
            if let symbol = barItem.symbolName {
                item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            } else if let icon = NSRunningApplication(processIdentifier: barItem.pid)?.icon {
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
            }
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let panelItem = NSMenuItem(title: "打开图标横条…", action: #selector(showMenuBarPanel), keyEquivalent: "")
        panelItem.target = self
        menu.addItem(panelItem)
    }

    @objc private func pressMenuBarItem(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? MenuBarItems.Item else { return }
        if !MenuBarItems.press(item) { NSSound.beep() }
    }

    @objc private func requestAccessibility() {
        Paster.requestAccessibilityPermission()
    }

    @objc func openDonate() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if let donateWindow {
            donateWindow.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: DonateView())
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 330),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.contentViewController = hosting
        window.title = "支持 qmac"
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                               object: window, queue: .main) { _ in
            MainActor.assumeIsolated { _ = NSApp.setActivationPolicy(.accessory) }
        }
        donateWindow = window
    }

    @objc func openSettings() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }

        let view = SettingsView(onHotKeysChanged: { [weak self] in self?.registerHotKeys() })
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = [.preferredContentSize]

        // styleMask 必须在建窗口时就给定：建完再改会把 contentViewController 的尺寸冲掉，
        // 窗口会缩成一条 1x32 的缝。
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered,
                              defer: false)
        window.contentViewController = hosting
        window.title = "qmac 设置"
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 620, height: 640))
        window.center()
        window.makeKeyAndOrderFront(nil)

        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                               object: window, queue: .main) { [weak self] _ in
            NSApp.setActivationPolicy(.accessory)
            self?.refreshMenu()
        }
        settingsWindow = window
    }

    /// 冒烟自测：弹出两个面板、模拟一次外部复制，检查历史是否落库，然后退出
    private func runSelfTest() {
        let marker = "qmac selftest \(UUID().uuidString.prefix(8))"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(marker, forType: .string)

        func report(_ name: String, _ controller: PanelController) {
            let frame = controller.panel.frame
            print("[selftest] \(name)面板 visible=\(controller.panel.isVisible) "
                  + "frame=\(Int(frame.origin.x)),\(Int(frame.origin.y)) "
                  + "\(Int(frame.width))x\(Int(frame.height))")
        }

        showClipboard()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            MainActor.assumeIsolated {
                report("剪贴板", self.clipboardPanel)
                self.clipboardPanel.hide()
                self.showSearch()
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            MainActor.assumeIsolated {
                report("快速搜索", self.searchPanel)
                self.searchPanel.hide()
                self.openSettings()
                let settingsVisible = self.settingsWindow?.isVisible ?? false
                let settingsFrame = self.settingsWindow?.frame ?? .zero
                print("[selftest] 设置窗口 visible=\(settingsVisible) "
                      + "frame=\(Int(settingsFrame.origin.x)),\(Int(settingsFrame.origin.y)) "
                      + "\(Int(settingsFrame.width))x\(Int(settingsFrame.height))")
                let captured = ClipboardStore.shared.items.contains { $0.text == marker }
                print("[selftest] 剪贴板监听 \(captured ? "OK" : "失败")，历史共 \(ClipboardStore.shared.items.count) 条")
                if let button = self.statusItem?.button, let window = button.window {
                    let frame = window.frame
                    let screen = NSScreen.screens.first { $0.frame.intersects(frame) }
                    let visible = screen != nil && frame.maxX > 0
                    print("[selftest] 菜单栏图标 x=\(Int(frame.origin.x)) y=\(Int(frame.origin.y)) "
                          + "宽=\(Int(frame.width)) 在屏幕上=\(visible ? "是" : "否，被挤出去了")")
                    print("[selftest] 屏幕宽度 \(NSScreen.screens.map { Int($0.frame.width) })")
                } else {
                    print("[selftest] 菜单栏图标创建失败")
                }
                print("[selftest] 辅助功能权限 \(Paster.hasAccessibilityPermission ? "已授权" : "未授权")")
                ClipboardStore.shared.flush()
                NSApp.terminate(nil)
            }
        }
    }

    func notifyAccessibilityNeeded() {
        guard !accessibilityAlertShown else { return }
        accessibilityAlertShown = true

        let alert = NSAlert()
        alert.messageText = "自动粘贴需要「辅助功能」权限"
        alert.informativeText = "内容已经复制到剪贴板，手动按 ⌘V 也能粘贴。\n"
            + "若要自动粘贴，请在「系统设置 → 隐私与安全性 → 辅助功能」里勾选 qmac。"
        alert.addButton(withTitle: "去授权")
        alert.addButton(withTitle: "稍后再说")
        if alert.runModal() == .alertFirstButtonReturn {
            Paster.requestAccessibilityPermission()
        }
    }
}
