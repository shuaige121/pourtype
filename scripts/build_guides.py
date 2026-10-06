#!/usr/bin/env python3
"""Build the guide pages of the site from site-src/guides/*.json.

A guide is one JSON file per language; files that share "group" are translations of each other
and get hreflang links. This script owns all SEO plumbing so content files stay plain:
  docs/[<lang>/]guides/<slug>/index.html   one page per JSON file
  docs/[<lang>/]guides/index.html          a list of guides per language
  docs/sitemap.xml                         regenerated for every page
  docs/llms.txt                            the "## Guides" section
  docs/[<lang>/]index.html                 a link to that language's guides in the footer

JSON fields: group, lang (en | zh-Hans | zh-Hant | ja), slug, title, description, h1, updated (YYYY-MM-DD),
answer (the short direct answer), intro [str], sections [{h2, body: [{p}|{ul:[]}|{ol:[]}|{note}]}],
howto {name, steps: [str]} (optional), faq [{q, a}], sources [{title, url}], related [group].
Inline text may use **bold**, `code` and [label](url).
"""
import html
import json
import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
SRC = REPO / "site-src" / "guides"
DOCS = REPO / "docs"
BASE = "https://shuaige121.github.io/pourtype/"
LANGS = ["en", "zh-Hans", "zh-Hant", "ja"]
PREFIX = {"en": "", "zh-Hans": "zh-hans/", "zh-Hant": "zh-hant/", "ja": "ja/"}
NAME = {"en": "English", "zh-Hans": "简体中文", "zh-Hant": "繁體中文", "ja": "日本語"}
OG_LOCALE = {"en": "en_US", "zh-Hans": "zh_CN", "zh-Hant": "zh_TW", "ja": "ja_JP"}
UI = {
    "en": dict(home="Home", guides="Guides", updated="Updated", answer="Short answer", sources="Sources",
               related="Related guides", faq="Questions", by="By Leonard Chow, developer of Pourtype",
               all_guides="Guides: fixing paste-blocked fields and copying text on a Mac",
               all_desc="Step-by-step guides for typing into fields that block paste and copying text out of images on a Mac.",
               cta_h="Pourtype does this in one shortcut",
               cta=("Pourtype is a small Mac menu-bar app made for these problems. Press ⌘⇧V and it types your clipboard "
                    "into the field as real keystrokes; press ⌘⇧C and drag a box to copy any text you can see. It runs "
                    "locally and collects no data. US$2.99, one-time, on the Mac App Store (coming soon)."),
               cta_btn="About Pourtype", disclosure="Disclosure: this guide is written by the developer of Pourtype."),
    "zh-Hans": dict(home="首页", guides="使用指南", updated="更新于", answer="简短回答", sources="参考来源",
                    related="相关指南", faq="常见问题", by="作者：Leonard Chow（Pourtype 开发者）",
                    all_guides="指南：Mac 上输入框禁止粘贴、截图识字怎么办",
                    all_desc="一步一步解决 Mac 上输入框禁止粘贴、从图片和屏幕上复制文字的问题。",
                    cta_h="用 Pourtype，一个快捷键搞定",
                    cta=("Pourtype 是专为这类问题做的 Mac 菜单栏小工具：按 ⌘⇧V，它把剪贴板里的文字当作真实按键打进输入框；"
                         "按 ⌘⇧C 拖一个框，屏幕上看得见的文字就能复制。全部在本机完成，不收集任何数据。"
                         "Mac App Store 一次买断 US$2.99（即将上架）。"),
                    cta_btn="了解 Pourtype", disclosure="利益相关：本文作者是 Pourtype 的开发者。"),
    "zh-Hant": dict(home="首頁", guides="使用指南", updated="更新於", answer="簡短回答", sources="參考來源",
                    related="相關指南", faq="常見問題", by="作者：Leonard Chow（Pourtype 開發者）",
                    all_guides="指南：Mac 上欄位禁止貼上、擷取螢幕文字怎麼辦",
                    all_desc="一步一步解決 Mac 上欄位禁止貼上、從圖片和螢幕上複製文字的問題。",
                    cta_h="用 Pourtype，一個快速鍵完成",
                    cta=("Pourtype 是專為這類問題做的 Mac 選單列小工具：按 ⌘⇧V，它會把剪貼簿裡的文字當作真實按鍵輸入到欄位中；"
                         "按 ⌘⇧C 拖曳一個框，螢幕上看得到的文字就能複製。全部在本機完成，不收集任何資料。"
                         "Mac App Store 一次買斷 US$2.99（即將上架）。"),
                    cta_btn="認識 Pourtype", disclosure="利益揭露：本文作者是 Pourtype 的開發者。"),
    "ja": dict(home="ホーム", guides="ガイド", updated="更新日", answer="結論", sources="参考資料",
               related="関連ガイド", faq="よくある質問", by="執筆：Leonard Chow（Pourtype 開発者）",
               all_guides="ガイド：Mac で貼り付けできない欄への入力と、画面の文字のコピー",
               all_desc="Mac で貼り付けが禁止された欄に入力する方法と、画像や画面の文字をコピーする方法を手順つきで解説します。",
               cta_h="Pourtype ならショートカットひとつで",
               cta=("Pourtype は、こうした場面のために作った Mac のメニューバーアプリです。⌘⇧V を押すと、クリップボードの文字を"
                    "実際のキー入力として欄に入力します。⌘⇧C で範囲を囲めば、画面に見える文字をコピーできます。処理はすべて Mac の中で行い、"
                    "データは収集しません。Mac App Store で US$2.99 の買い切り（近日公開）。"),
               cta_btn="Pourtype について", disclosure="開示：このガイドは Pourtype の開発者が書いています。"),
}


