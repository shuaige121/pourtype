#!/usr/bin/env python3
"""Capture the raw App Store screenshots from the real app, in Chinese and English UI.
TAKES OVER the screen, keyboard and mouse for about 40 s per language: ask first.

Scene: appstore/demo/index.html in Safari (a paste-blocked form with text drawn on a canvas),
the installed Pourtype.app driven through pourtype:// URLs, a curated sample history.
Your own history and language setting are backed up and put back afterwards.

Usage: capture_screenshots.py OUTDIR [--lang zh|en]   -> OUTDIR/<lang>/raw-*.png
Then:  compose_screenshots.py OUTDIR/<lang> --lang <lang>
"""
import json, os, shutil, subprocess, sys, time, uuid
from datetime import datetime, timedelta, timezone
import Quartz

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEMO = os.path.join(ROOT, "appstore", "demo", "index.html")
DOMAIN = "com.leonardchow.pourtype"
HIST_DIR = os.path.expanduser(f"~/Library/Application Support/{DOMAIN}/History")
APP = os.path.expanduser("~/Applications/Pourtype.app")
OUT = next((a for a in sys.argv[1:] if not a.startswith("--") and a not in ("zh", "en")), None) or sys.exit(__doc__)
LANGS = [sys.argv[sys.argv.index("--lang") + 1]] if "--lang" in sys.argv else ["zh", "en"]

MESSAGE = {
    "en": ("Hi, the desk lamp from order A-20481 arrived with a cracked base.\n"
           "Photos are attached. Could you send a replacement, or a return label?\n"
           "Thanks, Alex"),
    "zh": ("你好，订单 A-20481 的台灯收到时底座有裂痕。\n"
           "照片已附上，麻烦补发一个，或者给我退货标签。\n"
           "谢谢！林晓"),
}
SAMPLE_HISTORY = {
    "en": [("grab", "Receipt R-7731 · 6 Oct 2026\nDesk lamp x1    S$ 39.90\nReturns accepted within 14 days", "Safari"),
           ("typed", MESSAGE["en"], "Safari"),
           ("grab", "Meeting moved to Thursday 3 pm, room 4B. Please bring the Q3 numbers.", "Preview"),
           ("typed", "Order A-20481 — replacement requested, photos attached.", "Mail"),
           ("grab", "Wi-Fi: Studio-Guest  ·  Password on the card at the front desk", "Photos")],
    "zh": [("grab", "收据编号 R-7731 · 2026年10月6日\n桌面台灯 ×1    S$ 39.90\n退货期限：14 天内", "Safari浏览器"),
           ("typed", MESSAGE["zh"], "Safari浏览器"),
           ("grab", "会议改到周四下午 3 点，4B 会议室，请带上第三季度的数据。", "预览"),
           ("typed", "订单 A-20481：已申请补发，照片已附上。", "邮件"),
           ("grab", "访客 Wi-Fi：Studio-Guest · 密码见前台卡片", "照片")],
}


def osa(s):
    r = subprocess.run(["osascript", "-e", s], capture_output=True, text=True)
    return r.stdout.strip(), r.returncode


def frontmost():
    return osa('tell application "System Events" to get name of first application process whose frontmost is true')[0]


def key(kc, down):
    ev = Quartz.CGEventCreateKeyboardEvent(None, kc, down)
    Quartz.CGEventSetFlags(ev, 0)
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, ev)


def mouse(kind, x, y):
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, Quartz.CGEventCreateMouseEvent(None, kind, (x, y), Quartz.kCGMouseButtonLeft))


def ndisplays():
    return Quartz.CGGetActiveDisplayList(16, None, None)[2]


def shoot(d, name):
    subprocess.run(["screencapture", "-x", *[os.path.join(d, f"{name}-d{k + 1}.png") for k in range(ndisplays())]])


def pourtype(action):
    subprocess.run(["open", "-g", f"pourtype://{action}"])


def relaunch(lang):
    osa('tell application "Pourtype" to quit')
    time.sleep(1.2)
    subprocess.run(["defaults", "write", DOMAIN, "AppleLanguages", "-array", "zh-Hans" if lang == "zh" else "en"])
    subprocess.run(["open", APP])
    time.sleep(2.5)


def seed_history(lang):
    now = datetime.now(timezone.utc)
    items = []
    for k, (kind, text, app) in enumerate(SAMPLE_HISTORY[lang]):
        items.append({"id": str(uuid.uuid4()).upper(), "kind": kind, "text": text, "app": app,
                      "date": (now - timedelta(minutes=7 + 23 * k)).strftime("%Y-%m-%dT%H:%M:%SZ")})
    json.dump(items, open(os.path.join(HIST_DIR, "history.json"), "w"), ensure_ascii=False)


