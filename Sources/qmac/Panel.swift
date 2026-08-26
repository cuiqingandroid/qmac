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
        /// 屏幕水平居中，纵向按比例（面板中心落在该比例处）
        case centered(topRatio: CGFloat)
        /// 水平居中，**顶边**固定在可见区域顶部往下 ratio 处。
        /// 内容变多只往下长，框的位置不会跟着飘。
        case pinnedTop(ratio: CGFloat)
        /// 贴着菜单栏正下方、靠右——菜单栏图标就在那一侧
        case underMenuBarRight
        /// 刘海正下方（没有刘海的屏幕就退化成顶部居中）
        case underNotch
    }

    private let placement: Placement
    private var keyMonitor: Any?
    private var previousApp: NSRunningApplication?
    /// 显示时锁定的那块屏。内容变高触发重新定位时不能再按鼠标位置挑屏，
    /// 否则边打字边挪鼠标到另一块屏，面板会突然跳过去。
    private var anchorScreen: NSScreen?

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
                self.positionOnActiveScreen(reuseAnchor: true)
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

    /// pinnedTop 模式下面板能用的最大高度：让上下留白一样宽。
    /// 内容超过这个高度就该在面板内部滚动，而不是把框撑出屏幕。
    static func availableHeight(ratio: CGFloat) -> CGFloat {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return 480 }
        return max(240, visible.height - visible.height * ratio * 2)
    }

    func show() {
        if !panel.isVisible {
            previousApp = NSWorkspace.shared.frontmostApplication
            anchorScreen = nil
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

    private func positionOnActiveScreen(reuseAnchor: Bool = false) {
        let mouse = NSEvent.mouseLocation
        var screen = (reuseAnchor ? anchorScreen : nil)
            ?? NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main

        // 刘海模式下优先落在带刘海的那块屏上
        if case .underNotch = placement,
           let notched = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 || $0.auxiliaryTopLeftArea != nil }) {
            screen = notched
        }
        guard let visible = screen?.visibleFrame else { return }
        anchorScreen = screen

        let size = panel.frame.size
        switch placement {
        case .centered(let topRatio):
            let x = visible.midX - size.width / 2
            let y = visible.maxY - visible.height * topRatio - size.height / 2
            panel.setFrameOrigin(NSPoint(x: x.rounded(), y: max(visible.minY + 20, y).rounded()))
        case .pinnedTop(let ratio):
            let topGap = (visible.height * ratio).rounded()
            let x = visible.midX - size.width / 2
            let y = visible.maxY - topGap - size.height
            panel.setFrameOrigin(NSPoint(x: x.rounded(), y: max(visible.minY + 8, y).rounded()))

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
