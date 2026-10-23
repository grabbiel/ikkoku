# Managed game and Studio recovery

Reviewed 2026-09-25. Commands run from the repository root. The observed installed
game uses Mono. `Tools/reverse/analysis/recover_managed.py` now
recovers complete project exports, IL and metadata tables from five selected
first-party assemblies. It reads copied DLLs without executing them. Original
binaries, recovered code and evidence remain under ignored `.local/reverse/`.

## Recorded recovery coverage

| Assembly | Project C# files | Compatibility type overrides |
| --- | ---: | ---: |
| Main game `Assembly-CSharp.dll` | 2,026 | 9 |
| CharaStudio `Assembly-CSharp.dll` | 2,026 | 9 |
| Shared `Assembly-CSharp-firstpass.dll` | 929 | 2 |
| Main game `Assembly-UnityScript.dll` | 3 | 0 |
| CharaStudio `Assembly-UnityScript.dll` | 3 | 0 |

These 4,987 files include substantial duplication between players; they are not
4,987 unique gameplay systems. Each assembly also has a complete IL export and
`TypeDef`, `MethodDef`, `AssemblyRef` and `TypeRef` JSON tables. All referenced
assembly names resolve in the copied main-player Managed directory. The shared
firstpass DLL has the same inventoried hash in the main, Studio and VR players.
The VR-specific main assembly and arbitrary mod plug-ins are outside this pass.

ILSpy 11.1.0.9782 failed on some method-group disambiguations. Whole-project output
from ILSpy 9.1.0.7988 instead overflowed on unrelated types. The pipeline retains
the primary project and uses version 9 only for the types named in the primary
failure log. Generic types resolve through metadata names including their arity.
All 20 selected type overrides succeeded without detected error stubs. Original
error comments and logs remain available as evidence of the primary attempt.

**Read the primary project together with its manifest's `typeOverrides`.** The
overrides replace the affected types for analysis; the primary files are not
silently rewritten. Older partial generations remain preserved. `recovered`
means these exports and fallback checks succeeded. It does not certify that the
C# recompiles, every decompiler expression is correct, or behavior has been
translated into Swift.

## Reproduction and integrity

Use `vm_source.py fetch` to copy explicit Managed files first. Every selected
input must match a hash in `.local/reverse/inventory.json`; the reference folder
contains the 26 main-player DLLs. Install the two local tool versions:

```sh
dotnet tool install ilspycmd --version 11.1.0.9782 --tool-path .local/reverse/tools
dotnet tool install ilspycmd --version 9.1.0.7988 \
  --allow-roll-forward --tool-path .local/reverse/tools-compat
python3 Tools/reverse/analysis/recover_managed.py \
  --fallback-tool .local/reverse/tools-compat/ilspycmd \
  --assembly .local/reverse/source/Koikatu_Data/Managed/Assembly-CSharp.dll \
  --assembly .local/reverse/managed/CharaStudio/Assembly-CSharp.dll \
  --assembly .local/reverse/source/Koikatu_Data/Managed/Assembly-CSharp-firstpass.dll \
  --assembly .local/reverse/source/Koikatu_Data/Managed/Assembly-UnityScript.dll \
  --assembly .local/reverse/source/CharaStudio_Data/Managed/Assembly-UnityScript.dll
```

The Studio input above is the already-verified earlier copy; a fresh explicit
fetch can instead use `source/CharaStudio_Data/Managed/Assembly-CSharp.dll`.
Tools require compatible .NET runtimes; this workstation used .NET 10 with the
fallback tool's roll-forward option.

Output is restricted to repository `.local`. Generations are keyed by the source
hash, converter version, decompiler versions, time limit and every reference DLL
hash. Work is staged before publication. Reuse checks the identity, path
containment, exact file set, lengths and SHA-256 hashes; altered generations fail
instead of being accepted as fresh evidence. Each invocation updates `index.json`
with its selected assemblies. The local `verification.json` records a separate
integrity check of all five completed generations.

Manifests preserve command exits/timeouts, namespace inventories, reference
availability, primary errors, type overrides, and per-file provenance. A failed
project/override, IL export or metadata command produces partial status or an
explicit error. Error stubs detected in C# also force partial status, even after
exit zero, unless that source file is covered by a successful clean type override.
Seventeen synthetic regression tests check these failure paths, generic type
resolution, source inventory matching and cache integrity. Reference availability
is a filename check, not proof that a
Unity API implementation has a native equivalent.

