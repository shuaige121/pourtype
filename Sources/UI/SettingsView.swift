import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: AppIcon.image).resizable().frame(width: 52, height: 52)
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
                PermissionRow(title: L.t("辅助功能（无障碍）", "Accessibility"),
                              detail: L.t("用来打字，并在打字时暂时锁住键盘和鼠标。", "To type, and to hold the keyboard and mouse while it types."),
                              granted: model.accessibility,
                              grant: { Permissions.requestAccessibility(); Permissions.open("Privacy_Accessibility") })
                PermissionRow(title: L.t("屏幕录制", "Screen Recording"),
                              detail: L.f("只在 %1$@ 截取你框选的区域时使用。", "Only for the area you select with %1$@.", Shortcuts.get(.grab).display),
                              granted: model.screenRecording,
                              grant: { Permissions.requestScreenRecording(); Permissions.open("Privacy_ScreenCapture") })
            }
            Section(L.t("快捷键", "Shortcuts")) {
                ShortcutRecorder(action: .type, ok: model.typeHotkeyOK)
                ShortcutRecorder(action: .grab, ok: model.grabHotkeyOK)
                ShortcutRecorder(action: .slow, ok: model.slowHotkeyOK)
                Text(L.t("点击快捷键可以更换。打字时：↑↓ 调速度，←→ 调节奏，Esc 停止。", "Click a shortcut to change it. While typing: ↑↓ speed, ←→ rhythm, Esc stops."))
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
                Toggle(L.t("按我自己的节奏打字", "Type at my own pace"),
                       isOn: Binding(get: { model.ownPace && model.learned != nil }, set: { model.ownPace = $0 }))
                    .disabled(model.learned == nil)
                HStack(alignment: .top) {
                    Text(model.learnedNote).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if model.learned != nil {
                        Button(L.t("删除…", "Delete…"), role: .destructive) { model.confirmDeleteProfile = true }
                    }
                    Button(model.learned == nil ? L.t("学习我的打字习惯…", "Learn my typing…") : L.t("重新学习…", "Learn again…")) {
                        model.learning = true
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
                VStack(alignment: .leading, spacing: 2) {
                    Toggle(L.t("允许链接打出剪贴板", "Let links type the clipboard"), isOn: $model.linkTyping)
                    Text(L.t("给打开 pourtype://type 的脚本用。打开后，任何 App 或网页都能让 Pourtype 打出你复制的内容。",
                             "For scripts that open pourtype://type. When on, any app or web page can make Pourtype type what you copied."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .frame(minHeight: 560)
        .onAppear { model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refresh() }
        .sheet(isPresented: $model.learning) {
            LearnTypingView { _ in model.learning = false; model.refreshProfile() }
        }
        .confirmationDialog(L.t("删除学到的打字习惯？", "Delete your learned typing?"), isPresented: $model.confirmDeleteProfile) {
            Button(L.t("删除", "Delete"), role: .destructive) { model.deleteProfile() }
        } message: {
            Text(L.t("之后按上面的默认速度和节奏打字。", "Pourtype goes back to the default speed and rhythm above."))
        }
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
    @Published var ownPace = Prefs.ownPace { didSet { Prefs.ownPace = ownPace } }
    @Published private(set) var learned = ProfileStore.shared.load()
    @Published var learning = false
    @Published var confirmDeleteProfile = false
    @Published var linkTyping = Prefs.linkTyping { didSet { Prefs.linkTyping = linkTyping } }
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
        if linkTyping != Prefs.linkTyping { linkTyping = Prefs.linkTyping }
        let p = Prefs.pace("normal")
        if abs(exp(speedLog) - p.cps) > 0.5 { speedLog = log(p.cps) }
        if abs(rhythm - p.rand) > 0.01 { rhythm = p.rand }
    }

    private func savePace() { Prefs.setPace("normal", Pace(cps: exp(speedLog), rand: rhythm)) }

    func refreshProfile() { learned = ProfileStore.shared.load() }

    /// Removes the learned profile and turns "Type at my own pace" off.
    func deleteProfile() {
        ProfileStore.shared.delete()
        ownPace = false
        learned = nil
    }

    var learnedNote: String {
        guard let p = learned else {
            return L.t("先照着一段文字打一遍，Pourtype 会学会你的速度和节奏。", "Type a short passage once and Pourtype learns your speed and rhythm.")
        }
        let date = ISO8601DateFormatter().date(from: p.createdUtc).map { $0.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(L.locale)) } ?? ""
        return L.f("已于 %1$@ 学习。打开后按你的速度和节奏打字，不用上面的默认值；打字时 ↑↓ ←→ 照样可以调。",
                   "Learned on %1$@. When on, Pourtype types at your speed and rhythm instead of the defaults above; ↑↓ and ←→ still adjust each run.", date)
    }
}
