# Original Studio scene records

Reviewed 2026-09-25 against the working tree. The [Studio audit](../../component-audit/studio.md) is the feature-status and actionable-backlog index; this page records the narrower source contract and its evidence.

`KoikatsuSceneReader.decodeDocument` reads the full installed **1.0.4.2**
writer layout: all six object kinds, embedded character cards, character bones
and IK targets, accessory attachment groups, routes and control points, and the
complete scene-settings tail. Original bytes and trailing plug-in data are kept.
This establishes scene record loading; it does not recreate all runtime systems
needed to render or play an arbitrary original scene correctly.

## Evidence and framing

The source is the locally installed CharaStudio `Assembly-CSharp.dll`, SHA-256
`902b9a237337b17a64514bdb0d857b460ece4fb6a57c658375dd32c5fa504c45`.
The parser follows `SceneInfo.Save/Load`, `OICharInfo`, `OIRouteInfo`,
`OIRoutePointInfo`, `OIRoutePointAidInfo`, `LookAtTargetInfo`, `VoiceCtrl`, the
camera/light records, and the three sound controllers. Decompilation and
extracted game data remain under ignored `.local/reverse`.

The file consists of PNG framing, a .NET UTF-8 version string, the root object
dictionary, scene settings, and the writer marker `【KStudio】`. A root dictionary
key and its object's `dicKey` are separate values and are retained separately.
Most objects start with kind/key, nine ChangeAmount floats, tree state and
visibility. Nested bone, look-at and route-point records omit kind/tree/visibility;
treating them like normal objects would desynchronize all subsequent data.

| Kind | Parsed structure |
| --- | --- |
| 0, character | Embedded no-PNG ChaFile, bone/IK dictionaries, accessory-indexed children and every current persisted character field |
| 1, item | Existing full item record and child list |
| 2, light | Existing source light catalog identity and parameters |
| 3, folder | Name and child list |
| 4, route | Name, children, route points, helper transforms, speed/ease/connection/link fields, activity/loop/line/orientation/color |
| 5, camera | Name and activity flag |

An embedded card is framed by product 100, the character marker/version, face
thumbnail bytes, MessagePack block header and Int64 payload length. The native
card reader validates its internal block ranges and preserves unknown blocks.
The scene parser also consumes a recognized legacy `KKEx` version-2 trailer
immediately after that card. It does not mistake the following bone dictionary
count for a generic card trailer. Card thumbnail bytes are not displayed by this
parser. Embedded extension interpretation is bounded to the isolated card bytes;
malformed extension seek behavior that crosses into the next scene record is
not emulated. The whole original scene remains preserved for investigation.

Character fields include animation group/category/number and normalized time,
hand patterns, eight expression flags, FK/IK flags and preferences, voice
identities/repeat, mouth/lip settings, additional original status values,
simple-display color, animation option parameters, opaque neck/eye controller
state, and accessory group/item tree states. Unknown enum values are retained
where framing is unambiguous. Voice records are retained even when the source
runtime would later filter them against an unavailable voice catalog.

The scene tail includes map identity/transform/options, color correction and
effect parameters, the current camera plus ten camera slots, character and map
lighting, background/environment/outside sound settings, background and frame.
`floatSettings`, `boolSettings` and `colorSettings` use recovered source field
names. Reading these values does not apply Unity's post-processing or shaders.

### Character light

The scene tail's character light is the `charaLight` record: `color`,
`intensity`, a two-element `rot` and one `shadow` flag. `CameraLightCtrl.Reflect()`
applies it through its private nested `LightCalc` (fields `light` and
`transRoot`): the color and intensity are copied onto the `Light`,
`transRoot.localRotation` becomes `Quaternion.Euler(rot[0], rot[1], 0)`, and
`shadows` becomes `Soft`/`None` with the `shadow` flag. The first light slice
measured this on the installed player (`Tools/reverse/fixtures/OriginalLightProbe.cs`
through `Tools/reverse/original_light_probe.py`; Unity 5.6.2f1, one light per
record, status error null): it set color (0.9, 0.7, 0.5), intensity 1.3 and
`shadow` false and applied four rot pairs, (0, 0), (30, −45), (−20, 90) and
(10, 180), under the startup camera view and a second pose two frames after
`cameraCtrl.cameraAngle = (20, 135, 0)`. The applied light is the scene's
static "Directional Chara" (directional, enabled) under
`StudioScene → Light Chara → Directional Chara`; the chain is *not* under
`Camera.main` (`cameraIsAncestor` false). `Light Chara` is `transRoot` — its
local rotation matched `Euler(rot[0], rot[1], 0)` on all eight records to
5.0e-06° — while the light's own local rotation is the fixed `Euler(40, 180, 0)`
and `StudioScene` is identity, so the world rotation follows
`light.rotation == Q_root * Euler(rot[0], rot[1], 0) * Q_light` with `Q_root`
identity: the chain formula held on every record to a maximum of 9.7e-06°
(`Tools/reverse/analysis/chara_light_mapping.py`, derived from the capture's own
chains). Equal rot pairs gave identical world rotations under both camera
poses, and the camera-relative candidate
`light.rotation == Camera.main.rotation * Q1 * Euler(rot) * Q2` is refuted by
the same capture (best conjugation-solved fit leaves a 45.8° residual, matching
the 45.8° spread of `Q_base`, the rot (0,0) camera-space light rotation, between
the two poses). The world forward is therefore a function of `rot` alone, while
the forward in camera space (`InverseTransformDirection` against `Camera.main`)
also moves with the live view:

