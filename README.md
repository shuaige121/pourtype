# Pourtype

A small macOS menu-bar utility for two chores:

- **⌘⇧V — type the clipboard.** Some fields and dialogs block paste. Pourtype types the clipboard into the focused field as real keystrokes. While it types, every display is frosted except the target field and your keyboard and mouse are held, so focus cannot wander off. **Esc** stops it at once.
- **⌘⇧C — grab text.** Drag a box anywhere on screen; the text inside (Chinese, English, Japanese) is recognised on your Mac with Apple's Vision framework and copied.
- **History.** Every grab and every typed text is kept in a local, searchable history: copy it again or type it again.

Everything runs locally. The app makes no network requests and collects no data.

## While it types

| Key | Effect |
|---|---|
| Esc | stop now, give the keyboard and mouse back |
| hold ↑ / ↓ | faster / slower (3–150 characters per second) |
| hold ← / → | steadier / more random, human-like rhythm |

The card shows the app and window being typed into, the text streaming past, progress and time left. On other displays a small card points to the one being typed on. Typing stops by itself if another app comes to the front or the displays change. Newlines go in as Shift+Return so chat boxes do not send early; tabs become spaces.

In a password field macOS turns on Secure Input, which hides the keyboard from every app; there the keyboard cannot be held, so Pourtype types without the veil and **⌃⌥⌘.** stops it.

## Permissions

- **Accessibility** — to type, and to hold the keyboard and mouse while typing (an event tap that is on only during a run; Esc, a crash or a hang all give input back).
- **Screen Recording** — only for the box you draw with ⌘⇧C.

## Build

Deployment target macOS 14; so far built with Xcode 27 and tested on macOS 27 only.

```sh
brew install xcodegen        # the project file is generated from project.yml
scripts/build.sh             # -> build/Pourtype.app, signed with your Apple Development identity
```

Configurations: `Debug`, `Release` (direct download, hardened runtime), `AppStore` (sandboxed, `APPSTORE` compile flag). Unit tests: `xcodebuild -scheme Pourtype test`.

Automation hooks: `open -g pourtype://type`, `pourtype://type-slow`, `pourtype://grab`, `pourtype://history`.

## How it works

- `Sources/TypeOver` — the typing engine (one CGEvent per grapheme cluster, Unicode string payload, so input methods are bypassed), the HID-level event tap that holds input, and the veil: one window per display with a frosted `NSVisualEffectView` cut out around the field and a `WKWebView` HUD (`Resources/hud.html`).
- `Sources/Grab` — the region picker, ScreenCaptureKit capture and Vision text recognition.
- `Sources/History` — a JSON index plus PNG thumbnails under Application Support.

## License

MIT — see [LICENSE](LICENSE).
