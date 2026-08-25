import AppKit
import SwiftUI

@MainActor
final class MenuBarViewModel: ObservableObject {
    @Published private(set) var items: [MenuBarItems.Item] = []
    @Published private(set) var trusted = MenuBarItems.isTrusted
    @Published private(set) var loading = false
    @Published var selection = 0
    /// 鼠标悬停的那一项，只影响标签显示，不参与键盘选择
    @Published var hovered: UUID?

    var onHide: () -> Void = {}

    /// 只列被折叠的——能看见的图标本来就在菜单栏上，不必重复一遍
    var ordered: [MenuBarItems.Item] {
        items.filter { !$0.onScreen }
    }

    var foldedCount: Int { items.filter { !$0.onScreen }.count }

    var selected: MenuBarItems.Item? {
        ordered.indices.contains(selection) ? ordered[selection] : nil
    }

    /// 标签栏上显示的名字：优先鼠标指着的，其次键盘选中的
    var caption: String {
        if let hovered, let item = ordered.first(where: { $0.id == hovered }) {
            return item.onScreen ? item.primary : "\(item.primary)（被折叠）"
        }
        guard let selected else { return "" }
        return selected.onScreen ? selected.primary : "\(selected.primary)（被折叠）"
    }

    func reset() {
        selection = 0
        hovered = nil
        reload()
    }

    /// AX 查询要遍历所有 App，放后台跑；横条先弹出来，图标随后填上
    func reload() {
        trusted = MenuBarItems.isTrusted
        guard trusted else {
            items = []
            return
        }
        loading = true
        let apps = MenuBarItems.candidates()
        Task.detached(priority: .userInitiated) {
            let found = MenuBarItems.all(candidates: apps)
            await MainActor.run {
                self.items = found
                self.loading = false
                if self.selection >= found.count { self.selection = max(0, found.count - 1) }
            }
        }
    }

    /// 先收起横条再触发，否则弹出的菜单会被我们的窗口挡住
    func activate(_ item: MenuBarItems.Item) {
        onHide()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            MainActor.assumeIsolated {
                if !MenuBarItems.press(item) { NSSound.beep() }
            }
        }
    }

    func requestPermission() { Paster.requestAccessibilityPermission() }

    /// 返回 true 表示事件已消费
    func handleKey(_ event: NSEvent) -> Bool {
        let count = ordered.count
        switch event.keyCode {
        case 53:                                   // esc
            onHide()
            return true
        case 124, 125:                             // → / ↓
            if count > 0 { selection = (selection + 1) % count; hovered = nil }
            return true
        case 123, 126:                             // ← / ↑
            if count > 0 { selection = (selection - 1 + count) % count; hovered = nil }
            return true
        case 36, 76:                               // return
            if let item = selected { activate(item) }
            return true
        case 15 where event.modifierFlags.contains(.command):   // ⌘R
            reload()
            return true
        default:
            return false
        }
    }
}

/// 贴在菜单栏正下方的一条图标横条，参考 Ice 的形态。
struct MenuBarView: View {
    @ObservedObject var model: MenuBarViewModel

    private let iconSize: CGFloat = 20
    private let cellSize: CGFloat = 30

    var body: some View {
        VStack(spacing: 0) {
            if !model.trusted {
                permissionNotice
            } else {
                iconRow
                if !model.caption.isEmpty {
                    Text(model.caption)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 5)
                }
            }
        }
        .background(VisualEffectBackground())
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
        .fixedSize()
    }

    private var iconRow: some View {
        HStack(spacing: 2) {
            if model.loading && model.items.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .padding(.horizontal, 10)
                    .frame(height: cellSize)
            } else if model.ordered.isEmpty {
                Text(model.items.isEmpty ? "没读到菜单栏图标" : "菜单栏图标都能看见")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .frame(height: cellSize)
            } else {
                ForEach(Array(model.ordered.enumerated()), id: \.element.id) { index, item in
                    cell(item, index: index)
                }
            }
        }
        .padding(5)
    }

    private func cell(_ item: MenuBarItems.Item, index: Int) -> some View {
        let highlighted = model.hovered == item.id || (model.hovered == nil && model.selection == index)
        return icon(for: item)
            .frame(width: cellSize, height: cellSize)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(highlighted ? Color.primary.opacity(0.12) : Color.clear)
            )
            .overlay(alignment: .topTrailing) {
                if !item.onScreen {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 5, height: 5)
                        .padding(3)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { model.activate(item) }
            .onHover { model.hovered = $0 ? item.id : (model.hovered == item.id ? nil : model.hovered) }
            .help(item.primary)
    }

    @ViewBuilder
    private func icon(for item: MenuBarItems.Item) -> some View {
        if let symbol = item.symbolName {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(.primary)
        } else if let appIcon = NSRunningApplication(processIdentifier: item.pid)?.icon {
            Image(nsImage: appIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: iconSize, height: iconSize)
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }

    private var permissionNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill").foregroundStyle(.orange)
            Text("需要「辅助功能」权限才能读取菜单栏图标")
                .font(.system(size: 12))
            Button("前往授权") { model.requestPermission() }
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}
