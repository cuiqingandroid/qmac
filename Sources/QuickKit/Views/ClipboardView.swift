import AppKit
import SwiftUI

@MainActor
final class ClipboardViewModel: ObservableObject {
    @Published var query = "" { didSet { clampSelection() } }
    @Published var selection = 0
    @Published private(set) var revision = 0

    var onHide: () -> Void = {}
    var onPasteHide: () -> Void = {}
    var onOpenSettings: () -> Void = {}

    private let store = ClipboardStore.shared
    private var observer: NSObjectProtocol?

    var items: [ClipItem] { store.filtered(query) }
    var selected: ClipItem? { items.indices.contains(selection) ? items[selection] : nil }

    func reset() {
        query = ""
        selection = 0
    }

    private func clampSelection() {
        if selection >= items.count { selection = max(0, items.count - 1) }
    }

    // MARK: - 动作

    func use(_ item: ClipItem, paste: Bool) {
        guard ClipboardWatcher.shared.write(item) else { return }
        if paste { onPasteHide() } else { onHide() }
    }

    func remove(_ item: ClipItem) {
        store.remove(item)
        clampSelection()
    }

    func togglePin(_ item: ClipItem) {
        store.togglePin(item)
    }

    func clearAll() {
        let alert = NSAlert()
        alert.messageText = "清空剪贴板历史？"
        alert.informativeText = "已置顶的记录会保留。"
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn {
            store.clear(keepPinned: true)
            clampSelection()
        }
    }

    /// 返回 true 表示事件已消费
    func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        let count = items.count

        switch event.keyCode {
        case 53:                                   // esc
            if query.isEmpty { onHide() } else { query = "" }
            return true
        case 125:                                  // ↓
            if count > 0 { selection = (selection + 1) % count }
            return true
        case 126:                                  // ↑
            if count > 0 { selection = (selection - 1 + count) % count }
            return true
        case 36, 76:                               // return / enter
            if let item = selected { use(item, paste: !command) }
            return true
        case 51 where command:                     // ⌘⌫
            if let item = selected { remove(item) }
            return true
        case 35 where command:                     // ⌘P
            if let item = selected { togglePin(item) }
            return true
        default:
            break
        }

        // ⌘1…⌘9 快速选取
        if command, let scalar = event.charactersIgnoringModifiers?.first,
           let digit = Int(String(scalar)), (1...9).contains(digit) {
            let index = digit - 1
            if items.indices.contains(index) { use(items[index], paste: true) }
            return true
        }
        return false
    }
}

struct ClipboardView: View {
    @ObservedObject var model: ClipboardViewModel
    @ObservedObject private var store = ClipboardStore.shared
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                list
                Divider()
                detail
                    .frame(width: 250)
            }
            Divider()
            footer
        }
        .background(VisualEffectBackground())
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
        .onAppear { searchFocused = true }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.tertiary)
            TextField("搜索剪贴板历史…", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($searchFocused)
            if !store.items.isEmpty {
                Text("\(model.items.count) 条")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            Button { model.onOpenSettings() } label: { Image(systemName: "gearshape") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("设置")
            Button { model.clearAll() } label: { Image(systemName: "trash") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("清空历史")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if model.items.isEmpty {
                        Text(model.query.isEmpty ? "还没有剪贴板记录，复制点什么试试" : "没有匹配的记录")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    }
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                        ClipboardRow(item: item, index: index, selected: index == model.selection)
                            .id(item.id)
                            .contentShape(Rectangle())
                            .onTapGesture { model.selection = index }
                            .simultaneousGesture(TapGesture(count: 2).onEnded {
                                model.use(item, paste: true)
                            })
                    }
                }
                .padding(6)
            }
            .onChange(of: model.selection) { _, new in
                guard model.items.indices.contains(new) else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(model.items[new].id, anchor: .center)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var detail: some View {
        if let item = model.selected {
            VStack(alignment: .leading, spacing: 10) {
                if item.kind == .image, let image = store.image(for: item, thumbnail: true) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    Text("\(item.width) × \(item.height) · \(formatBytes(item.bytes))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        Text(item.text.prefix(4000) + (item.truncated ? "\n…（已截断）" : ""))
                            .font(.system(size: 11.5, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 300)
                    Text("\(item.chars) 字符 · \(item.text.split(separator: "\n", omittingEmptySubsequences: false).count) 行")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Text(relativeTime(item.date))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Spacer(minLength: 0)

                HStack(spacing: 6) {
                    Button("粘贴") { model.use(item, paste: true) }
                        .buttonStyle(.borderedProminent)
                    Button("仅复制") { model.use(item, paste: false) }
                    Button(item.pinned ? "取消置顶" : "置顶") { model.togglePin(item) }
                }
                .controlSize(.small)
                HStack {
                    Button("删除") { model.remove(item) }
                        .controlSize(.small)
                        .foregroundStyle(.red)
                    Spacer()
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            Text("选中一条记录查看详情")
                .font(.system(size: 12.5))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            hint("↑↓", "选择")
            hint("↵", "粘贴")
            hint("⌘↵", "仅复制")
            hint("⌘1–9", "快速选取")
            hint("⌘P", "置顶")
            hint("⌘⌫", "删除")
            hint("esc", "关闭")
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    private func hint(_ key: String, _ text: String) -> some View {
        HStack(spacing: 3) {
            Text(key)
                .font(.system(size: 10, design: .monospaced))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.07)))
            Text(text).font(.system(size: 10.5))
        }
        .foregroundStyle(.tertiary)
    }
}

struct ClipboardRow: View {
    let item: ClipItem
    let index: Int
    let selected: Bool

    var body: some View {
        HStack(spacing: 9) {
            Text(index < 9 ? "\(index + 1)" : "")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.quaternary)
                .frame(width: 14)

            if item.kind == .image, let image = ClipboardStore.shared.image(for: item, thumbnail: true) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 30, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(item.preview.isEmpty ? "（空白字符）" : item.preview)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Text(metaText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            if item.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.tint)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(selected ? Color.accentColor.opacity(0.18) : Color.clear)
        )
    }

    private var metaText: String {
        item.kind == .text
            ? "\(relativeTime(item.date)) · \(item.chars) 字符"
            : "\(relativeTime(item.date)) · \(formatBytes(item.bytes))"
    }
}

func relativeTime(_ date: Date) -> String {
    let diff = Date().timeIntervalSince(date)
    if diff < 60 { return "刚刚" }
    if diff < 3600 { return "\(Int(diff / 60)) 分钟前" }
    if diff < 86400 { return "\(Int(diff / 3600)) 小时前" }
    let formatter = DateFormatter()
    formatter.dateFormat = "M/d HH:mm"
    return formatter.string(from: date)
}

func formatBytes(_ bytes: Int) -> String {
    bytes >= 1_048_576
        ? String(format: "%.1f MB", Double(bytes) / 1_048_576)
        : "\(max(1, bytes / 1024)) KB"
}
