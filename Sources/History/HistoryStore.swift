import AppKit
import Combine

// Every grab and every typed text, kept on this Mac only: one JSON index plus a PNG per
// grab, under Application Support (inside the container in the App Store build).

struct HistoryItem: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case grab, typed }
    var id = UUID()
    var kind: Kind
    var text: String
    var date = Date()
    var app: String?
    var image: String?          // file name of the screenshot, grabs only
    var outcome: String?        // typed only: "done" or why it stopped, e.g. "esc 120/300"
}

final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()
    @Published private(set) var items: [HistoryItem] = []
    let dir: URL
    private var index: URL { dir.appendingPathComponent("history.json") }

    init(dir: URL? = nil) {
        let base = dir ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Pourtype", isDirectory: true)
            .appendingPathComponent("History", isDirectory: true)
        self.dir = base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: index),
           let list = try? JSONDecoder.history.decode([HistoryItem].self, from: data) { items = list }
        prune()
    }

    func imageURL(_ item: HistoryItem) -> URL? { item.image.map { dir.appendingPathComponent($0) } }

    func add(_ item: HistoryItem, png: Data? = nil) {
        guard Prefs.historyEnabled else { return }
        var it = item
        if let png, Prefs.keepScreenshots {
            let name = "\(it.id.uuidString).png"
            if (try? png.write(to: dir.appendingPathComponent(name), options: .atomic)) != nil { it.image = name }
        }
        items.insert(it, at: 0)
        prune()
        save()
    }

    func delete(_ ids: Set<UUID>) {
        for it in items where ids.contains(it.id) { removeImage(it) }
        items.removeAll { ids.contains($0.id) }
        save()
    }

    func clear() {
        for it in items { removeImage(it) }
        items = []
        save()
    }

    /// Older than the retention period, or beyond 2000 entries, goes.
    func prune(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Double(Prefs.historyDays) * 86400)
        let keep = items.enumerated().filter { $0.offset < 2000 && $0.element.date >= cutoff }.map { $0.element }
        guard keep.count != items.count else { return }
        let kept = Set(keep.map { $0.id })
        for it in items where !kept.contains(it.id) { removeImage(it) }
        items = keep
        save()
    }

    func search(_ q: String) -> [HistoryItem] {
        let s = q.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return items }
        return items.filter { $0.text.localizedCaseInsensitiveContains(s) || ($0.app ?? "").localizedCaseInsensitiveContains(s) }
    }

    private func removeImage(_ it: HistoryItem) {
        if let u = imageURL(it) { try? FileManager.default.removeItem(at: u) }
    }

    private func save() {
        guard let data = try? JSONEncoder.history.encode(items) else { return }
        try? data.write(to: index, options: .atomic)
    }
}

extension JSONEncoder {
    static var history: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
}
extension JSONDecoder {
    static var history: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}
