# Original character cards and Extended Save

Reviewed 2026-09-25 against the original-card reader/writer and Maker integration.
This reference covers supported wire formats, preservation and editing. See
[Maker assets](maker-assets.md), [card appearance](card-appearance.md) and the
[component audit](../../component-audit/character-and-mods.md) (CM-20–28;
CMT-02, CMT-08–11) for rendering scope and pending work. Commands run from the
repository root; recorded fixture results are historical evidence, not new runs.

The native `SourceCharacterCard` reader opens the installed game's character-card
framing, retains the entire input byte for byte, and exposes selected settings to
Maker. It reads 52 face values, 44 body values, and current ABMX card data. The
settings adapter applies all shape values after matching the selected assembly's
sex, head and body-bone identities. Supported static ABMX modifiers remain a
separate layer.

This is an import, edit and preservation path. Saved Sideloader references can
also be checked against the mounted native mod library, with catalog matches and
typed asset dependencies reported separately. That lookup is diagnostic. Actual
geometry and material application use `SourceMakerLibrary` and appearance
sidecars: supported normal assemblies bind all 44 body and 52 face slots, load a
bounded set of card-selected hair/clothes/accessories, and apply supported colors,
patterns and makeup. Missing conversions remain explicit diagnostics and can
retain reference geometry. The local Maker registry has no GUID-bearing geometry
entries, so preserving a mod identity does not establish modded appearance.
The native edited-card writer now changes validated shape and color fields while
preserving all unrelated wire bytes. Serialization support does not imply that
every retained asset selection or managed plug-in has a native renderer.

## Evidence and reproduction

The contract and source hashes are recorded in
`.local/reverse/cards/contract.json`. Its evidence includes the installed
`ExtensibleSaveFormat.dll`, the game's `Assembly-CSharp.dll`, the installed
MessagePack implementation in `Assembly-CSharp-firstpass.dll`, and the relevant
decompiled `ChaFile`, `BlockHeader`, `ChaFileCustom`, `ChaFileDefine`,
`ExtendedSave`, `PluginData`, `VersionFormatter`, and dynamic formatter classes.
All original assemblies, decompiled source, extracted data, and generated
evidence stay in ignored `.local/` paths.

`Tools/reverse/analysis/card_contract.py` is an independent Python framing oracle.
Its token reader tracks exact MessagePack byte spans without loading managed
types. The fixture writer uses `msgpack`; fixtures contain a blank PNG and
synthetic settings, including the previously generated synthetic ABMX payload.
It does not launch the game or execute plug-ins.

From the repository root:

```sh
.local/reverse/unitypy-venv/bin/python Tools/reverse/analysis/abmx_contract.py
.local/reverse/unitypy-venv/bin/python Tools/reverse/analysis/card_contract.py
.local/reverse/unitypy-venv/bin/python -m unittest discover \
  -s Tools/reverse -p 'test_card_contract.py' -v
```

The first command supplies `.local/reverse/mods/abmx/synthetic.boneData.bin` if
needed. Card generation records evidence hashes and produces current, legacy,
precedence, unknown-footer, PNG-free, and broken-legacy fixtures plus JSON reports.
Each report includes input and block hashes, exact offsets, selected extension
source, raw binary field spans, shape values, and diagnostics. Fixture generation
is deterministic for the same synthetic ABMX input. The 24 Python card tests
passed when this runbook was added; the source evidence hashes also matched the
recorded contract.

To inspect one explicitly selected local card without rendering its PNG:

```sh
.local/reverse/unitypy-venv/bin/python Tools/reverse/analysis/card_contract.py \
  --card .local/reverse/cards/selected-card.png \
  --output .local/reverse/cards/selected-report
```

The report is written to `card-report.json` under that output directory. The
helper requires evidence output beneath the repository's ignored `.local/`.
This command reads a selected file; it does not discover or copy a card library.

## Recovered framing