| rot | world forward | camera-space forward (default view) | camera-space forward (tilt pose) |
| --- | --- | --- | --- |
| (0, 0) | (0.0000, −0.6428, −0.7660) | (0.0000, −0.4787, 0.8780) | (0.5417, −0.4188, 0.7289) |
| (30, −45) | (0.6964, −0.1736, −0.6964) | (−0.6964, −0.0326, 0.7169) | (0.0000, 0.1736, 0.9848) |
| (−20, 90) | (−0.5000, −0.8660, 0.0000) | (0.5000, −0.8489, 0.1712) | (0.3536, −0.9347, −0.0360) |
| (10, 180) | (0.0000, −0.5000, 0.8660) | (0.0000, −0.6613, −0.7501) | (−0.6124, −0.6793, −0.4044) |

Reproduce the capture and the derivation with:

```sh
.local/reverse/unitypy-venv/bin/python Tools/reverse/original_light_probe.py \
  --output .local/stt11k/probe            # starts the isolated VM player capture
.local/reverse/unitypy-venv/bin/python Tools/reverse/original_light_probe.py \
  --output .local/stt11k/probe --collect  # fetches light-trace.json, stops the player
.local/reverse/unitypy-venv/bin/python \
  Tools/reverse/analysis/chara_light_mapping.py   # writes mapping.json beside the trace
PYTHONPATH=Tools/reverse/analysis .local/reverse/unitypy-venv/bin/python \
  -m unittest discover -s Tools/reverse/analysis -p 'test_chara_light_mapping.py'
```

This is one default startup scene, two camera poses and four rot pairs on the
installed CharaStudio 1.0.4.2: it establishes where the character light sits and
how `rot` maps to its world direction, not rendered lighting appearance, the
default `charaLight` values (the probe overwrote them) or map/gradient light
behavior.

## Native APIs and integration

```swift
let scene = try KoikatsuSceneReader.decodeDocument(data)
let objects = scene.snapshot.roots
let settings = scene.settings
let extensionReport = scene.extensions()
```

`KoikatsuSceneDocument.preservedData` is the exact input, and `trailingData` starts
after the original writer marker. `baseSceneEndOffset` and the snapshot's
`objectSectionEndOffset` support byte-level comparisons. The existing
`KoikatsuSceneReader.decode` remains an object-section reader, so original
prop/folder callers and object-only fixtures retain their old behavior.

`KoikatsuObjectRecord.character` and `.route` expose the added records. Character
children belong to `.character.accessoryChildren`, keyed by the original
attachment-point ID; they must not be flattened onto the character root. Route
children remain in the ordinary `.children` array. Bone dictionaries are keyed
by original **catalog IDs** and contain the separate source object key plus
ChangeAmount. Neither key should be confused with a native rig node index.

`KoikatsuCharacterRecord.card()` returns the existing `SourceCharacterCard`
adapter, including supported customization and saved mod metadata. After the
caller has assembled matching geometry and prepared the card/animation pose,
`makePose(rig:catalog:baseline:characterRoot:bodyRoot:hairRoot:)` binds original
catalog IDs and applies the recovered FK stage. It restores saved preferences
and reproduces the source's IK-then-FK initialization order. If both stored mode
flags are true, the shared original OICharInfo is mutated by IK activation before
the later FK flag is read, so the result is IK. The native helper preserves that
behavior and reports it.

The `makePose` result includes the staged FK pose/controller, deferred source
effects and diagnostics for missing saved bones and unsupported consumers. This
helper alone does not solve IK. `SourceStudioCharacterPreview` separately applies
[recovered schema-2 full-body IK](full-body-ik.md), or a clearly bounded schema-1
limb fallback, after the supported Animator/FK stages. Stored bone positions/scales
remain available as source data; FKCtrl only overwrites local Euler rotation.

`inspectStudioScene(url:)` is the CLI helper for complete record reports. It reads
at most 256 MiB and reports hashes, offsets, nested character/route structures,
extension IDs and settings without executing plug-ins or opening referenced
sound/image paths. The prop/folder layout converter continues to reject unsupported
runtime kinds before mutating a document. Parsing a character no longer fails
solely because kind 0 was unknown, but full restoration must be a separate,
explicit native integration path.

