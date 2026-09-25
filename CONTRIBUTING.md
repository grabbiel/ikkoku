# Contributing to Ikkoku

Contributions to code, tests, documentation and reproducible bug reports are
welcome. Ikkoku uses **Swift + Metal**, with SwiftUI for the app and Python/.NET
tooling for conversion and analysis. The original-game port is incomplete; the
bundled prototype and original-data paths have different capabilities.

Read the [architecture](docs/architecture.md),
[build and test guide](docs/guides/build-and-test.md) and
[component audit](docs/component-audit/README.md) before changing a subsystem.
The audit provides specific findings, task IDs and acceptance criteria.

## Choose and coordinate work

1. Search existing GitHub issues and pull requests for related work. For a
   substantial feature or architectural change, describe the problem, proposed
   scope and acceptance criteria in an issue before starting. Small fixes and
   documentation corrections can go directly to a pull request.
2. Reference the relevant audit task, such as `ST-T01` or `R1`. State which modules
   you expect to touch and note dependencies on other work. Comment when you start,
   change scope or hand work over so others can avoid overlapping edits.
3. Fork the repository if you lack write access. Start a descriptive topic branch
   from the current default branch; automated Codex branches use `codex/`.
4. Keep each pull request focused on one reviewable outcome. Separate unrelated
   refactors, asset regeneration and formatting changes.

For bug reports, include the commit, macOS/hardware/tool versions, reproduction
steps, expected and actual behavior, and whether you used bundled or original
content. Include a minimal synthetic fixture or sanitized diagnostic when possible.
Report missing data and unsupported behavior separately from regressions.

## Development conventions

- Follow the surrounding naming and formatting. There is no repository-wide
  formatter configuration; avoid unrelated reformatting. Keep app/UI behavior in
  `Apps/IkkokuCreator` and reusable logic in its owning engine module.
- Keep the native runtime in Swift + Metal. Original Unity DLL execution and
  decompilation belong to isolated analysis/probe tooling, not the native app.
- Explain non-obvious source semantics, units, coordinate conversions and ordering
  in comments. Link the maintained contract and record evidence; avoid claiming
  source parity from resemblance or from a successful parser alone.
- Validate imported data at boundaries. Unsupported inputs need explicit
  diagnostics; do not silently substitute unrelated assets or change saved IDs.
- Preserve the CPU/Metal layout contract when changing shared shader types. Apply
  the [Unity coordinate conversion](docs/reference/renderer.md) exactly once.
- Fix generated assets through their producer in `Tools/assets/`. Include the
  required regenerated outputs and provenance; do not hand-edit generated files.
- Do not add dependencies, change deployment targets or introduce another runtime
  without explaining the need and compatibility impact in the pull request.

## Source data, mods and persistence

Keep original game binaries/assets, decompiled source, local mod archives, private
cards/scenes and captured evidence in ignored `.local/` or the documented ignored
input directories. Do not force-add them or attach them to public issues/PRs.
Commit native implementations, conversion tools and shareable synthetic fixtures.
Inspect the staged file list: ignore rules alone are not a provenance check.

Document source/version hashes, converter versions and fixture requirements without
publishing private inputs. Any new shared asset or third-party dependency needs
clear origin and license information. The repository currently lacks a standalone
code license file; do not assume or add an MIT/CC0 declaration for the whole project.

Preserve original catalog IDs, mod GUIDs, resolver records, unknown fields and
untouched payloads when editing cards/scenes. Display names and runtime-local slots
must not replace saved identity. Format changes need an explicit compatibility
plan and round-trip coverage. Preserved plugin data does not imply plugin execution;
new executable behavior must state its supported APIs, versions and lifecycle.

## Validate the change

Use the exact commands and prerequisites in the
[build and test guide](docs/guides/build-and-test.md). Choose checks appropriate
to the affected behavior:

| Change | Expected validation |
| --- | --- |
| Engine logic | Relevant Swift tests; add a focused regression or invariant test when behavior changes |
| App or UI | App build and the affected visible workflow, including error paths; test save/reload when relevant |
| Rendering, rigging or animation | Targeted numerical/GPU checks and a controlled visual comparison; identify production versus diagnostic rendering |
| Import/export or mod identity | Supported fixtures, malformed-input handling, no-op/edited round trips and unchanged identities/payloads |
| Python/.NET tools | Relevant tool tests and a representative invocation; record required SDK/fixture versions |
| Documentation only | Check links, paths, commands, tables and `git diff --check`; a full app build is unnecessary |

For code changes, broaden checks when shared contracts or failures justify it.
Tests should verify observable behavior, not repeat the implementation. A missing
private fixture may make a test return early: list executed, failed, skipped and
unavailable checks separately. Contributors without the original installation can
use public fixtures and state what still needs a maintainer's private-data run.

For parity or performance claims, record input/build hashes, configuration,
reference type, sample count, tolerances and exclusions. Distinguish recovered-code
oracles from original-player probes, and frozen geometry from independent live
scene evaluation. A passing kernel does not establish UI or whole-game parity.
There is currently no checked-in GitHub Actions workflow; include local results
rather than assuming CI has exercised the change.

## Prepare the pull request

Use a title describing the resulting behavior. In the description, include:

- The problem, linked issue/audit task and concrete before/after behavior.
- The implementation scope, important tradeoffs and remaining unsupported cases.
- Exact verification commands and results, including missing fixtures or failures.
- Screenshots or comparison summaries for visual changes, using shareable content.
- Persistence, identity or compatibility impact and relevant documentation changes.

Before requesting review, inspect `git diff` and the staged diff, run
`git diff --check`, and remove unrelated/generated scratch output or sensitive data.
Use a draft PR when implementation or required evidence is still incomplete.
Request maintainer review; merging, releases and repository policy changes belong
to maintainers. Follow any branch protection rules configured on GitHub.
If you push substantive changes after review, summarize them and request another
look. Do not rewrite branches shared with other contributors without coordinating.

## Work with other contributors or agents

Agree on file/module ownership and shared interfaces before parallel work. Use
separate branches/worktrees when practical. In a shared checkout, avoid concurrent
edits to the same files, preserve unrelated uncommitted work, and never reset or
overwrite another contributor's changes to resolve your own conflict. Coordinate
access to shared VM probes and output directories; use distinct outputs per run.

Assign bounded tasks with an expected deliverable and validation criteria. The
integrating contributor reviews the resulting diff, resolves interface conflicts
and verifies the combined behavior; an agent's success report is not sufficient.
Human and agent-authored contributions follow the same review and evidence rules.

A handoff should name the branch/commit, owned files, completed work, exact checks
and results, local fixture/output paths, unresolved blockers and the next concrete
step. On GitHub, omit private payloads and sensitive machine details from that note.

## Keep the documentation current

Update the owning technical reference and audit feature/task row with the change.
Keep status limited to the behavior actually implemented and verified; check app
reachability and persistence separately where needed. Retain historical results
as dated evidence rather than relabeling them as fresh test runs.

Put instructions in `docs/guides/`, contracts in `docs/reference/`, status/tasks in
`docs/component-audit/`, and superseded records in `docs/archive/`. Link new pages
from the [documentation index](docs/README.md), repair links after moves and update
the [file coverage index](docs/component-audit/file-index.md) when files change.
