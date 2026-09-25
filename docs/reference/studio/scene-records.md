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
- Implement route path/ease/orientation/play/stop and childRoot placement, then
  source scene effects, camera-object behavior and sound (`ST-T11`, `ST-T12`).
  Route records currently have no runtime or edited writer.
- Add original scene topology edits/reference remapping and GUID-specific plugin
  callbacks/save adapters while preserving source identities (`ST-T03`, `ST-T13`).

Use the linked audit acceptance criteria for each task. Parsing success, a rendered
character and byte-preserved plugin data remain three different compatibility
claims; none establishes complete original scene restoration.
