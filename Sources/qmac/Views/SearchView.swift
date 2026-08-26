import AppKit
import SwiftUI

struct CalcEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var expression: String
    var display: String
    var value: Double
    var date: Date
}

/// 搜索面板里的一行
enum SearchRow: Identifiable {
    case calculation(Calculator.Output)
    case app(AppEntry)
    case history(CalcEntry)

    var id: String {
        switch self {
        case .calculation(let output): return "calc:\(output.raw)"
        case .app(let entry): return "app:\(entry.id)"
        case .history(let entry): return "history:\(entry.id)"
        }
    }
}

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var input = "" { didSet { rebuild() } }
    @Published private(set) var rows: [SearchRow] = []
    @Published var selection = 0
    @Published private(set) var entries: [CalcEntry] = []
    @Published private(set) var toast = ""
    @Published private(set) var errorText = ""
    /// 面板允许的最大高度（由 PanelController 在显示前按屏幕算好）
    @Published var maxPanelHeight: CGFloat = 480

    var onHide: () -> Void = {}
    var onCopyAndPaste: (String) -> Void = { _ in }

    private var apps: [AppEntry] = []
    private var historyCursor = -1
    private let key = "calc.history"
    private let maxEntries = 30
    private var toastWork: DispatchWorkItem?

    init() {
        entries = loadEntries()
        refreshApps()
    }

    var ans: Double { entries.first?.value ?? 0 }

    var selectedRow: SearchRow? { rows.indices.contains(selection) ? rows[selection] : nil }

    var currentOutput: Calculator.Output? {
        if case .calculation(let output)? = rows.first { return output }
        return nil
    }

    func reset() {
        input = ""
        selection = 0
        toast = ""
        historyCursor = -1
        entries = loadEntries()
        refreshApps()
        rebuild()
    }

    private func refreshApps() {
        Task {
            let list = await AppIndex.shared.all()
            await MainActor.run {
                self.apps = list
                self.rebuild()
            }
        }
    }

    // MARK: - 组织结果

    private func rebuild() {
        let text = input.trimmingCharacters(in: .whitespaces)
        var next: [SearchRow] = []
        errorText = ""

        if text.isEmpty {
            next = entries.prefix(8).map { SearchRow.history($0) }
            rows = next
            selection = 0
            return
        }

        // 1) 能算就把结果放第一行
        switch Calculator.evaluate(effectiveExpression(text), ans: ans) {
        case .success(let output):
            next.append(.calculation(output))
        case .failure(let failure):
            // 纯数字或运算符开头却算不出来时，把错误提示出来
            if looksLikeExpression(text) { errorText = failure.text }
        }

        // 2) 应用搜索
        let matches = apps
            .compactMap { entry -> (AppEntry, Int)? in
                guard let score = AppIndex.score(entry, query: text) else { return nil }
                return (entry, score)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(12)
            .map { SearchRow.app($0.0) }
        next.append(contentsOf: matches)

        rows = next
        if selection >= next.count { selection = max(0, next.count - 1) }
    }

    /// 多步计算：直接以运算符开头时，自动接上上一次的结果
    func effectiveExpression(_ text: String) -> String {
        guard let first = text.first, "+-*/^%×÷".contains(first), !entries.isEmpty else { return text }
        return "ans " + text
    }

    private func looksLikeExpression(_ text: String) -> Bool {
        text.rangeOfCharacter(from: CharacterSet(charactersIn: "0123456789")) != nil
            && text.rangeOfCharacter(from: CharacterSet(charactersIn: "+-*/^%()×÷")) != nil
    }

    // MARK: - 执行

    func activate(_ row: SearchRow?) {
        guard let row else { return }
        switch row {
        case .calculation(let output):
            commit(output)
        case .app(let entry):
            launch(entry)
        case .history(let entry):
            input = entry.expression
            selection = 0
        }
    }

    /// 回车：结果进历史 + 复制到剪贴板，输入框清空但保留 ans 供下一步用
    private func commit(_ output: Calculator.Output) {
        let expression = effectiveExpression(input.trimmingCharacters(in: .whitespaces))
        var list = entries.filter { $0.expression != expression }
        list.insert(CalcEntry(expression: expression, display: output.display,
                              value: output.value, date: Date()), at: 0)
        entries = Array(list.prefix(maxEntries))
        saveEntries()

        ClipboardWatcher.shared.writeText(output.raw)
        input = ""
        selection = 0
        showToast("= \(output.display) 已复制，可以接着算（直接输入 + - × ÷ 继续）")
    }

    private func launch(_ entry: AppEntry) {
        onHide()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: entry.url, configuration: configuration) { _, error in
            if let error {
                NSLog("[qmac] 启动 \(entry.name) 失败: \(error.localizedDescription)")
            }
        }
    }

    /// ⌘↵：只复制不进历史
    func copyOnly() {
        guard let output = currentOutput else { return }
        ClipboardWatcher.shared.writeText(output.raw)
        showToast("已复制 \(output.display)")
    }

    func clearHistory() {
        entries = []
        saveEntries()
        rebuild()
    }

    private func showToast(_ message: String) {
        toast = message
        toastWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.toast = "" }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
    }

    // MARK: - 键盘

    func handleKey(_ event: NSEvent) -> Bool {
        let command = event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)

        switch event.keyCode {
        case 53:                       // esc
            if input.isEmpty { onHide() } else { input = "" }
            return true
        case 36, 76:                   // return
            if command { copyOnly() } else { activate(selectedRow) }
            return true
        case 8 where command:          // ⌘C
            copyOnly()
            return true
        case 125:                      // ↓
            if !rows.isEmpty { selection = (selection + 1) % rows.count }
            return true
        case 126:                      // ↑
            if !rows.isEmpty { selection = (selection - 1 + rows.count) % rows.count }
            return true
        default:
            return false
        }
    }

    private func loadEntries() -> [CalcEntry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([CalcEntry].self, from: data) else { return [] }
        return decoded
    }

    private func saveEntries() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

