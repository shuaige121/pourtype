#!/usr/bin/env python3
"""Tell IndexNow engines (Bing and others) which pages changed. Free; no account needed.
The key file sits at docs/<key>.txt, so every URL under /pourtype/ may be submitted.
  python3 scripts/indexnow.py            # submits every URL in docs/sitemap.xml
  python3 scripts/indexnow.py URL ...    # submits only these
"""
import json
import pathlib
import re
import sys
import urllib.request

REPO = pathlib.Path(__file__).resolve().parent.parent
BASE = "https://shuaige121.github.io/pourtype/"
key = (REPO / "scripts" / "indexnow.key").read_text().strip()
urls = sys.argv[1:] or re.findall(r"<loc>([^<]+)</loc>", (REPO / "docs" / "sitemap.xml").read_text())
live = urllib.request.urlopen(f"{BASE}{key}.txt", timeout=20).read().decode().strip()
if live != key:
    sys.exit("the key file is not live yet; push docs/ and wait for Pages to deploy")
body = json.dumps({"host": "shuaige121.github.io", "key": key, "keyLocation": f"{BASE}{key}.txt", "urlList": urls}).encode()
req = urllib.request.Request("https://api.indexnow.org/indexnow", data=body, headers={"Content-Type": "application/json; charset=utf-8"})
with urllib.request.urlopen(req, timeout=30) as r:
    print(r.status, f"submitted {len(urls)} URLs")
