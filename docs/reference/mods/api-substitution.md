# C# AST and API substitution

Reviewed 2026-09-25. The semantic frontend, generated Swift and Studio IR runtime
implement an explicit **mid-stage subset**. General installed-plugin rewriting
is still in its infancy. See the [plugin audit](../../component-audit/app-gameplay-and-plugins.md)
(P01–17, P-T01/02/04/05) for missing APIs and acceptance criteria. This contract
covers translation; [packaging and Studio execution](plugin-execution.md) and
[exact installed behavior adapters](native-adapters.md) are separate layers.

`Tools/translation/translate.py` implements a bounded C# → Roslyn semantic AST →
localized JSON IR → Swift path. It uses the installed .NET SDK's Roslyn assemblies
without NuGet packages. Parsing and symbol resolution precede substitution; a
similarly named user method is not mistaken for a Unity API.

The generated Swift imports the `Gameplay` module. The native bridge is
`Packages/Engine/Sources/Gameplay/SourceTranslatedBehaviour.swift`. It exposes
explicit object, transform and world protocols so a scene adapter can retain
entity/asset identities and implement world versus local coordinates. It does
not implicitly load a plug-in. `SourceIRProgram`, `SourcePluginRuntime` and
`SourceStudioPluginSession` execute accepted IR in Studio after an explicit
profile load. This interprets typed data and never loads a Windows DLL.

## Running

Run these commands from the repository root with the local .NET SDK available.

```sh
python3 Tools/translation/translate.py path/to/source.cs \
  --type Example.Component --component \
  --plugin-guid 'Example.Author.Plugin' \
  --assembly path/to/Original.dll \
  --output .local/reverse/api-substitution/example

python3 Tools/translation/translate.py \
  .local/reverse/decompiled/Expressions/MathfEx.cs \
  --type MathfEx --methods LerpAccel LerpBrake \
  --assembly .local/reverse/source/Koikatu_Data/Managed/Assembly-CSharp.dll \
  --output .local/reverse/api-substitution/mathfex

python3 -m unittest discover -s Tools/translation/tests -v
```

The output is `translation.json` plus `Translated.swift` when accepted. Rejected
input returns exit status 2 and source-located diagnostics. A previous generated
Swift file in that output directory is removed before another attempt, so a
rejection cannot leave an older translation masquerading as the current one.
Recovered source, translations and original-DLL validation remain in `.local/`.

## Supported subset

A component must directly inherit the declaration-only `UnityEngine.MonoBehaviour`
or `BepInEx.BaseUnityPlugin` surface. All members must be understood; unsupported
members reject the entire component. Utility mode selects explicitly named, non-overloaded static methods.
Unselected utility methods are not translated; their unresolved types still
produce semantic diagnostics.

| Source construct | Native representation |
| --- | --- |
| `Awake`, `OnEnable`, `Start`, `FixedUpdate`, `Update`, `LateUpdate`, `OnDisable`, `OnDestroy` | Typed native lifecycle callbacks |
| Float/double/bool/int/string/Vector3 state | Swift Float/Double/Bool/Int32/String/SIMD3 values; supported types do not imply all operators |
| Initialized local variables, blocks, `if`, `return` | Structured IR and Swift control flow |
| Float/vector arithmetic, numeric comparisons, boolean expressions | Typed Swift expressions with explicit C# numeric conversions |
| `Mathf.Clamp01`, `Mathf.Lerp`, `Mathf.Sqrt` | `SourceAPIMath` helpers, including Clamp01's NaN behavior |
| `Time.deltaTime`, `Time.fixedDeltaTime` | Host supplied `SourceAPIContext` clocks |
| `transform`, `gameObject`, object `.transform` | Identity-retaining host protocol references |
| Transform position/localPosition/localScale | Host getters/setters |
| `Transform.Translate(Vector3, Space)` | Host translation with explicit space, defaulting to self space |
| `GameObject.Instantiate`, `Object.Instantiate` | Host clone operation |
| `GameObject.Destroy`, `Object.Destroy` | Host destruction request; host owns the end-of-frame barrier |
| `GameObject.SetActive` | Host activation operation |