The app now exposes that bounded path through **File → Preview CharaStudio Scene…**.
It selects converted Maker assemblies by sex, head and bone type, resolves the
saved coordinate and available hair/clothes/accessory geometry, and applies
supported card material/expression settings, shape and static ABMX. It samples
normal catalog animation, restores saved FK/configured IK, and advances selected
hair dynamics only when the host supplies a dynamics tick. Coverage depends on
the converted library; without it, reference hair/clothes remain with diagnostics.
The preview passes no mod library to its selected material overlay path, so it is
not arbitrary installed appearance/plugin compatibility.

Source object transforms retain their exact quaternion with consistent editable
Euler fields. Exact accessory-point mappings read the final character pose.
Unsupported variants, source props/lights/object cameras, routes and **all route
descendants** remain named, unrendered tree entries. The current viewport camera
and ten slots are applied; maps, scene lighting/effects and scene sound are parsed
only. The separate prop/folder catalog importer is not yet unified with this path.

The source Pose/Face/Clothes inspector gate still prevents normal access to the
existing pose controls (`ST-B01`). Prototype card/visibility controls can write
fields that do not affect the source preview (`ST-B04`). Removing the gate alone
does not implement mutable source face, clothing or coordinate editing.

Native scene cards persist the original scene path, SHA-256, object key, avatar
and bone-catalog references. The original file must remain available and unchanged;
reload verifies its hash. Scene replacements clear preview caches, and deleted or
converted objects release their cached previews. Unsupported original bytes
remain in the referenced file. The bounded
[edited-original writer](scene-editing.md) patches supported existing transforms,
FK/IK flags/targets, animation/voice and camera state while preserving other bytes;
unsupported edits reject before output. The initial four preview integration
tests covered native card round trips, actual-avatar FK/shape transforms and
finite Metal bounds, stale references, unsupported cards and failed-load mesh
cleanup. Later animation/full-body tests add separate source pose roundtrips.
Headless verification uses `IKKOKU_SOURCE_SCENE` with an independently generated
synthetic source-format fixture; no original scene thumbnails are rendered.

## Routes

`SourceStudioRoute` is the first route runtime piece. `SourceStudioRoute(record:)`
bridges a decoded `KoikatsuRouteRecord` (rejecting unknown connection, easing or
orientation ordinals), `segments()` reproduces the recovered `OCIRoute.SetPath`
segment building — line pairs with loop wrap, point/aid curve pairs, linked-curve
joining, and the `PathLength` double-padding that times a straight two-point
segment at three times its geometric length — and `evaluate(at:)` returns the
tweened position, current segment, finished flag and the lookahead orientation
(`Defaults.lookAhead` 0.05 added to the eased percentage) for a time in seconds.
All 32 recovered `StudioTween` easings are implemented with their endpoint
quirks, including the expo pair that stops 2⁻¹⁰/2⁻¹¹ short. Unplayable input
(fewer than two points, non-positive or non-finite speed, non-finite positions or
aids, zero-length paths, negative or non-finite times) throws
`RigError.invalid` diagnostics instead of guessing.

This is pure math in double precision, not playback. Verification is agreement
with `Tools/reverse/analysis/studio_route_reference.py` (a ported reference, not
an original CharaStudio capture) within that fixture's 1e-5 tolerance.

`SourceStudioRoutePlayback.childRootWorld` is the second piece: it applies the
recovered `OCIRoute.Play`/`Stop` world placement of `childRoot`, the transform
route child objects are parented under. An inactive route pins it to point 0's
world position and rotation every frame. An active route starts from point 0's
world placement and translates along the segments for the elapsed time the
caller supplies; its rotation changes only while the orientation is XY or Y
(orient-to-path, from the evaluator's instantaneous look rotation — the
stateful `StudioTween.LookUpdate` smoothing is not simulated), otherwise it
keeps point 0's rotation, and a finished non-looping route holds its end
position, holds its last aim (recomputed at percentage 1 - lookAhead on the
final segment) and reports inactive. The recovered assignments write position and rotation only; the
inherited route scale is kept. In the Studio preview an imported
route's authored record lives in a runtime-only cache gated by scene identity,
the world-matrix walks replace a route parent's authored transform with
`childRoot` (since the ninth slice placed by the per-frame stepper of the
next section, falling back to the continuous evaluator off-frame or past the
rebuild budget), and route descendants inherit it; the cache never becomes a
document node, so original export validation is untouched. A character under a
route renders through a second scene-identity-gated runtime-only preview map
placed by the same walk, while its document entry keeps the unrendered
placeholder (folder kind, fallback name, no character reference), so its
FK/IK, animation and expression edits are unoffered and original export keeps
rejecting them. After undo/redo the caches are empty and route children fall
back to the route object's authored transform rather than a guess derived from
edited document data. `ikkoku-inspect route-playback
<scene.png> <seconds>` samples every route of a decoded scene at one clock
position. Since the tenth slice the Studio editor exposes the recovered
`Play`/`Stop` presses as runtime controls (a selected route's Play/Stop button
plus a Play-all/Replay-all/Stop-all menu; see the preview-wiring paragraph at
the end of this section), and a route whose authored record is inactive can
be played from the editor through that state. Still missing: route-point
guide callbacks, edited route serialization, rendered non-character route
descendants and editable route characters.

