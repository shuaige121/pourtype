import AppKit
import Carbon

/// Typing without the veil, when input cannot be held: Secure Input (a password field) hides the keyboard from
/// every event tap, or the tap could not be made. It keeps every protection of a normal run that does not need
/// the tap:
/// - Accessibility must be granted at the start and stay granted;
/// - the keys go to the target app's pid only (CGEventPostToPid), never to whatever has the focus;
/// - before each key the window server's front window must still belong to the app that had it at the start;
///   the frontmost app is also polled and its activation notification watched: any change stops the run;
/// - it begins once the shortcut's keys are let go, and ends after MAX_HOLD;
/// - Esc stops it (taken as a global hotkey for the run, so it does not reach the app; its key state is
///   polled too), as do ⌃⌥⌘. and the menu.
final class PlainSession {
    /// What the run reads from and does to the system. The app passes `.system`; tests pass fakes, so a test
    /// never posts a key.
    struct Env {
        var trusted: () -> Bool
        var frontApp: () -> pid_t?
        /// Owner of the front window, from the window server; called on the typing thread.
        var windowOwner: () -> pid_t?
        var holdsInput: () -> Bool
        var escDown: () -> Bool
        /// Where keys go: an app's pid, or nil for the system's normal route (the run always passes its pid).
        var sender: (pid_t?) -> KeySend
        /// Makes Esc call the closure while the run lasts; returns how to give Esc back, or nil if it is taken.
        var takeEsc: (@escaping () -> Void) -> (() -> Void)?
        var workspace: NotificationCenter
        var appName: (pid_t) -> String
        var maxSeconds = MAX_HOLD
        var holdLimit = 4.0                // keys still down after this long: give up ("keys_held")

        static var system: Env {
            Env(trusted: { AXIsProcessTrusted() },
                frontApp: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
                windowOwner: { frontWindowOwner() },
                holdsInput: { userHoldsInput() },
                escDown: { CGEventSource.keyState(.hidSystemState, key: CGKeyCode(KEY_ESC)) },
                sender: { pid in { code, down, flags, unicode in postKey(code, down, flags: flags, unicode: unicode, to: pid) } },
                takeEsc: { f in
                    guard HotKeys.shared.register(PlainSession.escHotKeyID, key: Int(KEY_ESC), modifiers: 0, f) else { return nil }
                    return { HotKeys.shared.unregister(PlainSession.escHotKeyID) }
                },
                workspace: NSWorkspace.shared.notificationCenter,
                appName: { NSRunningApplication(processIdentifier: $0)?.localizedName ?? "?" })
        }
    }

    static let escHotKeyID: UInt32 = 5
    private enum Phase { case waiting, typing, ended }

    static func start(text: String, pace: Pace, own: OwnPace?, allowSelf: Bool, env: Env,
                      onFinish: @escaping (TypeResult) -> Void) -> Result<PlainSession, TypeStartError> {
        let units = splitUnits(prepareText(text))
        if units.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { return .failure(.empty) }
        guard env.trusted() else { return .failure(.untrusted) }
        guard let pid = env.frontApp(), allowSelf || pid != getpid() else { return .failure(.noTarget) }
        let s = PlainSession(units: units, pace: pace, own: own, pid: pid, env: env, onFinish: onFinish)
        s.begin()
        return .success(s)
    }

    let engine: Engine
    let pid: pid_t
    private let env: Env
    private let appName: String
    private let onFinish: (TypeResult) -> Void
    private var phase = Phase.waiting
    private let waitStarted = now()
    private var typingStarted = 0.0
    private var timers: [Timer] = []
    private var observer: NSObjectProtocol?
    private var giveEscBack: (() -> Void)?
    private var keepAlive: PlainSession?

    private init(units: [String], pace: Pace, own: OwnPace?, pid: pid_t, env: Env, onFinish: @escaping (TypeResult) -> Void) {
        engine = Engine(units, pace, own: own, send: env.sender(pid))
        self.pid = pid
        self.env = env
        appName = env.appName(pid)
        self.onFinish = onFinish
    }

    private func begin() {
        keepAlive = self
        giveEscBack = env.takeEsc { [weak self] in self?.stop("esc") }
        // whatever owned the front window at the start must still own it before each key (as in TypeSession)
        let startOwner = env.windowOwner(), owner = env.windowOwner
        engine.focusGuard = { owner() == startOwner }
        engine.onFocusLost = { [weak self] in self?.stop("focus") }
        engine.onEnd = { [weak self] all in if all { self?.stop("done") } }
        every(0.03) { [weak self] in self?.tick() }
        every(0.1) { [weak self] in self?.watchFront() }
        every(0.25) { [weak self] in self?.watchTrust() }
        once(env.maxSeconds) { [weak self] in self?.stop("timeout") }
        observer = env.workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if let s = self, a?.processIdentifier != s.pid { s.stop("focus") }
        }
        // no tick here: start() returns before anything can end the run
    }

    private func every(_ s: Double, _ f: @escaping () -> Void) {
        let t = Timer(timeInterval: s, repeats: true) { _ in f() }
        RunLoop.main.add(t, forMode: .common)
        timers.append(t)
    }

    private func once(_ s: Double, _ f: @escaping () -> Void) {
        let t = Timer(timeInterval: s, repeats: false) { _ in f() }
        RunLoop.main.add(t, forMode: .common)
        timers.append(t)
    }

    /// Waiting: begin once nothing is held. Both phases: Esc's key state, in case its hotkey does not fire.
    private func tick() {
        switch phase {
        case .waiting:
            if env.escDown() { return stop("esc") }
            if now() - waitStarted > env.holdLimit { return stop("keys_held") }
            guard !env.holdsInput() else { return }
            phase = .typing
            typingStarted = now()
            engine.start(replace: false)
        case .typing:
            if env.escDown() { stop("esc") }
        case .ended:
            break
        }
    }

    private func watchFront() {
        if env.frontApp() != pid { stop("focus") }
    }

    private func watchTrust() {
        if !env.trusted() { stop("untrusted") }
    }

    /// Ends the run: once this returns no further key reaches the app. why: done, esc, focus, timeout,
    /// untrusted, keys_held, or stop (the menu or ⌃⌥⌘.).
    func stop(_ why: String) {
        guard phase != .ended else { return }
        phase = .ended
        engine.stop()
        for t in timers { t.invalidate() }
        timers = []
        if let o = observer { env.workspace.removeObserver(o) }
        observer = nil
        giveEscBack?()
        giveEscBack = nil
        let r = TypeResult(reason: why, typed: engine.index, total: engine.units.count,
                           seconds: typingStarted > 0 ? now() - typingStarted : 0, app: appName, pace: engine.pace)
        keepAlive = nil
        onFinish(r)
    }
}