def safari_demo(lang):
    url = "file://" + DEMO + ("?lang=zh" if lang == "zh" else "")
    subprocess.run(["open", "-a", "Safari", url])
    time.sleep(1.5)
    osa('tell application "Safari" to set bounds of front window to {220, 90, 1120, 1000}')
    osa('tell application "Safari" to activate')
    time.sleep(0.8)


def one_language(lang):
    d = os.path.join(OUT, lang)
    os.makedirs(d, exist_ok=True)
    seed_history(lang)
    relaunch(lang)
    subprocess.run(["defaults", "write", DOMAIN, "pace.normal.cps", "-float", "24"])
    subprocess.run(["defaults", "write", DOMAIN, "pace.normal.rand", "-float", "0.25"])
    safari_demo(lang)
    if frontmost() not in ("Safari", "Safari浏览器"):
        print(lang, "skip: Safari not frontmost:", frontmost()); return
    # the textarea autofocuses; click it to be sure (window bounds above, page layout fixed)
    mouse(Quartz.kCGEventLeftMouseDown, 670, 470); mouse(Quartz.kCGEventLeftMouseUp, 670, 470)
    time.sleep(0.3)
    subprocess.run(["pbcopy"], input=MESSAGE[lang], text=True)
    pourtype("type")
    time.sleep(2.2)
    shoot(d, "raw-typing")
    key(126, True); time.sleep(0.5)
    shoot(d, "raw-typing-up")
    key(126, False)
    time.sleep(6)                                    # let it finish
    # grab: drag over the canvas receipt
    pourtype("grab")
    time.sleep(0.9)
    a, b = (250, 700), (1090, 858)
    mouse(Quartz.kCGEventLeftMouseDown, *a)
    for k in range(1, 21):
        mouse(Quartz.kCGEventLeftMouseDragged, a[0] + (b[0] - a[0]) * k / 20, a[1] + (b[1] - a[1]) * k / 20)
        time.sleep(0.02)
    shoot(d, "raw-grab")
    mouse(Quartz.kCGEventLeftMouseUp, *b)
    time.sleep(1.5)
    # history window, first entry selected
    pourtype("history")
    time.sleep(1.5)
    wins = [w for w in Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionOnScreenOnly, Quartz.kCGNullWindowID)
            if w.get("kCGWindowOwnerName") == "Pourtype" and w.get("kCGWindowLayer") == 0]
    if wins:
        bnd = wins[0]["kCGWindowBounds"]
        x, y = bnd["X"] + 150, bnd["Y"] + 110             # first row of the list
        mouse(Quartz.kCGEventLeftMouseDown, x, y); mouse(Quartz.kCGEventLeftMouseUp, x, y)
        time.sleep(0.8)
        subprocess.run(["screencapture", "-x", "-o", "-l", str(wins[0]["kCGWindowNumber"]), os.path.join(d, "raw-history.png")])
        osa('tell application "System Events" to keystroke "w" using command down')
    osa('tell application "Safari"\nif URL of current tab of front window starts with "file://" then close current tab of front window\nend tell')
    print(lang, "captured:", sorted(os.listdir(d)))


hist = os.path.join(HIST_DIR, "history.json")
backup = hist + ".before-screenshots"
langs_before = subprocess.run(["defaults", "read", DOMAIN, "AppleLanguages"], capture_output=True, text=True)
pace_before = {k: subprocess.run(["defaults", "read", DOMAIN, k], capture_output=True, text=True).stdout.strip()
               for k in ("pace.normal.cps", "pace.normal.rand")}
clip_before = subprocess.run(["pbpaste"], capture_output=True, text=True).stdout
if os.path.exists(hist):
    shutil.copy2(hist, backup)
try:
    for lang in LANGS:
        one_language(lang)
finally:
    if os.path.exists(backup):
        shutil.move(backup, hist)
    if langs_before.returncode != 0:
        subprocess.run(["defaults", "delete", DOMAIN, "AppleLanguages"], capture_output=True)
    for k, v in pace_before.items():
        if v:
            subprocess.run(["defaults", "write", DOMAIN, k, "-float", v])
    subprocess.run(["pbcopy"], input=clip_before, text=True)
    relaunch_back = osa('tell application "Pourtype" to quit')
    time.sleep(1.2)
    subprocess.run(["open", "-g", APP])
    print("restored history, language, pace and clipboard")
