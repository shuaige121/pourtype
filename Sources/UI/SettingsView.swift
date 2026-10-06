import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pourtype").font(.system(size: 17, weight: .semibold))
                        Text(L.t("版本 ", "Version ") + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L.t("使用指南", "Getting Started")) { NSWorkspace.shared.open(URL(string: "pourtype://welcome")!) }
                    Button(L.t("帮助", "Help")) { NSWorkspace.shared.open(URL(string: "https://shuaige121.github.io/pourtype/support.html")!) }
                }
                .padding(.vertical, 4)
            }
            Section(L.t("权限", "Permissions")) {
                PermissionRow(title: L.t("辅助功能", "Accessibility"),
                              detail: L.t("用来打字，并在打字时暂时锁住键盘和鼠标。", "To type, and to hold the keyboard and mouse while it types."),
                              granted: model.accessibility,
                              grant: { Permissions.requestAccessibility(); Permissions.open("Privacy_Accessibility") })
                PermissionRow(title: L.t("屏幕录制", "Screen Recording"),
                              detail: L.t("只在 ⌘⇧C 截取你框选的区域时使用。", "Only for the area you select with ⌘⇧C."),
                              granted: model.screenRecording,
                              grant: { Permissions.requestScreenRecording(); Permissions.open("Privacy_ScreenCapture") })
            }
            Section(L.t("快捷键", "Shortcuts")) {
                ShortcutRow(keys: "⌘⇧V", title: L.t("打出剪贴板", "Type the clipboard"), ok: model.typeHotkeyOK)
                ShortcutRow(keys: "⌘⇧C", title: L.t("截图识字", "Grab text"), ok: model.grabHotkeyOK)
                ShortcutRow(keys: "⌃⌥⌘B", title: L.t("慢速打出（更像人手）", "Type slowly, human-paced"), ok: model.slowHotkeyOK)
                Text(L.t("打字时：↑↓ 调速度，←→ 调节奏，Esc 停止。", "While typing: ↑↓ speed, ←→ rhythm, Esc stops."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L.t("打字", "Typing")) {
                LabeledContent(L.t("默认速度", "Default speed")) {
                    HStack {
                        Slider(value: $model.speedLog, in: log(CPS_MIN)...log(CPS_MAX))
                        Text("\(Int(exp(model.speedLog).rounded())) " + L.t("字/秒", "chars/s"))
                            .monospacedDigit().frame(width: 80, alignment: .trailing)
                    }
                }
                LabeledContent(L.t("默认节奏", "Default rhythm")) {
                    HStack {
                        Text(L.t("平稳", "Steady")).font(.caption)
                        Slider(value: $model.rhythm, in: 0...1)
                        Text(L.t("随机", "Random")).font(.caption)
                    }
                }
            }
            Section(L.t("截图识字", "Grab text")) {
                Toggle(L.t("英文和数字后的全角标点改成半角", "Half-width punctuation after Latin text"), isOn: $model.asciiPunct)
                Toggle(L.t("在历史里保留截图", "Keep the screenshot in history"), isOn: $model.keepScreenshots)
            }
            Section(L.t("历史记录", "History")) {
                Toggle(L.t("记录识别和打出的文字", "Keep grabbed and typed text"), isOn: $model.historyEnabled)
                Picker(L.t("保留", "Keep for"), selection: $model.historyDays) {
                    Text(L.t("7 天", "7 days")).tag(7)
                    Text(L.t("30 天", "30 days")).tag(30)
                    Text(L.t("90 天", "90 days")).tag(90)
                    Text(L.t("1 年", "1 year")).tag(365)
                }
                HStack {
                    Text(L.t("只存在这台 Mac 上，不联网。", "Stored on this Mac only. Nothing leaves it."))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(L.t("清空历史…", "Clear History…"), role: .destructive) { model.confirmClear = true }
                }
            }
            Section(L.t("通用", "General")) {
                Toggle(L.t("登录时启动", "Launch at login"), isOn: $model.launchAtLogin)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .frame(minHeight: 560)
        .onAppear { model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refresh() }
        .confirmationDialog(L.t("清空全部历史记录？", "Clear all history?"), isPresented: $model.confirmClear) {
            Button(L.t("清空", "Clear"), role: .destructive) { HistoryStore.shared.clear() }
        } message: {
            Text(L.t("文字和截图都会删除，无法恢复。", "Texts and screenshots are deleted and cannot be restored."))
        }
    }
}

private struct PermissionRow: View {
    let title: String, detail: String, granted: Bool, grant: () -> Void
    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted { Button(L.t("授权…", "Grant…"), action: grant) }
        }
    }
}

private struct ShortcutRow: View {
    let keys: String, title: String, ok: Bool
    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if !ok {
                Text(L.t("被别的 App 占用", "In use by another app")).font(.caption).foregroundStyle(.orange)
            }
            Text(keys).font(.system(.body, design: .rounded)).monospaced()
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
        }
    }
}

final class SettingsModel: ObservableObject {
    @Published var accessibility = Permissions.accessibility
    @Published var screenRecording = Permissions.screenRecording
    @Published var typeHotkeyOK = true
    @Published var grabHotkeyOK = true
    @Published var slowHotkeyOK = true
    @Published var confirmClear = false
    @Published var speedLog: Double = log(Prefs.pace("normal").cps) { didSet { savePace() } }
    @Published var rhythm: Double = Prefs.pace("normal").rand { didSet { savePace() } }
    @Published var asciiPunct = Prefs.asciiPunct { didSet { Prefs.asciiPunct = asciiPunct } }
    @Published var keepScreenshots = Prefs.keepScreenshots { didSet { Prefs.keepScreenshots = keepScreenshots } }
    @Published var historyEnabled = Prefs.historyEnabled { didSet { Prefs.historyEnabled = historyEnabled } }
    @Published var historyDays = Prefs.historyDays { didSet { Prefs.historyDays = historyDays; HistoryStore.shared.prune() } }
    @Published var launchAtLogin = LoginItem.enabled {
        didSet {
            guard launchAtLogin != LoginItem.enabled else { return }
            do { try LoginItem.set(launchAtLogin) } catch { launchAtLogin = LoginItem.enabled }
        }
    }

    func refresh() {
        accessibility = Permissions.accessibility
        screenRecording = Permissions.screenRecording
        let p = Prefs.pace("normal")
        if abs(exp(speedLog) - p.cps) > 0.5 { speedLog = log(p.cps) }
        if abs(rhythm - p.rand) > 0.01 { rhythm = p.rand }
    }

    private func savePace() { Prefs.setPace("normal", Pace(cps: exp(speedLog), rand: rhythm)) }
}
