#!/usr/bin/env python3
"""One live session with the installed Pourtype.app: functional checks plus the raw captures
for the App Store screenshots. It HOLDS the keyboard and mouse and veils the screen for a few
seconds per case (about 45 s in all, mostly setup): ask the person at the computer first.

Needs: Pourtype.app running (built with scripts/build.sh and opened once) with Accessibility
and Screen Recording granted; Python with pyobjc Quartz (e.g. ~/work/keytype/.venv/bin/python).
Cases are driven through the app's URL scheme (open -g pourtype://...), so they work even
while another app owns the cmd-shift-V / cmd-shift-C shortcuts.

  1 type     TextEdit: exact text; a stray key is dropped; holding Up speeds it up
  2 esc      TextEdit: Esc stops; the document holds exactly the reported prefix
  3 focus    TextEdit: another app activated mid-run stops it
  4 web      Safari paste-blocked page (served by ~/work/keytype/test/serve.py): exact text
  5 grab     drag a box over known text in TextEdit: the clipboard gets it
  6 history  the history window opens and lists the runs

Every case checks that the app it types into is frontmost and skips itself otherwise.
Usage: live_session.py OUTDIR [--only 1,5] ; then compose_screenshots.py OUTDIR
"""
import json, os, subprocess, sys, time
import Quartz

OUT = next((a for a in sys.argv[1:] if not a.startswith("--") and not a[0].isdigit()), None)
if not OUT:
    sys.exit(__doc__)
os.makedirs(OUT, exist_ok=True)
ONLY = set(map(int, sys.argv[sys.argv.index("--only") + 1].split(","))) if "--only" in sys.argv else None
want = lambda n: ONLY is None or n in ONLY

HISTORY = os.path.expanduser("~/Library/Application Support/com.leonardchow.pourtype/History/history.json")
KEYTYPE_TEST = os.path.expanduser("~/work/keytype/test")
TEXTEDIT, SAFARI = ("TextEdit", "文本编辑"), ("Safari", "Safari浏览器")

TEXT_FULL = ("1 pourtype live check: plain ASCII and digits 0123456789\n"
             "中文全角标点，测试（括号）以及省略号……\n"
             "组合字符 é ü ñ, emoji 🚀, CJK 日本語 한국어\n"
             "\t2 leading tab and end")
TEXT_LONG = "这是一段用来测试中止的文字，它足够长，不会在一秒之内打完。" * 4
GRAB_TEXT = "Pourtype grab check 2468\n识别这一行中文"


def prepared(t):
    return t.replace("\r\n", "\n").replace("\t", "    ")


def osa(script):
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    return r.stdout.rstrip("\n"), r.returncode, r.stderr.strip()


def frontmost():
    return osa('tell application "System Events" to get name of first application process whose frontmost is true')[0]


def key(kc, down):
    ev = Quartz.CGEventCreateKeyboardEvent(None, kc, down)
    Quartz.CGEventSetFlags(ev, 0)
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, ev)


def tap(kc):
    key(kc, True); time.sleep(0.03); key(kc, False)


def mouse(kind, x, y):
    ev = Quartz.CGEventCreateMouseEvent(None, kind, (x, y), Quartz.kCGMouseButtonLeft)
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, ev)


def displays():
    _, ids, n = Quartz.CGGetActiveDisplayList(16, None, None)
    return [tuple(Quartz.CGDisplayBounds(d).origin) + tuple(Quartz.CGDisplayBounds(d).size) for d in ids[:n]]


def shoot(prefix):
    files = [os.path.join(OUT, f"{prefix}-d{k + 1}.png") for k in range(len(displays()))]
    subprocess.run(["screencapture", "-x", *files])
    return files


def history():
    try:
        return json.load(open(HISTORY))
    except Exception:
        return []


def wait_history(before, kind, timeout=40):
    t0 = time.time()
    while time.time() - t0 < timeout:
        h = history()
        if len(h) > before and h[0].get("kind") == kind:
            return h[0]
        time.sleep(0.3)
    return None


def trigger(action):
    subprocess.run(["open", "-g", f"pourtype://{action}"])


def set_clipboard(text):
    subprocess.run(["pbcopy"], input=text, text=True)