Integers written by `BinaryWriter` use little endian. MessagePack has its own
token-specific byte order. A .NET string is a seven-bit encoded UTF-8 byte count
followed by those bytes, not a character count.

```text
optional PNG, ending after IEND and its CRC
int32 productNo = 100
.NET string "【KoiKatuChara】"
.NET string cardVersion = "0.0.0"
int32 facePngLength; raw face PNG bytes
int32 blockHeaderLength; MessagePack block header
int64 payloadLength; raw block payload
optional legacy Extended Save or other trailing bytes

block header = { "lstInfo": [{ "name", "version", "pos", "size" }, ...] }
```

Block positions are offsets into the payload. Header order does not determine
payload order. The installed Extended Save hook inserts its header record before
the base records but appends its data after the base payload. The source lookup
uses the first matching block name.

The supported `Custom` block version is `0.0.0`. Its body contains three
independently length-prefixed MessagePack records: face, body, and hair. Current
face/body versions are `0.0.2`; the installed hair version is `0.0.4`. The shape
adapter decodes face/body fields. Separate record adapters decode supported hair,
appearance and coordinate fields while retaining their original bytes. The
supported `Parameter` block version is `0.0.5`; character sex comes from its
`sex` field. Its optional `exType` field defaults to zero when absent and must
be a signed Int32 when present. Nonzero values select special original character
assemblies and are rejected by the native preview, while remaining valid opaque
identity data for preservation and edited-card export. `VersionFormatter` writes a version as a MessagePack string, or nil
for a null version. The current native settings adapter requires the exact
supported non-null version strings.

## Extended Save selection and PluginData

The installed current format is a `KKEx` block with version string `"3"`, holding
an uncompressed MessagePack dictionary. The source load hook seeks to:

```text
payloadEnd - sum(all block sizes) + firstKKEx.pos
```

For ordinary gap-free cards this is the normal payload base plus `KKEx.pos`.
The Python oracle and native reader reproduce that expression, including gapped
payloads. They read the requested bytes from the complete bounded input, matching
`BinaryReader.ReadBytes`: a read may cross the declared payload boundary into
trailing data, or return a short result at end of file. The selected data must
still decode as the expected MessagePack dictionary. This behavior is tested
independently from the ordinary block slices retained for inspection.

The source postfix also checks for the legacy trailer:

```text
.NET string "KKEx"
int32 version = 2
int32 positiveLength
raw MessagePack dictionary
```

A successfully decoded legacy version-2 trailer replaces the current version-3
dictionary. This remains true if current data failed to decode. Malformed legacy
data leaves an already decoded current dictionary selected. Unsupported versions,
unknown trailers, and malformed extension bytes remain preserved with diagnostics.
This reproduces the selected data, without invoking either hook or its events.
Legacy payloads use the same short-read behavior: a positive declared size can
exceed the remaining stream if the actual bytes still form a valid dictionary.
The oracle reports both `declaredSize` and actual `size` for this payload.

Each dictionary value is an integer-key MessagePack object encoded as an array:

```text
pluginID -> [version: Int32, data: map<string, object> | nil, ...extraSlots]
```

The dynamic formatter initializes field locals before constructing the object,
then assigns those locals to writable fields. Consequently `[]` yields version
zero and null data, and `[7]` yields version seven and null data, even though the
`PluginData` constructor initializes an empty dictionary. An explicit null second
slot remains null. Additional slots are skipped by the source formatter; their
original bytes remain in the native card. Version values must fit signed Int32;
booleans are not accepted as integers.

A null plugin value is accepted by the source reader and removed by its writer
before saving. The Python oracle reports it as null. The native adapter excludes
it from the executable settings dictionary, reports it, and retains its bytes in
the original card. A null top-level dictionary yields no applied entries.
Duplicate dictionary keys are invalid in the source `Dictionary.Add` path; the
typed native map also rejects them. Unknown plug-in data is kept without running
it or interpreting arbitrary managed objects.

