#!/usr/bin/env python3
"""Checks the GitHub Pages site in docs/ before it is pushed. Exit 1 on any problem.

Per page: JSON-LD parses; title, description and a canonical that is the page's own URL;
hreflang links point at real pages and are mutual; internal links and images resolve.
Site-wide: sitemap.xml lists exactly the indexable pages; llms.txt links every guide;
no wording we must not publish.
"""
import html.parser
import json
import pathlib
import re
import sys
import urllib.parse

ROOT = pathlib.Path(__file__).resolve().parent.parent / "docs"
BASE = "https://shuaige121.github.io/pourtype/"
# never publish: rhythm sold as human-like (reads as detector evasion), consoles we have not tested
BANNED = re.compile(r"human-like|humanlike|like a human|像真人|模拟真人|人間らしい|人のように|"
                    r"\bproxmox\b|\bidrac\b|\bcitrix\b|\bvmware\b|novnc", re.I)


class Page(html.parser.HTMLParser):
    def __init__(self):
        super().__init__()
        self.title = None
        self.meta = {}
        self.links = []          # (rel, hreflang, href)
        self.refs = []           # href/src values
        self.ldjson = []
        self._in = None
        self._buf = []

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "title" or (tag == "script" and a.get("type") == "application/ld+json"):
            self._in, self._buf = tag, []
        if tag == "meta" and "name" in a:
            self.meta[a["name"]] = a.get("content", "")
        if tag == "link":
            self.links.append((a.get("rel", ""), a.get("hreflang"), a.get("href", "")))
        for k in ("href", "src"):
            if k in a and tag != "link":
                self.refs.append(a[k])
        if tag == "link" and a.get("rel") in ("stylesheet", "icon"):
            self.refs.append(a.get("href", ""))

    def handle_endtag(self, tag):
        if self._in == tag:
            text = "".join(self._buf)
            if tag == "title":
                self.title = text.strip()
            else:
                self.ldjson.append(text)
            self._in = None

    def handle_data(self, data):
        if self._in:
            self._buf.append(data)


def url_of(path):
    rel = path.relative_to(ROOT).as_posix()
    return BASE + (rel[: -len("index.html")] if rel.endswith("index.html") else rel)


def file_of(url):
    if not url.startswith(BASE):
        return None
    rel = urllib.parse.urlparse(url).path[len(urllib.parse.urlparse(BASE).path):]
    p = ROOT / rel
    return p / "index.html" if (rel == "" or rel.endswith("/")) else p


def main():
    problems = []
    pages = sorted(ROOT.rglob("*.html"))
    parsed = {}
    for f in pages:
        src = f.read_text()
        p = Page()
        p.feed(src)
        parsed[f] = p
        name = f.relative_to(ROOT).as_posix()
        for i, block in enumerate(p.ldjson):
            try:
                json.loads(block)
            except json.JSONDecodeError as e:
                problems.append(f"{name}: JSON-LD block {i + 1} does not parse ({e})")
        if not p.title:
            problems.append(f"{name}: no <title>")
        if not p.meta.get("description"):
            problems.append(f"{name}: no meta description")
        canon = [h for r, _, h in p.links if r == "canonical"]
        if canon != [url_of(f)]:
            problems.append(f"{name}: canonical {canon} is not {url_of(f)}")
        for ref in p.refs:
            if re.match(r"^(https?:|mailto:|#|data:)", ref) and not ref.startswith(BASE):
                continue
            target = file_of(ref) if ref.startswith(BASE) else (f.parent / urllib.parse.urlparse(ref).path)
            if target is None:
                continue
            target = target / "index.html" if target.is_dir() else target
            if not target.exists():
                problems.append(f"{name}: broken link {ref}")
        text = re.sub(r"<[^>]+>", " ", src)
        for m in BANNED.finditer(text):
            problems.append(f"{name}: banned wording '{m.group(0)}'")
    # hreflang: targets exist and point back
    for f, p in parsed.items():
        name = f.relative_to(ROOT).as_posix()
        alts = {lang: h for r, lang, h in p.links if r == "alternate" and lang}
        if alts and url_of(f) not in alts.values():
            problems.append(f"{name}: hreflang set does not include the page itself")
        for lang, h in alts.items():
            t = file_of(h)
            if t is None or not t.exists():
                problems.append(f"{name}: hreflang {lang} -> missing page {h}")
                continue
            back = {hh for r, l, hh in parsed[t].links if r == "alternate" and l}
            if url_of(f) not in back:
                problems.append(f"{name}: hreflang {lang} -> {h} does not link back")
    # sitemap lists exactly the pages
    sm = set(re.findall(r"<loc>([^<]+)</loc>", (ROOT / "sitemap.xml").read_text()))
    want = {url_of(f) for f in pages}
    for u in sorted(want - sm):
        problems.append(f"sitemap.xml: missing {u}")
    for u in sorted(sm - want):
        problems.append(f"sitemap.xml: lists {u}, which is not a page")
    # GitHub Pages runs Jekyll unless .nojekyll exists, and Jekyll drops files whose names start with "_"
    if not (ROOT / ".nojekyll").exists():
        own = [r for p in parsed.values() for r in p.refs if r.startswith(BASE) or not re.match(r"^[a-z]+:", r)]
        underscored = sorted({r for r in own if re.search(r"(^|/)_[^/]+$", urllib.parse.urlparse(r).path)})
        for r in underscored:
            problems.append(f"{r}: Jekyll will not publish a file starting with '_' (add docs/.nojekyll)")
    llms = (ROOT / "llms.txt").read_text()
    for f in pages:
        if "/guides/" in f.as_posix() and url_of(f) not in llms:
            problems.append(f"llms.txt: guide {url_of(f)} is not listed")
    for m in BANNED.finditer(llms):
        problems.append(f"llms.txt: banned wording '{m.group(0)}'")
    for p in problems:
        print("FAIL", p)
    if problems:
        sys.exit(1)
    print(f"OK: {len(pages)} pages, sitemap and hreflang consistent")


if __name__ == "__main__":
    main()
