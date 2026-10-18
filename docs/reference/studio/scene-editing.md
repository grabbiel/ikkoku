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
- Embedded card body/face values, supported color fields, the worn outfit (`Status.coordinateType`, see [source outfit selection](#source-outfit-selection-st-c03-first-slice)) and face thumbnail, using the existing bounded card editor. Head/sex/bone type, asset IDs, saved resolver identities and opaque card plug-ins remain unchanged.
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

The app exports supported existing transforms, per-object visibility, folder/camera/route renames, camera active flags (only after the user switches the looked-through camera, then for every camera record), route play-state `active` flags, FK/IK and activation flags, animation, voice and cameras to a **new file** after checking the source SHA. It renders an explicit edited thumbnail. The app populates `edits.cards` with source face/body shape values and edited card colors that differ from the embedded card's saved values (ST-T06); shape and color edits on one character merge into a single `Edits`, and a value edited back to the saved rate or rgba writes nothing and the file stays byte-identical. Only colors that actually bound a material on the assembled character are exported; an edited color whose ID binds nothing still renders as saved. Its inspector diagnostic says it remains in the native document but is skipped by original-scene export. A selected outfit other than the card's saved one is merged into the same `Edits` as `coordinateType` (ST-C03); choosing the saved outfit again writes nothing. Thumbnail and other card destinations remain unpopulated, and a native `object.card` override is rejected.

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

Remaining exclusions: `clothesState` 0–3 (including half-dressed state) and
`showAccessory` are not consumed or editable. A saved all-off state on key 0
still renders clothed, a pre-existing gap. Shoes type, accessory groups, the
female skirt-dynamics and skirt-FK refresh, CharaStudio reload of the changed
export, mouse-driven use of the picker, and original-player appearance
parity remain unverified.

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
