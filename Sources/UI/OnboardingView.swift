import AppKit
import SwiftUI

// First-run guide for people who never touch System Settings: what the app does, the two
// permissions one at a time (with live status, so nobody has to guess whether it worked),
// and a practice field that blocks paste. The step survives a relaunch, because granting
// Screen Recording asks the user to quit and reopen the app.

final class OnboardingModel: ObservableObject {
    @Published var step: Int { didSet { UserDefaults.standard.set(step, forKey: "onboarding.step") } }
    @Published var accessibility = Permissions.accessibility
    @Published var screenRecording = Permissions.screenRecording
    @Published var practice = ""
    @Published var showHelp = false
    let sample: String
    var onFinish: () -> Void = {}
    private var timer: Timer?

    init() {
        step = min(max(UserDefaults.standard.integer(forKey: "onboarding.step"), 0), 3)
        sample = L.t("你好！这段文字是用 Pourtype 打出来的，不是粘贴的。", "Hello! Pourtype typed this — it was not pasted.")
        timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in self?.refresh() }
    }
    deinit { timer?.invalidate() }

    /// For offscreen renders: freeze the shown permission state.
    func freeze(accessibility a: Bool, screenRecording s: Bool) {
        timer?.invalidate(); timer = nil
        accessibility = a; screenRecording = s
    }

    func refresh() {
        let a = Permissions.accessibility, s = Permissions.screenRecording
        if a != accessibility { accessibility = a; if a && step == 1 { advance(after: 0.9) } }
        if s != screenRecording { screenRecording = s; if s && step == 2 { advance(after: 0.9) } }
    }

    func advance(after delay: Double = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) { self.step = min(self.step + 1, 3) }
        }
    }

    var practiceDone: Bool {
        let a = practice.trimmingCharacters(in: .whitespacesAndNewlines), b = sample.trimmingCharacters(in: .whitespacesAndNewlines)
        return !a.isEmpty && a == b
    }

    func finish() {
        UserDefaults.standard.set(true, forKey: "onboarding.done")
        UserDefaults.standard.set(0, forKey: "onboarding.step")
        timer?.invalidate()
        onFinish()
    }
}

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        ZStack {
            Backdrop()
            VStack(spacing: 0) {
                Group {
                    switch model.step {
                    case 0: Welcome(next: { model.advance() })
                    case 1: PermissionStep(
                        number: 1,
                        title: L.t("允许 Pourtype 替你按键", "Let Pourtype press keys for you"),
                        why: L.t("Pourtype 要替你一个键一个键地打字，并在打字时暂时锁住键盘鼠标，防止打到别的地方。macOS 需要你亲手允许一次。",
                                 "Pourtype types for you key by key, and holds the keyboard and mouse while it types so nothing lands in the wrong place. macOS asks you to allow this once."),
                        pane: L.t("辅助功能（无障碍）", "Accessibility"),
                        granted: model.accessibility,
                        open: { Permissions.requestAccessibility(); Permissions.open("Privacy_Accessibility") },
                        help: L.t("开关已经打开却还显示没开？把 Pourtype 的开关关掉再打开一次；还不行就在列表里选中 Pourtype，点「−」删掉，再回来点上面的按钮。",
                                  "Switched on but still shown as off? Turn Pourtype's switch off and on again. If that fails, select Pourtype in the list, click −, then use the button above again."),
                        next: { model.advance() })
                    case 2: PermissionStep(
                        number: 2,
                        title: L.t("允许 Pourtype 读取你框选的区域", "Let Pourtype read the area you select"),
                        why: L.f("只在你按 %1$@ 框选时，读取框里那一小块画面来识别文字。识别在本机完成，不上传。",
                                 "Only when you press %1$@ and drag a box, Pourtype reads that area to recognise the text. It happens on your Mac; nothing is uploaded.",
                                 Shortcuts.get(.grab).display),
                        pane: L.t("录屏与系统录音", "Screen & System Audio Recording"),
                        granted: model.screenRecording,
                        open: { Permissions.requestScreenRecording(); Permissions.open("Privacy_ScreenCapture") },
                        help: L.t("打开开关后，macOS 会提示「退出并重新打开」，点它就行，Pourtype 会回到这一步。",
                                  "After you switch it on, macOS offers to Quit & Reopen Pourtype. Click it; this guide comes back to this step."),
                        next: { model.advance() })
                    default: Practice(model: model)
                    }
                }
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                        removal: .move(edge: .leading).combined(with: .opacity)))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Dots(step: model.step).padding(.bottom, 18)
            }
        }
        .frame(width: 680, height: 540)
    }
}

// MARK: - pieces

private struct Backdrop: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            RadialGradient(colors: [Color(hex: 0xA27BFF).opacity(0.28), .clear], center: .init(x: 0.2, y: 0), startRadius: 0, endRadius: 420)
            RadialGradient(colors: [Color(hex: 0xFF6FB5).opacity(0.18), .clear], center: .init(x: 0.95, y: 0.1), startRadius: 0, endRadius: 360)
        }
        .ignoresSafeArea()
    }
}

