# Handoff: local-environment verification (2026-10-23)

For an agent or developer working in a local checkout on the reference Mac: Xcode
26, the private `.local/` data and the Parallels VM. A cloud session wrote this
file after merging PRs #104–#110 and #112–#124. That session had no Swift
toolchain, Mac or private data. GitHub Actions on macOS runners was the only
compile and test run for all of that work: **nothing in it has been compiled
locally or run in the app.** `main` was at `235b41c` when this was written.

The work below needs this machine. The audit README's
[2026-10-23 wave summary](docs/component-audit/README.md) says what each PR
changed.

## How to use this file

1. Read [CONTRIBUTING.md](CONTRIBUTING.md) and the
   [component audit](docs/component-audit/README.md) first.
2. Take tasks in order. Claim one by setting its row in the
   [status table](#status) to `claimed (<branch>)`, in the first commit of your
   branch.
3. Record evidence where the repository keeps it, not here:
   - tick an audit README checklist item only when every claim in it passed,
     and say how it was checked;
   - update the owning audit rows and reference docs, never promoting status
     beyond what was run;
   - keep private evidence under `.local/`.
4. A failure is a finding: record the command, the output and the commit. Fix it
   in a focused PR with the audit task ID, or record it as open work. Never
   weaken a check, skip a test or relax a validator to get a pass.
5. Set the row to `done (#PR)` when its PR merges. The PR that closes the last
   row deletes this file, its row in
   [docs/component-audit/file-index.md](docs/component-audit/file-index.md) and
   the pointer in the audit README.

Leave other sessions' open work alone: PR #125 (`claude/stc03b-clothes-state`)
and PR #127 (`claude/r1-live-b`).

## Setup

```sh
git switch main && git pull --ff-only
python3 Tools/verification/doctor.py --require public --require app-build --verbose
xcodebuild -project Ikkoku.xcodeproj -scheme IkkokuCreator \
  -configuration Debug -derivedDataPath .local/build \
  -destination 'platform=macOS,arch=arm64' build
APP=.local/build/Build/Products/Debug/Ikkoku.app/Contents/MacOS/Ikkoku
```

The private lanes read `.local/verification/environment.json`. Its keys are
listed in
[Tools/verification/environment.example.json](Tools/verification/environment.example.json).
Run every command from the repository root.

Since this wave, three things behave differently from what older local notes
assume:
- **A06 (#118):** startup rejects an inconsistent `IKKOKU_*` environment, and
  exits 1 printing `invalid capture request` with the offending variables. In an
  automated run, a capture input that fails exits 1 as
  `capture input failed: IKKOKU_X=…`.
- **A-T02 (#122):** automated runs ignore a converted library saved through
  File → Choose Converted Library. Interactive launches use it. A scene saved
  since #122 blocks any object whose referenced file is missing or changed.
- **T-T02 (#120):** `IKKOKU_SOURCE_TREE_FALLBACKS=0` turns off the
  checkout-relative assets, Maker library and original bases. Release bundles no
  longer contain `Contents/Resources/Engine/`.

## Tasks

### L1: app checks

Run the seven unticked items at the end of the 2026-10-23 wave in
[docs/component-audit/README.md](docs/component-audit/README.md). The item
texts there are the acceptance criteria. The commands are in the
[build guide](docs/guides/build-and-test.md).

| Item | PR | Where the commands are |
| --- | --- | --- |
| A-T05 capture integrity | #109 | build guide, "Offscreen and UI captures" |
| R4 app paths | #110 | interactive: a degenerate IK target, and a camera under a mirrored parent |
| R4 IK fix | #115 | interactive: drag a native IK handle |
| A06 capture validation | #118 | build guide, "Capture request validation" |
| T-T02 packaged app | #120 | build guide, "Package and inspect a Release build", then open the project in Xcode once |
| A-T01 gameplay lane | #121 | build guide, "Gameplay host scenario" (`gameplay-scenarios`, `--strict`) |
| A-T02 relocation | #122 | build guide, "Use a converted library outside the checkout" |

For the A-T02 check, choose the converted library interactively. For the T-T02
check, confirm that the Xcode navigator still shows `Packages/` and that the
Engine package resolves. #120's one-line project change has not been opened in
Xcode.

### L2: lanes

```sh
for lane in app-smoke maker maker-scenarios studio-scenarios private-source gameplay-scenarios; do
  python3 Tools/verification/run.py --manifest Tools/verification/lanes/$lane.json \
    --environment .local/verification/environment.json --strict
done
```

A06 changed `app-smoke`'s `startup-mute-capture` check. On `main` before #118
that check could only time out. It now ends with an `IKKOKU_AUTOCAPTURE` PNG.
Report the per-lane counts (executed, passed, failed, skipped) in the audit
rows that own them.

### L3: A-T04 Studio execution probe rerun

Rerun the release probe with both original adapter manifests. The command is in
[native adapters](docs/reference/mods/native-adapters.md#startup-and-acceptance),
on a Release build. Use a new output folder, such as
`.local/reverse/plugin-execution/native-adapter-capture-03`. The accepted
evidence from PR #2 is in `.local/reverse/plugin-execution/accepted-pr-2/`.

If its private `capture-environment.json` holds a capture option, such as
`IKKOKU_CAPTURE_YAW`, the scene-capture phases now exit 1 with
`invalid capture request`. Remove the option from that file instead of changing
the validator.

### L4: T-T01 prerequisite versions

[Tools/verification/prerequisites.json](Tools/verification/prerequisites.json)
records versions for most tools. These are only checked for presence:
- the Metal compiler;
- the public `python3`;
- the asset numpy and Pillow;
- Parallels `prlctl`;
- the host macOS version.

Record their versions from `doctor.py --verbose` on this Mac. If the format
needs it, extend `doctor-samples.json` and `test_doctor.py`, then run
`python3 -m unittest discover -s Tools/verification -p 'test_*.py'`. See the T06
row and T-T01 in
[toolchain-and-verification.md](docs/component-audit/toolchain-and-verification.md).

### L5: E-T02 private rerun

Some generators still read narrow `.local/reverse/decompiled/` trees. They are
listed under "Consumers not moved" in
[managed recovery](docs/reference/managed-recovery.md).
1. Rerun each one on its current input.
2. Rerun it through `Tools/reverse/analysis/recovered_source.py`.
3. Move a generator only when the two outputs are byte-identical.

Record which ones moved and why the rest did not (E03 row, E-T02).

### L6: texture-loader stall in the Engine suite

`CharacterLifetimeTests` (#124) draws untextured characters. With the bundled
textured characters, each test passed on CI when run alone (17 s and 6.6 s). In
the full parallel suite, both stopped at their first synchronous
`MTKTextureLoader` load until the lane's 600 s timeout. The cause was not
isolated.
- Reproduce with the textured version:
  `git show dbb62d2^:Packages/Engine/Tests/EngineTests/CharacterLifetimeTests.swift`.
- Run `swift test --package-path Packages/Engine`, with and without
  `--no-parallel`.
- If engine texture loading can deadlock off the main thread, fix it in a
  focused PR (R6).

### L7: branch cleanup

This needs push rights; the cloud session's proxy refused branch deletion.

- Delete `claude/r6-character-lifetime-diag`. It is unmerged and holds a
  temporary `ci.yml` rewrite. Never merge it.
- Delete these branches, which are fully merged into `main` (the A-T01 one by
  squash, as #121). Keep `claude/determined-hopper-in4slx`, the cloud session's
  branch.

  ```
  claude/a06-capture-inputs claude/at01-gameplay-host claude/at02-portable-library
  claude/at05-capture-integrity claude/audit-handoff-refresh claude/audit-refresh-after-pr2
  claude/camera-object-capture claude/ci-public-lane claude/ci-reverse-tools
  claude/et02-recovery-resolver claude/gt01-deferred-effect-host claude/gt03-adv-coverage
  claude/gt03b-adv-host-requests claude/item-color-mask-finding claude/native-walk-full-trs
  claude/post-merge-integration-checklist claude/probe-robustness claude/pt02-plugin-library
  claude/pt04-ir-fuzz-rollback claude/r1-live-bindings claude/r1-source-normal-magnitude
  claude/r4-ik-lower-bone-fix claude/r4-math-contracts claude/r4-runtime-callers
  claude/r5-gltf-interchange claude/r5-package-containment claude/r6-character-lifetime
  claude/r6-renderer-limits claude/stc03-outfit-select claude/tt01-dev-environment
  claude/tt02-release-packaging claude/vm-fixture-scenes
  ```

  Recheck each one first with `git branch -r --merged origin/main`, or for the
  squash-merged branch, by finding its merged PR.
- Optional, for the repository owner: enable "Automatically delete head
  branches" in the repository settings.

## Status

| Task | Status |
| --- | --- |
| L1 app checks | partial: A-T01 ticked (#133). The user ticked T-T02, A-T02, R4 #115 and R4 #110 by hand on 2026-10-23 (main `c9df5df`). A-T05 and A06 stay open on `app-smoke` 6/7 (`startup-mute-capture` binds source object 10 but loads no scene) |
| L2 lanes | done (#133): counts in `Tools/verification/README.md`. Open findings: `startup-mute-capture`; the appearance root exceeds the runner's tree bounds; no managed recovery export; `maker_roundtrip.py` argv |
| L3 A-T04 probe rerun | done (#132): `native-adapter-capture-04`, both configs exit 0, 89/89 compared |
| L4 T-T01 versions | done (#133) |
| L5 E-T02 rerun | done (#133) |
| L6 texture-loader stall | done (#133): not reproduced in six local runs |
| L7 branch cleanup | done (orchestrator, 2026-10-23: rechecked against origin/main and each branch's merged PR, then deleted the 32 listed merged claude/* branches and the unmerged claude/r6-character-lifetime-diag; its two TEMP commits are kept privately as patches) |

## Local continuation: three-task integration (2026-10-23)

Claude's performance, source-expression and selected-skirt work is continued on
local branch `codex/continue-claude-2026-10-23`, based on `main` `2f29e27`.
The original Claude worktrees and their changes were preserved; work used three
separate managed checkouts. `main` was unchanged during implementation; the
user has authorized publishing and merging this integration through a PR.
No additional system permissions were needed for builds, tests or visible app
interaction.

- **Performance phase 1:** cached rig/path/animation bindings and pose evaluation
  avoid repeated solves. Integration fixes preserve current neck/gaze state on
  checkpoint restore, reject obsolete shape baselines and retain explicit
  animation-error semantics. A fresh equivalent-output control reduces source
  simulation p50 from 22.502 ms to 5.353 ms (76.2%, 4.2×), with native, Maker
  and Studio PNGs byte-identical. The full integration measures 5.123 ms while
  rendering seven rather than six characters because of a corrected eye-row
  mapping. [Evidence and limits](docs/reference/performance.md#combined-integration-acceptance-2026-10-23).
- **ST-C04 expressions:** all eleven face-state fields are editable, validated
  and preserved through undo/reset, native load and original export. Actual
  inspector interaction and 83/6/8 scenario steps pass; the original player
  accepts 308/308 serialized-field claims. Unsupported tears, cheek, gag-eye
  side effects, transitions and voice-driven mouth behavior remain explicit.
  [Contract](docs/reference/studio/scene-editing.md#source-face-state-editing-st-c04).
- **ST-T08e selected skirts:** schema-2 garment identity binding, activity/FK
  gating, outfit rebuilds and checkpoints pass the independent 960-frame oracle
  and 31/6 save/load scenario steps. This supports selected converted garments;
  virtual ends, broader cloth coverage and original-player skirt parity remain
  open. [Scope and timing](docs/reference/animation/dynamics.md#selected-skirt-and-garment-root-dynamics-st-t08e).

Final runtime `dffc9df` builds in Debug and Release. Scenario-only `83cb84b`
corrects the skirt fixture's unavailable clip by selecting converted T-pose
`[0,0,0]` and freezing speed to zero; test-only `c5822a8` checks eye row 30 →
FBS 21 and the gag-eye diagnostic. Full Release Engine/CoreMath results are
736 executed passes, 0 failures and 3 named optional skips. Python verification
and focused reverse-tool suites pass 180 + 56 tests. Studio has passing evidence
for all 52 unique scenarios: 51/52 in the full run, then 2/2 for the corrected
skirt pair, with thresholds unchanged. Maker passes 4/4 and gameplay 1/1.
[Lane details](Tools/verification/README.md#combined-local-continuation-2026-10-23).

**Next performance work:** interactive main-thread/SwiftUI scheduling. Final
source idle presents 119.8 FPS; orbit presents 48.1 FPS with 30.4 hitches/s and
866 ms/s spent outside measured model/draw work. The existing phase-2 plan in
the performance reference remains open. **L1 remains open:** startup-Mute's
fixture profile binds object 10 while its check loads no scene. The isolated
Release-build retry passed after a DerivedData contention failure; app-smoke
therefore retains only that known fixture failure. Missing optional appearance
and managed-recovery fixtures are not fixed by this continuation.

Private evidence is centralized under `.local/codex-resume-2026-10-23/` in the
primary checkout, with lane reports under `.local/verification/reports/`.
The correct reverse-tool Python is `.local/reverse/unitypy-venv/bin/python`;
`.local/reverse/venv/bin/python` lacks NumPy. Keep app launches serialized under
the existing machine app lock, and pause other task builds/tests/VM work for
performance measurements. Do not terminate another session's processes.
