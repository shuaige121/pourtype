#!/usr/bin/env python3
"""After a deploy: every page in the live sitemap loads, and so does every stylesheet, script and image it uses.
The local check cannot see what GitHub Pages drops or rewrites; this one looks at the real site."""
import re
import sys
import urllib.parse
import urllib.request

BASE = "https://shuaige121.github.io/pourtype/"


def get(url):
    try:
        with urllib.request.urlopen(url, timeout=20) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, b""


status, sm = get(BASE + "sitemap.xml")
if status != 200:
    sys.exit(f"sitemap.xml -> {status}")
pages = re.findall(r"<loc>([^<]+)</loc>", sm.decode())
problems, assets = [], set()
for u in pages:
    st, body = get(u)
    if st != 200:
        problems.append(f"{u} -> {st}")
        continue
    html = body.decode("utf-8", "replace")
    for ref in re.findall(r'<link[^>]+rel="(?:stylesheet|icon)"[^>]+href="([^"]+)"', html) + re.findall(r'<(?:img|script)[^>]+src="([^"]+)"', html):
        assets.add(urllib.parse.urljoin(u, ref))
for a in sorted(assets):
    if a.startswith(BASE):
        st, _ = get(a)
        if st != 200:
            problems.append(f"asset {a} -> {st}")
for p in problems:
    print("FAIL", p)
if problems:
    sys.exit(1)
print(f"OK: {len(pages)} live pages and {len(assets)} assets load")
