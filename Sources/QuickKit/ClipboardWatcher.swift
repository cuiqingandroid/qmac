import AppKit

/// 轮询 NSPasteboard 的 changeCount，把新内容写入历史。
final class ClipboardWatcher {
    static let shared = ClipboardWatcher()

    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var ignoreChangeCount = -1
    private let store = ClipboardStore.shared

    /// 密码管理器会给内容打上这个类型，标记「不要记录」
    private let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    private init() {}

    func start() {
        stop()
        lastChangeCount = NSPasteboard.general.changeCount   // 启动前就在剪贴板里的东西不算新复制
        let interval = max(0.2, Settings.shared.pollInterval)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func restart() { start() }

    /// 我们自己往剪贴板写东西时调用，避免再被记录一遍
    func markSelfWrite() {
        ignoreChangeCount = NSPasteboard.general.changeCount
        lastChangeCount = ignoreChangeCount
    }

    private func tick() {
        let pasteboard = NSPasteboard.general
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        guard count != ignoreChangeCount else { return }

        let types = pasteboard.types ?? []
        if types.contains(concealedType) { return }

        if let text = pasteboard.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard !shouldIgnore(text) else { return }
            store.addText(text)
            return
        }

        guard Settings.shared.watchImages else { return }
        let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff]
        guard let type = imageTypes.first(where: { types.contains($0) }),
              let data = pasteboard.data(forType: type),
              let image = NSImage(data: data) else { return }
        store.addImage(image, pngData: type == .png ? data : (image.pngData ?? data))
    }

    private func shouldIgnore(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return Settings.shared.compiledIgnorePatterns.contains { $0.firstMatch(in: text, range: range) != nil }
    }

    // MARK: - 写回剪贴板

    func write(_ item: ClipItem) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        switch item.kind {
        case .text:
            pasteboard.setString(item.text, forType: .string)
        case .image:
            guard let image = store.image(for: item, thumbnail: false),
                  let data = image.pngData else { return false }
            pasteboard.setData(data, forType: .png)
        }
        markSelfWrite()
        return true
    }

    func writeText(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        markSelfWrite()
    }
}
