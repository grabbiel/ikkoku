# Edited original Studio scenes

Reviewed 2026-09-25 against the working tree. The [Studio audit](../../component-audit/studio.md) is the feature-status and actionable-backlog index; this page records the narrower source contract and its evidence.

`KoikatsuSceneDocument.editedData(SourceSceneEdits)` produces a new original-format 1.0.4.2 scene by replacing bounded byte spans recorded by the source reader. An empty edit returns the exact original bytes. The writer performs no file I/O.

Supported edits are:

- Object transforms identified by original object source key, including nested accessory children.
- Per-object `visible` flags keyed by source object ID, nested accessory children included. The flag is the single byte immediately after the record's `treeState`, four bytes past the end of its 36-byte transform span; the reader records it while reading. The patch is one byte (0 or 1), the current byte must already be 0 or 1 and an unknown key rejects the edit; an edit to the stored value returns the input bytes unchanged. Only the object's own flag is serialized — CharaStudio propagates a hidden parent through the tree at load time, and this writer never propagates.
- Name edits keyed by source object ID, folder, camera and route records only — the kinds whose own record stream carries a name. The reader records the full string span (seven-bit encoded UTF-8 byte length prefix plus the UTF-8 bytes) while reading, and a rename replaces that span with the same .NET `BinaryWriter.Write(string)` encoding, so the file resizes and every following record shifts. An edit to the stored name returns the input bytes unchanged. Characters, items and lights serialize no name (a character's name lives in its card) and have no name destination.
- Camera record `active` flags and route record `active` flags, each keyed by its own record's source object ID. Both are the one-byte bool immediately after the record's name string (for a camera) or its point list (for a route); the reader records each span while reading. Like visibility the patch is one byte, the current byte must already be 0 or 1, an unknown key — or a key whose record is not of that kind, a folder for either destination — rejects the edit, and an edit to the stored value returns the input bytes unchanged. For cameras the app writes these only after the user switches the looked-through camera, and then for every camera record: CharaStudio saves the current view, so the new camera goes true and the losers must go false or their stale `true` wins on reload (load order takes the last active camera). Without a switch the file already reloads to the same winner and nothing is written. Route `active` is the play state at save time; loading a true record resumes playback.
- Character FK bones, IK targets and look-at target transforms; item FK transforms identified by their original ordinal bone name.
- Character `enableFK`, `enableIK`, seven `activeFK` flags and five `activeIK` flags. Flags are written literally; source loading gives IK precedence if both modes are enabled.
- Character animation catalog IDs, speed, pattern, force-loop, options and normalized time; ordered voice playlists and repeat mode, including variable-length replacement.
- Embedded card body/face values, supported color fields, the worn outfit (`Status.coordinateType`, see [source outfit selection](#source-outfit-selection-st-c03-first-slice)), the per-garment clothes state and accessory visibility (`Status.clothesState` / `showAccessory`, see [source clothes state](#source-clothes-state-and-accessory-visibility-st-c03-second-slice)) and face thumbnail, using the existing bounded card editor. Head/sex/bone type, asset IDs, saved resolver identities and opaque card plug-ins remain unchanged.
- Current camera and ten saved camera slots, preserving position, all three Euler angles, all three distance components and field of view. Only the 40-byte version-2 payload changes.
- A replacement scene PNG only when explicitly supplied. It must be one complete CRC-valid PNG; an embedded card cannot acquire a PNG prefix.

Transforms are expressed in the original Unity coordinate basis and Euler degrees. The native app must convert edited transforms back before export. Duplicate or unavailable destinations, invalid group counts, nonfinite values, invalid camera FOV and invalid PNGs reject the entire edit. Object IDs, root dictionary keys, ordering, unedited catalog choices/settings and trailing plug-in bytes are preserved. Changing hierarchy, object type, item identity or plug-in behavior is outside this writer.

The writer validates complete output framing after applying patches in source byte order. Variable-length embedded card, voice-list and thumbnail edits therefore shift following records without reconstructing their bytes. Tests cover modifications both before and after a resized card, nested objects, ordinal Unicode bone identities, unknown trailers and source `Data` slices with nonzero start indices. Reversing transform, visibility, name, camera- and route-active, flag and camera edits restores every original byte.

The retained local evidence includes three independent synthetic scenes and two recovered original scenes containing seven embedded characters. Native test exports combine object, camera, card and kinematic edits. `Tools/reverse/analysis/scene_editing_oracle.py` independently re-reads five exports, verifies four changed cards and checks all nonedited scene fields, original thumbnails, unedited card records and scene/card extension bytes. It never decodes original image pixels.

Generate the optional native evidence by setting `IKKOKU_STUDIO_EDIT_OUTPUT` to an ignored `.local/` directory when running `SourceSceneEditingTests`, alongside `IKKOKU_STUDIO_SCENE_FIXTURES` and `IKKOKU_STUDIO_ORIGINAL_SCENES`. Then run:

```sh
.local/reverse/unitypy-venv/bin/python Tools/reverse/analysis/scene_editing_oracle.py
```

The default report is `.local/reverse/studio-edited/verification.json`. Rendering an edited scene still depends on the separately converted geometry, materials, animation and native plug-in adapters; serialization coverage does not imply execution of the original plug-ins.

## Native workspace layout

The native Studio workspace reserves 250 points for the object tree and 350 for
the inspector. Its toolbar overlays the viewport and scrolls horizontally when
its controls exceed the available width, including the extra FK group picker.
Toolbar content must not contribute a minimum width to the viewport container.
Timeline key markers overlay the scrubber, so their geometry reader takes the
slider's height instead of expanding the timeline row into the viewport.
These layout rules apply to both native and source scenes; they do not change
scene persistence or original Timeline-plugin support.

Visible regression check, 2026-10-17: the previous layout clipped the tree and
right inspector at the minimum window size and devoted roughly half the centre
column to the timeline. With the layout fix, the tree, all five inspector tabs
and full slider values fit at the same minimum size, and the timeline occupies a
single bottom row. Native Window → Move & Resize → Top Left reaches the app's
minimum size on the tested display; Zoom also verifies the larger layout. The
horizontal scrollbar exposes Camera/Capture and timeline controls, FK mode
exposes its group picker, the Scene tab opens, timeline hide/show works and
scrubbing 0→2.5→0 reads back correctly. Xcode 27 Debug build passes. Captures and
source-scene identity remain local; no scene file was saved or changed. This
closes the layout regression only; the full ST-T01 guide/undo/save acceptance
remains separate.

## App boundary and remaining work

The app exports supported existing transforms, per-object visibility, folder/camera/route renames, camera active flags (only after the user switches the looked-through camera, then for every camera record), route play-state `active` flags, FK/IK and activation flags, animation, voice and cameras to a **new file** after checking the source SHA. It renders an explicit edited thumbnail. The app populates `edits.cards` with source face/body shape values and edited card colors that differ from the embedded card's saved values (ST-T06); shape and color edits on one character merge into a single `Edits`, and a value edited back to the saved rate or rgba writes nothing and the file stays byte-identical. Only colors that actually bound a material on the assembled character are exported; an edited color whose ID binds nothing still renders as saved. Its inspector diagnostic says it remains in the native document but is skipped by original-scene export. A selected outfit other than the card's saved one is merged into the same `Edits` as `coordinateType` (ST-C03); choosing the saved outfit again writes nothing. Clothes states and accessory flags that differ from the card's saved `Status` are merged the same way; a state edited back to the saved bytes writes nothing. Thumbnail and other card destinations remain unpopulated, and a native `object.card` override is rejected.

The export validator rejects added/deleted/duplicated objects, reparenting, type changes, and name edits for any record kind other than folder, camera or route (a renamed character keeps its name in its card), plus native assets/materials/cards/hand/appearance overrides, light/effect/timeline changes and live typed plugin state. A retained source file is not serialization for those edits.

Implement missing field/topology writers and source-key remapping under `ST-T03`, a real source-card edit workflow under `ST-T06`, and GUID-specific plugin serialization under `ST-T13`. Each writer must preserve unknown siblings, verify a no-op byte match, reverse supported changes exactly where possible, and validate an edited file in the original loader before widening its compatibility claim.

## Shape and color reset contract

The source inspector and scenario runner share `StudioModel.resetSourceShape`:
resetting the face clears only `sourceFaceValues`, and resetting the body clears
only `sourceBodyValues`. The other shape domain and color edits remain intact.
`resetSourceColorEdits` clears every color override while retaining both shape
domains. Each operation rebuilds the preview through the same setters used for
edits and records an undo snapshot.

The ST-T06c scenarios in the [verification guide](../../../Tools/verification/README.md#shapecolor-visual-and-reset-acceptance-st-t06c)
exercise production renders at a fixed camera and clock. They distinguish
visible change (>2/255 in any RGBA8 channel) from exact reset restoration (zero
maximum channel delta), and compare restored exports against the initial source
SHA even after reimport. A changed-export rejection after reimport guards against
comparing an output with itself. On 2026-10-17, the shape and color scenarios
passed 45 and 31 steps respectively: 76 face, 40,270/38,581 body and 10,251
skin pixels exceeded the visible-change threshold; resets had zero differing
RGBA8 bytes and restored exports matched the initial source SHA. These checks
cover supported bound skin colors
and face/body shape slots.

Visible UI follow-up on 2026-10-17 used the same final Debug app build and a
CharaStudio-authored source scene. In the Face inspector, height changed from
0.5 to 0.8 and Face width from 0.5 to 1.0. Each section's visible Reset to card
button restored its saved 0.5 value, confirmed by slider readback and reset
status; the body height change and restoration were visible in the viewport.
Source Pose and Clothes tabs were also reachable. The window was maximized
because the default width clipped inspector controls; that layout defect is
separate from reset semantics. The native color panel did not open through the
available UI automation, so interactive color editing remains unverified.
Unbound hair-color writeback, the broader ST-T01 guide/undo/save workflow and
original-player appearance parity remain open. No source file was overwritten.

## Source outfit selection (ST-C03 first slice)

Reviewed 2026-10-17. CharaStudio's outfit buttons follow this recovered chain;
the C# remains private under `.local/reverse` and is not committed:

- `MPCharCtrl.StateInfo.OnClickCosType` (managed recovery,
  `Studio/MPCharCtrl.cs`) calls `OCIChar.SetCoordinateInfo(type)`, then refreshes
  the clothing-detail and accessory panels.
- `OCIChar.SetCoordinateInfo` (`decompiled/Studio/Studio.OCIChar.cs`) does
  nothing unless the type differs from `fileStatus.coordinateType` or `_force`
  is set. Otherwise it calls `ChaControl.ChangeCoordinateType(type)` and reloads
  the clothes. `OCICharFemale` then also refreshes bust softness/gravity, skirt
  dynamics and skirt FK activation.
- `ChaControl.ChangeCoordinateType(type, changeBackCoordinateType: true)`
  (`decompiled/Character/ChaControl.Koikatu.cs`) returns false without changing
  anything when `chaFile.coordinate.Length <= type`. Otherwise it loads that
  saved coordinate into `nowCoordinate`, stores the old `coordinateType` in
  `backCoordinateType` and sets `coordinateType = type`. No `Coordinate` record
  changes. Apart from this assignment and `ChaFileStatus`'s own
  initialization/copy, the recovered Assembly-CSharp contains no
  `backCoordinateType` reference.
- On scene load, `AddObjectAssist.UpdateState` copies the saved `ChaFileStatus`,
  then calls `SetCoordinateInfo(saved, _force: true)`. After loading,
  `backCoordinateType` therefore equals the saved outfit. The same method then
  reapplies every `clothesState` entry. Saving a scene writes `ChaFile.status`
  to the embedded card's `Status` block.

The native port has four parts:

- **Card writer.** `SourceCharacterCard.Edits.coordinateType` writes
  `coordinateType` and, if it differs, `backCoordinateType` = the saved outfit
  (see [card editing](../character/cards.md#editing-and-exporting-original-cards)).
  This reproduces one switch after a load. A chain A→B→C stores back = B in the
  original, but here it stores A, because only the final selection persists.
- **Preview.** `SourceStudioCharacterPreview(reference:resources:coordinate:)`
  assembles the requested saved coordinate instead of `Status.coordinateType`.
  Before any asset registration, it rejects an index outside 0…6 or one that
  the card does not carry. It exposes `savedCoordinate`, `outfitCount` and a
  diagnostic naming the replaced outfit.
- **Model.** `StudioModel.setSourceOutfit(_:coordinate:)` is called by both the
  Clothes inspector's Outfit picker and the scenario `setOutfit` op. It rebuilds
  the preview with the object's color edits and current pose state, validates
  the edited pose, and only then records one undo snapshot. It also sets
  `StudioObject.sourceOutfit`: nil for the saved outfit, and nil when a legacy
  document is decoded. While clothes/accessory/makeup color edits for the
  current outfit exist, it refuses the switch because those edits address that
  outfit's records; face, body, hair and shape edits are kept. A refused switch
  leaves the document and preview unchanged.
- **Export.** `exportSourceScene` merges `coordinateType` into the character's
  card `Edits` only when the rendered outfit differs from the saved one. The
  export validator rejects an out-of-range `sourceOutfit` and any `sourceOutfit`
  on a placeholder.

The Outfit picker numbers outfits from 1 by name (for example "4 Swimsuit");
documents, scenarios and this page use the 0-based `coordinateType` index. The
tab lists every `conversionMissing` selection of the chosen outfit with its
source ID. The preview diagnostic states that the card identity is preserved.
No other ID is substituted. `loadScene` now calls `refresh()` after source
rehydration and plug-in restoration. Before that fix, the first frame after a
native load was stale: undo after an outfit switch missed the loaded capture by
138,276 pixels.

Evidence, 2026-10-17 (headless, no VM): the complete `studio-scenarios` lane
passed 37/37 with `--strict` and 0 skipped. Source scene `koikatu_cs0002591.png`
has SHA-256 `029f0b1d248ba71158b08b8d237be14810819d411d62f529f77f3a612a8bea04`
(595,127 bytes). Character key 65 has saved outfit 0 with `backCoordinateType`
0; key 0 also saves outfit 0. Both cards carry all seven coordinates.

- Outfit 3 (Swimsuit) changes 19,155 of 262,144 pixels in the 512×512
  production render by more than 2/255. In total, 33,204 pixels differ at all,
  with a maximum channel delta of 146. Its top, bottom, gloves, pants, socks and
  outer shoes resolve to the converted library's empty entries. The bra (source
  ID 2) and shorts (ID 1) are `conversionMissing`, and nothing is drawn for
  them. Outfit 2 resolves converted outer shoes while its top is missing.
- Undo, redo, the switch back to outfit 0, the post-reimport outfit 3 render and
  undo after a native load all restore every RGBA8 byte, with maximum channel
  delta 0. After the native document loads in a fresh process, switching to outfit 0
  measures the same 19,155 / 33,204 / 146 difference as the original switch.
  The loaded frame is therefore consistent with outfit 3, although it was not
  byte-compared across processes.
- The saved-outfit export has the source SHA-256 before and after reimport.
- The outfit 3 export (688,155 bytes, SHA-256
  `35087745d5a2c5c93d41b690234c1aff0eb88af5743e0382fb02b0135eefe659`) was
  compared independently in Python with `msgpack`, not with app code. After the
  scene PNG, both scene bodies have the same length and differ only at body
  offset 142,432, where key 65's `Status.coordinateType` changes from 0 to 3.
  No other card block, card or scene byte changes. The leading scene PNG differs
  because every edited export renders a new thumbnail.
- Engine tests assert the rewrite of both fields on a synthetic card whose
  `Status` integers are int64-encoded. `coordinateType` 1→0 and
  `backCoordinateType` 2→1 shrink `Status` by 16 bytes because each changed
  value becomes a fixint. The real scene card already stores fixints, so its
  export changes one byte. When `backCoordinateType` already
  matches, only `coordinateType` changes. Unrelated blocks, thumbnails,
  KKEx and trailer bytes are identical.

Remaining exclusions: shoes type, accessory groups, the female skirt-dynamics
and skirt-FK refresh, CharaStudio reload of the changed export, mouse-driven
use of the picker, and original-player appearance parity remain unverified.
The clothes state and accessory visibility that this slice left unconsumed
(a saved all-off state on key 0 rendered clothed) are covered by the
[second slice](#source-clothes-state-and-accessory-visibility-st-c03-second-slice).

## Source clothes state and accessory visibility (ST-C03 second slice)

Reviewed 2026-10-22. The defect this slice fixes: the embedded card's
`Status.clothesState` and `showAccessory` were never read, so source character
key 0 of `koikatu_cs0002591.png` rendered clothed, although its card saves
`clothesState` = `c4 09 03 03 03 03 03 03 03 03 03` (all nine kinds off,
`shoesType` 1, every accessory flag true). The pre-fix lane build showed its
reference top, reference bottom and converted outdoor shoes drawn.

**Recovered semantics.** The C# remains private under `.local/reverse` and is
not committed:

- `ChaFileStatus` carries `clothesState` (`byte[9]`, one per
  `ChaFileDefine.ClothesKind`: 0 top, 1 bottom, 2 bra, 3 shorts, 4 gloves,
  5 pantyhose, 6 socks, 7 indoor shoes, 8 outdoor shoes; 0 on, 1 half, 2 half
  2, 3 off), `shoesType` (byte, 0 indoor / 1 outdoor) and `showAccessory`
  (`bool[20]`). `MemberInit` defaults are all on, `shoesType` 0 and every
  accessory shown. MessagePack-CSharp writes the byte array as `bin`.
- `ChaControl.AddClothesStateKind` / `AddClothesStateKindSub` build
  `dictStateType` from each loaded garment's catalog `StateType`: 0 → {on,
  half, off}, 1 → {on, off}, 2 → all four, anything else (including the empty
  id-0 rows, `StateType` 3) → not a state kind. Top and bottom widen each
  other through the top's `n_bot_a` and the bottom's `n_top_a` switch nodes,
  and bra and shorts do the same. The flags come from the garment loaders:
  `ChangeClothesTopAsync` sets `notBra` (`NotBra` == 1) and `notBot`
  (`Coordinate` == 2), `ChangeClothesBraAsync` sets `notShorts` (`Coordinate`
  == "2"), and `ChangeClothesBotAsync` sets `hideShortsBot` from `HideShorts`,
  or from a fixed bottom-ID list when the row lacks that column. For a sailor
  or jacket top (`Kind` 1 or 2), `ChangeClothesTopPartsAsync` can override
  `notBra` from sub-parts that are not converted.
- `ChaControl.SetClothesState(kind, state, next: true)` advances a state the
  kind does not allow to the next allowed one. It then applies the links: a
  one-piece top (`notBot`) drags the bottom, a no-shorts bra (`notShorts`)
  drags the shorts, and the indoor and outdoor shoes mirror each other.
  `SetClothesStateAll` and `UpdateClothesStateAll` replay it over every kind.
  A scene load (`AddObjectAssist.UpdateState`) runs Reload's
  `UpdateClothesStateAll` and then a `SetClothesState` loop over the saved
  bytes, so the loaded state is normalized twice.
- `ChaControl.UpdateVisible` decides which garment GameObjects are active.
  Top, bottom, bra and shorts stay drawn when half; bottom, bra and shorts also
  honour the one-piece, no-bra and HideShorts flags. Gloves, socks and shoes
  are drawn only when on, with the shoe matching `shoesType`, and pantyhose
  hides at half 2 and off. It also switches the `n_top_a/b`, `n_bot_a/b/c` and
  `n_panst_a/b` nodes by state. `ChangeAlphaMask` sets the body mask pair by
  top state: on (1,1), half (0,1), off (0,0). An accessory renders while its
  `showAccessory` flag is set. `CheckHideHair` hides the hair while a shown
  accessory's catalog `HideHair` is set.
- CharaStudio: `MPCharCtrl.StateInfo.OnClickClothingDetails` →
  `OCIChar.SetClothesState` (rows top, bottom, bra, shorts, gloves, pantyhose,
  socks, shoes; the shoes row is kind 7; a row is interactable only for a state
  kind). `OnClickCosState` → `SetClothesStateAll(0/1/3)`. `OnClickShoesType` →
  `SetShoesType`. `OnClickAccessories` → `OCIChar.ShowAccessory`, interactable
  only for a slot that holds an accessory. A scene save serializes
  `ChaFile.status` into the embedded card's `Status` block.

**Native port.**

- **Rules.** `SourceStudioWear` (`Packages/Engine/Sources/Studio/SourceStudioWear.swift`)
  ports `dictStateType`, `SetClothesState`, the load replay, garment
  visibility, switch nodes and the alpha-mask table. It reads the catalog rows
  through `SourceMakerLibrary.wearCatalog`, which uses each converted entry's
  verified material evidence. A kind without a converted row is "unknown":
  every state stays selectable, the saved byte is kept and never re-guessed,
  its one-piece flags read false, and a diagnostic names it. Bra and shorts
  rules are also unknown when the top is unknown or a sailor/jacket composite.
- **Preview.** `SourceStudioWearLayout` maps assembled renderers to their
  clothing kind, accessory slot or hair, using the assembly prefixes and the
  switch-node ancestors. `SourceStudioCharacterPreview` loads the saved wear
  (`savedWear`, `loadedClothesState`), applies it through `setWear`, and hands
  the hidden parts and the body-mask pair to `SourceRigPreview.frame`.
- **Native rendering.** On and off render natively for every assembled
  garment. Half states of gloves, socks and shoes, and pantyhose at half 2,
  render natively too, because the source simply hides them.
- **Fallback and stand-in diagnostics.** These draw the garment dressed and
  never draw silently wrong:
  - The converter keeps only the fully dressed meshes. A top, bottom, bra,
    shorts or pantyhose half state whose alternate node (`n_top_b`, `n_bot_b`,
    `n_bot_c`, `n_panst_b`) holds no converted mesh draws the dressed meshes
    and dressed body mask with a fallback diagnostic.
  - Half states of an unconverted (reference) garment get a "half state cannot
    be rendered" diagnostic.
  - The assembly converts only the outdoor shoes. With `shoesType` 0 that
    geometry stands in for the indoor shoes and follows their state; a
    diagnostic says so.
- **Model.** `StudioModel.setSourceClothesState` (one Clothes-tab row),
  `setSourceClothesStateAll` (All on/half/off) and `setSourceAccessoryVisible`
  serve both the inspector and the scenario ops `setClothesState` /
  `setAccessoryVisible`. Each records one undo snapshot. A row that is not a
  state kind is refused, and so is a toggle for a slot without an accessory;
  both name the CharaStudio control that is disabled. `StudioObject`
  persists `sourceClothesState` / `sourceShowAccessory`; nil means the card's
  saved state, and so does a value equal to it. An outfit switch renormalizes
  the current state under the new outfit's rules.
- **Export.** `exportSourceScene` merges `clothesState` / `showAccessory` into
  the character's card `Edits` only when they differ from the card's saved
  values, after checking that the preview and the document agree. See
  [card editing](../character/cards.md#editing-and-exporting-original-cards)
  for the in-place token patch. The export validator checks the field shapes
  and rejects them on placeholders.

**Evidence, 2026-10-22 (headless, no VM).** Five new `studio-scenarios`
checks:

- `clothes-saved-off`, 24 steps:
  - Key 0 imports with state `[3,3,3,3,3,3,3,3,3]`, draws none of its three
    assembled garments, and the body mask is (0,0). Key 65 (all on) draws
    all three.
  - Forcing key 0's top, bottom and shoes rows on changes 17,024 of 262,144
    pixels by more than 2/255 (maximum delta 140). Three undos restore every
    RGBA8 byte.
  - The saved-state export keeps the source SHA-256 `029f0b1d…a04` before and
    after reimport.
  - The top-on export reimports with `[0,3,3,3,3,3,3,3,3]` and differs from
    the source scene body in one byte only, at body offset 66,135: key 0's
    `clothesState[0]` changes 3→0.
- `clothes-toggle`, 31 steps:
  - Key 65 top off changes 10,762 pixels (maximum delta 125) and sets the body
    mask to (0,0). Undo and redo restore exactly.
  - Half on the reference top draws the dressed render byte-identically and
    reports that the half state cannot be rendered.
  - Out-of-range values are refused with the document unchanged. Returning to
    on gives `exportIdenticalToSource` before and after reimport.
  - The top-off export reimports with saved state `[3,0,0,0,0,0,0,0,0]`. It
    differs from the source in one byte, at body offset 142,468: key 65's
    `clothesState[0]` changes 0→3.
- `accessory-toggle`, 34 steps, on a synthetic character that wears glasses in
  slot 0:
  - Hiding the glasses changes 239 pixels (maximum delta 96). Undo and redo
    restore exactly.
  - Bottom half on a converted bottom whose `StateType` is 1 advances to off
    and changes 10,562 pixels.
  - Top half on a converted top hits the missing `n_top_b` fallback. The shoes
    row mirrors to kind 8. The gloves row (not a state kind in this outfit) is refused.
  - Restoring the state gives `exportIdenticalToSource` before and after
    reimport.
  - The changed export reimports with the glasses hidden. This card spells
    `clothesState` as a fixint array and saves no `showAccessory`, so the
    export appends the field (see below).
- `reload-save-clothes` / `reload-load-clothes`: a native save keeps two
  edited characters (key 65 top off, key 0 top on). A fresh process reloads
  both states beside the cards' unchanged saved bytes and draws the edited
  garments. An edit there followed by undo restores the loaded frame exactly.
  The engine test `sourceSceneExportValidationChecksWearShapesAndDocumentsRoundTripThem`
  covers the accessory flags' native round trip.

The full lane and runner counts are recorded in the
[verification guide](../../../Tools/verification/README.md). A headless UI
capture of the Clothes tab (`IKKOKU_CAPTURE_UI`, Studio mode, key 0 selected)
shows the new "Clothes state" section:

- Top, bottom, bra, shorts, socks and shoes pickers on Off.
- Gloves and pantyhose read "No garment".
- The `shoesType` 1 caption.
- The accessory list.

The offscreen capture does not draw the unselected segment and button labels.
No control was clicked, so mouse-driven acceptance remains open. Engine tests
`sourceCardEditingClothesStateAndAccessoryFlagsPatchOnlyTheirTokens`,
`sourceCardEditingWearRejectsInvalidValuesAndUnreadableFields`,
`sourceCardEditingWearReadsArraySpellingAndAppendsMissingFields`, the
document test above and the five `sourceStudioWear*` tests cover the patch,
the document fields and the rule tables.

**Still open.**

- Half-state meshes: the converter drops them, so half states fall back to
  dressed.
- Indoor-shoe assembly, `shoesType` editing, the bra/shorts/socks garments
  (not assembled in the tested outfits) and composite-top sub-parts.
- The `visibleSimple`/`visibleBodyAlways` toggles and accessory hide
  categories.
- The exact per-row button sets CharaStudio shows: the port enables a row for
  any state kind and maps unsupported requests the way `SetClothesState`
  does.
- CharaStudio reload of a changed export, mouse-driven use of the new
  controls, and original-player appearance parity.

## Source face-state editing (ST-C04)

The source Face tab now exposes an Expression section. Its controls, Reset to
card, and `StudioScenario`'s `setExpression`/`resetExpression` operations share
`StudioModel.setSourceExpression`. The model validates an edit before recording
undo or changing the document. `StudioObject.sourceExpression` stores the settled
state; nil means the loaded card and scene values, including on legacy decode.
Undo, redo, native load and outfit changes reapply it to the preview.

**Recovered control contract.** The source is `Studio.MPCharCtrl`'s `EtcInfo`,
`LookAtInfo`, `NeckInfo` and `OtherInfo`, `Studio.OCIChar`, `ChaControl` and
`FBSCtrl*` from the local managed recovery of source hash `902b9a237337b17a…`.
The pattern limits come from FBS `GetMaxPtn` and the `cha_eyeset` table, not UI
labels. The current converted contract has 17 eyebrow patterns, 28 eye FBS
patterns, 39 eye catalog rows and 43 mouth patterns; assemblies supply their own
counts. Native rate controls accept finite 0…1 values, continuously; original
pattern arrows advance by one. A saved out-of-range value is preserved so an
unchanged field and Reset remain representable.

| Control | Original call chain | Saved destination | Native consumer |
| --- | --- | --- | --- |
| Eyebrows, 0…16 on this contract | `EtcInfo.ChangeEyebrowsPtn` → `ChaControl.ChangeEyebrowPtn` | Card `Status.eyebrowPtn` | FBS morph weights |
| Eyes, 39 `cha_eyeset` row IDs | `EtcInfo.ChangeEyesPtn` → `ChaControl.ChangeEyesPtn` | Card `Status.eyesPtn` | Row's FBS pattern; special visibility, gag objects and expression textures diagnostic-only |
| Mouth, 0…42 on this contract | `EtcInfo.ChangeMouthPtn` → `ChaControl.ChangeMouthPtn` | Card `Status.mouthPtn` | FBS morph weights; tongue/width side effects of patterns 21/22 diagnostic-only |
| Eyes open, 0…1 | `OCIChar.ChangeEyesOpen` → `ChangeEyesOpenMax` | Card `Status.eyesOpenMax` | Clamped eyes openness |
| Blink, Boolean | `OCIChar.ChangeBlink` → `ChangeEyesBlinkFlag` | Card `Status.eyesBlink` | Existing blink clock; off fixes eyes/eyebrow rates open |
| Mouth open, 0…1 | `OCIChar.ChangeMouthOpen` | Scene `OICharInfo.mouthOpen` | Mouth `FixedRate` |
| Lip sync, Boolean | `OCIChar.ChangeLipSync` | Scene `OICharInfo.lipSync` | Saved/exported; voice-driven mouth is diagnostic-only |
| Eye look, 0…4 | `LookAtInfo.OnClick` → `OCIChar.ChangeLookEyesPtn` | Card `Status.eyesLookPtn` | Existing eye/iris runtime, pattern 4 uses the look-at guide |
| Neck look, {0,1,3,4} | `NeckInfo.OnClick` → `OCIChar.ChangeLookNeckPtn` | Card `Status.neckLookPtn` | Existing neck runtime; editing disabled while FK neck group owns it |
| Tears, 0…3 | `OtherInfo.tears` → `OCIChar.SetTearsLv` → `ChangeTearsLv` | Card `Status.tearsLv` | Saved/exported; missing tear meshes diagnosed |
| Cheek, 0…1 | `OtherInfo.cheek` → `OCIChar.SetHohoAkaRate` → `ChangeHohoAkaRate` | Card `Status.hohoAkaRate` | Saved/exported; no default-toon blush consumer, diagnosed |

The recovered panel also has eye/brow foreground dropdowns (configuration,
normal, foreground) and a look-at guide-size slider. Those remain outside this
face-state slice. `hideEyesHighlight` is not exposed by this recovered panel;
its saved material behavior remains unchanged. The opt-in source-shader path's
load-time cheek binding does not establish live edited-cheek support.

**Runtime and limits.** An edit replaces expression inputs; it does not reload
geometry/materials or rebuild the pose baseline. The Face section reads document
state and edit-time diagnostics, never the per-frame clock/output. Reapplying an
identical state returns before validation or allocation. Neck changes clear only
the evaluated pose/look runtime; eye pattern changes retain an active eye runtime
and switch its target, as `OCIChar.ChangeLookEyesPtn` does. Native pattern changes
are immediate: the original FBS blend transition (0.15 s in this contract) and
in-place neck type-change interpolation are not reproduced by this slice.

Blink-off forces the runtime eyes rate to 1. A later eyes-open slider edit while
blink is off resets that held rate to the clamped slider value. The optional
`heldEyesOpenRate` records this transient distinction for native undo/save/load.
It is not an original serialized field: original load replays Blink then EyesOpen
and uses the saved openness. Mouth openness is the fixed rate without voice
lip-sync. Tears, cheek, lip-sync and special eye/mouth behavior use per-character
messages and never substitute an invented visual.

**Persistence.** Changed Status fields merge into the same card edit as shape,
color and outfit, preserving untouched tokens, unknown blocks, KKEx and trailers.
A missing Status field is appended only when the edit differs from its MemberInit
default. Mouth openness and lip-sync patch their existing four-byte float and
one-byte Boolean scene spans. Returning to saved state generates no card or scene
patch and no replacement thumbnail. Edited exports regenerate only the outer
scene thumbnail in addition to the explicitly changed card/scene fields.

**Verification (2026-10-23).** The fixture-backed Engine run reports 705 Engine
cases (703 executed, 2 skipped: optional timing probe and missing appearance image
oracle) and 21 CoreMath cases, with no failures. Focused tests cover every field's
validation, mutable preview/geometry identity, blink side effects, mouth fixed
rate, guide targeting, document/legacy decode, token preservation and scene
write/reread. Synthetic scene mouth edits touch exactly the two changed float
bytes and adjacent lip-sync byte and reverse to every original byte. The app
builds for macOS arm64 Debug. The reverse reload tooling passes 38 tests and the
verification runner passes 80. The initial app run passed the native save/load
pair (5/5 and 8/8); two mouth-only pixel checks exposed fixture framing: key 65's
mouth is outside the saved camera, so the corrected checks use fully visible key
0. That corrected task-local run was interrupted after its exports completed;
the final combined Release run below completes its two live-blink advances with
the R7 pose cache. No full visual parity is claimed.

An independent byte audit of the corrected eleven-field export found 13 changed
bytes in the unchanged-length 534,166-byte scene body. Only the nine requested
Status fields and the mouth-open/lip-sync spans changed; all six other character
cards, the target card's other blocks, unknown data, scene settings and trailer
are identical. The outer thumbnail was regenerated. Reset export is identical
to the complete source file (SHA-256 `029f0b1d248ba71158b08b8d237be14810819d411d62f529f77f3a612a8bea04`).

**Original-player reload, 2026-10-23.** One isolated CharaStudio run loaded the
corrected edited export and the unedited source. The read-only
`OriginalSceneReloadProbe.ExpressionRecord` captured all eleven serialized
expression fields for every character immediately after `LoadScene` and four
frames later. `compare_scene_reload.py` independently decoded both PNGs with the
Python scene/card reader: 308/308 claims pass (7 characters × 11 fields × 2
snapshots × 2 scenes). Key 65 reads eyebrow 3, eyes 2, mouth 6, eyes-open 0.5,
blink true, mouth-open 0.75, lip-sync false, eye-look 4, neck-look 0, tears 2 and
cheek 0.5 in both edited snapshots. All eleven differ from this character's
source values. The observed mouth controller `FixedRate` is 0.75 as well; it is
recorded separately from the serialized-field claims.

Both guest-side input hashes matched the host exports: edited
`188c7a5357ed62d4caec1443b1bc0885f7852e925e1a86bafcdf0104ee8c265f`, source
`029f0b1d248ba71158b08b8d237be14810819d411d62f529f77f3a612a8bea04`.
The player was Unity 5.6.2f1, `Assembly-CSharp.dll` SHA-256
`902b9a237337b17a64514bdb0d857b460ece4fb6a57c658375dd32c5fa504c45`, probe
source SHA-256 `2000ab5f20b4720a9410f0fa27b33fc5793efe03c32378f8796e8e9c5a0ca178`.
The voice table already contained 44 entries, so `RepairVoice` did nothing.
`status.json` reports no error and the Unity log contains no exception. The
temporary player root was removed after collection, with no remaining game
processes; Parallels `errno: 24` occurrences stayed at the pre-run count of 5.

Private evidence is under `.local/codex-resume-2026-10-23/expression/` in the
primary checkout: `byte-audit.json`, `expression-original-comparison.json` and
`vm/{run.json,status.json,reload-trace.json,unity.log,SceneReloadProbe.cs}`.
The task-local batched transport (`vm-batch.py`) used a temporary host-only HTTP
endpoint because this VM's shared-folder paths were unavailable; the first
launch attempt exceeded the Parallels command-length limit before starting any
process, then the shorter compressed command succeeded. No installed binaries,
plugins, settings, saves or fixture files were changed. This verifies serialized
field acceptance, including currently unrendered tears/cheek/lip-sync fields;
it does not establish original rendered pixels, blending transitions, or
voice-driven mouth parity.

Historical Release evidence from Claude's engine step (`89dd836`, before main
integration), same fixture/key 65, 20 warmups and 300 frame calls: pre-edit frame
medians 94.250/95.250/94.708 µs; after 94.500/95.208/94.042 µs. Expression edit
medians 1.333/1.333/1.416 µs, neck-pattern edits 2.166/2.042/2.167 µs, edited
frames 94.375/94.916/93.917 µs. These are dated local CPU timings, not a current
integrated-build result. `sourceStudioExpressionPerformanceProbe` reproduces the
measurements with `IKKOKU_EXPRESSION_PERF=1` and the scenario fixture environment,
`swift test -c release -Xswiftc -enable-testing --filter sourceStudioExpressionPerformanceProbe`.

**Combined acceptance (2026-10-23).** With final runtime `dffc9df`, the Release
app scenarios pass 83/83 edit steps, 6/6 native-save steps and 8/8 fresh-process
load steps. Visible Face-inspector acceptance on the earlier integrated Release
build `9737631` showed all eleven controls, mouth openness 1 → 0.5, Undo → 1,
Redo → 0.5 and Reset → 1, the FK-owned neck control disabled, and the lip-sync
limitation displayed. The later checkpoint correction retains current neck
pattern/live gaze on dynamics restore and atomically rejects old shape baselines;
its regressions failed before the fix and pass afterward. Full combined Release
Engine/CoreMath verification passes 736 executed tests, with three named optional
skips; Debug and Release app builds both succeed.

A fresh byte audit reproduces the 13 changed scene-body bytes and exact reset.
Its edited PNG differs from the VM input only in its regenerated thumbnail;
both scene bodies have SHA-256
`c5aeff049c8ef13028f9c0a255bc5621232c929feb1379b025386c83565a82fd`.
The 308 original-player serialized-field claims therefore cover the final
exported body, without claiming a second VM run or rendered-image parity.

The same input scene now renders seven characters instead of six. Key 1299's
saved eye catalog row 30 maps to FBS 21; before this change the importer used
30 directly against 28 FBS patterns and retained that whole character unrendered.
The original-player trace confirms saved row 30 after load and after settling.
The fixture regression in `c5822a8` verifies the mapped pattern, nonempty frame,
unchanged reset and explicit unsupported gag-eye diagnostic. The character is
now visible, but row 30's special eye visibility/object/texture behavior remains
unrendered. This intentional coverage change explains the integrated Studio
image difference; the separate performance-only build preserves baseline pixels.

Three final Release probes give steady-frame medians
96.416/94.500/100.167 µs, edited-frame medians 97.250/94.333/98.167 µs,
expression-edit medians 1.458/1.416/1.459 µs and neck-pattern-edit medians
2.250/2.042/2.250 µs. These fixture measurements show no material steady-frame
penalty. See [combined performance](../performance.md#combined-integration-acceptance-2026-10-23)
for conditions, scene coverage and the unresolved interaction stalls.
Private final evidence is in `.local/codex-resume-2026-10-23/integration/`:
`face-ui-verification.json`, `face-window.png`, `byte-audit.json`,
`original-player-body-match.json` and `expression-perf-{1,2,3}.log`; the eye-row
diagnosis and focused regression log are in the sibling `expression/` directory.

## CharaStudio reload acceptance

Reviewed 2026-09-30. This closes the "reload in the original CharaStudio" half of the ST-T03 edit destinations: our app's own exported scene records are loaded into the real CharaStudio player, and the state the player shows is recorded and compared claim by claim.

Four scenario checks in the `studio-scenarios` lane (`studio-scenario-charastudio-hide-rename`, `-camera-switch`, `-route-stop`, `-route-rename`; the three-check subset ran `--strict` passed=3 failed=0 on 2026-09-30 and the four-check subset passed=4 failed=0 the same day) each edit a probe-authored scene, export it under `.local/verification/scenario-exports/` and reimport it with our importer's asserts:

- `Tools/verification/scenarios/charastudio-hide-rename.json` — on scene-x: hide folder key 1, rename camera key 0 to `IKKOKU-A2` and folder key 1 to `IKKOKU-F2`.
- `Tools/verification/scenarios/charastudio-camera-switch.json` — on scene-x the load winner is camera key 2; toggling camera key 0 active must make key 0 the view camera.
- `Tools/verification/scenarios/charastudio-route-stop.json` — on the stt11c route scene (routes key 0 and key 3 both saved playing): stopping route key 0 must leave key 3 playing.
- `Tools/verification/scenarios/charastudio-route-rename.json` — on the stt11c route scene (route key 3's saved name is `IKKOKU-B`): renaming route key 3 to `IKKOKU-R3` must pass export validation and serialize into the record; after reimport the route is still playing and shows the new name — route records import unrendered but under their saved record name (only an unnamed route record falls back to the `Unrendered source route <key>` placeholder), so the rename reads back in our document as well as in the exported bytes and the original player.

`Tools/reverse/original_scene_reload_probe.py` uploads exactly those exported PNGs beside `Tools/reverse/fixtures/OriginalSceneReloadProbe.cs` in the isolated VM player (the first acceptance run: one VM run, 2026-09-30, Unity 5.6.2f1, three scenes), and the plug-in loads each into an emptied scene (`InitScene(false)`, `dicObjectCtrl` empty, then `Studio.LoadScene`) and records, immediately after the load and four frames later, every object's name, `objectInfo.visible`/`treeNodeObject.visible` and their `treeState`, each camera's `cameraInfo.active`, which camera `studio.ociCamera` uses and each `OCIRoute.isPlay`. `Tools/reverse/compare_scene_reload.py` reads the loaded bytes back from the capture and evaluates the claims; report `.local/stt03e/scene-reload-comparison.json` (capture also copied to `/Users/rumpology/code/repo/ikkoku/.local/stt03e/`; the probe's own `reload-*.png` hashes equal the exported files' SHA-256). All three cases passed — our reimport side (scenario asserts) and the CharaStudio side:

- hide-rename: folder key 1 shows `objectInfoVisible=false` and `treeNodeVisible=false` under the names `IKKOKU-A2`/`IKKOKU-F2`.
- camera-switch: the view camera is key 0 (`IKKOKU-A`, `cameraInfo.active=true`); key 2 reads back `active=false`.
- route-stop: route key 0 reads back `isPlay=false` and route key 3 `isPlay=true`.

Recorded observation (reported, not asserted): the hidden folder's child camera key 2 keeps its **own** visible flags at load (`objectInfo.visible=true`, `treeNodeObject.visible=true` — the exported record saved them true and CharaStudio did not rewrite them), so the load-time parent-hidden propagation the decompiled tree code performs is not observable on a camera child's flags. Our writer serializes only each object's own flag, which matches what the player keeps. In both camera cases `studio.cameraCtrl.enabled` was false while an active camera object drove the view (the view winner was key 2, the saved load winner, in hide-rename, where no camera flags were edited).

Route rename run, 2026-09-30. After the fourth scenario was added, a second VM run (one run, same player) uploaded all four freshly exported PNGs — their SHA-256s equal the exports written by the later four-check `--strict` lane run (passed=4 failed=0, 2026-09-30) — and `compare_scene_reload.py` reports all four cases passed in `.local/stt03f/scene-reload-comparison.json` (capture in `.local/stt03f/probe/`): route key 3 reads back `IKKOKU-R3` in CharaStudio and route key 0 keeps its saved name `IKKOKU-A`, and the three earlier cases reproduced the first run unchanged. The settled snapshot again equals the after-load snapshot. So the route rename destination is proven end to end: the rename goes through `StudioModel`'s name edit (already unit-tested for byte patch and reversal in `SourceSceneEditingTests`), export validation accepts it, the name is in the exported bytes as the original player reads them, and our importer keeps the record playing behind its documented placeholder name. Updated 2026-09-30: that last clause no longer holds — the importer now names route records by their saved record name (the route stays unrendered; only an unnamed route record keeps the placeholder), the scenario's post-reimport assert reads `name: "IKKOKU-R3"` and the rename now reads back in our own document too; the rename baseline in both export sites measures a route against `original.name` like a folder, and the exported bytes for a renamed route are unchanged (`StudioModel`'s diff writes the same single name edit).

FK edit run, 2026-10-01 (ST-T01 slice). A fourth scenario, `Tools/verification/scenarios/charastudio-fk-edit.json` (lane check `studio-scenario-charastudio-fk-edit`, which needs the new environment key `IKKOKU_CHARASTUDIO_FK_SCENE` naming a CharaStudio-authored scene), first needs a source scene the original player itself authored: `Tools/reverse/original_scene_reload_probe.py --author-character` uploads a synthetic fixture card and has the player build `scene-char.png` (85,792 bytes, one female, dicKey/sourceKey 0, `enableFK=false`, bones 19/21 saved `[0,0,0]`) and read it back — the read-back load is the `charastudio-fk-source` baseline. The scenario then turns FK on and rotates bone 19 to `[0,35,0]` degrees, asserts the exact degrees and the moved left-hand guide (bone 21), exports `charastudio-fk-edit.png` (103,771 bytes) and reimports it; after reimport the guide reproduces its post-edit position within 0.02. Like `fk-edit.json` it asserts the exact degrees only before the export: `importSourceScenePreview` never populates `sourceFKRotations` (only a live `setFK` does), so the degrees an export actually contains are instead asserted by the original player. A one-check manifest cut from the lane ran `--strict` passed=1 failed=0 (2026-10-01; the first run failed on a post-reimport exact-degrees assert and its log and report are retained under `.local/verification/`). VM run B then loaded the export and the unedited source scene in one player run and `Tools/reverse/compare_scene_reload.py` passed both cases in `.local/stt01c/scene-reload-comparison.json` (capture also copied to `/Users/rumpology/code/repo/ikkoku/.local/stt01c/`; the probe's `reload-charastudio-fk-edit.png` hash `bb29231d…` equals the exported file): `enableFK` reads back true, bone 19's saved rotation is `[0,35,0]` within 1e-3°, and the settled left hand sits 0.288 m from its position in the unedited load ([-0.5634,1.3001,-0.0321] → [-0.4800,1.3001,0.2435]); the unedited baseline case reads `enableFK=false` and bone 19 `[0,0,0]`, and `activeFK` reads the loaded group tracking `[False,True,False,True,False,False,False]` in both cases (recorded, not asserted).

Environment defect found in that VM (not an acceptance detail, but the acceptance could not run without it): this player copy's `Manager.Voice.Awake()` throws during start-up — an `AssetBundleManager.LoadAllAsset` NullReferenceException on the AppleDouble `._00.unity3d` junk beside the real bundles in `abdata/etcetra/list/config/` — after the singleton registered but before `voiceInfoList = sortList` ran, so `ChaFileControl.LoadCharaFile`'s range check (which every `Studio.LoadScene` of a character-bearing scene makes via `OICharInfo.Load`) throws `ArgumentNullException` on the null `voiceInfoDic` and no character scene loads at all. The probe's `RepairVoice()` reflectively assigns an empty `List<VoiceInfo.Param>` through the auto-property's private setter when the list is null — on a healthy boot the list is populated and nothing changes. Its only consumer, `ChaFileControl.CheckDataRangeParameter`, then reports the character's personality as an out-of-range voice number and clamps it to 0 (the fixture card's is 0 either way), `LoadCharaFile` ignores the check's result, and nothing in the range check touches FK bookkeeping or bone transforms. The outcome is recorded as `voiceRepair` in every capture's `status.json`.

Limits: single-run captures with the default player; the settled snapshot equals the after-load snapshot in all three cases of the first run and in the route-rename run (no later flip was observed within four frames); route playing is read from the `active` flag, not from motion; the visibility cascade of the original was exercised for a camera child only, not a character part, and the first capture's renames covered camera and folder kinds only (the route rename is covered by the second run above).

## CharaStudio-authored route-children and neck TARGET/AWAY fixtures

Recorded 2026-10-17 (VM run) and 2026-10-22 (lane run). No scene under the fixture root had a route with children or a character with a TARGET/AWAY neck pattern, so the ST-T11 "route children move along their routes" and ST-T07 "TARGET/AWAY characters follow or avoid the Studio camera" checklist items had nothing to run against. The original player now authors both scenes from the synthetic fixture card. `author-scenes.txt` beside `OriginalSceneReloadProbe.cs` (written by `original_scene_reload_probe.py --author-scenes`, which requires `--author-character` unless it lists only the card-free `mirrored-camera` scene) lists the scenes to build. The default stays `char`, which builds the ST-T01 `scene-char.png`. Each listed scene is built, saved with `OnSavePreprocessing` on every object plus `cameraCtrl.Export()`, cleared with `InitScene(false)`, reloaded and traced:

- `route-children` saves `scene-route-children.png`. It holds route key 0 `IKKOKU-RC`, built with `AddObjectRoute.Add` and three `OCIRoute.AddPoint` calls. Its four points sit at Unity (0,0,0), (1.2,0,0), (1.2,0,1.2) and (0,0,1.2): point keys 1/3/5/7 with aid keys 2/4/6/8, speed 2, ease 21. The route loops and is saved playing. Its children are folder key 9 `IKKOKU-RC-F` (local (0,0.5,0)) and the fixture female key 10. Both were attached with `TreeNodeCtrl.SetParent`, so `Studio.OnParentage` → `OCIRoute.OnAttach` adds them to `routeInfo.child` (two entries, checked before saving).
- `neck-target` saves `scene-neck-target.png` with two fixture females. Key 0 stands at x = −0.5 with `ChangeLookNeckPtn(1)` (TARGET, こっち). Key 147 stands at x = +0.5 with `ChangeLookNeckPtn(2)` (AWAY, あっち). Both have `ChangeLookEyesPtn(1)` (eyes TARGET) and neck/eye target type 0, the main camera. The scene was saved after 120 frames, so the saved `fixAngle` bytes are a settled look. Saved camera: position (0, 2.09, 4.21), rotation (11.4, 180, 0). The read-back then orbits that camera by yaw 0, +60° and −60°: it calls `cameraCtrl.Import` on a copied `CameraData` and records 120 frames per phase.

```sh
# synthetic card only; one player run, stopped by --collect
.local/reverse/unitypy-venv/bin/python Tools/reverse/original_scene_reload_probe.py \
  --output .local/vm-fixture-scenes/probe \
  --author-character .local/r1b/probe/fixture-card.png \
  --author-scenes route-children,neck-target
# after the player reports done:
.local/reverse/unitypy-venv/bin/python Tools/reverse/original_scene_reload_probe.py \
  --output .local/vm-fixture-scenes/probe --collect
```

The run used one isolated player copy, `C:\Temp\IkkokuShaderProbe-794c90a6…`, Unity 5.6.2f1, plugin source SHA-256 `b339db94…`, card `4b892fc4…`. `--collect` stopped the player, and a later check found 0 CharaStudio processes. `scene-route-children.png` is 84,668 bytes, SHA-256 `f263e2f4…`. `scene-neck-target.png` is 165,580 bytes, SHA-256 `950ccaf5…`. Both are kept under `.local/vm-fixture-scenes/probe/` with `reload-trace.json`, `status.json`, `unity.log` and `manifest.json`. `status.json` records `voiceRepair` = "voiceInfoList already holds 44 voice entries: nothing to repair": after the 2026-10-01 quarantine of the seven AppleDouble `._*` files from `abdata/etcetra/list/config/`, `Manager.Voice` boots normally and the repair is a no-op. The `scope` string's sentence about a throwing `Awake` describes the earlier player and was left unchanged, so the committed probe source keeps the hash that ran. `unity.log` has no exception, and no remaining `._*` file broke the player. Our importer reads the same saved bytes: `ikkoku-inspect scene-document` gives the route tree above, and `ikkoku-inspect look-data` gives key 0 neck/eyes patterns 1/1 and key 147 2/1, with neck and eye target type 0 for both. Key 147's saved neck `fixAngle` is (0, 0.3402, 0, 0.9404), a 39.8° yaw.

What the original showed (reload trace):

- Route children: after load the route's `childRoot` is at (0,0,0). 60 frames (1.56 s) later it is at Unity (1.032,0,0), and so are both children's world positions; the folder keeps its +0.5 m height. `routePlaying` stays true.
- Neck look (head yaw relative to the body, positive toward Unity +x, against the camera's yaw from the body):

  | Camera | TARGET key 0 head / camera | AWAY key 147 head / camera |
  | --- | --- | --- |
  | saved (yaw 0) | 6.699° / 6.749° | 59.862° / −6.749° |
  | +60° | 59.850° / 63.168° | −52.994° / 56.355° |
  | −60° | −49.088° / −56.355° | 52.979° / −63.168° |

  TARGET turns toward the camera and AWAY turns to the opposite side. In both orbit phases each character had covered about 94% of its swing after 120 frames. This is interpretation only: the original's phases are not settled, and we do not use them as magnitudes.

Our side: `Tools/verification/scenarios/route-children-motion.json` and `neck-target-orbit.json` run in the `studio-scenarios` lane. Their numbers are in `Tools/verification/README.md` ("Route children and neck TARGET/AWAY"). Under the same saved camera, after a 3 s advance, our live TARGET/AWAY solver gives hair-front bone 100 (`cf_J_hairF_00`, from the scenario's `captureBone` positions) a horizontal bearing about the original's default-pose head position (0, 1.394, −0.0154 Unity) of 6.698° for key 0 and 59.879° for key 147. Those match the original's settled head yaws of 6.699° and 59.862° to within 0.02°. After each 3 s orbit leg, the same bearings are TARGET 63.05° / AWAY −59.76° at +60° and TARGET −56.11° at −60°. At −60°, AWAY is back within 0.01 m of its front pose, the same side as the original's. The directions match the recovered semantics, so this is not a finding against the solver. Exact orbit-phase magnitudes are not compared, because the orbit geometry and frame clocks differ and the original's phases had not settled. Our route children move at about 0.66 m/s: 1.311 m of path in the first 2 s, then 0.333 m in the next 0.5 s. The original moved 1.032 m in 1.56 s. We record this speed comparison but do not assert it.

A later card-free author scene, `mirrored-camera` (2026-10-23, R4/ST-A06), saves `scene-mirrored-camera.png`: a camera under an item scaled (−1, 1, 1) and a control camera under an unmirrored copy. Its capture and the lane check that runs it are in [Mirrored camera parent](scene-records.md#mirrored-camera-parent-original-capture-r4).

Observation, not changed in this slice: `ikkoku-inspect look-data` and `SourceStudioNeckLookOverride.resolve` still report TARGET/AWAY as "Neck gaze solver pending; animated pose kept.". The Studio preview meanwhile runs the live `SourceStudioNeckLookRuntime` and says "Neck look override live: TARGET|AWAY follows the Studio camera from the saved fixAngle.". The data-only reason text is stale.
