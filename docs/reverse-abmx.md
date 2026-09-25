# ABMX static bone modifier bridge

`SourceBoneModifiers` implements the installed ABMX plugin's ordinary local
scale, rotation, length, and position adjustments over a supplied neutral pose.
It runs in Swift; no source plugin assembly executes in the native application.
The caller applies it after source body/face customization and before building
skin palettes. The baseline must be freshly evaluated on every change so that
offsets do not accumulate.

This is a port of one recovered managed behavior, not general compatibility with
ABMX's Unity plugin lifecycle, animation hooks, accessory editor, or other mods.

## Installed evidence

The inspected installation contains `BepInEx/plugins/KKABMX.dll`, assembly
`KKABMX, Version=5.4.0.0`, with plugin version `5.4` and GUID `KKABMX.Core`.
Its SHA-256 is
`f3e2d9877b08b2b25187cbc101478ea0d484bcfe4856244050ba3119578e9f68`.
The transferred DLL and its source provenance are under
`.local/reverse/mods/source/BepInEx/plugins/`.

Only the relevant classes were decompiled into
`.local/reverse/decompiled/ABMX/`: `BoneModifier`, `BoneModifierData`,
`BoneController`, `BoneFinder`, `BoneEffect`, `BoneLocation`, `Baseline`,
`OldDataConverter`, and `KKABMX_Core`. The manifest records individual source
hashes. The original source and derived private evidence remain ignored by Git.

MessagePack's LZ4 serializer and Unity Vector3 formatter were also inspected in
the installed `Assembly-CSharp-firstpass.dll`, SHA-256
`ca572fff8740bbcd58d549723c80b0088d6676611eae2ab91624f460739aea10`.
The game and CharaStudio copies were independently hash-checked and are identical.
The local implementation does not invoke the ABMX DLL to convert or evaluate data.

## Original persistence format

The extended-save GUID is **`KKABMPlugin.ABMData`**, which differs from the
plugin GUID. The relevant `PluginData.data` key is **`boneData`**.

| Container | Current written version | Source versions read | Native converter |
| --- | ---: | --- | --- |
| Character card | 2 | 1, 2 | 2 |
| Coordinate/outfit | 3 | 2, 3 | 3 |

Current card-v2 and coordinate-v3 values contain an LZ4 MessagePack
`List<BoneModifier>`. The integer-key objects are arrays:

```text
BoneModifier = [BoneName, CoordinateModifiers, BoneLocation]
BoneModifierData = [ScaleModifier, LengthModifier, PositionModifier, RotationModifier]
Vector3 = [x, y, z]  // serialized float32 elements
```

`CoordinateModifiers` contains one or more `BoneModifierData` arrays. One entry
is coordinate-independent. Multiple entries are indexed by the current outfit;
an index beyond the stored array supplies no modifier for that outfit. Defaults
are scale `(1,1,1)`, length `1`, position `(0,0,0)`, rotation `(0,0,0)`.

The serializer leaves MessagePack shorter than 64 bytes uncompressed. Otherwise,
it writes extension type **99**, with a MessagePack int32 expanded byte count
followed by a raw LZ4 block. Its writer forces an ext32 header and a signed-int32
size header. The converter accepts both the plain and compressed forms.

The original plugin additionally migrates legacy card text and coordinate-v2
dictionaries. That migration is not ported. The converter matches the current
serialization constructor's repair of individual null coordinate entries to
identity values, retaining one warning per repaired entry in `diagnostics`.
A null whole coordinate array or an empty array is rejected, matching the
constructor's explicit exceptions. Incomplete non-null records remain unsupported.
These behaviors are confirmed in the installed constructor; no inference from
empty-array behavior in `GetModifier` is needed. The tool does not extract
`PluginData` from an entire character card: framing and extended-save extraction
are a separate layer.

## Reproduction and conversion

The helper requires NumPy, msgpack, and lz4 in the existing extraction environment.
Run it without arguments to check the evidence hashes and create the synthetic
example and independent matrix fixtures:

```sh
.local/reverse/unitypy-venv/bin/python Tools/reverse/analysis/abmx_contract.py
.local/reverse/unitypy-venv/bin/python Tools/reverse/test_abmx_contract.py
```

Outputs:

