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

/// The list always matches what is on disk: an entry leaves it only once its screenshot is gone and the
/// index without it is written. Delete, clear and the retention cleanup return the first error instead of
/// hiding it; what could not be removed stays listed, so the user sees it is still there.
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()
    @Published private(set) var items: [HistoryItem] = []
    let dir: URL
    private var index: URL { dir.appendingPathComponent("history.json") }
    private let days: () -> Int
    private let clock: () -> Date
    private var pruneTimer: Timer?
    private var wakeObserver: (center: NotificationCenter, token: NSObjectProtocol)?
    /// The index was there but could not be read: its screenshots are not known, so none count as orphans.
    private var indexUnreadable = false

    /// days: the retention period (Settings); clock: now. Both replaceable for tests.
    init(dir: URL? = nil, days: @escaping () -> Int = { Prefs.historyDays }, clock: @escaping () -> Date = Date.init) {
        let base = dir ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Pourtype", isDirectory: true)
            .appendingPathComponent("History", isDirectory: true)
        self.dir = base
        self.days = days
        self.clock = clock
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: index),
           let list = try? JSONDecoder.history.decode([HistoryItem].self, from: data) { items = list }
        else if FileManager.default.fileExists(atPath: index.path) { indexUnreadable = true }
        prune()
    }

    deinit {
        pruneTimer?.invalidate()
        if let w = wakeObserver { w.center.removeObserver(w.token) }
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
        try? save()
        prune()
    }

    @discardableResult
    func delete(_ ids: Set<UUID>) -> Error? { remove(items.filter { ids.contains($0.id) }) }

    @discardableResult
    func clear() -> Error? { remove(items) }

    /// Older than the retention period, or beyond 2000 entries, goes; so do screenshots no entry refers to
    /// (left by an earlier failure). Runs at launch, on add, on a change of the period, and while the app
    /// runs (keepPruning).
    @discardableResult
    func prune(now: Date? = nil) -> Error? {
        let cutoff = (now ?? clock()).addingTimeInterval(-Double(days()) * 86400)
        let old = items.enumerated().filter { $0.offset >= 2000 || $0.element.date < cutoff }.map { $0.element }
        let swept = sweepOrphans()
        return (old.isEmpty ? nil : remove(old)) ?? swept
    }

    /// Prunes every `interval` seconds and when the Mac wakes, until the store goes away.
    func keepPruning(every interval: Double = 3600, wake: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        pruneTimer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.prune() }
        t.tolerance = interval / 10
        RunLoop.main.add(t, forMode: .common)
        pruneTimer = t
        if let w = wakeObserver { w.center.removeObserver(w.token) }
        let token = wake.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.prune()
        }
        wakeObserver = (wake, token)
    }

    func search(_ q: String) -> [HistoryItem] {
        let s = q.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return items }
        return items.filter { $0.text.localizedCaseInsensitiveContains(s) || ($0.app ?? "").localizedCaseInsensitiveContains(s) }
    }

    /// Removes the screenshots first; an entry whose screenshot is still there stays. Then writes the index
    /// without the rest; if that fails, the list goes back to what the index on disk still holds.
    private func remove(_ gone: [HistoryItem]) -> Error? {
        var firstError: Error?
        var removed = Set<UUID>()
        for it in gone {
            do { try removeImage(it); removed.insert(it.id) } catch { firstError = firstError ?? error }
        }
        guard !removed.isEmpty else { return firstError }
        let before = items
        items.removeAll { removed.contains($0.id) }
        do { try save() } catch {
            items = before
            return error
        }
        return firstError
    }

    private func removeImage(_ it: HistoryItem) throws {
        guard let u = imageURL(it), FileManager.default.fileExists(atPath: u.path) else { return }
        try FileManager.default.removeItem(at: u)
    }

    /// Screenshot files (<UUID>.png) that no entry refers to.
    private func sweepOrphans() -> Error? {
        guard !indexUnreadable, let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        let used = Set(items.compactMap(\.image))
        var firstError: Error?
        for n in names where n.hasSuffix(".png") && !used.contains(n) && UUID(uuidString: String(n.dropLast(4))) != nil {
            do { try FileManager.default.removeItem(at: dir.appendingPathComponent(n)) } catch { firstError = firstError ?? error }
        }
        return firstError
    }

    private func save() throws {
        try JSONEncoder.history.encode(items).write(to: index, options: .atomic)
    }
}

extension JSONEncoder {
    static var history: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
}
extension JSONDecoder {
    static var history: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}