An original capture now exists. `Tools/reverse/original_route_probe.py` runs
`Tools/reverse/fixtures/OriginalRouteProbe.cs` inside the isolated VM player
copy: it authors two routes in an empty scene — `IKKOKU-A`, four points, line
connections, linear/easeInQuad/easeOutCubic easings at speeds 1.5/2/3, looping,
no orientation; `IKKOKU-B`, four points with two curve connections (one aid
offset from the auto-initialised midpoint, one linked curve), speed 2, non-loop,
XY orientation — saves the scene record while both routes play
(`route-scene.png` via the real `sceneInfo.Save`), and records 240 frames of
`Time.frameCount`, `deltaTime`, the running cumulative time and each route's
`childRoot` world position, rotation and `active` flag (`route-trace.json`):

```sh
.local/reverse/unitypy-venv/bin/python Tools/reverse/original_route_probe.py \
  --output .local/stt11c/probe        # launch; the probe self-quits when done
.local/reverse/unitypy-venv/bin/python Tools/reverse/original_route_probe.py \
  --output .local/stt11c/probe --collect
.local/reverse/unitypy-venv/bin/python Tools/reverse/compare_route_playback.py
```

Curve aids compose through their point. The aid `KoikatsuBoneRecord` in a
route point is the aid object's *Point-local* change amount (its
`localPosition` under the route point), so the route-local control point is
`pointPosition + R(pointEuler) · (pointScale ⊙ aidLocal)` with `R` the Unity
`Quaternion.Euler` order (Z applied first, then X, then Y), staying in Unity
route-local space. Both construction paths originally read the aid as
route-local directly — `SourceStudioRoute(record:)` and
`SourceStudioRoutePlayback.childRootWorld` — and both are fixed: the record
bridge composes it with a double-precision ZXY helper (`routeLocalAid`), and
the playback path composes it in engine space as
`routeWorld * locals[index] * localMatrix(point.aid.transform)`. Verified
against the capture on `IKKOKU-B` point dicKey 8 (Point at (0.8, 0.2, 0.6)
rotated -15° about Y, aid local (-0.2683783, 0.675, -0.3895974) → route-local
aid (0.6416017, 0.875, 0.1542164)) and point dicKey 12 (→ (-0.55, 0.525,
-0.2999999)); an unrotated point keeps `pointPosition + aidLocal`.

`Tools/reverse/compare_route_playback.py` runs
`ikkoku-inspect route-playback route-scene.png <cumulative t>` at all 240
recorded times and compares in a common Unity basis: positions directly,
rotations as quaternion angles against quaternions reconstructed from the
emitted Z-X-Y Euler angles. Because the original `StudioTween` advances in
`Update` by whole `Time.deltaTime` steps, it reports maxima at offset 0, at
the best constant frame offset (-2 for this capture) and at every constant
offset -2…+2 (`maximumPositionErrorMetresByOffset`):

| offset | `IKKOKU-A` max pos (m) | `IKKOKU-B` max pos (m) |
|---|---|---|
| -2 | 0.023816 | 0.159800 |
| -1 | 0.018048 | 0.160517 |
| 0  | 0.030087 | 0.182161 |
| +1 | 0.049930 | 0.218115 |
| +2 | 0.063310 | 0.249216 |

`IKKOKU-A` rotation is 0.0° at every offset. `IKKOKU-B` deviates by 155.0°
at offset 0 and 141.4° at -2 — down from 166.0° / 166.0° when the completion
semantics bug was open, and 0.905 m / 175.9° before the aid-frame fix. The
continuous evaluator's remaining position error has two sources, and the
per-frame stepping below accounts for both:

1. Timing. Each frame the original writes the position before it advances
   its tween clock, and it drops the overshoot at every segment boundary.
   The continuous evaluator models neither (on route A, stepping reduces the
   error to 1e-6 m).
2. A route B input artifact of this capture. The saved scene record holds
   the authored point/aid rotations, all zero, while the live capture ran
   the curve points at a compensating -15° about Y. The curve chain composed
   from the record (3.1679 m) is therefore 2.4 % shorter than the one the
   original walked (3.2473 m), and native reaches the end about 0.05 s
   before the original's 3.92 s deactivation.

