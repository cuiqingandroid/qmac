import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings = Settings.shared
    @ObservedObject var store = ClipboardStore.shared
    @State private var ignoreText = Settings.shared.ignorePatterns.joined(separator: "\n")
    @State private var accessibilityGranted = Paster.hasAccessibilityPermission
    @State private var message = ""
    @State private var messageIsError = false

    var onHotKeysChanged: () -> Void = {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section("全局快捷键") {
                    HotKeyRow(title: "剪贴板历史", combo: $settings.clipboardHotKey,
                              others: [settings.searchHotKey, settings.lockHotKey, settings.menuBarHotKey],
                              message: $message, isError: $messageIsError, onChange: onHotKeysChanged)
                    HotKeyRow(title: "快速搜索", combo: $settings.searchHotKey,
                              others: [settings.clipboardHotKey, settings.lockHotKey, settings.menuBarHotKey],
                              message: $message, isError: $messageIsError, onChange: onHotKeysChanged)
                    HotKeyRow(title: "菜单栏图标", combo: $settings.menuBarHotKey,
                              others: [settings.clipboardHotKey, settings.searchHotKey, settings.lockHotKey],
                              message: $message, isError: $messageIsError, onChange: onHotKeysChanged)
                    HotKeyRow(title: "锁屏", combo: $settings.lockHotKey,
                              others: [settings.clipboardHotKey, settings.searchHotKey, settings.menuBarHotKey],
                              message: $message, isError: $messageIsError, onChange: onHotKeysChanged)
                    Text(message.isEmpty ? "点击右侧按钮后直接按下想要的组合键，esc 取消，⌫ 清除。" : message)
                        .font(.caption)
                        .foregroundStyle(message.isEmpty ? AnyShapeStyle(.secondary)
                                                         : AnyShapeStyle(messageIsError ? Color.red : Color.green))
                }

                section("剪贴板") {
                    row("保留条数", detail: "超出后自动丢弃最旧的，置顶的不受限制") {
                        TextField("", value: $settings.maxHistory, format: .number)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                    }
                    row("轮询间隔（秒）", detail: "越小越灵敏，越大越省电") {
                        TextField("", value: $settings.pollInterval, format: .number)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                            .onSubmit { ClipboardWatcher.shared.restart() }
                    }
                    row("记录图片", detail: "截图、复制的图片也会进入历史") {
                        Toggle("", isOn: $settings.watchImages).labelsHidden()
                    }
                    row("选中后自动粘贴", detail: "关闭后只写入剪贴板，由你手动 ⌘V") {
                        Toggle("", isOn: $settings.autoPaste).labelsHidden()
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("忽略规则（正则，一行一条）").font(.system(size: 13))
                        Text("命中的内容不会写入历史；密码管理器标记过的内容本来就会跳过")
                            .font(.caption).foregroundStyle(.tertiary)
                        TextEditor(text: $ignoreText)
                            .font(.system(size: 11.5, design: .monospaced))
                            .frame(height: 56)
                            .padding(4)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))
                            .onChange(of: ignoreText) { _, new in
                                let list = new.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
                                    .filter { !$0.isEmpty }
                                let bad = list.filter { (try? NSRegularExpression(pattern: $0)) == nil }
                                settings.ignorePatterns = list.filter { !bad.contains($0) }
                                if !bad.isEmpty {
                                    message = "这些正则写得不对，已忽略：" + bad.joined(separator: "、")
                                    messageIsError = true
                                }
                            }
                    }
                    row("历史记录", detail: "当前 \(store.items.count) 条") {
                        Button("清空历史") {
                            store.clear(keepPinned: true)
                        }
                    }
                }

                section("锁屏") {
                    row("锁屏方式", detail: settings.lockMethod.detail) {
                        Picker("", selection: $settings.lockMethod) {
                            ForEach(Settings.LockMethod.allCases) { method in
                                Text(method.title).tag(method)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 150)
                    }
                    row("测试", detail: "会立刻锁屏，先保存好手头的工作") {
                        Button("立即锁屏") { AppDelegate.shared?.lockNow() }
                    }
                }

                section("通用") {
                    row("开机自动启动", detail: "需要 App 放在固定位置，例如「应用程序」文件夹") {
                        Toggle("", isOn: $settings.launchAtLogin).labelsHidden()
                    }
                    row("辅助功能权限",
                        detail: accessibilityGranted ? "已授权，自动粘贴可用"
                                                     : "未授权，自动粘贴不可用（内容仍会复制到剪贴板）") {
                        if accessibilityGranted {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Button("前往授权") { Paster.requestAccessibilityPermission() }
                        }
                    }
                    row("数据目录", detail: ClipboardStore.shared.baseURL.path) {
                        Button("在访达中显示") {
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: ClipboardStore.shared.baseURL.path)
                        }
                    }
                    row("其它", detail: "") {
                        HStack(spacing: 6) {
                            Button("恢复默认") {
                                settings.restoreDefaults()
                                ignoreText = ""
                                onHotKeysChanged()
                            }
                            Button("退出 QuickKit") { NSApp.terminate(nil) }
                        }
                    }
                    row("支持作者", detail: "免费开源，觉得顺手可以请我喝杯咖啡") {
                        Button("打赏…") { AppDelegate.shared?.openDonate() }
                    }
                    Text("QuickKit \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0") · 原生 macOS 版")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            .padding(20)
        }
        .frame(width: 620, height: 640)
        .onAppear { accessibilityGranted = Paster.hasAccessibilityPermission }
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in
            accessibilityGranted = Paster.hasAccessibilityPermission
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.7)
            content()
        }
    }

    private func row<Trailing: View>(_ title: String, detail: String,
                                     @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
            trailing()
        }
    }
}

/// 一行快捷键设置：点击后录制
struct HotKeyRow: View {
    let title: String
    @Binding var combo: HotKeyCombo
    let others: [HotKeyCombo]
    @Binding var message: String
    @Binding var isError: Bool
    var onChange: () -> Void

    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Text(title).font(.system(size: 13))
            Spacer()
            Button(recording ? "按下组合键…" : combo.display) {
                recording ? stop() : start()
            }
            .frame(width: 160)
            .font(.system(size: 12, design: .monospaced))
            .tint(recording ? Color.accentColor : nil)
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        message = ""
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            handle(event)
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == 53 { stop(); return }                 // esc 取消
        if event.keyCode == 51 {                                  // ⌫ 清除
            combo = .none
            stop()
            onChange()
            return
        }
        guard let candidate = HotKeyCombo(event: event) else {
            message = "请至少搭配一个修饰键（⌘ / ⌃ / ⌥ / ⇧），或使用 F1–F15"
            isError = true
            return
        }
        if others.contains(candidate) {
            message = "\(candidate.display) 已经分配给别的功能了"
            isError = true
            return
        }
        if candidate != combo, !HotKeyCenter.shared.isAvailable(candidate) {
            message = "\(candidate.display) 已被系统或其它应用占用"
            isError = true
            return
        }
        combo = candidate
        message = "\(candidate.display) 已生效"
        isError = false
        stop()
        onChange()
    }
}