## Consuming recovered source

Since E-T02 (2026-10-23), contract generators read these generations only
through `Tools/reverse/analysis/recovered_source.py`.
`RecoveredAssembly(index, source_path=…)` or `RecoveredAssembly(index, sha256=…)`
selects an assembly's generation from `index.json`, not from a directory glob.
It also checks that the index agrees with that generation's `manifest.json`
identity and selected project. `source(type_name)` then resolves one type:

- A type with a recorded `typeOverrides` entry uses that fallback file. The name
  may be the exact metadata name or an unambiguous name without generic arity.
  The fallback is used only if its command exited 0, did not time out and has no
  error stub. Otherwise the request fails; it never reverts to the primary file.
- Any other type comes from the manifest-selected project, at
  `project/<dotted namespace>/<Type>.cs`. This is the same layout
  `recover_managed.py` uses when an override supersedes a primary file. A nested
  namespace directory is also accepted, but not if both layouts exist.
- The returned file must stay inside the generation, appear in the manifest
  inventory and match its recorded size and SHA-256. It must contain no
  stub marker and have no recorded decompiler diagnostic.

Refusals are named `ValueError` subclasses:

| Exception | Raised when |
| --- | --- |
| `RecoveredErrorStub` | The chosen file has a stub marker or recorded diagnostic, or is empty; the fallback is unclean; or the primary failure log names the type but no fallback is recorded |
| `MissingRecoveredSource` | The index lists no such assembly, or the manifest records no file for the type |
| `RecoveredHashMismatch` | A file, manifest identity or (with `verify_assembly()`) original DLL differs from its record; or a file is unrecorded, missing or outside the generation |
| `AmbiguousRecoveredSource` | The index lists two generations for one assembly, two fallbacks share one arity-free name, or both namespace layouts exist |
| `RecoveryManifestError` | The index or manifest is unreadable or inconsistent, or the recovery selected no project |

Stub markers come from `recover_managed.py`'s `ERROR_STUB`, the same definition
that sets recovery status. The resolver adds no new heuristic.

| Consumer | Assembly | Previous lookup |
| --- | --- | --- |
| `analysis/gameplay_execution_contract.py`, `analysis/adv_command_coverage.py` | Main game | Own helper checked only `Error decompiling` and `throw new NotImplementedException`; the second check remains as a consumer-specific refusal. ADV handler lookup treats only stubbed types as existing; hash, ambiguity and manifest errors now propagate |
| `analysis/trigonometric_ik_contract.py` | Firstpass | Own override lookup checked only `Error decompiling` |
| `analysis/body_shape_contract.py` | Main game | `--source` accepted any directory. `--recovery-index` replaces it; the generator still requires `recovered` status and the DLL hash |
| `analysis/card_roundtrip.py` | Both pinned hashes | Took the first sorted generation directory for each hash and ignored the index |
| `analysis/studio_fullbody_oracle.py` | Firstpass | `--recovered-project` copied files from any directory. `--recovery-index` replaces it; nothing is copied if any of the 14 files is refused |
| `dynamics_contract.py` | Main game | Read `assemblies[0]` and its `project/` directory directly |
| `analysis/studio_animation_contract.py` | CharaStudio | `--source` hashed four files from any directory. `--recovery-index` replaces it |
| `test_male_body_parity.py` | Main game | Read `ShapeHeadInfoFemale.cs` from the narrow `decompiled/Character/Koikatu` tree; `--recovery-index` is new |

For valid inputs these consumers record the same paths, hashes and text as before.
The last two moved after the private rerun below showed byte-identical output.
This assumes the main game's `Assembly-CSharp.dll` is the first indexed assembly,
as in the recovery command above. `Tools/translation/translate.py` translates an
explicitly supplied C# file and does not read the manifest. It now refuses any
source with these stub markers before building or writing anything. Its
`plugin.py` caller therefore applies the same refusal to the plugin types it
decompiles.

