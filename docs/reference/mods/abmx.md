# ABMX static bone modifier bridge

Reviewed 2026-09-25. Current card-v2/coordinate-v3 decoding and ordinary static
bone adjustments are implemented, and card-v1 legacy text is migrated as the
original migrates it (2026-11-18, #403); full ABMX compatibility remains **mid-stage**.
The [character/mod audit](../../component-audit/character-and-mods.md) (CM-39,
CMT-05) tracks dynamic/accessory scopes, legacy data and a future plugin writer.

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
| Character card | 2 | 1, 2 | 1 (legacy text), 2 |
| Coordinate/outfit | 3 | 2, 3 | 3 |

Current card-v2 and coordinate-v3 values contain an LZ4 MessagePack
`List<BoneModifier>`. The integer-key objects are arrays:

```text
BoneModifier = [BoneName, CoordinateModifiers, BoneLocation]
BoneModifierData = [ScaleModifier, LengthModifier, PositionModifier, RotationModifier]
Vector3 = [x, y, z]  // serialized float32 elements
```

These are the arrays the current plugin writes. Its int-keyed formatters read
an array of any length: a missing trailing key takes its type's default, and
keys beyond the last known one are skipped. Older saves therefore load in the
shorter layouts, and the converter reads them the same way:

| Saved array | Read as |
| --- | --- |
| `[BoneName, CoordinateModifiers]` | `BoneLocation` 0 (`Unknown`) |
| `[ScaleModifier, LengthModifier]` | position and rotation `(0,0,0)` |
| `[ScaleModifier, LengthModifier, PositionModifier]` | rotation `(0,0,0)` |
| any longer array | extra fields skipped, one `skipped-unknown-fields` warning each |

The two-field record with two-field entries is the only layout found in a local
corpus of version-2 character cards. Records with fewer than two fields are
rejected, as the original's constructor rejects them. Coordinate entries with
fewer than two fields are also rejected: the original would read them with a
zero `ScaleModifier` or `LengthModifier`, which is not implemented, and no known
card uses that layout. The generated object formatter for these two types is not
in the recovered C#; the recovered `Vector3` formatter follows the same pattern.
The installed plug-in confirms the defaults: reading a card saved in the
two-field layout in CharaStudio, ABMX's own reader produced `BoneLocation` 0 and
zero position and rotation, with scale and length as saved, and the converter
matches that read exactly. After the load, ABMX resolves location 0 to BodyTop
for bones it finds in the body.

`CoordinateModifiers` contains one or more `BoneModifierData` arrays. One entry
is coordinate-independent. Multiple entries are indexed by the current outfit;
an index beyond the stored array supplies no modifier for that outfit. Defaults
are scale `(1,1,1)`, length `1`, position `(0,0,0)`, rotation `(0,0,0)`.

The serializer leaves MessagePack shorter than 64 bytes uncompressed. Otherwise,
it writes extension type **99**, with a MessagePack int32 expanded byte count
followed by a raw LZ4 block. Its writer forces an ext32 header and a signed-int32
size header. The converter accepts both the plain and compressed forms.

The original plugin additionally migrates legacy card text and coordinate-v2
dictionaries. Card v1 text is ported ([below](#card-v1-legacy-text)); the
coordinate-v2 migration is not. The converter matches the current
serialization constructor's repair of individual null coordinate entries to
identity values, retaining one warning per repaired entry in `diagnostics`.
A null whole coordinate array or an empty array is rejected, matching the
constructor's explicit exceptions. Shorter and longer records and entries are
read as described above.
These behaviors are confirmed in the installed constructor; no inference from
empty-array behavior in `GetModifier` is needed. The standalone Python converter
consumes extracted `boneData`; it does not parse whole cards. The native `SourceCharacterCard` layer now performs card framing and
Extended Save selection before calling the binary decoder described below.

## Card v1 legacy text

A card whose `KKABMPlugin.ABMData` record has version **1** stores `boneData` as
a **string**. `BoneController.ReadModifiers` passes it to
`OldDataConverter.MigrateOldExtData`, whose rules the native decoder
(`SourceBoneModifiers.decodeLegacyText`) and the Python converter
(`convert_legacy`) follow, with the same messages. Recovered source: the same
`KKABMX.dll` f3e2d987 (`OldDataConverter.cs`, `BoneController.cs` 396–419,
`BoneModifier.cs` 92–126).

The text is a list of tokens, each `field0,name,field2,x,y,z[,length]`:

| Step | Original | Native |
| --- | --- | --- |
| Tokens | `text.Split()` with no separators, then `Trim()`; empty tokens are dropped | split on the `char.IsWhiteSpace` set below |
| Fields | `Split(',')`, empty fields kept; tokens with fewer than 6 fields dropped | same |
| Group key | the name (field 1) without a trailing `__<one character>`: it is trimmed when its UTF-16 units `[len-2]` and `[len-3]` are both `_` | same, in UTF-16 units |
| Group order | `GroupBy`: first occurrence | same |
| Order in a group | `OrderBy` on the full name, stable | ordinal UTF-16 order, stable (see culture below) |
| Values | Scale = `float.Parse` of fields 3–5; Length = field 6, or 1 when the token has 6 fields; fields 0, 2 and 7 onward are never read | same; Position and Rotation (0,0,0) |
| Parse failure | the token is skipped and logged | skipped, with a `skipped-legacy-line` warning (token number, bone, field) |
| Coordinate list | more than 7 parsed tokens: the last 7; 2 to 6: the last 1; 1 and 7 unchanged | same, with a `legacy-coordinates-truncated` warning when tokens are dropped |
| Group with no parsed token | no modifier | same |
| Record | `new BoneModifier(key, Unknown, list)`: location 0 | location 0, and the same dynamic-family warning as card v2 |

Whole-card outcomes:

- **Bone name too short to index.** `GetTrimmedName` reads `name[len-2]`, then `name[len-3]` only when the first is `_`. A name shorter than 2 units, or `_` plus one unit, throws. `GroupBy` evaluates every token before the first group is read, so `ReadModifiers` catches the exception and the character loads with **no ABMX at all**. The native decoder returns an empty document with a `legacy-data-dropped` warning ("…the original drops all ABMX data for this card").
- **Empty key.** A name of `__` plus one unit trims to an empty key. Once its group has a parsed token, the `BoneModifier` constructor throws for it, with the same outcome and the same warning.
- **Missing or empty text.** No modifiers. `MigrateOldExtData` returns null for a missing key or an empty string, and `OnReload` then groups over that null and throws, so a freshly loaded character has no ABMX. Not ported: on a reload into an existing character, the earlier modifier list would stay. Whitespace-only text reads as an empty list, with the same result.
- **`boneData` not a string.** The original's reader returns null, as above. The native decoder returns an empty document with a `legacy-bone-data-not-text` warning.
- **Other plug-in versions.** The original reads them as empty (`NotSupportedException`, caught). The native decoder still refuses them (unchanged).

Divergences and `[corlib]` assumptions. Mono's corlib (`string.Split`, `string.Trim`, `float.Parse`) is not in the recovered set. Where a rule depends on it, the documented .NET behaviour is used. The original player's results for each are from the #403 phase in [Checked against the original](#checked-against-the-original):

- **Culture.** The original parses with the current culture and orders names with a culture-sensitive comparer. The native decoder parses with the invariant culture (`.` decimal) and orders by ordinal UTF-16. Fields are split on `,`, so a comma-decimal culture would split the numbers themselves: the original's own field count needs the `.` decimal. The two orderings agree on the suffix forms in use (none, or `__` plus a digit). They differ only for other suffix characters, for example `__A` against `__a` or `___`. Observed in the original player: the group `cc` with the names `cc__a`, `cc___`, `cc__A`, `cc__1`, `cc__0`, `cc__2`, `cc__3`, in that input order, is read in the order `cc___`, `cc__0`, `cc__1`, `cc__2`, `cc__3`, `cc__a`, `cc__A`. The native ordinal order is `cc__0`, `cc__1`, `cc__2`, `cc__3`, `cc__A`, `cc___`, `cc__a`.
- **Whitespace** `[corlib]`: `char.IsWhiteSpace`, spelled out as U+0009–U+000D, U+0020, U+0085, U+00A0, U+1680, U+180E, U+2000–U+200A, U+2028, U+2029, U+202F, U+205F and U+3000. U+180E is included because Mono's Unicode data predates its move out of Zs. U+001C–U+001F, U+200B and U+FEFF do not separate tokens; Python's `str.split()` would split on U+001C–U+001F, so the converter uses this explicit set. Checked in the original player on 17 separators, each placed between two tokens: U+0009, U+000B, U+001C, U+001F, U+0085, U+00A0, U+1680, U+180E, U+2000, U+200A, U+200B, U+2028, U+2029, U+202F, U+205F, U+3000 and U+FEFF. Fourteen agree with this set. Three differ, so the original's `Split()` is not `char.IsWhiteSpace` for them:
  - U+180E does not separate tokens in the original;
  - U+200B and U+FEFF do.

  The native set is unchanged for now; #417 aligns it with the original. Only tokens containing these three characters read differently, and the corpus separates tokens with CR+LF only.
- **Number grammar** `[corlib]`: `NumberStyles.Float | AllowThousands`, invariant. A token has no whitespace or commas left, so the accepted forms are `[+-]?(d+(.d*)?|.d+)([eE][+-]?d+)?` and the case-sensitive symbols `Infinity`, `-Infinity` and `NaN`. Only ASCII digits are accepted. The value is parsed as a double, then rounded to float32, as Mono does. `-0` keeps its sign. Checked in the original player on 22 strings:
  - The 11 finite strings give the same float32 bits, including `1e-45`, `1e-50`, `3.4028234663852886e38`, and `1.0000000596046448` → `3f800000`, which is a double-rounding case.
  - The 6 strings this grammar rejects (`infinity`, `+Infinity`, `0x10`, `1e`, a full-width digit and `1_0`) are skipped by the original too.
- **Non-finite values.** The original applies `NaN` and `±Infinity`; the player read them as `ffc00000`, `7f800000` and `ff800000`. The native decoder refuses the character: "…has a non-finite or out-of-range value in field K; ABMX modifier values must be finite float32 numbers." Only the tokens that reach the character count. A token that is skipped, or that the last-7/last-1 rule drops, does not refuse it.
- **Beyond float32 range.** A value whose double magnitude exceeds `float.MaxValue` refuses the character in either direction, with the same message, even when it would round to `float.MaxValue`. The original differs, as checked in the player:
  - A positive value above `float.MaxValue` is skipped as a parse failure ("Number overflow"). This includes `1e39` and `3.4028235e38`.
  - A negative value between −`double.MaxValue` and −`float.MaxValue` is applied as −∞ (`-1e39` → `ff800000`).
  - A value beyond the double range is skipped in either sign (`1e400`, `-1e400`).
- **Native limits** (not the original's): 16 MiB of text, 10,000 groups, and bone names of at most 1,024 characters with no NUL. These are refusals with the card-v2 messages.

A local census of the version-1 characters in the corpus scenes gives the shapes these rules meet: 12 unique characters and 765 tokens.
- Tokens: every one is CR+LF-separated and has 7 fields; 756 names have a `__` plus digit suffix and 9 have none.
- Values: 3,009 integer strings and 51 decimals, the largest magnitude 1.2. No parse failures and no non-finite values.
- Groups: 108 have 7 tokens and 9 have 1, so the last-7/last-1 rule drops nothing.
- No short names and no repeated full names.

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
For card v1, `--data-version 1` reads the file as the `boneData` string's UTF-8
text and applies the [legacy rules](#card-v1-legacy-text).
The converter validates sizes, finite numeric values, vector arity, duplicate
record identities, and the array layouts above. It records the payload SHA-256
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
or legacy card trailers and invokes that binary decoder. A version-1 record goes to
`SourceBoneModifiers.decodeLegacyText(_:)` instead (`legacyNotText()` when its
`boneData` is not a string); the document then has data version 1 and the text's
UTF-8 SHA-256. Maker's **File → Import
Source Card Settings…** applies the supported shape and modifier subset while
retaining all original card bytes. The associated [card report](../character/cards.md)
describes precedence and the supported surgical shape/color writer. Original-card
export requires the imported ABMX payload to remain unchanged and enabled; it
rejects a replaced or disabled payload because the native JSON adapter is not an
original ABMX writer. For headless rig capture, set `IKKOKU_SOURCE_CARD` to a supported source card instead of separate
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
rig. Converted accessories can be part of the assembled avatar, but their ABMX
locations are outside this static evaluator's supported lookup scope. The original
chooses the first duplicate name in a depth-first traversal; this port rejects ambiguity
and overlapping active records rather than depend on a changed import order.

The source tracks which properties changed and restores its baseline when a
modifier becomes identity. A static evaluator supplied with a fresh baseline
gets the same resulting pose without those per-frame bookkeeping flags. Missing
outfit entries and identity entries have no effect.

## Explicit limits

The ABMX evaluator does not run its dynamic-baseline path, source gravity
correction, animation-driven partial baseline collection or `BoneEffect` callbacks.
The separate native hair dynamics solver does not supply those ABMX callbacks.
The source marks BodyTop names starting `cf_d_sk_`, `cf_j_bust0`, `cf_d_siri01_`, and
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
`SourceBoneModifierLegacyTests.swift` and the Python `LegacyABMXTests` cover the
card-v1 rules case for case, on synthetic text: the whitespace set (including
U+001C–U+001F, which do not split), field counts, suffix trimming in UTF-16,
group and in-group order, the last-7/last-1 rule, parse failures, the number
grammar as float32 bit patterns, non-finite and out-of-range refusals, the
whole-card drop, limits, the card bridge and an apply equal to the matching
card-v2 document.

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
skin palette. The Python contract tests cover plain/compressed MessagePack,
current data versions, null-entry repair, constructor rejection of null/empty
arrays, truncation, bounded inputs/expansion, unsupported-scope diagnostics,
duplicate identities, and invalid numeric values. These checks cover the stated
static behavior. Card framing and byte-preserving edits have their own tests;
none of these checks establishes complete ABMX lifecycle or managed-runtime
compatibility. Source-backed comparisons require the private fixtures shown in
the command; an unset fixture variable is not an original-game parity result.

The next implementation step is a source-backed writer for the selected ABMX
payload before exposing modifier edits in original-card export. Then extend
accessory lookup and dynamic baseline recollection with independently captured
source traces, retaining the original data GUID, bone names, outfit records and
unknown sibling payloads. CMT-05 in the linked audit defines acceptance.

## Checked against the original

**Setup.** The original CharaStudio player (Unity 5.6.2f1) ran with KKABMX 5.4 (`KKABMX.dll` f3e2d987), KKAPI 1.46.1 and ExtensibleSaveFormat 21.1.2.1.
- There were four phases, one probe exec each, on 2026-11-18 (`Tools/reverse/original_abmx_probe.py`).
- The probe reads uploaded scene records only. Nothing in the game folder is written, and the plug-ins and configs are checked by SHA-256. Each phase left the guest clean.
- The scene records and captures stay local.

**Phase 1, the decoder.** One male character whose card holds 7 records in the older two-field layout.
- The native decoder and the Python mirror equal ABMX's own `ReadModifiers` on all 7 records, field by field as float32 bit patterns.
- The records read as location 0 (Unknown). Once the character is loaded, ABMX's live controller holds the same values, with location 0 resolved to BodyTop (1).

**Phase 2, scale.** The same character, framed by a probe camera.
- On ABMX's collected baselines, the static evaluator reproduces the scale of the 7 live bones exactly.
- In scale, the native shape baseline is within 1.4e-8 of ABMX's, and the full static result is within 1.8e-7 of the capture.
- Skin silhouette at 960×720, pixel-centre coverage, against the original's skin render:
  - the captured bones: IoU 0.99967 (3 px apart);
  - the native evaluator: identical to that (0 px apart);
  - no modifiers: IoU 0.739 (2,599 px).

**Phase 3, length, position and rotation.** No saved card in the surveyed scenes carries Position or Rotation, and a Length other than 1 appears on one bone only.
- **Length, from a card.** A second male character with 6 records, including a Length below 1 on `cf_d_kokan`.
  - The captured local position equals baseline × length bit for bit in float32.
  - The native decoder and evaluator reproduce all 6 bones with no difference.
  - Silhouette: the captured bones and the native evaluator both have IoU 0.99975 (1 px). With no modifiers it is 0.711, mostly from `cf_n_height`'s scale.
- **Five synthetic rows.** These were added in memory with ABMX's own `AddModifier` on the phase-1 character, on bones its card leaves alone:
  - a 3-axis rotation (`cf_s_neck`);
  - rotation plus position (`cf_s_forearm01_L`);
  - length plus position on a joint with a 0.25 m offset (`cf_j_forearm01_R`);
  - scale plus position (`cf_s_thigh01_L`);
  - a request for location 0 (`cf_s_spine02`).

  All five held still over two frames.

  | Applied on ABMX's baselines | Rotation | Position | Scale |
  |---|---|---|---|
  | ABMX's formula (Euler Z, X, then Y) | within 2.4e-6° | within 4e-9 | within 9.2e-8 |
  | The native evaluator | within 9.9e-7° | exact | within 1.3e-7 |

  Silhouette: the captured bones have IoU 0.99968 (3 px), and the native evaluator is identical. Without the five rows it is 0.979 (196 px). The original's own renders before and after the five rows differ by 195 px.
- **SaveModifiers.** ABMX serialized the five rows alone (PluginData version 2, 208 bytes).
  - Both decoders read them back bit for bit, as ABMX's own `ReadModifiers` does.
  - ABMX resolved the location-0 request to BodyTop when the row was added and saved it as 1. So this writer produces no stored location 0; reading one is covered by phase 1.
  - The payload is the test vector in `sourceBoneModifierDecodesTheOriginalSaveModifiersPayloadBitForBit`.

**Phase 4, card v1 legacy text (#403).** The comparison was pre-registered before the run. Two v1 characters from the corpus scenes were used: a female with 18 groups (9 with 7 tokens and 9 with 1) and the corpus's only male v1 character (9 groups of 7).
- **Provenance.** Each card's ABMX entry is version 1, with a string `boneData` whose UTF-8 SHA-256 equals the native document's payload hash.
- **The decoder.** ABMX's own `ReadModifiers` equals the native decoder and the Python mirror on all 27 records:
  - names, order and location 0;
  - every Scale, Length, Position and Rotation value as float32 bits.

  The two decoders also agree on the diagnostics: 9 dynamic-family warnings per character and nothing else.
- **Live, observed, unverified.** Once the characters are loaded, ABMX's live controller holds every record whose bone is on the body, with the same values, at BodyTop (1).
  - It holds no record whose bone is not on that body: `cf_d_sk_top` on the female, and all 9 skirt (`cf_d_sk_`) groups on the male body.
  - The native decoder warns on these same dynamic groups.
  - Those bones do not exist on that body, so nothing visible differs.
- **Nine synthetic texts,** read by ABMX's own reader:
  - These match: token counts and the last-7/last-1 rule, field counts and empty fields, the two whole-card drops (an empty list, the exception caught and logged) and blank text.
  - These are the documented divergences, recorded in [Card v1 legacy text](#card-v1-legacy-text): number range, non-finite values and culture order.
  - Whitespace differs on 3 of 17 separators (#417).

**Not checked against the original:** accessory locations, coordinate (outfit) records, the dynamic-baseline families, `BoneEffect` callbacks, and saving to a card or coordinate file.