Position is independent of
`LookUpdate`, which only smooths the aim; the remaining rotation differences
are `LookUpdate` decay at the start of each oriented segment (155.0° peak)
and a frozen-smoothing offset on the held frames (14.2°). The completion
semantics that produced the earlier 166° rotation maximum — the native
evaluator returned point 0's rotation (yaw 15°) and kept the route active
from 3.86 s, while the original deactivates at 3.92 s and holds its last aim
(yaw about -151°) — are fixed: a finished non-loop route recomputes its aim
at percentage 1 - lookAhead on the final segment, holds it, and reports
inactive.

On both routes the native position leads the original by exactly one frame
from the start: the first recorded original frame is still at point 0, which
gives a constant 0.65 cm (A) and 1.05 cm (B) error through their first
straight segments. The report also carries a segment-timing table:
`ikkoku-inspect route-playback` emits `segmentDurations` (native
`segments()` start indices and durations per route), and the comparator finds
where the original `childRoot` comes nearest each route point per loop cycle
(`segmentTiming`). `IKKOKU-A` native durations are 2.1190 / 2.5111 / 1.4942 /
1.4329 s (period 7.5571 s); the original passes point dicKey 1 (native t=0)
at t=0.0173 s (lag +0.0173 s, one frame) and point dicKey 6 (native
t=2.1190) at t=2.1374 s (lag +0.0184 s). The capture ends at t=4.003 s,
inside the cycle, so points 10 and 14 have no arrival. Route A's loop drift
therefore starts in segment 1 (the easeInQuad segment from point 6 at
2.1190 s to point 10 at 4.6301 s): the offset-0 position error is a constant
0.0065 m through segment 0 and grows monotonically 0.0002→0.0270 m through
segment 1, so the original traverses the eased segment more slowly than the
native duration assigns — not a wrap-time arithmetic error (the wrap itself
is beyond this capture). `IKKOKU-B`'s chain-interior points 12 and 16 have
nearest approaches (t=2.734 s at 0.007 m; t=3.920 s at 1e-6 m, after which it
holds) but no native boundary to lag against. The report is
`.local/stt11c/route-playback-comparison.json`.

### Per-frame stepping

The `StudioTween`/`OCIRoute.Play` pair is a stateful stepper: each frame it
re-applies the eased percentage to `childRoot`, then advances
`percentage += deltaTime / duration`, and at a `TweenComplete` boundary moves
to the next segment (a looping route restarts at percentage 0) inside the
same frame, dropping the overshoot; a non-looping finish stops the tween, so
the last written placement and aim persist and the route reports inactive.
`SourceStudioRouteStepper` ports those rules over the same segment builder,
durations and easing as the continuous evaluator
(`Tools/reverse/analysis/studio_route_reference.py` gained
`simulate_frames`; its stepping test compares both record orders), and
`SourceStudioRoutePlayback` reports the finished route's inactive state with
the held aim at `1 - lookAhead`. The capture is one write behind its own
deltas: the probe snapshots at the start of the next frame, so row 0's
`deltaTime` belongs to the `Play` frame and is never consumed. Feeding
`deltas[1:]` and comparing capture row *k* with stepped frame *k* over the
recorded deltas reproduces the original to the micrometre — the reference
simulator's after-update record order gives a worst error of 1.06e-06 m on
`IKKOKU-A` and 1.79e-06 m on `IKKOKU-B` with no active-frame disagreement
(`Tools/reverse/compare_route_stepping.py`; the before-update order is worse,
0.0225/0.0496 m, which confirms the write-after-update order).
`ikkoku-inspect route-steps <scene.png> <deltas.json>` exposes the stepper and
`Tools/reverse/compare_route_playback.py --mode {continuous,stepped,both}`
(default `both`) runs it over the capture. Over the live-authoring capture
(`.local/stt11c/probe`) the stepped maxima are (the rotation column is the
simulated `LookUpdate` state described below):

| route | stepped max pos (m) | worst frame | stepped max rot (°) | active mismatches |
|---|---|---|---|---|
| `IKKOKU-A` | 0.00000101 | 211 | 0.0 | 0 |
| `IKKOKU-B` | 0.160000 | 198 | 16.9 | 1 (native frame 233, original 234) |

`IKKOKU-A` steps in lockstep. `IKKOKU-B`'s 0.16 m residual there is an input
artifact, not a stepping or evaluator error: `AddObjectRoute.AddPoint` parents
each new point with `SetParent(route)`, keeping its world position and
rotation, so when the route object carries +15° Y the live curve points end up
with a compensating −15° local rotation — `(0, -0.1305262, 0, 0.9914449)` —
while the saved `changeAmount.rot` stays at its authored `(0, 0, 0)`. The
record therefore reloads differently from the live authoring run: the aid
worlds the native evaluator composes from the record differ from the ones the
original actually used, the chain comes out 3.1679 m instead of 3.2473 m, and
segment 1 lasts 2.3259 s instead of 2.3452 s. That 0.0193 s shortfall is also
the single active-frame mismatch. Substituting only the captured aid world
positions — record point positions otherwise, the same 239 deltas — drops the
worst error to 1.25e-06 m with no mismatch and completion on exactly the
captured frame 234 (`.local/stt11c/route-stepping-aid-attribution.json`), so
the per-frame rules, durations and interpolation are exact for the transforms
the original walked.

