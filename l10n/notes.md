# Translation notes (ja, zh-Hant)

- Blocker (not a translation issue): `Accessibility` has two Chinese versions in Swift (OnboardingView.swift:72 and SettingsView.swift:23); `l10n.py check` fails on it before reading the JSON. Fix the Swift so both use the same zh-Hans.
- "Grab Text": ja テキストを取り込む (fixed term list), zh-Hant 擷取文字 (matches aso/zh-Hant.md). ASO ja uses 画面の文字をコピー as a description, not a feature name.
- Shortcut: zh-Hant 快速鍵 (Taiwan usage); ASO does not name it.
- Sample email (38): kept the name "Alex" from English; zh-Hans uses 林晓.
- Sample receipt/Wi-Fi: followed English; zh-Hans adds "访客" before Wi-Fi, English does not.
- "Typing into" / "Typing on another display into" (50/51): ja 入力先 / 別のディスプレイの入力先 are labels; check the overlay layout that a label then app name reads naturally.
- "Hide" (89): ja 隠す, zh-Hant 收合 (it collapses a help block).
- "Help" (104): zh-Hant 說明 (macOS uses 輔助說明, avoided to not clash with 輔助使用).
- "Default speed/rhythm": ja 標準の…, button "Restore default": 初期設定に戻す.
- "Stopped" label (63): ja 停止 same as "Stop" button; consider 停止済み if ambiguity matters.