The supported ABMX entry uses data identity `KKABMPlugin.ABMData`, version `2`,
and binary field `boneData`. The nested bytes are the original ABMX plain or
LZ4 MessagePack payload; the native decoder consumes them directly. This identity
differs from the ABMX plugin GUID. See [ABMX behavior and limits](../mods/abmx.md)
for coordinate defaults, null-entry repairs, transform order, and unsupported
accessory/dynamic behavior.

## Saved Sideloader references

The recovered `UniversalAutoResolver` hook selects
`EC.Core.Sideloader.UniversalAutoResolver` before
`com.bepis.sideloader.universalautoresolver`, including when the EC entry exists
but has no `info` field. A null EC plug-in entry allows the other marker to be
selected. The hook does not inspect `PluginData.version` for this payload.

The `info` field is an array of binary values. Each binary value is an
uncompressed MessagePack `ResolveInfo` map with string fields `ModID`, `Property`,
`Author`, `Website`, and `Name`, and signed Int32 fields `Slot`, `LocalSlot`, and
`CategoryNo`. Missing fields default to nil or zero. The GUID setter trims source
whitespace; matching remains case sensitive and does not normalize Unicode.
Repeated known map keys validate each value and keep the last value. Separate
records with the same exact property use the first record for that destination.

The saved `CategoryNo` is metadata. Lookup uses the category belonging to the
actual field in the card, along with the record's saved `Slot`, trimmed GUID and
unprefixed catalog property. The report retains both the saved record and actual
destination so mismatched categories remain visible. It never substitutes the
record's `LocalSlot` or the current field's slot for the saved `Slot`.

The native decoder retains each complete binary record and its hash, including
unknown fields. It rejects null records, trailing bytes after a record, invalid
field types, more than 10,000 records, records larger than 1 MiB, or more than
64 MiB of record data. These are native bounds rather than original game limits.
The source behavior and evidence hashes are recorded in
`.local/reverse/cards/resolver/contract.json`. Reproduce the independent oracle
and synthetic marker-precedence fixtures with:

```sh
.local/reverse/unitypy-venv/bin/python Tools/reverse/analysis/resolver_contract.py
.local/reverse/unitypy-venv/bin/python -m unittest discover \
  -s Tools/reverse -p 'test_resolver_contract.py' -v
```

## Native preservation and bounds

`SourceCharacterCard.preservedData` is the exact original input, with its SHA-256.
`thumbnailData`, `faceThumbnailData`, `headerData`, individual block data, and
`trailingData` retain their original bytes. In particular, native `trailingData`
includes a legacy trailer even when that trailer was successfully decoded; the
Python report's `footer` describes only the bytes remaining after successful
legacy parsing. These are different reporting conventions, not discarded data.

Decoding selected fields does not mutate their original bytes. Unknown blocks,
plug-ins, future array slots, and accepted payload gaps survive in the retained
snapshot. An import failure does not modify its source file. Explicit edits use
the token-preserving writer described below.

The native reader deliberately has narrower framing acceptance than the source
oracle: block names must be unique and valid, ranges must fit the payload, and
nonempty block ranges cannot overlap. Typed MessagePack maps reject duplicate
or non-string keys, even where an original generated class formatter may have
accepted repeated field names. This is reported as unsupported input rather than
guessed source behavior.

Current implementation bounds are:

| Bound | Native reader | Python oracle default |
| --- | --- | --- |
| Complete card | 256 MiB; regular file required by `load` | 128 MiB |
| Block header | 1 MiB; 1,024 blocks | 4 MiB; 256 blocks |
| Declared block payload | Within 256 MiB card limit | 64 MiB |
| MessagePack message | 64 MiB; header overrides this to 1 MiB | Within applicable framing limits |
| MessagePack values | 1,000,000; 64 container levels | 200,000 nodes; depth limit 64; 100,000 items per container |
| Plug-ins | 4,096; identity at most 4,096 UTF-8 bytes | 4,096 |
| .NET strings | 1 MiB; checked seven-bit Int32 length | 1 KiB for framing strings |
| PNG | CRC checked; 100,000 chunks; bounded by card bytes | CRC checked; 16 MiB; 4,096 chunks; dimensions 1–16,384 |

