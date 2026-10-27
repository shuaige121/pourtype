import AppKit
import XCTest
@testable import Pourtype

/// The app around the features: its main menu and its URL scheme.
final class AppShellTests: XCTestCase {
    private func items(_ m: NSMenu?) -> [NSMenuItem] {
        (m?.items ?? []).flatMap { [$0] + items($0.submenu) }
    }

    private func find(_ key: String, _ mods: NSEvent.ModifierFlags) -> NSMenuItem? {
        items(NSApp.mainMenu).first {
            $0.keyEquivalent == key && $0.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == mods
        }
    }

    /// The menu the app installs at launch (the test host is the app) has the standard editing and window keys.
    func testTheAppInstallsAMainMenuWithTheStandardKeys() throws {
        let expected: [(String, NSEvent.ModifierFlags, String)] = [
            ("c", .command, "copy:"), ("v", .command, "paste:"), ("x", .command, "cut:"), ("a", .command, "selectAll:"),
            ("z", .command, "undo:"), ("z", [.command, .shift], "redo:"), ("w", .command, "performClose:"),
            ("q", .command, "terminate:"),
        ]
        for (key, mods, action) in expected {
            let item = try XCTUnwrap(find(key, mods), "no menu item for \(mods) \(key)")
            XCTAssertEqual(item.action.map(NSStringFromSelector), action)
        }
        XCTAssertEqual(find("q", .command)?.target as? NSApplication, NSApp)
    }

    /// It stays a menu-bar app, and the menu leaves ⇧⌘V and ⇧⌘C to the global shortcuts.
    func testTheMainMenuKeepsTheAppMenuBarOnlyAndTheShortcutsFree() {
        XCTAssertEqual(NSApp.activationPolicy(), .accessory)
        XCTAssertNil(find("v", [.command, .shift]))
        XCTAssertNil(find("c", [.command, .shift]))
        let fresh = MainMenu.make(settingsTarget: nil, settingsAction: nil)
        XCTAssertFalse(items(fresh).contains { $0.keyEquivalentModifierMask.contains(.shift) && ["v", "c"].contains($0.keyEquivalent) })
    }

    // MARK: - pourtype:// links

    private func parse(_ s: String, _ allowed: Bool) -> LinkCommand? { LinkCommand.parse(URL(string: s)!, typingAllowed: allowed) }

    /// A web page or another app can open pourtype://type: unless the user allowed it, nothing is typed.
    func testLinksDoNotTypeUnlessAllowed() {
        XCTAssertEqual(parse("pourtype://type", false), .typeRefused)
        XCTAssertEqual(parse("pourtype://type-slow", false), .typeRefused)
        XCTAssertEqual(parse("pourtype://type", true), .type(mode: "normal"))
        XCTAssertEqual(parse("pourtype://type-slow", true), .type(mode: "slow"))
    }

    func testLinkTypingIsOffByDefault() throws {
        let empty = try XCTUnwrap(UserDefaults(suiteName: "pourtype-tests-\(UUID().uuidString)"))   // read only
        XCTAssertNil(empty.object(forKey: Prefs.linkTypingKey))
        XCTAssertFalse(Prefs.linkTyping(in: empty))
    }

    /// The links that type nothing work as before, whether or not typing links are allowed.
    func testLinksThatTypeNothingStillWork() {
        for allowed in [false, true] {
            XCTAssertEqual(parse("pourtype://grab", allowed), .grab)
            XCTAssertEqual(parse("pourtype://history", allowed), .history)
            XCTAssertEqual(parse("pourtype://settings", allowed), .settings)
            XCTAssertEqual(parse("pourtype://welcome", allowed), .welcome)
            XCTAssertEqual(parse("pourtype://status", allowed), .status)
            XCTAssertNil(parse("pourtype://unknown", allowed))
        }
    }
}
