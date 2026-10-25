#!/usr/bin/env python3
"""Render the dependency-free status site; --check rejects stale output/bad links."""
import argparse
import datetime
import html
import json
from pathlib import Path
import re
import sys

SITE = Path(__file__).resolve().parent
ROOT = SITE.parent
REPO = "https://github.com/grabbiel/ikkoku"


def escape(value):
    return html.escape(str(value), quote=True)


def doc_link(label, target):
    relative, _, fragment = target.partition("#")
    path = (ROOT / relative).resolve()
    if not path.is_relative_to(ROOT) or not path.is_file() or path.suffix != ".md":
        raise ValueError(f"Invalid documentation path: {target}")
    if fragment:
        # GitHub heading slugs used by this site's references (plain headings).
        headings = re.findall(r"^#{1,6}\s+(.+)$", path.read_text(), re.M)
        slugs = [re.sub(r"[^\w\- ]", "", h.lower()).replace(" ", "-") for h in headings]
        if fragment not in slugs:
            raise ValueError(f"Missing documentation heading: {target}")
    return f'<a href="{REPO}/blob/main/{escape(target)}">{escape(label)} <span aria-hidden="true">↗</span></a>'


def render():
    data = json.loads((SITE / "status.json").read_text())
    datetime.date.fromisoformat(data["reviewed"])
    if not re.fullmatch(r"[a-f0-9]{40}", data["revision"]):
        raise ValueError("Expected a full reviewed Git revision")
    seen, rows, navigation = set(), [], []
    for index, c in enumerate(data["components"], 1):
        ident = c["id"]
        if not re.fullmatch(r"[a-z][a-z0-9-]*", ident) or ident in seen:
            raise ValueError(f"Invalid/duplicate component ID: {ident}")
        seen.add(ident)
        if c["stage"] not in ("Mid-stage", "Infancy") or c["group"] not in ("Priority", "Application", "Foundation"):
            raise ValueError(f"Unknown status/group for {ident}")
        links = "".join(doc_link(*link) for link in c["docs"])
        issue = c.get("issue")
        if issue:
            if not re.fullmatch(r"[1-9][0-9]*", issue[1]):
                raise ValueError(f"Invalid issue number: {ident}")
            links += f'<a href="{REPO}/issues/{issue[1]}">{escape(issue[0])} #{issue[1]} <span aria-hidden="true">↗</span></a>'
        rows.append(f'''<article class="component" id="{ident}" data-group="{c['group']}" data-stage="{c['stage']}">
  <div class="component-head"><span class="number">{index:02d}</span><div><p class="eyebrow">{c['group']}</p><h3>{escape(c['name'])}</h3></div><span class="stage {'early' if c['stage'] == 'Infancy' else ''}">{c['stage']}</span></div>
  <p class="summary">{escape(c['summary'])}</p>
  <div class="scope"><div><h4>Available today</h4><p>{escape(c['available'])}</p></div><div><h4>Still to complete</h4><p>{escape(c['remaining'])}</p></div></div>
  <details><summary>Evidence &amp; limitations</summary><p>{escape(c['evidence'])}</p></details>
  <nav class="references" aria-label="{escape(c['name'])} documentation">{links}</nav>
</article>''')
        navigation.append(f'<a href="#{ident}"><span>{index:02d}</span>{escape(c["name"])}</a>')
    template = (SITE / "template.html").read_text()
    values = {"COMPONENTS": "\n".join(rows), "NAVIGATION": "\n".join(navigation),
              "REVIEWED": escape(data["reviewed"]), "REVISION": data["revision"],
              "SHORT_REVISION": data["revision"][:7], "COUNT": str(len(rows)),
              "PRIORITY_COUNT": str(sum(c["group"] == "Priority" for c in data["components"]))}
    for key, value in values.items():
        template = template.replace("{{" + key + "}}", value)
    if re.search(r"\{\{[A-Z_]+\}\}", template):
        raise ValueError("Unexpanded template marker")
    return template


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    output = render()
    target = SITE / "dist" / "index.html"
    if args.check:
        if not target.exists() or target.read_text() != output:
            sys.exit("Status site is stale. Run python3 site/build.py and commit site/dist/index.html.")
    else:
        target.parent.mkdir(exist_ok=True)
        target.write_text(output)
    size = len(output.encode()) + sum((SITE / "dist" / name).stat().st_size for name in ("style.css", "app.js"))
    if size > 100_000:
        sys.exit(f"Status site exceeds its 100 KB uncompressed budget: {size} bytes")
    print(f"Status site: documentation links valid, generated HTML current, {size:,} bytes total.")


if __name__ == "__main__":
    main()