The Python MessagePack scalar and string limits are respectively 16 MiB and
1 MiB. Both implementations reject truncated tokens, invalid lengths, reserved
tokens, and extra bytes after a parsed MessagePack value. The face thumbnail is
retained as opaque length-prefixed bytes rather than decoded as an image.
These are implementation resource bounds, not claimed original game limits.

## Native CLI and Maker

After building the inspector, the original-card command is:

```sh
swift run --package-path Packages/Engine ikkoku-inspect card \
  .local/reverse/cards/synthetic-current.png
```

It reports original and block hashes, preserved byte counts, selected extension
format (`block-v3`, `trailer-v2`, or `none`), plug-in IDs/versions/keys, shapes,
ABMX modifier count, saved mod-reference metadata, and diagnostics. Unsupported
customization, ABMX data, or resolver metadata is reported independently after
framing succeeds. The command does not render the thumbnail, write a replacement
card, or execute plug-ins.

To check a selected card's saved mod identities against an imported library:

```sh
swift run --package-path Packages/Engine ikkoku-inspect card-mods \
  .local/reverse/cards/selected-card.png \
  .local/reverse/mods/library/library.json \
  .local/reverse/mods/catalog-contract.json
```

This reports each saved resolver record's original slot, runtime `LocalSlot`,
GUID, property, category, original byte count and hash. A recognized card
destination is reported separately from the saved metadata. Direct catalog
matches include the selected CSV path, row and fields; typed dependencies include
the requested bundle and asset names, expected type, availability and provider.
The command uses the explicit default native profile and reports its unresolved
package choices. A malformed resolver payload fails this dedicated command.

`LocalSlot` is retained only as evidence. It is a runtime counter and is never
used as a persistent native asset identity. A catalog match establishes which
installed row a supported saved reference names; it does not establish that the
referenced appearance has been converted or applied. The JSON explicitly reports
`appearanceApplied: false` for every record because this command does not apply
appearance. Compatibility migrations and missing-mod substitutions remain
unimplemented. Bounded [translated plugin execution](../mods/plugin-execution.md)
and [installed-plugin adapters](../mods/native-adapters.md) exist separately;
card loading never runs an arbitrary managed DLL or treats opaque KKEx as code.

The report distinguishes these outcomes:

| Status | Meaning |
| --- | --- |
| `resolved` | A direct supported reference has a matching mounted catalog row. |
| `shadowed` | An earlier saved reference takes priority for this destination. |
| `unmatchedProperty` | The saved property does not match a supported card destination. |
| `compatibilityRequired` | Resolving this reference requires an unimplemented compatibility rule. |
| `libraryNotLoaded` | No native content library was supplied. |
| `catalogUnavailable` | No source catalog and contract were supplied. |
| `modNotMounted` | The referenced mod is not mounted in this profile. |
| `catalogEntryMissing` | The mounted catalog has no matching supported entry. |
| `metadataOnly` | The record is preserved, but no card-destination scan is available. |

Dependency status is independent: `convertedTexture` means a native texture is
available, `sourceOnly` means a matching source asset has been indexed but still
needs conversion, and `unresolved` means the available inventory cannot answer
the reference. Unresolved inventory is not proof that an asset is absent from
the original game installation. Type mismatches and ambiguous source bundles
are reported explicitly.

In Maker, choose **File → Import Source Card…** and an original-format character
card. The app locates the matching normal male/female assembly, including
registered heads 0, 200 and 201, or reuses a matching open source rig. **Open
Source Rig…** remains available for explicit local manifests. The settings
adapter checks sex and head identity, selects standard or corrected body-bone
options, and requires complete 44-body/52-face destination bindings. Special
`exType` assemblies and resolver-backed mod heads are rejected. All applied shape values must be in
`0...1`; extended ranges cause an explicit preview error. The writer can still
retain and serialize finite extended shape values without claiming they can be
rendered by this preview.

