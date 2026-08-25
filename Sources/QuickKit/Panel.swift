import AppKit
import SwiftUI

/// 无边框、可获得键盘焦点的浮动面板
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// 负责面板的显示位置、焦点回归、键盘事件转发
@MainActor
final class PanelController {
    let panel: FloatingPanel

    /// 返回 true 表示事件已被消费
    var onKeyDown: (@MainActor (NSEvent) -> Bool)?
    var onShow: (@MainActor () -> Void)?
    var onHide: (@MainActor () -> Void)?

    enum Placement {
        /// 屏幕水平居中，纵向按比例
        case centered(topRatio: CGFloat)
        /// 贴着菜单栏正下方、靠右——菜单栏图标就在那一侧
        case underMenuBarRight
        /// 刘海正下方（没有刘海的屏幕就退化成顶部居中）
        case underNotch
    }

    private let placement: Placement
    private var keyMonitor: Any?
    private var previousApp: NSRunningApplication?

    init<Content: View>(content: Content, width: CGFloat, height: CGFloat?, placement: Placement) {
        self.placement = placement

        let hosting = NSHostingController(rootView: content)
        if height == nil {
            hosting.sizingOptions = [.preferredContentSize]     // 内容多高，窗口就多高
        }

        panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height ?? 120),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hosting
        panel.setContentSize(NSSize(width: width, height: height ?? hosting.view.fittingSize.height))
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        // 内容尺寸变了（比如图标条读完数据变宽）要重新摆位，否则右边缘会飘
        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification,
                                               object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.panel.isVisible else { return }
                self.positionOnActiveScreen()
            }
        }

        // 点到别的应用（或别的面板）就收起，符合 Spotlight 类工具的习惯
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                               object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hideWithoutRestoringFocus() }
        }
    }

    /// 失去焦点时收起：焦点已经在别处了，不要再抢回来
    private func hideWithoutRestoringFocus() {
        guard panel.isVisible else { return }
        removeMonitor()
        panel.orderOut(nil)
        onHide?()
    }

    var isVisible: Bool { panel.isVisible }

    func show() {
        if !panel.isVisible {
            previousApp = NSWorkspace.shared.frontmostApplication
        }
        positionOnActiveScreen()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        installMonitor()
        onShow?()
    }

    func hide() {
        guard panel.isVisible else { return }
        removeMonitor()
        panel.orderOut(nil)
        onHide?()
        restoreFocus()
    }

    func toggle() {
        panel.isVisible ? hide() : show()
    }

    /// 把焦点还给弹出面板之前的那个应用
    func restoreFocus() {
        if let previousApp, previousApp.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp.activate()
        } else {
            NSApp.hide(nil)
        }
    }

    /// 收起面板 → 焦点还给原应用 → 稍等一下再发 ⌘V
    func hideAndPaste() {
        removeMonitor()
        panel.orderOut(nil)
        onHide?()
        restoreFocus()
        guard Settings.shared.autoPaste else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) {
            MainActor.assumeIsolated {
                if !Paster.paste() { AppDelegate.shared?.notifyAccessibilityNeeded() }
            }
        }
    }

    private func positionOnActiveScreen() {
        let mouse = NSEvent.mouseLocation
        var screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main

        // 刘海模式下优先落在带刘海的那块屏上
        if case .underNotch = placement,
           let notched = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 || $0.auxiliaryTopLeftArea != nil }) {
            screen = notched
        }
        guard let visible = screen?.visibleFrame else { return }

        let size = panel.frame.size
        switch placement {
        case .centered(let topRatio):
            let x = visible.midX - size.width / 2
            let y = visible.maxY - visible.height * topRatio - size.height / 2
            panel.setFrameOrigin(NSPoint(x: x.rounded(), y: max(visible.minY + 20, y).rounded()))
        case .underNotch:
            let notchCenterX: CGFloat
            if let screen, screen.safeAreaInsets.top > 0 || screen.auxiliaryTopLeftArea != nil {
                // 刘海居中于屏幕，用屏幕水平中点即可
                notchCenterX = screen.frame.midX
            } else {
                notchCenterX = visible.midX
            }
            let x = notchCenterX - size.width / 2
            let y = visible.maxY - size.height - 6
            panel.setFrameOrigin(NSPoint(x: max(visible.minX + 8, x).rounded(), y: y.rounded()))

        case .underMenuBarRight:
            // visibleFrame 的上边缘就在菜单栏下方
            let x = min(visible.maxX - size.width - 8, visible.maxX - 8)
            let y = visible.maxY - size.height - 6
            panel.setFrameOrigin(NSPoint(x: max(visible.minX + 8, x).rounded(), y: y.rounded()))
        }
    }

    private func installMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.panel.isKeyWindow else { return event }
                return (self.onKeyDown?(event) ?? false) ? nil : event
            }
        }
    }

    private func removeMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

/// SwiftUI 里用的系统材质背景
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}
