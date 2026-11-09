#!/usr/bin/env python3
"""build.py — the styled reading copy of neenv, rendered from the repository's own Markdown.

    python3 pages/build.py TREE OUT

TREE is neenv as published (README.md at its root, patterns/<name>/README.md beside each pattern's files). OUT
receives one HTML page per Markdown file, the stylesheet, and a copy of every other file so that links to drills
and marks keep working. Nothing is written twice: every word on a page comes from the Markdown it renders, and the
only text this script adds is the site's name and the list of pages.

Needs: Python 3.9+ and the `markdown` package.
"""
import html
import os
import re
import shutil
import sys

import markdown

HERE = os.path.dirname(os.path.abspath(__file__))
TITLE = "neenv"
# Reading order: the foundation's own patterns first, in the order they are built on, then the walk-through that ties
# them together, then the practice. A pattern not named here follows, by name.
ORDER = ["constrained-root", "root-of-trust", "names", "tenants", "cms-tenant", "environments", "dev-box", "walk-through", "the-practice"]


def pages(tree):
    """[(source .md, output .html, link from the site root)], the root README first, then patterns by name."""
    out = [("README.md", "index.html", "")]
    pdir = os.path.join(tree, "patterns")
    names = sorted(os.listdir(pdir)) if os.path.isdir(pdir) else []
    names.sort(key=lambda n: (ORDER.index(n) if n in ORDER else len(ORDER), n))
    for name in names:
        if os.path.isfile(os.path.join(pdir, name, "README.md")):
            out.append((f"patterns/{name}/README.md", f"patterns/{name}/index.html", f"patterns/{name}/"))
    return out


def heading(md_text):
    m = re.search(r"^#\s+(.+)$", md_text, re.M)
    return m.group(1).strip() if m else TITLE


def relink(body, src):
    """A link to another page's README.md, or to a pattern's folder, points at that page's HTML."""
    def fix(m):
        url = m.group(2)
        if re.match(r"^[a-z]+:|^#|^/", url):
            return m.group(0)
        new = re.sub(r"(^|/)README\.md(#|$)", r"\1\2", url)
        return f'{m.group(1)}"{new}"'
    return re.sub(r'(href=)"([^"]+)"', fix, body)


def render(tree, out):
    css = os.path.join(HERE, "style.css")
    listing = pages(tree)
    for root, _dirs, files in os.walk(tree):
        rel = os.path.relpath(root, tree)
        if rel.split(os.sep)[0] in (".git", "pages"):
            continue
        for f in files:
            if not f.endswith(".md"):
                dst = os.path.join(out, rel, f)
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                shutil.copy2(os.path.join(root, f), dst)
    shutil.copy2(css, os.path.join(out, "style.css"))
    titles = {src: heading(open(os.path.join(tree, src)).read()) for src, _, _ in listing}
    for src, dst, _link in listing:
        text = open(os.path.join(tree, src)).read()
        body = markdown.markdown(text, extensions=["tables", "fenced_code", "toc", "sane_lists"],
                                 extension_configs={"toc": {"permalink": False}})
        body = relink(body, src)
        depth = dst.count("/")
        up = "../" * depth
        nav = "\n".join(
            f'<li{" class=\"here\"" if s == src else ""}><a href="{up}{l}">{html.escape(titles[s])}</a></li>'
            for s, _d, l in listing)
        page = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{html.escape(titles[src])} · {TITLE}</title>
<link rel="stylesheet" href="{up}style.css">
</head>
<body>
<header class="site"><a class="name" href="{up}">{TITLE}</a></header>
<div class="frame">
<nav class="pages" aria-label="Pages"><ol>
{nav}
</ol></nav>
<main>
{body}
</main>
</div>
</body>
</html>
"""
        path = os.path.join(out, dst)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        open(path, "w").write(page)
    return [d for _s, d, _l in listing]


if __name__ == "__main__":
    if len(sys.argv) != 3 or not os.path.isfile(os.path.join(sys.argv[1], "README.md")):
        sys.exit(__doc__)
    for p in render(sys.argv[1], sys.argv[2]):
        print("wrote", p)
