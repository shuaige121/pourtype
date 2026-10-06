#!/usr/bin/env python3
"""Turn the raw captures from live_session.py into Mac App Store screenshots (2880x1800,
16:10) with a caption, in English and Simplified Chinese.

Crops are in points of the main display (captures are Retina, so pixels = points x scale).
They keep only the test window and the card: the grab capture dims but does not blur the
rest of the desktop, which must not end up in a screenshot. Check every output by eye.

Usage: compose_screenshots.py OUTDIR      -> OUTDIR/appstore/{en,zh-Hans}/0N.png
"""
import base64, os, subprocess, sys

OUT = sys.argv[1] if len(sys.argv) > 1 else sys.exit(__doc__)
DST = os.path.join(OUT, "appstore")

# file, crop (x, y, w, h in points; None = whole image), caption en, caption zh
SHOTS = [
    ("raw-typing-d1.png", (40, 100, 1440, 900), "Paste blocked? Type it.", "粘贴被拦住？直接敲进去。"),
    ("raw-typing-up-d1.png", (160, 480, 960, 600), "Speed and rhythm, your call", "速度和节奏，由你掌握"),
    ("raw-grab-d1.png", (40, 60, 1440, 900), "Grab text from anything you can see", "看得见的文字，都能抓取"),
    ("raw-history.png", None, "Everything you grabbed or typed, searchable", "抓取和键入过的内容，随时搜索"),
    (("raw-typing-d1.png", "raw-typing-d2.png"), None, "Works across multiple displays", "支持多显示器"),
]


def pixels(path):
    out = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", path], capture_output=True, text=True).stdout.split()
    return int(out[-3]), int(out[-1])


def crop(src, box, dst, scale):
    x, y, w, h = (int(v * scale) for v in box)
    W, H = pixels(src)
    w, h = min(w, W - x), min(h, H - y)
    # sips crops around the centre; --cropOffset is the top-left corner
    subprocess.run(["sips", "-c", str(h), str(w), "--cropOffset", str(y), str(x), src, "--out", dst],
                   capture_output=True, check=True)
    return dst


def data_url(path):
    return "data:image/png;base64," + base64.b64encode(open(path, "rb").read()).decode()


PAGE = """<!doctype html><html><head><meta charset="utf-8"><style>
html,body{margin:0;width:1440px;height:900px;overflow:hidden}
body{background:radial-gradient(1100px 700px at 15% 0%,#2B2E48 0,transparent 60%),
 radial-gradient(900px 600px at 100% 100%,#3a2448 0,transparent 60%),#0E0F1A;
 font-family:-apple-system,"PingFang SC",system-ui,sans-serif;color:#F4F5FA;
 display:flex;flex-direction:column;align-items:center}
h1{margin:64px 0 0;font-size:54px;font-weight:700;letter-spacing:-.01em;text-align:center}
.bar{height:4px;width:96px;border-radius:2px;margin:22px 0 40px;
 background:linear-gradient(90deg,#5E9BFF,#A27BFF,#FF6FB5,#FFB066)}
.shots{flex:1;display:flex;gap:28px;align-items:flex-start;justify-content:center;padding:0 64px 56px;min-height:0}
img{max-width:100%;max-height:100%;border-radius:14px;box-shadow:0 30px 80px rgba(0,0,0,.55),0 0 0 1px rgba(255,255,255,.08);
 object-fit:contain;min-width:0}
.two{align-items:center} .two img{max-width:calc(50% - 14px)}
</style></head><body><h1>{caption}</h1><div class="bar"></div><div class="shots {cls}">{imgs}</div></body></html>"""


def main():
    from playwright.sync_api import sync_playwright
    tmp = os.path.join(OUT, "crops")
    os.makedirs(tmp, exist_ok=True)
    jobs = []
    for i, (files, box, en, zh) in enumerate(SHOTS, 1):
        files = files if isinstance(files, tuple) else (files,)
        paths = []
        for f in files:
            src = os.path.join(OUT, f)
            if not os.path.exists(src):
                print(f"skip {i}: missing {f}")
                break
            if box:
                scale = pixels(src)[0] / 1920 if f.endswith("-d1.png") else 2
                src = crop(src, box, os.path.join(tmp, f"{i:02d}-{f}"), scale)
            paths.append(src)
        else:
            jobs.append((i, paths, en, zh))
    with sync_playwright() as p:
        b = p.chromium.launch()
        page = b.new_page(viewport={"width": 1440, "height": 900}, device_scale_factor=2)
        for i, paths, en, zh in jobs:
            imgs = "".join(f'<img src="{data_url(x)}">' for x in paths)
            for lang, cap in (("en", en), ("zh-Hans", zh)):
                os.makedirs(os.path.join(DST, lang), exist_ok=True)
                page.set_content(PAGE.replace("{caption}", cap).replace("{imgs}", imgs)
                                 .replace("{cls}", "two" if len(paths) > 1 else ""))
                page.wait_for_timeout(150)
                out = os.path.join(DST, lang, f"{i:02d}.png")
                page.screenshot(path=out)
                print(out, pixels(out))
        b.close()


main()