**Consumers not moved.** These generators predate the complete recovery. They
read narrow ILSpy `-t` decompilations under `.local/reverse/decompiled/`, or an
explicit `--source`/`--source-root` directory. Those decompilations have no
primary/fallback split and their manifests use other schemas; only
`decompile_studio.py` is checked in. Moving them would change the text they
parse and the evidence they record. That requires a private rerun to confirm the
contracts are unchanged. None of them refuses stub markers today
(`gameplay_contract.py` records a count of `Error decompiling`). If one is
pointed at a primary project directory, a stub can still reach it.

- Game types: `analysis/character_contracts.py`,
  `analysis/expression_contract.py`, `analysis/animation_playback_contract.py`,
  `analysis/card_contract.py`, `analysis/gameplay_contract.py`,
  `analysis/studio_scene_contract.py`, `analysis/studio_pose_contract.py`,
  `analysis/mod_catalog_contract.py` (`ChaControl` and copied game types),
  `clothed_material_contract.py` and the parity scripts
  `test_face_rig_parity.py` and `test_avatar_parity.py`.
- Plugin and mod sources outside the five recovered assemblies:
  `analysis/abmx_contract.py`, `analysis/resolver_contract.py`, the Sideloader
  part of `analysis/mod_catalog_contract.py`,
  `analysis/accessory_names_oracle.py`, `analysis/mute_plugin_oracle.py`, and the
  ExtendedSave sources in `card_contract.py` and `studio_scene_contract.py`.

**Private rerun (2026-10-23).** On the reference Mac, each game-type generator
first ran on its current input. It then ran again with its inputs resolved
through `recovered_source.py`. A generator moved only when the two runs wrote
byte-identical output. The run used the private five-assembly generations, at
`claude/local-wave-verify` `5c24bb9`. All 13 first runs exited 0. Their
contracts matched the recorded ones apart from the run's own paths (worktree
and output locations). Two outputs also differed for other reasons. `clothed_material_contract.py` omits the
VM-only shader disassembly. The parity reports name a newer native inspector and
regenerated avatar files.

Two generators moved: `studio_animation_contract.py` records only file names and
hashes, and the `test_male_body_parity.py` report records no source path. The
rest stayed, for one of two reasons:

- **Same input bytes, but the output records where each source was read.** The
  resolver run differed only in those paths:
  - `character_contracts.py`: three source paths;
  - `expression_contract.py`: `decompiledManifest`, `chaControl` and
    `chaReference`, so the reference file's `contractSHA256` changes with them;
  - `animation_playback_contract.py`: the `file` of 9 contract entries and 15
    dependency-inventory entries (`reference.json` is unchanged);
  - `clothed_material_contract.py`: two `sourceEvidence` paths;
  - `test_avatar_parity.py`: five `assemblyEvidence` paths.

  `test_face_rig_parity.py` also requires its setter file to be one the shape
  contract records. It therefore refuses the recovered path until
  `character_contracts.py` moves. Against a shape contract regenerated through
  the resolver, it passes and records the new paths. Moving any of these
  generators changes its output bytes and every recorded hash of that output.
- **Different input bytes.** The narrow files were decompiled without the full
  reference set. ILSpy therefore wrote extra casts, `//IL_…` comments and
  expanded auto-properties. These contracts record each input's SHA-256, so
  their output cannot be byte-identical:
  - `card_contract.py`: `PngFile`, plus the ExtendedSave and PluginData sources
    outside the recovery;
  - `gameplay_contract.py`: 9 of its 11 sources, plus a 0-byte
    `ActionGame.PlayerAction.cs` with no recovered type;
  - `studio_scene_contract.py`: `CameraControl` and `CameraLightCtrl`, plus
    ExtendedSave;
  - `studio_pose_contract.py`: `OCIRoute`;
  - `mod_catalog_contract.py`: `ChaFileClothes`, `AssetBundleManager` and
    `CustomSelectListCtrl`. `Illusion.Utils.Value` has no recovered type, and
    Sideloader is outside the recovery.

  Fed resolver bytes, `gameplay_contract.py` still produced the same 264 cases
  and 454 steps, and `mod_catalog_contract.py` the same catalog. Only their
  source evidence changed (paths, hashes and anchor line numbers).

