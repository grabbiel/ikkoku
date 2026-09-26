# Documentation

Current review: **2026-09-25**, working tree based on `2cfb859`, including uncommitted
implementation. Ikkoku is a partial Swift + Metal reconstruction with a separate
bundled prototype. The [component audit](component-audit/README.md) is the current
feature-status and implementation-backlog entry point. No whole-game completion
percentage or general mod compatibility is claimed.

## Start here

| Need | Read |
| --- | --- |
| Project overview | [Repository README](../README.md) |
| Contribute and collaborate through GitHub | [Contribution guide](../CONTRIBUTING.md) |
| Build, tests, captures and prerequisites | [Build and test](guides/build-and-test.md) |
| Maker, cards, Studio and source-mode limitations | [Using the app](guides/using-the-app.md) |
| Scan/mount a local mod library | [Mod library guide](guides/mod-library.md) |
| Locate code and understand data boundaries | [Architecture](architecture.md) |
| Resume implementation | [Audit and prioritized backlog](component-audit/README.md) |
| Recover/convert original data | [Source pipeline runbook](../Tools/reverse/README.md) |
| Regenerate bundled prototype assets | [Bundled asset runbook](../Tools/assets/README.md) |
| Run or extend reproducible verification lanes | [Verification lane runner](../Tools/verification/README.md) |

## Component audit

Each report contains specific review comments, per-feature stages, evidence limits,
and actionable tasks with acceptance criteria. Task IDs remain stable.

- [Character, Maker, cards and asset mods](component-audit/character-and-mods.md)
- [Studio, scenes, full-body IK, animation and voice](component-audit/studio.md)
- [Renderer, math, assets and GPU foundation](component-audit/renderer-and-foundation.md)
- [App, gameplay and plugin execution](component-audit/app-gameplay-and-plugins.md)
- [Recovery, build and verification tooling](component-audit/toolchain-and-verification.md)
- [Repository file coverage index](component-audit/file-index.md)

## Technical references

These pages document implemented contracts, source evidence, reproduction commands
and bounded gaps. They are not installation-independent asset packages: private
inputs and recorded measurements remain under `.local/`. Commands run from the
repository root unless a page says otherwise. A recorded result is not a new test
run; use the owning audit task to decide what still needs verification.

### Foundation and recovery

- [Native bundled asset contract](reference/native-assets.md)
- [Unity coordinates, renderer and matched-frame evidence](reference/renderer.md)
- [Managed assembly recovery](reference/managed-recovery.md)

### Character and Maker

- [Character Maker: recovered shape and persistence contracts](reference/character/contracts.md)
- [Character Maker rig recovery](reference/character/rigs.md)
- [Source head rig and clothed assembly](reference/character/head-rig.md)
- [Head-00 material inputs and preview bakes](reference/character/head-materials.md)
- [Source face shape destinations](reference/character/face-shape.md)
- [Body shape destinations](reference/character/body-shape.md)
- [Original normal male assembly](reference/character/male.md)
- [Original character cards and Extended Save](reference/character/cards.md)
- [Source card appearance recipes](reference/character/card-appearance.md)
- [Source head expression contract](reference/character/expressions.md)
- [Maker catalog asset library](reference/character/maker-assets.md)
- [Bounded Maker asset coverage](reference/character/maker-coverage.md)
- [Maker material expansion and Metal translation](reference/character/material-expansion.md)

### Animation and dynamics

- [Original animation playback: temporal expressions and dependency map](reference/animation/expression-playback.md)
- [Original Animator assets and generic clip playback](reference/animation/animator.md)
- [Source trigonometric IK kernel](reference/animation/trigonometric-ik.md)
- [Original hair dynamics](reference/animation/dynamics.md)
- [Independent DynamicBone verification](reference/animation/dynamics-parity.md)

### Studio

- [CharaStudio binary contracts recovered locally](reference/studio/binary-contracts.md)
- [Original CharaStudio item lookup](reference/studio/item-catalog.md)
- [Original Studio scene records](reference/studio/scene-records.md)
- [Recovered CharaStudio pose behavior](reference/studio/pose.md)
- [Original Studio animation playback](reference/studio/animation.md)
- [Studio full-body IK and original guide editing](reference/studio/full-body-ik.md)
- [Edited original Studio scenes](reference/studio/scene-editing.md)
- [Source Studio voice playback](reference/studio/voice.md)

### Gameplay

- [Source gameplay control-state recovery](reference/gameplay/cycle.md)
- [Fixed-event selection and bounded ADV execution](reference/gameplay/adv.md)

### Mods and plugin translation

- [Mod compatibility and source evidence](reference/mods/overview.md)
- [Source mod catalog and resolver contract](reference/mods/catalog.md)
- [Character-card mod references](reference/mods/card-references.md)
- [ABMX static bone modifier bridge](reference/mods/abmx.md)
- [C# AST and API substitution](reference/mods/api-substitution.md)
- [Translated plugin execution in Studio](reference/mods/plugin-execution.md)
- [Installed native plugin adapters](reference/mods/native-adapters.md)

## Historical records

The [archive index](archive/README.md) explains how to use the superseded
[prototype plan](archive/2026-09-09-plan.md),
[design research](archive/design-research.md),
[rebuild checkpoint](archive/2026-09-25-rebuild.md), and
[expansion checkpoint](archive/2026-09-25-expansion.md). Their earlier status claims
are preserved as historical evidence, not maintained support promises.

## Keeping documentation organized

- Put task-oriented instructions in `guides/`, source/data/runtime contracts in
  `reference/`, feature status and actionable work in `component-audit/`, and dated
  superseded plans or checkpoints in `archive/`. Tool-specific runbooks stay beside
  their tools and link here.
- Update a feature's reference and audit row together. Name the supported data,
  execution path, UI availability, test fixture and remaining exclusions. Distinguish
  parsed/preserved data, executable kernels and measured original-player parity.
- Keep local evidence private; document paths, hashes and scope without copying
  recovered original code or assets into Markdown. Retain dates on old measurements.
- Link repository files relatively within Markdown, update links after moves and
  add new pages here. Refresh the file coverage index when repository files change.
  Old top-level `PLAN`, `RESEARCH`, `REBUILD`, `ASSET_SPEC`, `reverse-*` and mod notes
  have been placed in the folders above; use these maintained paths.
