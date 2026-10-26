import AppKit
import SwiftUI

// Settings > Learn my typing: the user types a fixed passage into a box of ours. Save fits the
// recording and keeps only the numeric profile; Discard drops it. Not part of the first-run guide.

final class LearnTypingModel: ObservableObject {
    @Published var text = ""
    @Published private(set) var keystrokes = 0
    @Published var error: String?
    let passage = CalibrationPassage.text
    let recorder = CalibrationRecorder()
    private let store: ProfileStore

    init(store: ProfileStore = .shared) {
        self.store = store
        recorder.onChange = { [weak self] in self?.keystrokes = self?.recorder.count ?? 0 }
    }

    var typed: Int { min(text.count, passage.count) }
    /// Most of the passage: enough samples for every overall fit.
    var enough: Bool { keystrokes >= passage.count * 4 / 5 }

    func startOver() {
        recorder.discard()
        text = ""
        error = nil
    }

    /// Fits and saves the profile (replacing any earlier one), then drops the recording. false on failure.
    func save() -> Bool {
        let profile = HabitFitter.fit(recorder.makeRaw(), nowUtc: ISO8601DateFormatter().string(from: Date()))
        do {
            try store.save(profile)
        } catch {
            self.error = L.f("保存失败：%1$@", "Could not save: %1$@", error.localizedDescription)
            return false
        }
        startOver()
        return true
    }

    func close() {
        recorder.stop()
        startOver()
    }
}

struct LearnTypingView: View {
    @StateObject private var model = LearnTypingModel()
    let onDone: (_ saved: Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L.t("学习我的打字习惯", "Learn my typing")).font(.title2.weight(.semibold))
            Text(L.t("用平时的速度，把下面这段英文照着打进框里。打错了就照常改。请先切换到英文输入法（比如 ABC）。",
                     "Type the English passage below into the box at your usual pace. Fix mistakes as you normally would. Switch to an English input source (such as ABC) first."))
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            passage
            LearnField(text: $model.text, recorder: model.recorder)
                .frame(height: 110)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.15)))
            HStack(spacing: 10) {
                ProgressView(value: Double(model.typed), total: Double(model.passage.count)).frame(maxWidth: 220)
                Text(L.f("已打 %1$@ / %2$@ 字", "%1$@ of %2$@ characters typed", "\(model.typed)", "\(model.passage.count)"))
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Text(model.enough ? L.t("可以保存了。", "Ready to save.") : L.t("打完大部分就可以保存。", "You can save once most of the passage is typed."))
                    .font(.caption).foregroundStyle(model.enough ? Color.green : Color.secondary)
            }
            Label(L.t("只记录在这个框里按下的键：每个键按了多久、键与键之间隔了多久。保存时只把这些时间的统计数字存在这台 Mac 上，不保存你打的字，也不保存原始记录。",
                      "Only keys pressed in this box are measured: how long each key is held and the time between keys. Save keeps only summary numbers on this Mac: not the text you type, and not the raw timings."),
                  systemImage: "lock.shield")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let e = model.error { Text(e).font(.caption).foregroundStyle(.red) }
            HStack {
                Button(L.t("重新开始", "Start over")) { model.startOver() }
                Spacer()
                Button(L.t("放弃", "Discard")) { model.close(); onDone(false) }
                    .keyboardShortcut(.cancelAction)
                Button(L.t("保存", "Save")) { if model.save() { model.close(); onDone(true) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.enough)
            }
        }
        .padding(22)
        .frame(width: 500)
        .onDisappear { model.close() }
    }

    /// The passage, the part already typed in full color.
    private var passage: some View {
        let p = model.passage, n = model.typed
        return (Text(String(p.prefix(n))).foregroundColor(.primary) + Text(String(p.dropFirst(n))).foregroundColor(.secondary))
            .font(.system(size: 14))
            .lineSpacing(3)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The box the passage is typed into. It refuses paste and drop, has no automatic corrections, and is the only
/// view whose keys the recorder measures.
private struct LearnField: NSViewRepresentable {
    @Binding var text: String
    let recorder: CalibrationRecorder

    final class View: NSTextView {
        override func paste(_ sender: Any?) { NSSound.beep() }
        override func pasteAsPlainText(_ sender: Any?) { NSSound.beep() }
        override func pasteAsRichText(_ sender: Any?) { NSSound.beep() }
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
        tv.isAutomaticTextCompletionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.allowsUndo = false
        let sv = NSScrollView()
        sv.documentView = tv
        sv.hasVerticalScroller = true
        sv.drawsBackground = false
        tv.autoresizingMask = [.width]
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        recorder.field = tv
        recorder.start()
        DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        if let tv = sv.documentView as? NSTextView, tv.string != text { tv.string = text }
    }

    static func dismantleNSView(_ sv: NSScrollView, coordinator: Coordinator) {
        coordinator.parent.recorder.stop()
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: LearnField
        init(_ p: LearnField) { parent = p }
        func textDidChange(_ n: Notification) {
            if let tv = n.object as? NSTextView { parent.text = tv.string }
        }
    }
}