def textedit_doc():
    wid, rc, err = osa('tell application "TextEdit"\nactivate\nmake new document\ndelay 0.3\nreturn id of window 1\nend tell')
    if rc != 0 or not wid.isdigit():
        sys.exit("cannot create a TextEdit document: " + err)
    osa(f'tell application "TextEdit" to set bounds of window id {wid} to {{160, 140, 1060, 640}}')
    time.sleep(0.4)
    return wid


def textedit_text(wid):
    t, rc, err = osa(f'tell application "TextEdit" to get text of document of window id {wid}')
    if rc != 0:
        raise RuntimeError("cannot read the test document: " + err)
    return t.replace(" ", "\n").replace("\r", "\n")


def textedit_ready(wid, text=""):
    _, rc, _ = osa(f'tell application "TextEdit"\nset text of document of window id {wid} to {json.dumps(text)}\n'
                   f'set index of window id {wid} to 1\nactivate\nend tell')
    time.sleep(0.5)
    return rc == 0 and frontmost() in TEXTEDIT


results = []


def record(case, ok, detail):
    results.append({"case": case, "ok": bool(ok), **detail})
    print(("\033[32mPASS\033[0m " if ok else "\033[31mFAIL\033[0m ") + case + ": " + json.dumps(detail, ensure_ascii=False))


def skip(case, why):
    results.append({"case": case, "ok": False, "skipped": why})
    print(f"\033[33mSKIP\033[0m {case}: {why}")


def typed_count(outcome):
    try:
        return int(outcome.split()[1].split("/")[0])
    except Exception:
        return -1