private struct Dots: View {
    let step: Int
    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<4) { i in
                Capsule().fill(i == step ? AnyShapeStyle(Aurora.gradient) : AnyShapeStyle(Color.secondary.opacity(0.25)))
                    .frame(width: i == step ? 22 : 7, height: 7)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: step)
    }
}

enum Aurora {
    static let gradient = LinearGradient(colors: [Color(hex: 0x5E9BFF), Color(hex: 0xA27BFF), Color(hex: 0xFF6FB5), Color(hex: 0xFFB066)],
                                         startPoint: .leading, endPoint: .trailing)
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

struct Keycap: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 13, weight: .semibold, design: .rounded))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.18)))
    }
}

private struct PrimaryButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 22).padding(.vertical, 10)
                .background(Capsule().fill(LinearGradient(colors: [Color(hex: 0x5E9BFF), Color(hex: 0xA27BFF)], startPoint: .leading, endPoint: .trailing)))
                .shadow(color: Color(hex: 0xA27BFF).opacity(0.35), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
    }
}

private struct Welcome: View {
    let next: () -> Void
    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: AppIcon.image).resizable().frame(width: 96, height: 96)
                .shadow(color: Color(hex: 0xA27BFF).opacity(0.35), radius: 18, y: 6)
                .padding(.top, 28)
            Text("Pourtype").font(.system(size: 30, weight: .bold, design: .rounded))
            Text(L.t("把剪贴板「打」进禁止粘贴的输入框，\n也能把屏幕上看得见的文字抓下来。",
                     "Type your clipboard into fields that block paste,\nand grab any text you can see on screen."))
                .font(.system(size: 15)).multilineTextAlignment(.center).foregroundStyle(.secondary)
            HStack(spacing: 14) {
                Feature(keys: Shortcuts.get(.type).display, title: L.t("打出剪贴板", "Type the clipboard"),
                        text: L.t("先复制，点一下要输入的地方，按下快捷键，它替你一个字一个字地打进去。按 Esc 随时停。",
                                  "Copy, click where it should go, press the shortcut. It types it for you. Esc stops."),
                        symbol: "keyboard")
                Feature(keys: Shortcuts.get(.grab).display, title: L.t("截图识字", "Grab text"),
                        text: L.t("拖一个框，框里的中英文自动识别并复制，图片、PDF、视频里的字都行。",
                                  "Drag a box; the text inside is recognised and copied — from images, PDFs, videos."),
                        symbol: "text.viewfinder")
            }
            .fixedSize(horizontal: false, vertical: true)   // both cards as tall as the taller one
            .padding(.horizontal, 36).padding(.top, 6)
            Label(L.t("全部在你的 Mac 上完成，不联网、不收集任何数据。", "Everything stays on your Mac. No network, no data collected."),
                  systemImage: "lock.shield").font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            PrimaryButton(title: L.t("开始设置（约 1 分钟）", "Set up (about 1 minute)"), action: next)
            Spacer(minLength: 8)
        }
    }
}

private struct Feature: View {
    let keys: String, title: String, text: String, symbol: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(Aurora.gradient)
                Text(title).font(.system(size: 15, weight: .semibold))
                Spacer()
                Keycap(text: keys)
            }
            Text(text).font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.08)))
    }
}

private struct PermissionStep: View {
    let number: Int, title: String, why: String, pane: String, granted: Bool
    let open: () -> Void, help: String, next: () -> Void
    @State private var showHelp = false
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 16) {
            Text(L.f("第 %1$@ 步，共 2 步", "Step %1$@ of 2", "\(number)")).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                .padding(.top, 30)
            Text(title).font(.system(size: 24, weight: .bold, design: .rounded)).multilineTextAlignment(.center)
            Text(why).font(.system(size: 13.5)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 520).fixedSize(horizontal: false, vertical: true)
            Status(granted: granted)
            if !granted {
                // what the user will see in System Settings, drawn so they recognise it
                VStack(alignment: .leading, spacing: 10) {
                    Text(L.f("在打开的「%1$@」列表里：", "In the %1$@ list that opens:", pane))
                        .font(.system(size: 12.5, weight: .medium)).foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Image(nsImage: AppIcon.image).resizable().frame(width: 22, height: 22)
                        Text("Pourtype").font(.system(size: 13))
                        Spacer()
                        Capsule().fill(Color.accentColor).frame(width: 34, height: 20)
                            .overlay(Circle().fill(.white).frame(width: 16, height: 16).offset(x: 7))
                            .overlay(Capsule().stroke(Color(hex: 0xA27BFF), lineWidth: 2).scaleEffect(pulse ? 1.35 : 1.0)
                                        .opacity(pulse ? 0 : 0.9))
                        Text(L.t("← 打开这个开关", "← switch this on")).font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color(hex: 0xA27BFF))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
                    Text(L.t("可能需要输入 Mac 的开机密码或按一下指纹。", "macOS may ask for your Mac password or Touch ID."))
                        .font(.system(size: 11.5)).foregroundStyle(.tertiary)
                }
                .frame(width: 440)
                .onAppear { withAnimation(.easeOut(duration: 1.3).repeatForever(autoreverses: false)) { pulse = true } }
            }
            Spacer(minLength: 0)
            if granted {
                PrimaryButton(title: L.t("下一步", "Next"), action: next)
            } else {
                PrimaryButton(title: L.t("打开系统设置", "Open System Settings"), action: open)
                Button(showHelp ? L.t("收起", "Hide") : L.t("打开了还是显示没开？", "Switched on but still shown as off?")) {
                    withAnimation { showHelp.toggle() }
                }
                .buttonStyle(.link).font(.system(size: 12))
                if showHelp {
                    Text(help).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .frame(maxWidth: 480).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 40)
    }
}

