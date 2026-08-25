import AppKit
import CryptoKit

struct ClipItem: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case text, image }

    let id: UUID
    var kind: Kind
    var text: String          // 文本内容；图片时为空
    var preview: String
    var chars: Int
    var truncated: Bool
    var imageFile: String?    // images/ 下的原图文件名
    var thumbFile: String?    // images/ 下的缩略图文件名
    var width: Int
    var height: Int
    var bytes: Int
    var date: Date
    var pinned: Bool
    var hash: String
}

/// 剪贴板历史：内存里排好序，落盘到 Application Support。
final class ClipboardStore: ObservableObject {
    static let shared = ClipboardStore()

    @Published private(set) var items: [ClipItem] = []

    private let queue = DispatchQueue(label: "com.cuiqing.quickkit.store")
    private var saveWork: DispatchWorkItem?
    private let maxTextLength = 20_000

    let baseURL: URL
    private let imagesURL: URL
    private var fileURL: URL { baseURL.appendingPathComponent("history.json") }

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        baseURL = support.appendingPathComponent("QuickKit", isDirectory: true)
        imagesURL = baseURL.appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: imagesURL, withIntermediateDirectories: true)
        load()
    }

    // MARK: - 读写

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([ClipItem].self, from: data) else { return }
        items = decoded
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let snapshot = items
        let work = DispatchWorkItem { [fileURL] in
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: fileURL, options: .atomic)
        }
        saveWork = work
        queue.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    func flush() {
        saveWork?.cancel()
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func imageURL(_ name: String) -> URL { imagesURL.appendingPathComponent(name) }

    func image(for item: ClipItem, thumbnail: Bool) -> NSImage? {
        guard let name = thumbnail ? (item.thumbFile ?? item.imageFile) : (item.imageFile ?? item.thumbFile) else { return nil }
        return NSImage(contentsOf: imageURL(name))
    }

    // MARK: - 增删改

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    func addText(_ raw: String) -> ClipItem? {
        let truncated = raw.count > maxTextLength
        let body = truncated ? String(raw.prefix(maxTextLength)) : raw
        let hash = Self.digest(Data(body.utf8))

        if let index = items.firstIndex(where: { $0.kind == .text && $0.hash == hash }) {
            items[index].date = Date()          // 重复内容只刷新时间
            sortAndTrim()
            scheduleSave()
            return items.first { $0.hash == hash }
        }

        let item = ClipItem(id: UUID(), kind: .text, text: body,
                            preview: Self.preview(of: body), chars: raw.count, truncated: truncated,
                            imageFile: nil, thumbFile: nil, width: 0, height: 0, bytes: body.utf8.count,
                            date: Date(), pinned: false, hash: hash)
        items.insert(item, at: 0)
        sortAndTrim()
        scheduleSave()
        return item
    }

    @discardableResult
    func addImage(_ image: NSImage, pngData: Data) -> ClipItem? {
        let hash = Self.digest(pngData)
        if let index = items.firstIndex(where: { $0.kind == .image && $0.hash == hash }) {
            items[index].date = Date()
            sortAndTrim()
            scheduleSave()
            return items.first { $0.hash == hash }
        }

        let id = UUID()
        let fullName = "\(id.uuidString).png"
        let thumbName = "\(id.uuidString)-thumb.png"
        try? pngData.write(to: imageURL(fullName), options: .atomic)

        let size = image.size
        if let thumb = Self.thumbnail(image, maxEdge: 480) {
            try? thumb.write(to: imageURL(thumbName), options: .atomic)
        }

        let item = ClipItem(id: id, kind: .image, text: "",
                            preview: "图片 \(Int(size.width))×\(Int(size.height))",
                            chars: 0, truncated: false,
                            imageFile: fullName, thumbFile: thumbName,
                            width: Int(size.width), height: Int(size.height), bytes: pngData.count,
                            date: Date(), pinned: false, hash: hash)
        items.insert(item, at: 0)
        sortAndTrim()
        scheduleSave()
        return item
    }

    func remove(_ item: ClipItem) {
        items.removeAll { $0.id == item.id }
        deleteFiles(of: item)
        scheduleSave()
    }

    func togglePin(_ item: ClipItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].pinned.toggle()
        sortAndTrim()
        scheduleSave()
    }

    func clear(keepPinned: Bool = true) {
        let dropped = keepPinned ? items.filter { !$0.pinned } : items
        items = keepPinned ? items.filter(\.pinned) : []
        dropped.forEach(deleteFiles)
        flush()
    }

    func filtered(_ query: String) -> [ClipItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return items }
        return items.filter {
            $0.kind == .text ? $0.text.lowercased().contains(q) : "图片 image".contains(q)
        }
    }

    // MARK: - 私有

    private func deleteFiles(of item: ClipItem) {
        for name in [item.imageFile, item.thumbFile].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: imageURL(name))
        }
    }

    private func sortAndTrim() {
        items.sort { lhs, rhs in
            lhs.pinned == rhs.pinned ? lhs.date > rhs.date : lhs.pinned
        }
        let limit = max(20, Settings.shared.maxHistory)
        var unpinnedSeen = 0
        var kept: [ClipItem] = []
        var dropped: [ClipItem] = []
        for item in items {
            if item.pinned { kept.append(item); continue }
            unpinnedSeen += 1
            if unpinnedSeen <= limit { kept.append(item) } else { dropped.append(item) }
        }
        items = kept
        dropped.forEach(deleteFiles)
    }

    private static func preview(of text: String) -> String {
        let collapsed = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return String(collapsed.prefix(160))
    }

    private static func thumbnail(_ image: NSImage, maxEdge: CGFloat) -> Data? {
        let size = image.size
        let scale = min(1, maxEdge / max(size.width, size.height))
        guard scale < 1 else { return image.pngData }
        let target = NSSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let resized = NSImage(size: target)
        resized.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: target))
        resized.unlockFocus()
        return resized.pngData
    }
}

extension NSImage {
    var pngData: Data? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