Sixteen synthetic tests in `Tools/reverse/analysis/test_recovered_source.py`
cover the resolver. They build each generation with the real
`recover_managed.recover()` and a fake decompiler, then check:

- the indexed project wins over another generation of the same assembly;
- a clean fallback replaces only its failed type;
- a primary stub is refused with or without a fallback;
- unclean fallbacks never revert to the primary;
- hash, missing, ambiguous and manifest errors fail by name.

Four of these tests run real generators. `trigonometric_ik_contract.evidence`
refuses a `// System.…Exception:` primary stub that its earlier check accepted.
`card_roundtrip.managed_evidence` uses the indexed generation rather than a stale
generation that sorts first. `studio_fullbody_oracle.copy_sources` copies nothing
when one file is a stub. `studio_animation_contract.contract` refuses a stubbed
Studio type, and otherwise hashes the recorded bytes under the same keys as
before. These tests use synthetic trees only. The private rerun covered only the two
consumers it moved, not the six moved earlier.

## Independent REA check — 2026-10-17

At repository base `d671aee`, REA **6.5.0** independently inspected the five
retained DLLs using its execution-free `rea-dotnet-static` provider. All five
were classified as Unity Mono CIL with complete metadata coverage. Their source
hashes match the installation inventory and the recovery manifests; REA's
`TypeDef`, `MethodDef`, `TypeRef` and `AssemblyRef` counts match the corresponding
ILSpy tables. The game and Studio main DLLs have different hashes and MVIDs even
though their four recorded table counts agree: they are separate inputs.

| Input | SHA-256 | TypeDef / MethodDef | Verified retained files | Selected methods cross-checked |
| --- | --- | ---: | ---: | ---: |
| Game CSharp | `0038281caf8df48a7903c55dc389642eeeb3f2a9114bd9d68ac11c8ac0396bc5` | 4,581 / 31,220 | 2,058 | 105 |
| Studio CSharp | `902b9a237337b17a64514bdb0d857b460ece4fb6a57c658375dd32c5fa504c45` | 4,581 / 31,220 | 2,058 | 115 |
| Shared firstpass | `ca572fff8740bbcd58d549723c80b0088d6676611eae2ab91624f460739aea10` | 1,620 / 7,451 | 947 | 38 |
| Game UnityScript | `577f3c430705b0012b56bebc0511e81c495111a9e50b6ca56015fab3ae943766` | 3 / 18 | 17 | 18 |
| Studio UnityScript | `9ce7621ac1e6f586a83a2c0a4a8904a3a7a269372e291496667d4d6ca06bcade` | 3 / 18 | 17 | 18 |

Re-running the recovery command above reused all five generations after the
existing integrity checks: **5,097 retained files**, including the **4,987 C#
project files**, passed exact file-set, length and SHA-256 checks. All **26**
reference DLL hashes still match their manifest identities. The **20** fallback
type exports retain successful commands and no detected error stubs; unresolved
decompiler diagnostics remain zero. The recovery regression suite executed
**17 tests, all passing**, with no skipped cases:

```sh
python3 -m unittest discover -s Tools/reverse -p 'test_recover_managed.py'
```

REA member inspection also cross-checked **294** selected method tokens, names
and RVAs against ILSpy's retained `MethodDef` rows; every selected method has a
file-backed CIL body. Selection was `ADV.Program` and `ActionGame.Cycle` in the
game, `Studio.OCIChar` and `Studio.SceneInfo` in Studio,
`RootMotion.FinalIK.IKSolverFullBody` and `RootMotion.FinalIK.IKSolverTrigonometric`
in firstpass, and all methods in both small UnityScript assemblies. Coverage is
complete for these selections, not for every method's behavior. In particular,
`ADV.Program` still requires its documented fallback C# export.

The complete private records and local cross-check are under
`.local/rea-audit-2026-10-17/`: `integrity-report.json`, `cross_check.py`,
`recovery-reuse.json` (one JSON record per line), `recovery-tests.log`, and the
REA `*-artifact.json` / `*-members.json` files. `firstpass-ik-members.json` is
the successful firstpass selection; the earlier `firstpass-members.json`
explicitly reports an unmatched `DynamicBone` selection and supports no member
coverage claim. These files, DLLs and recovered source remain uncommitted.