Maker validates the candidate rendered pose and bounds before replacing settings.
It enables customization and ABMX, selects coordinate zero, retains the original
card, and shows scope diagnostics under **Imported card settings**. Normal male
Maker height is set to the original caller's fixed 0.6; a subsequent Maker export
serializes the current shape values, including that height. Existing
expression controls remain separate from imported shape settings. **Card mod
references** shows the direct lookup and dependency report. It refreshes when a
mod library is loaded, reloaded or unloaded; the imported shape values and bone
modifiers remain in place. Library changes validate the replacement preview
before committing it. Malformed resolver metadata produces a visible diagnostic
without rejecting otherwise valid shape settings, and the entire original card
remains retained. **Open Card…**
still reads the separate native Ikkoku card format. **Save Card…** and **Send to
Studio** are disabled while a source preview is active because that preview is
not yet a complete native character.

For a GUI launch with the same imports, set `IKKOKU_OPEN_RIG` and
`IKKOKU_SOURCE_CARD` to explicit local paths. For an offscreen Metal capture:

```sh
IKKOKU_CAPTURE_RIG="$PWD/.local/reverse/rigs/source-avatar.json" \
IKKOKU_SOURCE_CARD="$PWD/.local/reverse/cards/synthetic-current.png" \
IKKOKU_SOURCE_EXPRESSION=defaults \
IKKOKU_CAPTURE_PRESET=face \
IKKOKU_CAPTURE_W=900 IKKOKU_CAPTURE_H=900 \
IKKOKU_AUTOCAPTURE="$PWD/.local/reverse/cards/native-card-face.png" \
.local/build/Build/Products/Debug/Ikkoku.app/Contents/MacOS/Ikkoku
```

This uses the selected clothed source-avatar assembly and the actual Metal
renderer. `IKKOKU_SHAPE_CONTRACT` can supply an explicit contract; otherwise its
sidecar is loaded from the rig directory. Source-card capture rejects concurrent
`IKKOKU_SOURCE_BODY`, `IKKOKU_SOURCE_FACE`, `IKKOKU_SOURCE_HEIGHT`, or
`IKKOKU_BONE_MODIFIERS` overrides. `IKKOKU_MOD_LIBRARY` can still mount a native
content profile for explicit converted-texture appearance bindings. Card-selected
geometry is prepared through the separate Maker library located automatically or
supplied by `IKKOKU_MAKER_LIBRARY`; a mounted zipmod catalog alone does not convert
or assemble its geometry.

Native tests in `SourceCharacterCardTests.swift` cover byte preservation,
truncation, block/range/PNG validation, extension precedence, PluginData defaults,
shape selection, and the ABMX bridge. Set `IKKOKU_SOURCE_CARD_FIXTURE` and
`IKKOKU_SOURCE_CARD_ORACLE` to a generated fixture and corresponding JSON report
to enable the independent Python/native comparison. Tests and synthetic captures
do not establish full compatibility with saved characters or arbitrary mods.

Remaining work includes expanding converted selections, transactional asset-ID
and resolver edits, compatibility migrations, unsupported dependency conversion,
special/modded heads, standalone coordinate-card framing and additional behavior
adapters. The current source UI reports selected assets but does not edit their
identities. Native rendering coverage is distinct from preserving and editing the
original card format.


## Editing and exporting original cards