Construct the context with the project's actual fixed timestep before creating a
component, for example `try SourceAPIContext(world: host, fixedDeltaTime: 0.02)`
when that interval is confirmed by the host. There is no guessed default.
`configureClocks(deltaTime:fixedDeltaTime:)` can atomically update both clocks
before component construction or later host phases. Non-finite/negative frame
durations and nonpositive physics intervals are rejected without partial changes.
This also makes field initializers, Awake and Start observe the configured physics
interval before the first fixed update.

The small `SourceBehaviourDriver` harness invokes Awake once and Start before its
first enabled update or fixed update. During a fixed update, deltaTime is the
supplied fixed duration. It rejects negative and non-finite durations before executing code. Enable/disable,
scene-wide callback ordering and destruction scheduling belong to the host.
Vectors at the bridge remain in Unity's source coordinate basis. A concrete native
scene adapter must perform the basis conversion at the boundary; generated scalar
and vector math does not silently reflect coordinates. Local Translate must
rotate a delta without multiplying it by object scale.

Studio now supplies the concrete transform, activation, cloning, destruction and
transaction adapter. See [plugin execution](plugin-execution.md) for
package loading, callback order and native scene persistence. The small compiled
`SourceBehaviourDriver` remains a four-callback utility harness; full scene
execution uses `SourcePluginRuntime`.

## Identity and rejection boundaries

Each IR records the exact input SHA-256, original DLL filename/hash when supplied,
fully qualified C# method documentation IDs, parser version, semantic-surface
hash, bridge/emitter hashes, substitution sites and generated Swift hash. Plug-in
GUIDs are opaque: casing and Unicode are retained. Generated type names include
an identity hash so different plug-in identities with the same C# class name do
not collide. Original card, zipmod, asset, resolver and KKEx data are not rewritten
by this tool. A supplied GUID is provenance supplied by the caller, not a claim
that the input implements that plug-in.

Coroutines, async, loops, exceptions, arbitrary inheritance, properties, generic
and overloaded methods, unknown attributes, serialized object fields, reflection,
Harmony patches, Unity fake-null/equality, integer overflow arithmetic, string
comparison, unsafe code and unknown API calls are rejected. Unmapped lifecycle
callbacks (including `On*`) are rejected rather than emitted as inactive helpers.
BepInPlugin/process/dependency/incompatibility metadata, public fields,
`SerializeField` and `NonSerialized` are supported. Other BepInEx APIs require
explicit mappings or native behavior adapters; loading metadata is not full
BepInEx compatibility.

## Verification

The retained 2026-09-25 verification log records ten frontend/translation tests.
The suite compiles generated Swift, validates package publication, recovers
BepInEx metadata/field serialization, executes lifecycle/clock/transform/object
behavior, checks identities and typed mutation, and verifies rejection boundaries
and stale-output removal. This documentation revision did not rerun those tests.
Clock regressions cover field initialization and callbacks before the first physics tick, invalid
configuration and atomic preservation of clocks after a rejected update.

When the local original files are present, the tests invoke the **unmodified**
`MathfEx.LerpAccel` and `MathfEx.LerpBrake` from `Assembly-CSharp.dll`, linked to the
original `UnityEngine.dll`, under .NET. They compare 2,001 input triples (4,002
method evaluations), including clamping and negative square-root inputs, with
compiled generated Swift. This validates those two methods, not other game logic.
Evidence is written to `.local/reverse/api-substitution/original-math-parity.json`
and `lifecycle-report.json`; the recovered translation stays beside that evidence.
Private-fixture tests must actually execute to support this claim; a run with
missing local assemblies is not a new differential result.

Expand the surface from a measured inventory of rejected installed APIs. Each new
construct needs matching original C#, generated Swift and interpreted-IR cases,
including evaluation order, unsupported inputs and rollback. Keep unknown APIs as
diagnostics until a concrete native host consumer exists; an accepted manifest
alone is not proof of game or plugin behavior.
