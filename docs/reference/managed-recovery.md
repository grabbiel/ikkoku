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