saved_clipboard = subprocess.run(["pbpaste"], capture_output=True, text=True).stdout
doc = None
try:
    if any(want(k) for k in (1, 2, 3, 5)):
        doc = textedit_doc()

    if want(1):
        if not textedit_ready(doc):
            skip("1 type", "TextEdit not frontmost: " + frontmost())
        else:
            set_clipboard(TEXT_FULL)
            before = len(history())
            trigger("type")
            time.sleep(0.9)
            tap(7)                                           # 'x' must not reach TextEdit
            shoot("raw-typing")
            key(126, True); time.sleep(0.8); key(126, False)   # hold Up
            shoot("raw-typing-up")
            item = wait_history(before, "typed")
            got, exp = textedit_text(doc), prepared(TEXT_FULL)
            record("1 type: exact, stray key dropped", item is not None and item.get("outcome") is None and got == exp,
                   {"outcome": item and item.get("outcome"), "exact": got == exp, "gotLen": len(got), "expLen": len(exp)})

    if want(2):
        if not textedit_ready(doc):
            skip("2 esc", "TextEdit not frontmost: " + frontmost())
        else:
            set_clipboard(TEXT_LONG)
            before = len(history())
            trigger("type")
            time.sleep(1.4)
            tap(53)
            item = wait_history(before, "typed")
            got, exp = textedit_text(doc), prepared(TEXT_LONG)
            n = typed_count(item.get("outcome") or "") if item else -1
            record("2 esc: stops, document = reported prefix",
                   item is not None and (item.get("outcome") or "").startswith("esc") and exp.startswith(got) and len(got) == n,
                   {"outcome": item and item.get("outcome"), "docLen": len(got)})

    if want(3):
        if not textedit_ready(doc):
            skip("3 focus", "TextEdit not frontmost: " + frontmost())
        else:
            calc_running = subprocess.run(["pgrep", "-x", "Calculator"], capture_output=True).returncode == 0
            set_clipboard(TEXT_LONG)
            before = len(history())
            trigger("type")
            time.sleep(1.4)
            osa('tell application "Calculator" to activate')
            time.sleep(0.3)
            switched = frontmost()
            item = wait_history(before, "typed")
            got, exp = textedit_text(doc), prepared(TEXT_LONG)
            if switched not in ("Calculator", "计算器"):
                skip("3 focus", f"Calculator never came to the front ({switched})")
            else:
                record("3 focus: another app in front stops it",
                       item is not None and (item.get("outcome") or "").startswith("focus") and exp.startswith(got),
                       {"outcome": item and item.get("outcome"), "docLen": len(got)})
            if not calc_running:
                osa('tell application "Calculator" to quit')

    if want(4):
        report = os.path.join(KEYTYPE_TEST, "report.json")
        if subprocess.run(["pgrep", "-f", "test/serve.py"], capture_output=True).returncode != 0:
            subprocess.Popen([sys.executable, os.path.join(KEYTYPE_TEST, "serve.py")], cwd=KEYTYPE_TEST,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
            time.sleep(1)
        subprocess.run(["open", "-a", "Safari", f"http://127.0.0.1:8777/paste_blocked.html?focus=ta&t={int(time.time())}"])
        title = ""
        for _ in range(25):
            time.sleep(0.6)
            title = osa('tell application "Safari" to get name of current tab of front window')[0]
            if "TA len=0 kd=0" in title and frontmost() in SAFARI:
                break
        if "TA len=0 kd=0" not in title or frontmost() not in SAFARI:
            skip("4 web", f"page not ready or Safari not frontmost ({title!r}, {frontmost()})")
        else:
            set_clipboard(TEXT_FULL)
            before = len(history())
            trigger("type")
            item = wait_history(before, "typed")
            time.sleep(1.3)
            rep = json.load(open(report))
            record("4 web: Safari textarea exact", item is not None and rep.get("ta") == prepared(TEXT_FULL),
                   {"outcome": item and item.get("outcome"), "exact": rep.get("ta") == prepared(TEXT_FULL), "vis": rep.get("vis")})
        osa('tell application "Safari"\nif URL of current tab of front window starts with "http://127.0.0.1:8777/" '
            'then close current tab of front window\nend tell')

    if want(5):
        if not textedit_ready(doc, GRAB_TEXT):
            skip("5 grab", "TextEdit not frontmost: " + frontmost())
        else:
            osa(f'tell application "TextEdit" to set size of text of document of window id {doc} to 40')
            time.sleep(0.4)
            before = len(history())
            set_clipboard("")
            trigger("grab")
            time.sleep(0.8)
            a, b = (170, 200), (1040, 360)                   # the text area of the window set in textedit_doc()
            mouse(Quartz.kCGEventLeftMouseDown, *a)
            for k in range(1, 21):
                mouse(Quartz.kCGEventLeftMouseDragged, a[0] + (b[0] - a[0]) * k / 20, a[1] + (b[1] - a[1]) * k / 20)
                time.sleep(0.02)
            shoot("raw-grab")
            mouse(Quartz.kCGEventLeftMouseUp, *b)
            item = wait_history(before, "grab", timeout=15)
            clip = subprocess.run(["pbpaste"], capture_output=True, text=True).stdout
            ok = item is not None and "2468" in clip and "Pourtype" in clip and "识别" in clip
            record("5 grab: text in the box reaches the clipboard", ok, {"clipboard": clip[:80]})

    if want(6):
        trigger("history")
        time.sleep(1.2)
        wins = [w for w in Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionOnScreenOnly, Quartz.kCGNullWindowID)
                if w.get("kCGWindowOwnerName") == "Pourtype" and w.get("kCGWindowLayer") == 0]
        if wins:
            subprocess.run(["screencapture", "-x", "-o", "-l", str(wins[0]["kCGWindowNumber"]), os.path.join(OUT, "raw-history.png")])
        record("6 history: window opens, lists the runs", bool(wins) and len(history()) > 0,
               {"windows": len(wins), "entries": len(history())})
        if wins and frontmost() == "Pourtype":
            ev = Quartz.CGEventCreateKeyboardEvent(None, 13, True)   # cmd-W closes it
            Quartz.CGEventSetFlags(ev, Quartz.kCGEventFlagMaskCommand); Quartz.CGEventPost(Quartz.kCGHIDEventTap, ev)
            ev = Quartz.CGEventCreateKeyboardEvent(None, 13, False)
            Quartz.CGEventSetFlags(ev, Quartz.kCGEventFlagMaskCommand); Quartz.CGEventPost(Quartz.kCGHIDEventTap, ev)
finally:
    if doc:
        osa(f'tell application "TextEdit" to close (document of window id {doc}) saving no')
    set_clipboard(saved_clipboard)
    json.dump(results, open(os.path.join(OUT, "results.json"), "w"), ensure_ascii=False, indent=1)

bad = [r for r in results if not r["ok"]]
print(f"{len(results) - len(bad)}/{len(results)} passed; raw captures and results.json in {OUT}")
sys.exit(1 if bad else 0)
