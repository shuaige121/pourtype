#!/usr/bin/env python3
"""Translation tables for Pourtype's UI.

Strings live in the Swift code as L.t("简体中文", "English") / L.f(...). Traditional Chinese
and Japanese live in Resources/strings-<lang>.json, keyed by the English text.

  scripts/l10n.py extract   -> l10n/source.json (every pair, for translators)
  scripts/l10n.py check     -> exit 1 if a translation is missing, stale, breaks a
                               placeholder, or (zh-Hant) still has Simplified characters
"""
import json
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
LANGS = ["zh-Hant", "ja"]
PAIR = re.compile(r'L\.[tf]\(\s*"((?:[^"\\]|\\.)*)"\s*,\s*"((?:[^"\\]|\\.)*)"', re.S)
CALL = re.compile(r'L\.[tf]\(')
PLACEHOLDER = re.compile(r'%\d+\$@')
# characters that are the same in Traditional usage even though ICU's Hans-Hant changes them
HANT_OK = set("台著")


def unescape(s):
    return json.loads('"' + s + '"')


def pairs():
    out, problems = {}, []
    for f in sorted((ROOT / "Sources").rglob("*.swift")):
        src = f.read_text()
        found = {m.start() for m in PAIR.finditer(src)}
        for m in CALL.finditer(src):
            if m.start() not in found:
                problems.append(f"{f.name}:{src[:m.start()].count(chr(10)) + 1}: L.t/L.f without two string literals")
        for m in PAIR.finditer(src):
            zh, en = unescape(m.group(1)), unescape(m.group(2))
            line = src[:m.start()].count("\n") + 1
            if "\\(" in m.group(1) or "\\(" in m.group(2):
                problems.append(f"{f.name}:{line}: interpolation inside L.t; use L.f with %1$@")
            if en in out and out[en]["zh-Hans"] != zh:
                problems.append(f"{f.name}:{line}: '{en}' has two Chinese versions")
            out.setdefault(en, {"en": en, "zh-Hans": zh, "where": []})["where"].append(f"{f.name}:{line}")
    return out, problems


def simplified_only(chars):
    """Characters that ICU's Hans-Hant transform changes: Simplified-only forms."""
    text = "".join(sorted(chars))
    js = ("ObjC.import('Foundation');"
          f"$({json.dumps(text)}).stringByApplyingTransformReverse('Hans-Hant', false).js")
    hant = subprocess.run(["osascript", "-l", "JavaScript", "-e", js], capture_output=True, text=True, check=True).stdout.strip()
    if len(hant) != len(text):
        sys.exit("transform changed the length; cannot compare characters")
    return {a for a, b in zip(text, hant) if a != b} - HANT_OK


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "check"
    src, problems = pairs()
    if cmd == "extract":
        out = ROOT / "l10n" / "source.json"
        out.parent.mkdir(exist_ok=True)
        out.write_text(json.dumps(list(src.values()), ensure_ascii=False, indent=1) + "\n")
        print(f"{len(src)} strings -> {out.relative_to(ROOT)}")
        return
    hans_only = simplified_only({c for v in src.values() for c in v["zh-Hans"] if ord(c) > 0x2E80})
    for lang in LANGS:
        path = ROOT / "Resources" / f"strings-{lang}.json"
        table = json.loads(path.read_text()) if path.exists() else {}
        for en, v in src.items():
            t = table.get(en, "")
            if not t.strip():
                problems.append(f"{lang}: missing '{en}' ({v['where'][0]})")
                continue
            if sorted(PLACEHOLDER.findall(t)) != sorted(PLACEHOLDER.findall(en)):
                problems.append(f"{lang}: placeholders differ in '{en}' -> '{t}'")
            if lang == "zh-Hant":
                bad = sorted({c for c in t if c in hans_only})
                if bad:
                    problems.append(f"zh-Hant: Simplified characters {''.join(bad)} in '{t}'")
        for en in table:
            if en not in src:
                problems.append(f"{lang}: stale key '{en}'")
    for p in problems:
        print("FAIL", p)
    if problems:
        sys.exit(1)
    print(f"OK: {len(src)} strings, translated into {', '.join(LANGS)}")


if __name__ == "__main__":
    main()