| Input | REA artifact Evidence ID | REA selected-member Evidence ID |
| --- | --- | --- |
| Game CSharp | `ev_7b717e04a2da835b9595cd7f44a17ff58edecadae885cd6f6da2ea6c66e5bd7f` | `ev_575a067e6059ff61d27c57410b1b8f9e898a9115c76e7b25b61dfb4762c550d6` |
| Studio CSharp | `ev_8149a2c85887d082e17faee67384e092c627a6ac854d1b85c59a52a2b7ecd08b` | `ev_9f8da1d0633a47c6d8dd4e6cada806e77d8e0c32512e0b058a727099a18d3685` |
| Shared firstpass | `ev_833191b4737590bba02b05d368444cc3710302fe96749996cf3100a38be506c6` | `ev_7b90a3d977b46786c388410be05735452e3969ac1b9193e1e90d76a7cf4c76e3` |
| Game UnityScript | `ev_c21ef3405075a6c52a32abd135e4139e4d110238cc36fca4d418ee09661da26d` | `ev_743cd742a78ad3338e1e7a466fc4a5bd389470f1d647f5d84007c41d9e52b16c` |
| Studio UnityScript | `ev_218cbd36f6ddc40a661431fe1b43b4ddcfc557cedf370ea13d30e7216f2169f6` | `ev_d7c09b7dd42933e9add9bad71dd2354703e440af0556990314fd5027c22531e9` |

To reproduce the independent inspection, run the pinned CLI against each input
in the recovery command above, saving its complete JSON under `.local/`. For
example:

```sh
mkdir -p .local/rea-audit
npx -y rea-agents@6.5.0 inspect-managed-artifact \
  .local/reverse/managed/CharaStudio/Assembly-CSharp.dll --json \
  > .local/rea-audit/studio-artifact.json
npx -y rea-agents@6.5.0 inspect-managed-members \
  .local/reverse/managed/CharaStudio/Assembly-CSharp.dll \
  --type Studio.OCIChar --type Studio.SceneInfo --json \
  > .local/rea-audit/studio-members.json
```

Use the artifact digest and MVID when interpreting tokens. Check
`normalized_result.metadata.status`, table counts,
`normalized_result.coverage` and `selection.unmatched_type_names` before using
member rows; an omitted type selection is represented by `selection: null`.
The CLI does not require MCP registration or Hopper/Ghidra for these managed
operations. This run used the CLI because REA was not connected to the active
client; no client configuration or analysis engine was changed.

**Conclusion:** the retained five-assembly recovery is intact and independently
corroborated as usable static evidence. This did not recompile the C#, prove the
semantics of every recovered expression, execute the original player, or verify
native feature parity. VR-specific code, arbitrary plugins, launcher/native
engine internals, serialized assets and whole-game behavior remain outside this
check. The renderer, dynamics and Animator failures recorded in their owning
references remain open; successful recovery does not close them.

## Native translations built from this evidence

The current [app/gameplay/plugin audit](../component-audit/app-gameplay-and-plugins.md)
and [Studio audit](../component-audit/studio.md) separate executable subsets from
full-system support. Recovery completion is not port completion.


- [Gameplay](gameplay/cycle.md): day/period progression and action-clock state,
  with explicit effects owed to scene, NPC, ADV and save systems.
- [Animation](animation/expression-playback.md): temporal blinking and expression
  timers; automatic blinking is connected to Maker.
- [Studio](studio/pose.md): FK target binding, FK/IK activation and rotation evaluation;
  [full-body IK](studio/full-body-ik.md) has a bounded recovered-source oracle.
- [Animator](animation/animator.md) and [Studio animation](studio/animation.md):
  selected serialized controller/clip consumers with original-player sample checks.
- [ADV](gameplay/adv.md): fixed-event selection and a bounded command interpreter;
  the recorded original scenario still stops on an unsupported command.
- [API substitution](mods/api-substitution.md): a strict Roslyn/IR subset and
  [native adapters](mods/native-adapters.md) for two exact installed plugin versions.

Complete managed exports make the remaining code available for analysis. They
do not recover serialized Animator graphs, motion clips, scenario data, navigation
or scene assets by themselves. Those data and their native runtime consumers are
still necessary for playable gameplay and full Studio parity.
