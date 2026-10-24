# Claude handoff: Renderer, Character Maker and base models

**Historical checkpoint, 2026-10-23.** For current support and work, read the
[project overview](README.md#current-scope) and
[maintained audit](docs/component-audit/README.md#current-work-and-evidence).
The branch state, task limits and next steps below describe this session and
have since changed; current user directions take precedence. The
[older local-environment handoff](HANDOFF-2026-10-23-local-environment.md)
retains earlier verification history.

## Start state

The completed work is merged into `main` at
`88d84473b555c1624ec4dd775596dbf0f29b34a9`. The primary checkout was clean before
this documentation-only handoff was added. There are no outstanding feature
commits to cherry-pick and no pending merge in this wave. Read the handoff changes
in `git status` before starting; they are not unfinished application code.

| Task | Merged PR | Issue / audit | Result |
| --- | --- | --- | --- |
| Renderer | [#139](https://github.com/grabbiel/ikkoku/pull/139) | #137 / R1, CMT-04 | All 47 requested native asset textures decode; controlled live material coverage increases from 1/20 to 11/20 slots. |
| Character Maker | [#140](https://github.com/grabbiel/ikkoku/pull/140) | #138 / CMT-02 | Original-format hair/clothing edits are transactional and survive export/reimport; changed-selection latency falls from 846 to 646 ms. |
| Base models | [#141](https://github.com/grabbiel/ikkoku/pull/141) | #136 / R2, CM-14 | Correct source female hand scales; independently verify three neutral original-player models without fitted hand timing. |

PR #135, the preceding wave, already merged cached simulation work, Studio
expression editing and selected skirt dynamics. Do not reimplement that work.
Read [CONTRIBUTING.md](CONTRIBUTING.md), the [component audit](docs/component-audit/README.md),
and the relevant reference below before changing a subsystem.

## User directions and coordination

- Work on **at most three development tasks at once**, using agents/worktrees
  where useful. Performance is a requirement throughout development.
- The user authorized creating PRs and merging autonomously through their Git
  and `gh` tooling. Review the final diff and require appropriate checks before
  merging. This explicit authorization supersedes the generic maintainer-only
  wording in CONTRIBUTING; it does not bypass branch protection.
- The user authorized local application management for development/testing.
  No additional system settings permissions were needed in this wave.
- There is a **hard limit of three Claude agents**. Account for any Claude
  coordinator when counting active Claude agents; do not add three supporters
  on top of an already-running Claude coordinator.
- Only one owner may use the shared native app/GUI or original-game VM at a
  time. Serialize all app launches through the existing machine app lock.
  Pause other builds, tests, captures and VM probes for quiet benchmarks.
- Use separate build/output folders across worktrees. Do not edit a source tree
  while its compiler is reading it. One early mixed-version Engine run failed
  for this reason; the stable final run passed.
- Preserve other sessions' worktrees, ignored inputs and processes. Identify an
  owned process by its exact executable and current PID before stopping it;
  never use `killall`/broad `pkill` or trust an old recorded PID.
- Keep original assets, cards/scenes, recovered source, VM captures and all
  private evidence in ignored `.local/`. Never force-add them to Git or upload
  them to a public PR. Do not weaken source identities, validators or tolerances
  to obtain a pass.

## Local tools, worktrees and review sessions

Commands below run from the primary repository root. The tested toolchain was
Xcode 27.0 / build 27A266a on Apple Silicon; old handoff toolchain prose is historical.

Git remote is `git@github.com:grabbiel/ikkoku.git`. Git SSH uses the correct
account, but the globally active `gh` account was different. The existing
private wrapper selects the `grabbiel` credential for a subprocess without
printing it or changing the global login:

```sh
python3 .local/codex-resume-2026-10-23/gh.py pr list
```

Do not print tokens. `gh pr edit` hit the deprecated Projects GraphQL API in
this environment; editing PR bodies/base with `gh api ... --method PATCH
--input <json-file>` worked. Create focused branches, preserve real newlines in
PR bodies, and merge with `--match-head-commit <reviewed-sha>`.

The correct reverse-tool Python is `.local/reverse/unitypy-venv/bin/python`.
The other `.local/reverse/venv/bin/python` lacks NumPy. Do not resolve the venv
executable symlink to its underlying system interpreter.

These managed worktrees remain available, with completed branches:

| Directory under `~/.codex/worktrees/` | Branch | Last task head |
| --- | --- | --- |
| `renderer-native-textures/ikkoku` | `codex/renderer-native-textures` | `356a56b` |
| `maker-source-selection/ikkoku` | `codex/maker-source-selection` | `5c6f408` |
| `base-model-accuracy/ikkoku` | `codex/base-model-accuracy` | `b109692` |

Check `git worktree list` and each checkout's status before reuse. Start new
work from current `main`, not an old task head. The original Claude worktrees
and earlier Codex worktrees were preserved. Some `.local/reverse` directories
are symlinks into the primary checkout; do not remove shared targets when
cleaning up a worktree. Retain private evidence before archiving anything.

The three supporting Claude reviews finished successfully. Claude authentication
was renewed by the user. The local CLI is `~/.local/bin/claude`. Review state,
session IDs, working directories and saved outputs are in:

```text
.local/codex-renderer-maker-models-2026-10-23/claude-support/workers.json
.local/codex-renderer-maker-models-2026-10-23/claude-support/completed.json
```

The same three identities were reused for follow-ups, never extra agents.
`claude-support/followup.py <renderer|maker|models> <label> <prompt-file>` resumes
the corresponding restricted read-only reviewer. It disables GUI, shell,
editing, MCP servers and spawning. Inspect the helper before reuse. The last
Maker reviewer could read its worktree but not the central private timing
files; Codex independently checked those exports, hashes and resource counts.

The machine app-lock wrapper's exact path is retained in
`integration/maker-release.json` under each check's `argv[0]`. It uses
`.local/orchestration/ikkoku-app.lock`. The wrapper lives in the retained Claude
scratchpad; verify it exists. If recreating it, coordinate all agents to use the
same lock file. All app/probe processes owned by this wave exited; do not infer
the state of unrelated user sessions from that statement.

## Implementation contracts to preserve

### Renderer

Start with [renderer reference](docs/reference/renderer.md), especially
"Native asset completion (R1 / #137, 2026-10-23)". Main files:

- `Packages/Engine/Sources/Renderer/SourceShaderLiveMaterial.swift`
- `Packages/Engine/Sources/Renderer/OriginalProbeTextureLoader.swift`
- `Tools/reverse/source_texture_store.py`
- `Packages/Engine/Tests/EngineTests/SourceShaderLiveTests.swift`

Texture requests bind exact source identity, dimensions and mip count. Every
cold-read mip is bounded/hash-checked; the **same verified bytes** are uploaded,
with no second file read and no retained CPU mip cache. GPU cache keys include
all content hashes and layout, so changing files/manifest at the same path
cannot silently reuse old content. Resource ownership guards avoid aliasing
recycled object identifiers. One provider serializes cold uploads; this is not
a general thread-safety guarantee for ResourceStore or multiple providers.

The translated live path remains experimental and defaults off. Nine tested
slots still require runtime composites; real Studio scene globals remain
unresolved. Native hair color residuals and whole-character production color
still fail their gates. Teeth/tongue/nose coverage has no frontmost visible
pixels in this fixture, so resolution alone is not visual proof for them.
Independent GPU base comparisons, offline authored mip comparisons and
uncompared levels remain separate evidence categories.

### Character Maker

Read [cards](docs/reference/character/cards.md) and
[Maker assets](docs/reference/character/maker-assets.md). Main files:

- `Apps/IkkokuCreator/Maker/MakerModel.swift`, `SourceRigPanel.swift`
- `Packages/Engine/Sources/Character/SourceCharacterCardSelections.swift`
- `Packages/Engine/Sources/Character/SourceCharacterCardEditing.swift`
- `Packages/Engine/Sources/Character/SourceMakerLibrary.swift`
- `Tools/verification/scenarios/maker-selection-roundtrip.json`

Four hair and eight current-outfit clothing pickers edit original card bytes,
not native `CharacterCard`. Only the selected ID and exact-destination UAR
records change; both supported markers and current/legacy Extended Save layouts
are handled. Unknown payloads, unrelated outfits and raw records are preserved.
Malformed or ambiguous resolver metadata fails explicitly; a mod ID must never
silently alias a numerically equal vanilla ID.

Candidate geometry, appearance, pose and frame must validate before editor state
commits. Pending colors/shapes survive failures. A resolved no-op preserves
preview identity/GPU resources; a same-number mod selection is not that no-op.
Selection rows are cached outside frame updates. Replacing hair clears stale
simulation particles.

The performance fix defers reference hair/clothing geometry parsing until a
selection actually needs that fallback. All manifest path/slot checks remain
eager; selected asset hashes/size limits remain enforced. Converted/explicitly
empty selections may bypass an unused missing/malformed reference, but a needed
fallback must still fail. No broad parsed-asset cache was introduced.

Selection remains synchronous at roughly 0.61–0.67 seconds in the measured
runs. Accessories, head, inner shoes, profile/personality and mod geometry
editing remain outside this implementation. Selected IDs retain other saved
part fields; original Maker default-reset and edited-card visual parity are
not established.

### Base model accuracy

Read [neutral model parity](docs/reference/character/neutral-model-parity.md).
Main files:

- `Packages/Engine/Sources/Character/SourceBodyLateCorrection.swift`
- `Packages/Engine/Sources/Character/SourceRigPreview.swift`
- `Packages/Engine/Sources/Studio/SourceStudioCharacterPreview.swift`
- `Packages/Engine/Sources/IkkokuInspect/SourceCardModelInspection.swift`
- `Tools/reverse/fixtures/OriginalCharacterProbe.cs`
- `Tools/reverse/original_character_probe.py`, `compare_original_model.py`

Source high-detail female late setters use absolute forearm scales `(0.92,1,1)`
when the arm flag is on and hand scales `(1,0.9,0.9)` when the hand flag is on;
off flags set unit scale. Source defaults are arm off, hand on. Male/low-detail
paths do not apply these setters. Destinations are bound once, not searched per
frame. Maker samples animation before the shape/late/static-ABMX pose. Studio
caches final corrected/static-ABMX scales and restores them after body/hand
animation, before FK/IK; shape rebuilds refresh the cache transactionally.
Animation clips contain scale channels, so baseline-only correction is wrong.

Low-level `SourceRigPreview` defaults remain disabled; application callers
explicitly opt in and preserve options across all rebuilds. The historical R1
capture actually has unit hand scales. Its legacy `card-pose`/shader diagnostics
stay uncorrected; use `card-model` for the new settled-player captures. Never
silently reinterpret the old reference using the new startup context.

The independent gate covers female/head00, female/head200 and normal male/head200:
19 selected parts each, 112,761 vertex entries total, maximum vertex error
7.16e-7 at unchanged tolerance 2e-5. It compares every selected vertex against
both source runtime skinning and actual Unity BakeMesh, and gates ordered skin
joint world matrices/rest identities/topology. Female00 repeat captures have
814 identical transform records and 20 identical geometry/BakeMesh streams;
same/copied producer provenance is rejected. CPU silhouette IoU is 1.0 for all
three, a geometric diagnostic rather than a Metal/color claim.

Full hierarchy/local-transform equality is diagnostic only. Exact source shadow
hashes and card-disabled canine are explicit inspector exclusions. **Production
toon canine visibility remains unresolved.** Dynamics, arbitrary animated/FK/IK
states, original ABMX plug-in execution, low detail and special male are outside
this original-player comparison. Native ordering regressions do not prove
original animated-player parity.

## Evidence, validation and rerun commands

The central private evidence root is:

```text
.local/codex-renderer-maker-models-2026-10-23/
```

Read `integration/validation-summary.json` first. Useful retained files:

| Path relative to that root | Evidence |
| --- | --- |
| `renderer/reviewed-summary.json` | Final texture coverage, paired Release cost and opt-out image controls |
| `maker-selection-lazy-summary.json` | Six interleaved selection runs, executable/input hashes, timings, byte-identical exports and stable resources |
| `maker-selection-stage-profile.json` | Pre-optimization stage profile: prepare ~748 ms, card appearance ~107 ms |
| `maker-ui-check.json`, `maker-ui-byte-audit.json` | Actual native hair/top UI edits, outfit switch and export/reimport |
| `base-model/` | Original-player captures, neutral comparisons, silhouettes, repeat provenance and late-pass benchmark |
| `integration/maker-selection-byte-audit.json` | Exactly 13 permitted scalar edits, other blocks/outfits/trailer preserved |
| `integration/maker-combined-payload-audit.json` | Combined corrected-hand thumbnail differs, but card block bytes/trailer equal the Maker-only export |
| `integration/perf-summary.json`, `integration/orbit-confirmation-summary.json` | Final app snapshots and three orbit pairs, with interpretation limits |
| `integration/models-ci-final.json` | Four successful CI jobs on final model branch head |

Final validation: 752 executed Engine checks passed in the full Release run;
two skirt checks initially skipped for missing environment mappings then passed
separately with strict supplied fixtures. Only the unavailable original appearance
RGBA oracle and opt-in expression timing probe remain skipped. Python reverse
suite: 421 reported, 415 executed, six skipped; verification suite: 180 passed.
All five Maker and twenty affected Studio scenarios passed. This wave did not
rerun every Studio scenario; the previous wave's full 52-scenario evidence is
historical.

All four CI jobs passed for each merged task. Final model
[CI run](https://github.com/grabbiel/ikkoku/actions/runs/40028247364) was manually
dispatched against `b109692962b65dd1bf3ba5ed1eca7db7566fbbf2` while its PR was
stacked. The prospective merge tree and actual `main` tree both matched the
tested tree `ad4a297d2c82ad15ffd47e0d3d53adbc06348742`. Final local Release
executable SHA-256: `47b363ed06b9a1179dcc343d532830d3d4df8a4482a2df78a4cb425674ba302b`.

Performance claims are bounded:

- Maker selection: three eager medians 841/846/847 ms versus lazy 646/646/648 ms;
  median-of-medians improvement **23.62%**, identical exports and resource counts.
- Renderer: ten additional translated slots add about **0.124 ms CPU encoding /
  0.252 ms GPU** median. Added work is not an equal-output speedup; experimental
  opt-out images remain byte-identical.
- Model correction: cached female four-bone pass measures about **125 ns** median,
  including clock overhead. This is not whole-pose or FPS performance.
- Continuous Maker slider and Studio orbit work still nearly saturate the main
  thread. Extra orbit pairs did not reproduce the initial slower snapshot;
  frame presentation/input delivery vary. Do not claim an overall FPS gain.

Use the retained combined environment, which includes the new 47-texture store
and restored skirt fixture mappings. The older `.local/verification/environment.json`
alone does not include all of those overrides. App manifests contain absolute
paths to the primary Release executable and shared lock; inspect them before
running from another checkout. Keep new report/output paths separate from the
accepted evidence. These are rerun examples, not instructions to repeat all
checks before choosing a task:

```sh
# Build first, with no edits/merges in this checkout during compilation.
xcodebuild -project Ikkoku.xcodeproj -scheme IkkokuCreator \
  -configuration Release -derivedDataPath .local/build-release \
  -destination 'platform=macOS,arch=arm64' ARCHS=arm64 build

# Private full Engine run: intentionally skip-tolerant for the two named limits.
python3 Tools/verification/run.py \
  --manifest .local/codex-renderer-maker-models-2026-10-23/integration/engine-release.json \
  --environment .local/codex-renderer-maker-models-2026-10-23/integration/environment.json \
  --report .local/verification/reports/claude-next-engine.json

# Shared-app launches are already wrapped with the machine lock in these manifests.
python3 Tools/verification/run.py \
  --manifest .local/codex-renderer-maker-models-2026-10-23/integration/maker-release.json \
  --environment .local/codex-renderer-maker-models-2026-10-23/integration/environment.json \
  --report .local/verification/reports/claude-next-maker.json --strict
python3 Tools/verification/run.py \
  --manifest .local/codex-renderer-maker-models-2026-10-23/integration/studio-release.json \
  --environment .local/codex-renderer-maker-models-2026-10-23/integration/environment.json \
  --report .local/verification/reports/claude-next-studio.json --strict

.local/reverse/unitypy-venv/bin/python -m unittest discover -s Tools/reverse -p 'test_*.py'
python3 -m unittest discover -s Tools/verification -p 'test_*.py'
```

Before rerunning app manifests, copy them and redirect their scenario report and
export paths as needed; changing only the runner's `--report` does not redirect
scenario-owned artifacts. Before benchmarks, stop other owned app/build/test/VM
work and use `Tools/verification/perf_trace.py` with the same fixtures, Release
configuration, warmup, duration and shared lock. The retained baseline executable
is under `baseline/Ikkoku.app`; it corresponds to `2aaee54`. Preserve it rather
than replacing it with a new build labeled baseline.

## Next concrete work: keep it to three tasks

These are recommended follow-ups, not work already started. Check current issues,
PRs and audit rows before claiming each scope. Keep performance measurement in
each task and validate combined behavior before merging.

1. **Renderer / R1, CMT-04:** choose one unresolved runtime-composite family and
   connect its native output to live material resolution. Alternatively, tackle
   one missing Studio global if independent source evidence is available first.
   Preserve all-or-nothing resolution and explicit fallback reasons. Prove exact
   source identity, measure added CPU/GPU/memory cost, and compare matched source
   pixels; do not broaden the claim from the frozen fixture to production scenes.
2. **Maker / CMT-02 with performance:** profile the remaining ~646 ms selection
   path, then remove the next measured cost or prepare candidates asynchronously.
   If asynchronous, reject stale/cancelled selections and commit only a fully
   validated candidate on the appropriate UI/resource queues. Preserve pending
   edits, UAR bytes, no-op identity and repeated-failure resource stability. The
   main-thread/SwiftUI phase-2 work in [performance](docs/reference/performance.md)
   remains relevant; avoid introducing another independent fourth task.
3. **Base model accuracy / R2, CM-14:** close production canine visibility against
   the card's `doubleTooth` flag using an original-player on/off control and a
   native rendered regression. The inspector's existing exclusion is not a runtime
   fix. Extend other neutral/animated variants only with independent source
   captures and unchanged numerical gates, not fitted hand phases.

Separate historical finding: `startup-mute-capture` binds source object 10 while
loading no scene, so the older app-smoke lane remains 6/7. Missing appearance and
managed-recovery fixtures are also not fixed by this wave. Do not misclassify
those findings as regressions from these three merged tasks or silently expand
this plan to cover them.