The reload capture removes that input difference at the source.
`Tools/reverse/original_route_probe.py --load-scene <png>` uploads the record
beside the compiled plugin, and the probe's load mode skips authoring and calls
`Studio.Studio.Instance.LoadScene` — whose route load path calls `OCIRoute.Play`
itself — then runs the same 240-frame trace (`"mode": "load"` in the trace)
without re-saving, so the record under comparison is the uploaded file
byte-for-byte and `--collect` fetches that file itself:

```sh
.local/reverse/unitypy-venv/bin/python Tools/reverse/original_route_probe.py \
  --output .local/stt11g/probe --load-scene .local/stt11c/probe/route-scene.png
.local/reverse/unitypy-venv/bin/python Tools/reverse/original_route_probe.py \
  --output .local/stt11g/probe --collect
.local/reverse/unitypy-venv/bin/python Tools/reverse/compare_route_playback.py \
  --probe .local/stt11g/probe --mode both
.local/reverse/unitypy-venv/bin/python Tools/reverse/compare_route_stepping.py \
  --probe .local/stt11g/probe
```

The loaded points' live local rotations are `(0, 0, 0, 1)` on both routes —
the record stored no authored rotation, so there is nothing to compensate —
and stepping the same exact deltas over the same scene record gives:

| route | stepped max pos (m) | worst frame | stepped max rot (°) | active mismatches |
|---|---|---|---|---|
| `IKKOKU-A` | 0.00000073 | 238 | 0.0 | 0 |
| `IKKOKU-B` | 0.00000098 | 220 | 0.0511 | 0 |

Both routes now close the loop against the record to under a micrometre with
no active-frame disagreement (`.local/stt11g/route-playback-stepped-comparison.json`,
`.local/stt11g/route-stepping-comparison.json`): the native stepper is exact on
the transforms the serialized scene actually carries, and the earlier route-B
residual was the authoring-time `SetParent` compensation the record never
contained.