def inline(text):
    s = html.escape(text, quote=False)
    s = re.sub(r"`([^`]+)`", r"<code>\1</code>", s)
    s = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", s)
    s = re.sub(r"\[([^\]]+)\]\((https?://[^)\s]+|[./][^)\s]*)\)", r'<a href="\2">\1</a>', s)
    return s


def plain(text):
    return re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", text).replace("**", "").replace("`", "")


def guide_url(g):
    return f"{BASE}{PREFIX[g['lang']]}guides/{g['slug']}/"


def index_url(lang):
    return f"{BASE}{PREFIX[lang]}guides/"


def home_url(lang):
    return f"{BASE}{PREFIX[lang]}"


def head(lang, title, desc, url, alternates, ld):
    alt = "".join(f'<link rel="alternate" hreflang="{l}" href="{u}">\n' for l, u in alternates)
    lds = "".join(f'<script type="application/ld+json">\n{json.dumps(x, ensure_ascii=False, indent=2)}\n</script>\n' for x in ld)
    return (f'<!doctype html>\n<html lang="{lang}"><head><meta charset="utf-8">'
            f'<meta name="viewport" content="width=device-width,initial-scale=1">\n'
            f"<title>{html.escape(title)}</title>\n"
            f'<meta name="description" content="{html.escape(desc)}">\n'
            f'<link rel="canonical" href="{url}">\n{alt}'
            f'<meta name="theme-color" content="#0E0F1A">\n<link rel="icon" type="image/png" href="{BASE}img/icon.png">\n'
            f'<meta property="og:type" content="article"><meta property="og:site_name" content="Pourtype">\n'
            f'<meta property="og:title" content="{html.escape(title)}"><meta property="og:description" content="{html.escape(desc)}">\n'
            f'<meta property="og:url" content="{url}"><meta property="og:image" content="{BASE}img/og.png">\n'
            f'<meta property="og:locale" content="{OG_LOCALE[lang]}"><meta name="twitter:card" content="summary_large_image">\n'
            f'<link rel="stylesheet" href="{BASE}_style.css">\n{lds}</head>\n')


def top(lang, switch):
    links = " · ".join(
        f'<a href="{u}" hreflang="{l}" lang="{l}"' + (' aria-current="page"' if l == lang else "") + f">{NAME[l]}</a>"
        for l, u in switch)
    return (f'<body class="lp guide-page">\n<header class="lp-top"><a class="lp-brand" href="{home_url(lang)}">'
            f'<span class="lp-dot" aria-hidden="true"></span>Pourtype</a>\n'
            f'<nav class="lp-lang" aria-label="Language">{links}</nav></header>\n')


def foot(lang):
    t = UI[lang]
    return (f'<footer class="lp-foot"><p>{t["by"]}</p><p><a href="{home_url(lang)}">Pourtype</a> · '
            f'<a href="{index_url(lang)}">{t["guides"]}</a> · <a href="https://github.com/shuaige121/pourtype">GitHub</a> · '
            f'<a href="{BASE}privacy.html">Privacy</a></p></footer>\n</body></html>\n')


def render_body(blocks):
    out = []
    for b in blocks:
        if "p" in b:
            out.append(f"<p>{inline(b['p'])}</p>")
        elif "ul" in b:
            out.append("<ul>" + "".join(f"<li>{inline(x)}</li>" for x in b["ul"]) + "</ul>")
        elif "ol" in b:
            out.append("<ol>" + "".join(f"<li>{inline(x)}</li>" for x in b["ol"]) + "</ol>")
        elif "note" in b:
            out.append(f'<p class="note">{inline(b["note"])}</p>')
        else:
            raise ValueError(f"unknown block {b}")
    return "\n".join(out)


def build_guide(g, groups, by_lang):
    lang, t, url = g["lang"], UI[g["lang"]], guide_url(g)
    sib = groups[g["group"]]
    alternates = [(l, guide_url(sib[l])) for l in LANGS if l in sib]
    alternates.append(("x-default", guide_url(sib["en"] if "en" in sib else sib[alternates[0][0]])))
    switch = [(l, guide_url(sib[l]) if l in sib else home_url(l)) for l in LANGS]
    author = {"@type": "Person", "name": "Leonard Chow"}
    ld = [{"@context": "https://schema.org", "@type": "Article", "headline": g["h1"], "description": g["description"],
           "inLanguage": lang, "author": author, "datePublished": g["updated"], "dateModified": g["updated"],
           "mainEntityOfPage": url, "publisher": author},
          {"@context": "https://schema.org", "@type": "BreadcrumbList", "itemListElement": [
              {"@type": "ListItem", "position": 1, "name": t["home"], "item": home_url(lang)},
              {"@type": "ListItem", "position": 2, "name": t["guides"], "item": index_url(lang)},
              {"@type": "ListItem", "position": 3, "name": g["h1"], "item": url}]}]
    if g.get("howto"):
        ld.append({"@context": "https://schema.org", "@type": "HowTo", "name": g["howto"]["name"], "inLanguage": lang,
                   "step": [{"@type": "HowToStep", "position": i + 1, "text": plain(s)} for i, s in enumerate(g["howto"]["steps"])]})
    if g.get("faq"):
        ld.append({"@context": "https://schema.org", "@type": "FAQPage", "inLanguage": lang, "mainEntity": [
            {"@type": "Question", "name": plain(f["q"]), "acceptedAnswer": {"@type": "Answer", "text": plain(f["a"])}} for f in g["faq"]]})
    body = [f'<main class="lp-main guide">',
            f'<nav class="crumbs"><a href="{home_url(lang)}">{t["home"]}</a> › <a href="{index_url(lang)}">{t["guides"]}</a></nav>',
            f"<h1>{inline(g['h1'])}</h1>",
            f'<p class="meta">{t["by"]} · {t["updated"]} <time datetime="{g["updated"]}">{g["updated"]}</time></p>',
            f'<div class="answer"><strong>{t["answer"]}</strong><p>{inline(g["answer"])}</p></div>']
    body += [f"<p>{inline(p)}</p>" for p in g.get("intro", [])]
    for s in g["sections"]:
        body.append(f"<h2>{inline(s['h2'])}</h2>\n{render_body(s['body'])}")
    body.append(f'<aside class="cta"><h2>{t["cta_h"]}</h2><p>{t["cta"]}</p>'
                f'<p><a class="btn" href="{home_url(lang)}">{t["cta_btn"]}</a></p><p class="note">{t["disclosure"]}</p></aside>')
    if g.get("faq"):
        body.append(f'<section class="faq"><h2>{t["faq"]}</h2>' + "".join(
            f"<details><summary>{inline(f['q'])}</summary><p>{inline(f['a'])}</p></details>" for f in g["faq"]) + "</section>")
    rel = [groups[r][lang] for r in g.get("related", []) if r in groups and lang in groups[r]]
    if rel:
        body.append(f'<h2>{t["related"]}</h2><ul>' + "".join(
            f'<li><a href="{guide_url(r)}">{inline(r["h1"])}</a></li>' for r in rel) + "</ul>")
    if g.get("sources"):
        body.append(f'<h2 class="small">{t["sources"]}</h2><ul class="sources">' + "".join(
            f'<li><a href="{html.escape(s["url"])}" rel="nofollow">{html.escape(s["title"])}</a></li>' for s in g["sources"]) + "</ul>")
    body.append("</main>")
    page = head(lang, g["title"], g["description"], url, alternates, ld) + top(lang, switch) + "\n".join(body) + "\n" + foot(lang)
    out = DOCS / f"{PREFIX[lang]}guides/{g['slug']}/index.html"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(page)
    return out


def build_index(lang, guides, langs_with_guides):
    t, url = UI[lang], index_url(lang)
    alternates = [(l, index_url(l)) for l in LANGS if l in langs_with_guides]
    alternates.append(("x-default", index_url("en" if "en" in langs_with_guides else alternates[0][0])))
    switch = [(l, index_url(l) if l in langs_with_guides else home_url(l)) for l in LANGS]
    ld = [{"@context": "https://schema.org", "@type": "CollectionPage", "name": t["all_guides"], "inLanguage": lang, "url": url}]
    items = "".join(f'<li><a href="{guide_url(g)}">{inline(g["h1"])}</a><p>{inline(g["description"])}</p></li>' for g in guides)
    page = (head(lang, t["all_guides"], t["all_desc"], url, alternates, ld) + top(lang, switch) +
            f'<main class="lp-main guide"><nav class="crumbs"><a href="{home_url(lang)}">{t["home"]}</a></nav>'
            f'<h1>{t["all_guides"]}</h1><ul class="guide-list">{items}</ul></main>\n' + foot(lang))
    out = DOCS / f"{PREFIX[lang]}guides/index.html"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(page)


def link_from_home(lang, has):
    p = DOCS / f"{PREFIX[lang]}index.html"
    s = p.read_text()
    s = re.sub(r"\s*<!--guides-->.*?<!--/guides-->", "", s, flags=re.S)
    if has:
        s = s.replace("</footer>", f'\n<!--guides--><p><a href="{index_url(lang)}">{UI[lang]["guides"]}</a></p><!--/guides--></footer>', 1)
    p.write_text(s)


def sitemap(groups, langs_with_guides):
    def alt_xml(pairs):
        return "".join(f'<xhtml:link rel="alternate" hreflang="{l}" href="{u}"/>' for l, u in pairs)
    homes = [(l, home_url(l)) for l in LANGS] + [("x-default", home_url("en"))]
    rows = [f"<url><loc>{u}</loc>{alt_xml(homes)}</url>" for _, u in homes[:-1]]
    rows += [f"<url><loc>{BASE}privacy.html</loc></url>", f"<url><loc>{BASE}support.html</loc></url>"]
    if langs_with_guides:
        idx = [(l, index_url(l)) for l in LANGS if l in langs_with_guides]
        idx_alt = idx + [("x-default", index_url("en" if "en" in langs_with_guides else idx[0][0]))]
        rows += [f"<url><loc>{u}</loc>{alt_xml(idx_alt)}</url>" for _, u in idx]
    for sib in groups.values():
        pairs = [(l, guide_url(sib[l])) for l in LANGS if l in sib]
        pairs_x = pairs + [("x-default", guide_url(sib["en"] if "en" in sib else sib[pairs[0][0]]))]
        for l, u in pairs:
            rows.append(f"<url><loc>{u}</loc><lastmod>{sib[l]['updated']}</lastmod>{alt_xml(pairs_x)}</url>")
    (DOCS / "sitemap.xml").write_text('<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" '
                                      'xmlns:xhtml="http://www.w3.org/1999/xhtml">\n' + "\n".join(rows) + "\n</urlset>\n")


def llms(all_guides):
    p = DOCS / "llms.txt"
    s = re.sub(r"\n## Guides\n.*?(?=\n## |\Z)", "", p.read_text(), flags=re.S).rstrip() + "\n"
    if all_guides:
        lines = [f"- [{plain(g['h1'])}]({guide_url(g)}) ({NAME[g['lang']]}): {plain(g['answer'])}" for g in all_guides]
        s += "\n## Guides\n" + "\n".join(lines) + "\n"
    p.write_text(s)


def main():
    guides = [json.loads(f.read_text()) for f in sorted(SRC.glob("*.json"))] if SRC.exists() else []
    groups = {}
    for g in guides:
        for k in ("group", "lang", "slug", "title", "description", "h1", "updated", "answer", "sections"):
            if not g.get(k):
                sys.exit(f"{g.get('group')}.{g.get('lang')}: missing {k}")
        if g["lang"] not in LANGS:
            sys.exit(f"{g['group']}: unknown lang {g['lang']}")
        if g["lang"] in groups.setdefault(g["group"], {}):
            sys.exit(f"{g['group']}: two {g['lang']} versions")
        groups[g["group"]][g["lang"]] = g
    # remove pages of guides that no longer exist
    for lang in LANGS:
        d = DOCS / f"{PREFIX[lang]}guides"
        if d.exists():
            keep = {g["slug"] for g in guides if g["lang"] == lang}
            for sub in d.iterdir():
                if sub.is_dir() and sub.name not in keep:
                    for f in sub.rglob("*"):
                        f.unlink()
                    sub.rmdir()
    for g in guides:
        build_guide(g, groups, None)
    langs_with = {g["lang"] for g in guides}
    for lang in LANGS:
        mine = [g for g in guides if g["lang"] == lang]
        idx = DOCS / f"{PREFIX[lang]}guides/index.html"
        if mine:
            build_index(lang, mine, langs_with)
        elif idx.exists():
            idx.unlink()
        link_from_home(lang, bool(mine))
    sitemap(groups, langs_with)
    llms(guides)
    print(f"built {len(guides)} guides in {len(langs_with)} languages")


if __name__ == "__main__":
    main()
