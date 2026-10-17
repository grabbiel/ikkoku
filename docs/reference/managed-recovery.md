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
