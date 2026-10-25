# Component status website

[Open the public status website](https://ikkoku-status.felipearceo.chatgpt.site).

The site is a concise, dated view of the component audit: eight priority
components plus Studio, animation, IK, audio, gameplay, app/document workflows,
scene foundations and tooling. Each entry states available scope, remaining
work, evidence limits and links back to the owning repository documentation.
It does not calculate a whole-game completion percentage or query live CI.

## Update alongside a completed task

1. Review the accepted change and update its owning reference/audit first.
2. Edit only the affected entry in `site/status.json`. Keep unmerged work out of
   available scope. Advance `reviewed` and `revision` to the review date and
   accepted source commit after checking the affected statements.
3. Run `python3 site/build.py`, then `python3 site/build.py --check` from the
   repository root. Commit the JSON and generated `site/dist/index.html`
   together. CI checks reproducibility, document paths and referenced headings.
4. Publish the reviewed source to the existing Sites project identified in
   `site/.openai/hosting.json`. Preserve its public audience and project ID.
   Use the Sites source workflow to open its source repository, copy this
   directory's reviewed files into that separate checkout (excluding caches and
   Git metadata), push/package the exact source and deploy the saved version.
   Keep credentials in memory and pass them through the helper's hidden stdin;
   never commit them. Verify deployment success before reporting the site updated.

The Ikkoku repository is authoritative. The Sites source repository is a
publication mirror, not a second backlog. Site publication and the GitHub merge
are separate operations; report any lag explicitly. Future component handoffs
should refresh the affected site entry when its support boundary changes, along
with the normal scoped documentation update.

## Local preview and checks

```sh
python3 site/build.py --check
python3 -m http.server 8765 --bind 127.0.0.1 --directory site/dist
```

Open `http://127.0.0.1:8765`. Check desktop and narrow layouts, text search,
combined area/stage filters, no-result/reset behavior, component anchors and
evidence disclosures. All component content and documentation links remain
available without JavaScript. Search caches component text once, uses native
controls and performs no network requests.

The site ships only HTML, CSS and JavaScript, with system fonts, no external
assets, analytics, dependencies or game content. `build.py` enforces a 100 KB
uncompressed budget for those three files. This is a transfer-size bound, not a
measured load-time claim. The website has no effect on native runtime performance.