- `.local/reverse/mods/abmx/contract.json`: evidence, keys, formulas, and limits.
- `.local/reverse/mods/abmx/synthetic.boneData.bin`: synthetic data in the original wire format.
- `.local/reverse/rigs/source-abmx-example.json`: the converted native example.
- `.local/reverse/rigs/source-abmx-reference.json`: eight independent matrix cases.

The example adjusts the clothed avatar's face-root scale/position/tilt and both
forearm lengths. It is explicitly synthetic and does not pretend to be a mod
recovered from a user's saved character.

To convert an actual extracted `boneData` byte array:

```sh
.local/reverse/unitypy-venv/bin/python Tools/reverse/analysis/abmx_contract.py \
  --bone-data .local/reverse/abmx-boneData.bin \
  --data-kind card --data-version 2 \
  --output .local/reverse/rigs/imported-bone-modifiers.json
```

For a current outfit payload, use `--data-kind coordinate --data-version 3`.
The converter validates sizes, finite numeric values, vector arity, duplicate
record identities, and the current array layout. It records the payload SHA-256
and preserves bone names, coordinate entries, and location numbers without
renaming or mirroring. Accessory and dynamic records remain identifiable in
the converted document with explicit scope diagnostics; the native static
evaluator reports unsupported active records instead of silently applying an
approximation. CLI conversion also prints diagnostics, including null-entry
repairs, so a successful conversion cannot conceal these conditions.

## Native document and API

The native document uses:

```text
schemaVersion: 1
kind: "ikkoku-source-bone-modifiers"
coordinateSpace: "unity-left-handed-y-up"
angleUnit: "degrees"
mode: "staticBaseline"
source:
  pluginGUID, dataGUID, pluginVersion
  dataKind, dataVersion
  assemblySHA256, payloadSHA256
diagnostics:                         // optional on older native documents
  - code, severity, message
modifiers:
  - boneName, boneLocation
    coordinateModifiers:
      - scaleModifier: [x, y, z]
        lengthModifier: scalar
        positionModifier: [x, y, z]
        rotationModifier: [x, y, z]
```

The source plugin version is `5.4`; data versions follow the table above.
`SourceBoneModifiers.decode(Data)` validates the header and record structure.
Public `source`, `modifiers`, `count`, `coordinateCounts`, and optional
`diagnostics` properties support preview status. Each diagnostic exposes public
`code`, `severity`, and `message` fields. Apply it with:

```swift
let modifiers = try SourceBoneModifiers.decode(data)
let modifiedPose = try modifiers.applying(
    to: source.rig, baseline: shapedPose, coordinate: 0)
```

The application owns loading, enabling, clearing, and outfit selection. Clearing
uses the original shaped pose again; callers must not pass a previously modified
pose as the new baseline. The capture environment uses `IKKOKU_BONE_MODIFIERS`.

`SourceBoneModifiers.decodeBoneData(_:dataKind:dataVersion:)` now accepts original
binary payloads directly. It uses the native bounded MessagePack/raw LZ4 decoder,
retains the original-byte SHA-256, and applies the same null-entry repair and
scope diagnostics as the Python converter. Native limits also cap decoded values
at one million and container nesting at 64.

`SourceCharacterCard` locates the selected plug-in record in current `KKEx` blocks
or legacy card trailers and invokes that binary decoder. Maker's **File → Import
Source Card Settings…** applies the supported shape and modifier subset while
retaining all original card bytes. The associated [card report](reverse-card.md)
describes precedence and the remaining appearance/save limitations. For headless
rig capture, set `IKKOKU_SOURCE_CARD` to a supported source card instead of separate
shape/`IKKOKU_BONE_MODIFIERS` overrides.

## Recovered transform rules

ABMX captures each bone's **local** scale, rotation, and position after source
shape evaluation. Its `Apply` method updates scale, then rotation, then position:

```text
localScale    = baselineScale * ScaleModifier             // componentwise
localRotation = baselineRotation * EulerZXY(RotationModifierDegrees)
localPosition = baselinePosition * LengthModifier + PositionModifier
```