private struct Status: View {
    let granted: Bool
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(granted ? Color.green : Color.orange)
                .symbolEffect(.bounce, value: granted)
            Text(granted ? L.t("已允许", "Allowed") : L.t("还没允许 · 允许后这里会自动变绿", "Not yet allowed · turns green by itself once you do"))
                .font(.system(size: 13, weight: .medium))
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Capsule().fill((granted ? Color.green : Color.orange).opacity(0.12)))
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: granted)
    }
}

private struct Practice: View {
    @ObservedObject var model: OnboardingModel
    @State private var copied = false

    var body: some View {
        VStack(spacing: 14) {
            Text(L.t("试一下", "Try it")).font(.system(size: 24, weight: .bold, design: .rounded)).padding(.top, 30)
            VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                stepBadge("1")
                VStack(alignment: .leading, spacing: 8) {
                    Text(L.t("复制这段文字：", "Copy this text:")).font(.system(size: 13, weight: .medium))
                    HStack {
                        Text(model.sample).font(.system(size: 13)).textSelection(.enabled)
                        Spacer()
                        Button(copied ? L.t("已复制", "Copied") : L.t("复制", "Copy")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(model.sample, forType: .string)
                            copied = true
                        }
                    }
                    .padding(10).background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                }
            }
            HStack(alignment: .top, spacing: 10) {
                stepBadge("2")
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 4) {
                        Text(L.t("点一下下面的输入框（它禁止粘贴），然后按", "Click the box below (it blocks paste), then press"))
                            .font(.system(size: 13, weight: .medium))
                        Keycap(text: Shortcuts.get(.type).display)
                    }
                    NoPasteField(text: $model.practice)
                        .frame(height: 64)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(model.practiceDone ? Color.green : Color.primary.opacity(0.15),
                                                                          lineWidth: model.practiceDone ? 2 : 1))
                }
            }
            }
            .frame(maxWidth: 560, alignment: .leading)
            if model.practiceDone {
                Label(L.t("成功了！以后在任何禁止粘贴的地方都这样用。", "It worked. Use it the same way anywhere paste is blocked."),
                      systemImage: "checkmark.seal.fill").foregroundStyle(.green).font(.system(size: 13, weight: .semibold))
                    .transition(.scale.combined(with: .opacity))
            } else {
                Text(L.t("打字时按 Esc 可以随时停；按住 ↑ ↓ 调速度。", "While it types: Esc stops, hold ↑ ↓ to change speed."))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            PrimaryButton(title: model.practiceDone ? L.t("开始使用", "Start using Pourtype") : L.t("跳过，开始使用", "Skip and start"),
                          action: model.finish)
            Text(L.t("Pourtype 住在屏幕顶部的菜单栏里。", "Pourtype lives in the menu bar at the top of the screen."))
                .font(.system(size: 11.5)).foregroundStyle(.tertiary)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 48)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: model.practiceDone)
    }

    private func stepBadge(_ s: String) -> some View {
        Text(s).font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
            .frame(width: 22, height: 22).background(Circle().fill(Aurora.gradient))
    }
}

/// A text box that refuses paste and drop, like the fields this app is for.
struct NoPasteField: NSViewRepresentable {
    @Binding var text: String

    final class View: NSTextView {
        override func paste(_ sender: Any?) { NSSound.beep() }
        override func pasteAsPlainText(_ sender: Any?) { NSSound.beep() }
        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { false }
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = View()
        tv.isRichText = false
        tv.font = .systemFont(ofSize: 14)
        tv.textContainerInset = NSSize(width: 8, height: 8)
        tv.drawsBackground = false
        tv.delegate = context.coordinator
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        let sv = NSScrollView()
        sv.documentView = tv
        sv.hasVerticalScroller = false
        sv.drawsBackground = false
        tv.autoresizingMask = [.width]
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        if let tv = sv.documentView as? NSTextView, tv.string != text { tv.string = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: NoPasteField
        init(_ p: NoPasteField) { parent = p }
        func textDidChange(_ n: Notification) {
            if let tv = n.object as? NSTextView { parent.text = tv.string }
        }
    }
}