`SourceCharacterCard.editedData(_:)` accepts `SourceCharacterCard.Edits` and
returns a new `Data` value. It never writes or overwrites a file. Its supported
edits are the 52 face values, 44 body values, existing RGBA color arrays in
face/body/hair records, existing RGBA colors in a selected coordinate's
clothes/accessory/makeup records, and optional replacement thumbnails. Shape and
color numbers must be finite Float32 values with the expected array lengths.
Editing a sex or asset identity is deliberately outside this API: retaining the
old Sideloader resolver entry after changing its destination would create a
misleading identity. Hair selections, clothing selections, card parameters,
ABMX, resolver metadata and other plug-in bytes remain unchanged.

The writer indexes original MessagePack token spans. Only numeric leaves whose
Float32 values actually changed are replaced, using the source Float32 wire
representation. The unchanged map keys, map order, integer and float encodings,
array headers, binary values, extension values and unknown fields remain exact.
A no-op export returns the byte-identical original. Editing one coordinate leaves
all other coordinate binary values untouched. `recordData(_:)` and
`recordFields(_:)` expose independently version-validated records for typed
appearance import, without running managed code.

The Custom record lengths and Coordinate binary lengths are updated as needed.
The payload remains in its original physical order, with original gaps retained;
header ordering is preserved independently. Only changed header `pos` and `size`
values are rewritten. The outer header length and payload length are corrected,
while the exact current Extended Save block and the exact legacy/unknown trailer
are copied unchanged. The result is decoded again, checking edited shapes,
unchanged blocks and trailer preservation before it is returned.

An empty optional thumbnail removes that image; `nil` retains the original.
Nonempty replacement thumbnails must contain exactly one CRC-valid PNG ending
at IEND, with no appended card data. A fresh native render can therefore replace
the original thumbnail without reading or displaying its pixels. The face
thumbnail is validated by the same replacement rule, while an unedited original
face-thumbnail blob remains opaque.

Ambiguous or unsupported edits fail before producing an output: overlapping
field edits, missing destinations, mismatched versions, nonnumeric/invalid color
arrays, unsupported coordinate indexes, or an empty block pointing inside a
resized block. A gapped payload containing a current `KKEx` block also rejects
payload edits because the installed hook's `payloadEnd - sum(sizes)` lookup can
refer to bytes outside that block. No-op exports and image-only edits retain that
layout. Standalone coordinate cards and arbitrary field/plug-in serialization
remain outside this writer.

The dedicated Swift tests cover no-op identity, male and finite extended shape
serialization, all six editable record types, selected-coordinate preservation,
unknown fields, legacy precedence, payload gaps, reordered headers, offsets,
opaque hair, invalid edits and replacement PNG validation. To generate explicit
synthetic round-trip evidence and verify it with an independent parser:

```sh
IKKOKU_CARD_EDIT_OUTPUT="$PWD/.local/reverse/cards/edited-roundtrip" \
  swift test --package-path Packages/Engine --filter sourceCardEditing
.local/reverse/unitypy-venv/bin/python Tools/reverse/analysis/card_roundtrip.py
.local/reverse/unitypy-venv/bin/python -m unittest discover \
  -s Tools/reverse -p 'test_card_roundtrip.py' -v
```

The fixture uses a synthetic male card, two coordinates, unknown extension
values, a current Extended Save block and an overriding legacy trailer. The
independent Python token walker verified 27 edited numeric leaves, six relocated
header fields, a replacement face PNG, and exact bytes for every other token in
the edited records. Its report is written to
`.local/reverse/cards/edited-roundtrip/verification.json`. This establishes
structural compatibility with the recovered source reader and writer framing;
it is not evidence of a complete character rendered or round-tripped inside the
Windows game.

Maker exports a new file through **Export Edited Source Card…** and refuses the
imported filename. It writes independent 504×704 full-body and 256×256 face PNGs.
Native-only ABMX changes cannot be exported: the imported modifiers must be
restored and enabled because the original plug-in payload is preserved.

`Tools/reverse/analysis/maker_roundtrip.py` independently audits explicit app
exports, including all 96 shape values, selected color leaves, every untouched
record token and opaque block, header relocation, and both PNG dimensions/CRCs.