The rotation column is the `LookUpdate` state itself, not the instantaneous
aim. `StudioTween.LookUpdate` runs in `LateUpdate` on every frame the tween was
running — the frame a non-looping route completes on is smoothed for the last
time, and every later frame freezes at that Euler. It saves `childRoot`'s
current Euler, lets `LookAt` write the instantaneous aim, then restores the
saved angles and damps each axis toward that aim with `Mathf.SmoothDampAngle`
on a fresh zero velocity every call (the damp has no memory across frames).
Its smoothTime resolves from the tween arguments — `looktime * 0.05`, else the
move's `time * 0.15 * 0.05`, else `Defaults.updateTime` — and because a route
tween passes only "speed" the 0.05 s fallback applies; the capture confirms it
rather than assuming it: with 0.05 s the stepping rotation maxima are 0.0° on
`IKKOKU-A` and 0.0511° on `IKKOKU-B` (worst frame 166), while the `time`-branch
scaling `segmentDuration * 0.15 * 0.05` = `segmentDuration * 0.0075` leaves
85.1° (worst frame 93) and is rejected (`compare_route_stepping.py` reports
both columns). The axis-"y" orientation then re-keeps the root's own x/z, and
because Unity stores rotations as quaternions the damped Euler is written back
through `transform.eulerAngles` — each frame damps from the canonicalised Z-X-Y
read-back, not the raw damped angles. Row *k*'s damp targets the aim the
previous row's tween write established and consumes that previous write's
`deltaTime` — the `Play` frame's own delta seeds row 0 and is passed separately
(`ikkoku-inspect route-steps`' optional fourth argument), which is why the
rotation column lags the position/aim column by one row.
`Fixtures/route-stepping.json` carries the reference's per-frame `rotation`
column and `SourceStudioRouteStepper` matches it to 1e-4°. Before the port the
captures' own rotation column was that raw lag — a 155.7° peak at the curve
segment start (frame 90) decaying below 5° by frame 146, held frames 1.4° off
the instantaneous held aim — and the ported rules reproduce the original's
smoothing itself: the reload capture now sits 0.0511° off, and the
live-authoring capture's 16.9° rotation residual goes with its `SetParent`
position artifact.
`ikkoku-inspect` exposes stepping as a diagnostic.

**Preview wiring (ninth slice).** The Studio preview now places imported
route `childRoot`s through this stepper instead of only the continuous
evaluator. `SourceStudioRouteClock` (Engine) keeps one clock mirror per
imported route, following the hair-dynamics "step on tick, clear on jump"
pattern: each live tick steps the stepper by the same `1 / 30` delta (the
mirror consumes the identical `Float` additions, so it matches the preview
clock bit for bit), and a jump — a scrub, a checkpoint restore or an import —
rebuilds a fresh `Play` and fast-forwards in fixed `1 / 30` frames to the
nearest frame, so the placement matches what live stepping produces there.
`sourceWorldMatrix`/`sourceWorldRotation` answer from the stepper's latest
frame only while it belongs to the queried instant (1e-6 s) and the route
object has not moved (a moved route object carries its whole path and
rebuilds, like a jump); a completed non-looping route keeps answering with its
frozen inactive hold frame, and a record-inactive route never builds a stepper,
so `childRoot` keeps its `Stop` pin. A rebuild that would need more than
18,000 frames (10 minutes) drops the stepper, reports a one-time status
diagnostic and keeps the continuous evaluator for that route until a later
in-budget jump re-arms it. The stepper is built through the same
`SourceStudioRoutePlayback.stepper` composition `ikkoku-inspect route-steps`
validates against the reload captures — no second stepping implementation —
and its frame is converted through the same `UnityCoordinates` basis change
`samples` reports. The bookkeeping has five pure Engine tests
(`swift test --package-path Packages/Engine --filter RouteClockTests`,
2026-09-28: live per-frame equality against a hand-stepped stepper, a jump
matching 120 live `1 / 30` steps exactly, the cap falling back and re-arming,
the non-loop hold surviving both live stepping and a rebuild to the same time,
and a route-world change rebuilding like a jump). That is Engine-test
evidence; an interactive app-session comparison of the wired preview against
the original player was not run in this slice, and edited route serialization
remains open.

**Play/stop controls (tenth slice).** The editor now offers the recovered
`RouteControl` presses. `SourceStudioRouteClock` gained a play instant:
`play(at:routeWorld:)` records the clock time the route's tween starts, the
stepper's tween time is `clockTime - playStart`, and `stop()` drops the stepper
so the route answers nothing until the next `play`. That mirrors the
original's rule that pressing `OCIRoute.Play` starts the tween at the press
frame (`childRoot` shows point 0 with `deltaTime` 0 that frame, then advances),
while scrubbing to before the press has no tween to evaluate
(`lastAction == .notPlayingYet`) and the placement falls back to the caller's
pin until the clock reaches the press again, where a live query re-arms the
stepper exactly as the live crossing would. Import seeds each route's play
state from the record's `active` flag at clock time 0, so an imported
active route behaves as before (its tween runs from the start of the preview),
and an editor Play press on an inactive route plays it by overriding that flag
(`SourceStudioRoutePlayback.childRootWorld`'s `activeOverride`), including the
point-0 `Play` placement at the press instant and the `Stop` pin when the user
stops it. Undo, redo and a new scene clear the play state along with the route
cache. **This is runtime-only by design:** the `active` flag a scene record
serializes is the state the original's `sceneInfo.Save` captured, and
`SourceSceneExportValidation` rejects changing it, so the export keeps the
saved route state and the controls only move the preview. Engine tests cover
the press-time offset (a press at 3 s then 13 live ticks equals a fresh stepper
stepped 13 times; a jump to 1/30 past the press sees one tween frame, not 91),
the before-press instant, and replay-then-stop (`swift test --package-path
Packages/Engine --filter RouteClockTests`, 2026-09-28; eight tests).

## Extended Save and preservation

The installed scene load hook reads the writer marker, then a `KKEx` string,
version Int32, byte count and MessagePack dictionary. It reads the version but
does not compare it. The native extension report preserves that behavior,
exposes the observed version, and decodes the raw map without invoking handlers.
Unknown plug-in values remain MessagePack values. Unknown trailers, malformed
extensions and additional bytes are retained with diagnostics; they do not erase
the base scene. This extension API provides data retention, not plugin execution.
The bounded edited-original writer preserves those bytes; it does not dispatch
plugin save callbacks or serialize arbitrary translated runtime fields.

The original import hook searches for the marker after the imported objects;
the native document decoder instead parses the full known base format and reads
the trailer at its verified boundary. Arbitrary byte scanning could select a
coincidental marker inside a card or opaque field, so that import-hook heuristic
is not used as a substitute for known scene framing.

## Bounds and deliberate strictness

The reader accepts the observed scene version and camera record version 2.
Other historical layouts fail explicitly. Limits are 256 MiB total input,
100,000 objects/collection entries, 64 hierarchy levels, 1 MiB UTF-8 strings,
64 MiB individual binary fields and embedded card payloads, and 1 MiB card block
headers. Counts/ranges, finite floats and duplicate dictionary/object keys are
validated. Boolean bytes must be 0 or 1; this is stricter than BinaryReader's
nonzero-as-true behavior. Unknown variable-length object kinds cannot be skipped.
The PNG is structurally skipped, not image-decoded or CRC-validated by this
existing scene reader. The full decoder requires the writer marker even though
the original base loader does not consume it itself.

## Verification

Generate independent synthetic scenes and source-hash evidence:

```sh
PYTHONPATH=Tools/reverse .local/reverse/unitypy-venv/bin/python \
  -m analysis.studio_scene_contract
.local/reverse/unitypy-venv/bin/python -m unittest discover \
  -s Tools/reverse -p test_studio_scene_contract.py
IKKOKU_STUDIO_SCENE_FIXTURES="$PWD/.local/reverse/studio-scenes" \
  swift test --package-path Packages/Engine --filter KoikatsuScene
```

The Python writer and offset oracle exercise current and legacy embedded cards,
accessory children, source bone identities, two route points, every settings-tail
segment, extension retention and dual kinematic flags. It rejects every truncated
base-scene prefix. Native tests additionally verify exact bytes, source-card
customization, marker/tail truncation, nonzero Data slice indices, corrupt
extensions and saved-FK application. These are synthetic scene fixtures following
recovered source behavior, not a successful load of the user's complete original
Studio scene collection.

Route evaluation has its own reference, fixture and tests:

```sh
.local/reverse/unitypy-venv/bin/python \
  Tools/reverse/analysis/studio_route_reference.py --out \
  Packages/Engine/Tests/EngineTests/Fixtures/route-reference.json
PYTHONPATH=Tools/reverse/analysis .local/reverse/unitypy-venv/bin/python \
  -m unittest test_studio_route_reference
swift test --package-path Packages/Engine --filter SourceStudioRouteTests
```

The Python reference runs 25 tests against closed forms taken from the recovered
C#; the Swift tests compare every sample of the 41 fixture routes within the
fixture's 1e-5 tolerance. Evaluator-versus-reference agreement is not an original
CharaStudio run.

Two original installation files were also copied through the read-only,
SHA-verified VM transfer and decoded without viewing or rendering their PNGs:

| Original file | Bytes | Root objects | Total objects | Characters | Object-section end | Base-scene end |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `Asset-PlayGround-IronBar.png` | 17,876 | 1 | 14 | 0 | 16,782 | 17,862 |
| `koikatu_cs0002591.png` | 595,127 | 8 | 32 | 7 | 593,997 | 595,127 |

Both native and independent Python parsing agree on those boundaries, object
kind counts, input hashes and exact byte preservation. The first file has a
14-byte ExtendedSave version-3 trailer containing an empty plug-in map; the second
has no trailing extension. All seven embedded character cards passed native
framing validation. This verifies real scene records, not full runtime appearance
or motion restoration. The local evidence report is
`.local/reverse/studio-scenes/actual-validation.json`.

The optional native test `KoikatsuSceneReadsExplicitOriginalSceneDirectoryWhenSupplied`
reads only the directory provided by `IKKOKU_STUDIO_ORIGINAL_SCENES`, validates
each `.png`, and prints per-file hashes, offsets, object counts and extension
structure. It does not display thumbnails or instantiate scene content.

## Remaining integration work

- Unblock and test the source inspector, then implement source appearance,
  coordinate/clothing and face controls rather than writing prototype fields
  (`ST-T01`, `ST-T06`, `ST-T07`).
- Unify exact-key converted props/maps/lights/object cameras with source characters
  and their attachment hierarchy (`ST-T04`).
- Extend full-body original-player evidence, dynamics topologies/world inertia and
  Animator controller coverage; existing adapters are mid-stage, not absent
  (`ST-T05`, `ST-T08`, `ST-T10`).
- Build route-point guide callbacks and an edited route writer on top of the
  `SourceStudioRoute` evaluator and the
  `SourceStudioRoutePlayback` `childRoot` placement, then source
  scene effects, camera-object behavior and sound (`ST-T11`, `ST-T12`).
  Stateful `LookUpdate` smoothing is ported in `SourceStudioRouteStepper`
  (per-frame stepping above) and reaches `ikkoku-inspect route-steps` and,
  through the `SourceStudioRouteClock`-mirrored stepper, the Studio preview's
  `childRoot` placement (ninth slice); the continuous `childRootWorld` path
  still reports the instantaneous aim and remains the fallback for off-frame
  instants and past-budget rebuilds. The editor play/stop control is
  implemented (tenth slice, play/stop controls above) as a runtime-only play
  state over the record's saved `active` flag. An interactive app-session
  comparison of the wired preview against the original player is still open.
- Add original scene topology edits/reference remapping and GUID-specific plugin
  callbacks/save adapters while preserving source identities (`ST-T03`, `ST-T13`).

Use the linked audit acceptance criteria for each task. Parsing success, a rendered
character and byte-preserved plugin data remain three different compatibility
claims; none establishes complete original scene restoration.
