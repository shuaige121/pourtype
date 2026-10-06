#!/usr/bin/env python3
"""Render the Mac App Store screenshots (2880x1800) for every store language.

Serve the repo root first:  (cd ~/work/pourtype && python3 -m http.server 8799)
Then:                       python3 appstore/shots/render.py [lang ...]
Writes appstore/shots/out/<lang>-0N-<shot>.png; lang is en, zh-Hans, zh-Hant or ja.
"""
import pathlib
import sys
from playwright.sync_api import sync_playwright

OUT = pathlib.Path(__file__).resolve().parent / "out"
SHOTS = ["typing", "grab", "history", "speed", "multi"]
LANGS = {"en": "en", "zh-Hans": "zh", "zh-Hant": "zh-Hant", "ja": "ja"}   # file name -> compose.html lang

langs = sys.argv[1:] or list(LANGS)
OUT.mkdir(exist_ok=True)
with sync_playwright() as p:
    b = p.chromium.launch()
    ctx = b.new_context(viewport={"width": 1440, "height": 900}, device_scale_factor=2, color_scheme="dark")
    for lang in langs:
        for n, shot in enumerate(SHOTS, 1):
            pg = ctx.new_page()
            pg.goto(f"http://127.0.0.1:8799/appstore/shots/compose.html?shot={shot}&lang={LANGS[lang]}")
            pg.wait_for_selector("body[data-ready='1']", timeout=20000)
            pg.wait_for_timeout(600)
            path = OUT / f"{lang}-{n:02d}-{shot}.png"
            pg.screenshot(path=str(path))
            pg.close()
            print(path.name)
    b.close()