Length scales the bone's local offset from its parent. It is not a scale factor
on the mesh, a child-bone distance operation, or a translation along a chosen
axis. Position offsets are in parent-local coordinates and source length units.
There is no parent lossy-scale compensation in this method. Rotation is a
postmultiplication; changing the order changes the result on a rotated baseline.
Unity's Euler conversion rotates Z first, then X, then Y.

The Swift pose already uses the native coordinate basis. Position offsets receive
one Z reflection. The Euler helper constructs the source rotation and converts
it into the native basis before postmultiplication. Scale and length are unchanged
by the basis conversion. Left/right bones have separate source records; the
evaluator never invents a mirrored counterpart.

The source controller iterates ascending `BoneLocation`, retaining list order
within each location. Locations 0 and 1 are Unknown and BodyTop; accessory slot
`n` is `10+n`. For the current assembled avatar, native BodyTop lookup stays
within `p_cf_body_bone` and excludes nested `chaF_`/`chaM_` character subtrees.
Isolated head or synthetic rigs without that root use unique names in the supplied
rig. Accessory subtrees are outside the supported assembly. The original chooses
the first duplicate name in a depth-first traversal; this port rejects ambiguity
and overlapping active records rather than depend on a changed import order.

The source tracks which properties changed and restores its baseline when a
modifier becomes identity. A static evaluator supplied with a fresh baseline
gets the same resulting pose without those per-frame bookkeeping flags. Missing
outfit entries and identity entries have no effect.

## Explicit limits

The native evaluator does not run dynamic bones, source gravity correction,
animation-driven partial baseline collection, or `BoneEffect` callbacks. The
source marks BodyTop names starting `cf_d_sk_`, `cf_j_bust0`, `cf_d_siri01_`, and
`cf_j_siri_` for its special dynamic-baseline path. Active records in these
families fail with a specific unsupported-behavior message. Ordinary position,
scale, length, and rotation records do not depend on an animation runtime and
remain supported.

For reference, additional source effects multiply scale and length, and add
position and **Euler-degree vectors before quaternion conversion**. This is
documented in the evidence but is not exposed as executable callback support.

Scale/position-only adjustments preserve existing matrix axes, including signed
or zero scale when the resulting rig remains valid. Rotation requires a freshly
shaped baseline whose local scale components are known positive. It rejects
nonpositive authored scales, matrix-only authored nodes, and singular, reflected,
or sheared rotation bases. Two negative scales also have a positive determinant;
the authored-scale check catches that case. Arbitrary signed baseline matrices
cannot reveal their original TRS signs, so preserving such signs through a future
animation/modifier stack requires a richer pose representation. The current
source body/face shaping stages preserve positive local scales.

Source missing targets are silently ignored; the native evaluator reports them
because a missing bone usually means the selected rig does not support that
modifier. No saved record is silently redirected to a different scope or bone.

## Verification

`SourceBoneModifierTests.swift` covers explicit baseline use, noncommuting
rotation composition, the distinction between length and scale, coordinate
selection, identity/reset behavior, repeated application, signed scale without
rotation, scope filtering, ambiguous/missing targets, and unsupported dynamics.
It includes the two-negative-authored-scale regression.

The private fixture applies original array records with independent NumPy
position/scale operations and quaternion composition, then reflects complete
source matrices into the native basis. Eight cases cover combined properties,
global and coordinate-specific records, missing coordinates, length plus
position, negative scale, and simultaneous parent/child changes. Local and world
matrices are compared, with float tolerances rather than a bitwise Unity claim.

```sh
IKKOKU_ABMX_REFERENCE="$PWD/.local/reverse/rigs/source-abmx-reference.json" \
IKKOKU_ABMX_MODIFIERS="$PWD/.local/reverse/rigs/source-abmx-example.json" \
IKKOKU_SOURCE_AVATAR="$PWD/.local/reverse/rigs/source-avatar.json" \
swift test --package-path Packages/Engine --filter sourceBoneModifier
```

The local avatar check resolves the three example targets and evaluates every
skin palette. Eight formal Python tests cover plain/compressed MessagePack,
current data versions, null-entry repair, constructor rejection of null/empty
arrays, truncation, bounded inputs/expansion, unsupported-scope diagnostics,
duplicate identities, and invalid numeric values. These checks cover the stated
static behavior; they do not establish compatibility with complete source
character cards or the original managed plugin runtime.
