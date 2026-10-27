import SwiftUI
import XCTest
@testable import Pourtype

/// The history window's keys, deletion and retention.
final class HistoryTests: XCTestCase {
    /// Return ends a search in the sidebar; it must not also type the selected entry into another app.
    func testReturnDoesNotTypeAgain() {
        let s = HistoryView.typeAgainShortcut
        XCTAssertNotEqual(s, .defaultAction)
        XCTAssertEqual(s.key, .return)
        XCTAssertTrue(s.modifiers.contains(.command))
    }

    // MARK: - deletion

    private var dirs: [URL] = []

    override func tearDown() {
        for d in dirs {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: d.path)
            try? FileManager.default.removeItem(at: d)
        }
        dirs = []
        super.tearDown()
    }

    /// A history folder holding these entries (written directly, so the History setting does not matter),
    /// each grab with a screenshot file.
    private func folder(_ items: [HistoryItem]) throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        dirs.append(d)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        for it in items { if let img = it.image { try Data([0x89, 0x50]).write(to: d.appendingPathComponent(img)) } }
        try JSONEncoder.history.encode(items).write(to: d.appendingPathComponent("history.json"))
        return d
    }

    private func grab(_ text: String, daysAgo: Double = 0, now: Date = Date()) -> HistoryItem {
        let id = UUID()
        return HistoryItem(id: id, kind: .grab, text: text, date: now.addingTimeInterval(-daysAgo * 86400), app: "Preview",
                           image: "\(id.uuidString).png")
    }

    private func readOnly(_ d: URL, _ on: Bool) throws {
        try FileManager.default.setAttributes([.posixPermissions: on ? 0o555 : 0o755], ofItemAtPath: d.path)
    }

    /// The disk refuses: delete says so, and the entry and its screenshot stay, in the list and on disk.
    /// Once the disk allows it, the same delete removes both.
    func testAFailedDeleteIsReportedAndTheListStaysTrue() throws {
        let a = grab("alpha"), b = grab("beta")
        let d = try folder([a, b])
        let store = HistoryStore(dir: d, days: { 90 })
        let png = try XCTUnwrap(store.imageURL(a))
        try readOnly(d, true)
        XCTAssertNotNil(store.delete([a.id]))
        XCTAssertEqual(store.items.map(\.id), [a.id, b.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: png.path))
        XCTAssertNotNil(store.clear())
        XCTAssertEqual(store.items.map(\.id), [a.id, b.id])
        XCTAssertEqual(HistoryStore(dir: d, days: { 90 }).items.map(\.id), [a.id, b.id])
        try readOnly(d, false)
        XCTAssertNil(store.delete([a.id]))
        XCTAssertEqual(store.items.map(\.id), [b.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: png.path))
        XCTAssertEqual(HistoryStore(dir: d, days: { 90 }).items.map(\.id), [b.id])
    }

    /// The index cannot be written (its screenshot is already gone): the entry stays listed, as the index on
    /// disk still has it.
    func testWhenTheIndexCannotBeWrittenTheEntryStaysListed() throws {
        let a = HistoryItem(kind: .typed, text: "typed alpha", app: "Notes")
        let d = try folder([a])
        let store = HistoryStore(dir: d, days: { 90 })
        let index = d.appendingPathComponent("history.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: index.path)
        try readOnly(d, true)
        XCTAssertNotNil(store.delete([a.id]))
        XCTAssertEqual(store.items.map(\.id), [a.id])
        XCTAssertEqual(HistoryStore(dir: d, days: { 90 }).items.map(\.id), [a.id])
    }

    // MARK: - retention while the app runs

    /// No launch, no add and no settings change: an entry that ages past the period still goes, on the timer.
    func testRetentionRunsOnATimer() throws {
        let start = Date()
        var now = start
        let a = grab("old soon", now: start)
        let d = try folder([a])
        let store = HistoryStore(dir: d, days: { 7 }, clock: { now })
        XCTAssertEqual(store.items.count, 1)
        store.keepPruning(every: 0.05, wake: NotificationCenter())
        now = start.addingTimeInterval(8 * 86400)
        let gone = expectation(for: NSPredicate { _, _ in store.items.isEmpty }, evaluatedWith: nil)
        wait(for: [gone], timeout: 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(store.imageURL(a)).path))
        XCTAssertTrue(HistoryStore(dir: d, days: { 7 }, clock: { now }).items.isEmpty)
    }

    /// Waking the Mac (after days asleep) prunes at once, without waiting for the hourly timer.
    func testRetentionRunsOnWake() throws {
        let start = Date()
        var now = start
        let d = try folder([grab("old soon", now: start)])
        let store = HistoryStore(dir: d, days: { 7 }, clock: { now })
        let wake = NotificationCenter()
        store.keepPruning(every: 3600, wake: wake)
        now = start.addingTimeInterval(8 * 86400)
        XCTAssertEqual(store.items.count, 1)
        wake.post(name: NSWorkspace.didWakeNotification, object: nil)
        let gone = expectation(for: NSPredicate { _, _ in store.items.isEmpty }, evaluatedWith: nil)
        wait(for: [gone], timeout: 5)
    }

    /// A screenshot no entry refers to (left by an older version's failed delete) is removed; other files stay.
    func testPruneRemovesOrphanedScreenshots() throws {
        let a = grab("kept")
        let d = try folder([a])
        let orphan = d.appendingPathComponent("\(UUID().uuidString).png"), other = d.appendingPathComponent("notes.png")
        try Data([1]).write(to: orphan)
        try Data([1]).write(to: other)
        let store = HistoryStore(dir: d, days: { 90 })
        XCTAssertNil(store.prune())
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(store.imageURL(a)).path))
    }

    /// An index that exists but cannot be read: its screenshots are unknown, so none is treated as an orphan.
    func testAnUnreadableIndexKeepsTheScreenshots() throws {
        let d = try folder([])
        let png = d.appendingPathComponent("\(UUID().uuidString).png")
        try Data([1]).write(to: png)
        try Data("not json".utf8).write(to: d.appendingPathComponent("history.json"))
        _ = HistoryStore(dir: d, days: { 90 })
        XCTAssertTrue(FileManager.default.fileExists(atPath: png.path))
    }
}
