import AppKit

// 全局持有，NSApplication.delegate 是 weak 的
let delegate = MainActor.assumeIsolated { AppDelegate() }

MainActor.assumeIsolated {
    let application = NSApplication.shared
    application.delegate = delegate
    application.setActivationPolicy(.accessory)   // 只在菜单栏常驻，不进 Dock 和 ⌘⇥
    application.run()
}