struct SearchView: View {
    @ObservedObject var model: SearchViewModel
    @FocusState private var focused: Bool

    /// 面板总高度减去输入框和底部提示条，剩下的留给结果列表
    private var listMaxHeight: CGFloat {
        max(120, model.maxPanelHeight - 64 - 34)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17))
                    .foregroundStyle(.tertiary)
                TextField("搜索应用，或直接输入算式", text: $model.input)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22))
                    .focused($focused)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            if !model.toast.isEmpty || !model.errorText.isEmpty {
                Text(model.toast.isEmpty ? model.errorText : model.toast)
                    .font(.system(size: 11.5))
                    .foregroundStyle(model.toast.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.accentColor))
                    .lineLimit(1)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 8)
            }

            if !model.rows.isEmpty {
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 1) {
                            ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                                rowView(row, selected: index == model.selection)
                                    .id(row.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture { model.selection = index; model.activate(row) }
                            }
                        }
                        .padding(6)
                    }
                    // 装得下就按内容高度，装不下就滚动，框本身不再往下长
                    .frame(maxHeight: listMaxHeight)
                    .onChange(of: model.selection) { _, index in
                        guard model.rows.indices.contains(index) else { return }
                        proxy.scrollTo(model.rows[index].id, anchor: .center)
                    }
                }
            }

            Divider()
            HStack(spacing: 12) {
                hint("↵", model.selectedIsApp ? "打开应用" : "记入历史并复制")
                hint("⌘↵", "仅复制")
                hint("↑↓", "选择")
                hint("ans", "上次结果")
                hint("esc", "关闭")
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
        }
        .frame(width: 620)
        .background(VisualEffectBackground())
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
        .onAppear { focused = true }
    }

    @ViewBuilder
    private func rowView(_ row: SearchRow, selected: Bool) -> some View {
        HStack(spacing: 10) {
            switch row {
            case .calculation(let output):
                Image(systemName: "equal.square.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 22)
                Text(output.display)
                    .font(.system(size: 17, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                Spacer(minLength: 10)
                if !output.extras.isEmpty {
                    Text(output.extras.joined(separator: "  "))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }

            case .app(let entry):
                if let icon = NSWorkspace.shared.icon(forFile: entry.path) as NSImage? {
                    Image(nsImage: icon).resizable().frame(width: 22, height: 22)
                }
                Text(entry.name).font(.system(size: 14))
                Spacer(minLength: 10)
                Text("应用").font(.system(size: 10.5)).foregroundStyle(.tertiary)

            case .history(let entry):
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .frame(width: 22)
                Text(entry.expression)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 10)
                Text("= \(entry.display)")
                    .font(.system(size: 13, design: .monospaced))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(selected ? Color.accentColor.opacity(0.18) : Color.clear)
        )
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

extension SearchViewModel {
    var selectedIsApp: Bool {
        if case .app? = selectedRow { return true }
        return false
    }
}
