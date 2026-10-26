# Edited original Studio scenes

Reviewed 2026-09-25 against the working tree. The [Studio audit](../../component-audit/studio.md) is the feature-status and actionable-backlog index; this page records the narrower source contract and its evidence.

`KoikatsuSceneDocument.editedData(SourceSceneEdits)` produces a new original-format 1.0.4.2 scene by replacing bounded byte spans recorded by the source reader. An empty edit returns the exact original bytes. The writer performs no file I/O.

Supported edits are:

- Object transforms identified by original object source key, including nested accessory children.
- Per-object `visible` flags keyed by source object ID, nested accessory children included. The flag is the single byte immediately after the record's `treeState`, four bytes past the end of its 36-byte transform span; the reader records it while reading. The patch is one byte (0 or 1), the current byte must already be 0 or 1 and an unknown key rejects the edit; an edit to the stored value returns the input bytes unchanged. Only the object's own flag is serialized — CharaStudio propagates a hidden parent through the tree at load time, and this writer never propagates.
- Name edits keyed by source object ID, folder, camera and route records only — the kinds whose own record stream carries a name. The reader records the full string span (seven-bit encoded UTF-8 byte length prefix plus the UTF-8 bytes) while reading, and a rename replaces that span with the same .NET `BinaryWriter.Write(string)` encoding, so the file resizes and every following record shifts. An edit to the stored name returns the input bytes unchanged. Characters, items and lights serialize no name (a character's name lives in its card) and have no name destination.
- Camera record `active` flags and route record `active` flags, each keyed by its own record's source object ID. Both are the one-byte bool immediately after the record's name string (for a camera) or its point list (for a route); the reader records each span while reading. Like visibility the patch is one byte, the current byte must already be 0 or 1, an unknown key — or a key whose record is not of that kind, a folder for either destination — rejects the edit, and an edit to the stored value returns the input bytes unchanged. For cameras the app writes these only after the user switches the looked-through camera, and then for every camera record: CharaStudio saves the current view, so the new camera goes true and the losers must go false or their stale `true` wins on reload (load order takes the last active camera). Without a switch the file already reloads to the same winner and nothing is written. Route `active` is the play state at save time; loading a true record resumes playback.
- Route points and route settings (ST-T11): point and aid moves, the start point's rotation, added and deleted points under CharaStudio's keys, each point's speed, ease, connection and link, and the route's loop, line visibility, orient and line colour. See [route points and settings](#route-points-and-settings-st-t11-st-t03).
- Character FK bones, IK targets and look-at target transforms; item FK transforms identified by their original ordinal bone name.
- Character `enableFK`, `enableIK`, seven `activeFK` flags and five `activeIK` flags. Flags are written literally; source loading gives IK precedence if both modes are enabled.
- Character animation catalog IDs, speed, pattern, force-loop, options and normalized time; ordered voice playlists and repeat mode, including variable-length replacement.
- Embedded card body/face values, supported color fields, the worn outfit (`Status.coordinateType`, see [source outfit selection](#source-outfit-selection-st-c03-first-slice)), the per-garment clothes state and accessory visibility (`Status.clothesState` / `showAccessory`, see [source clothes state](#source-clothes-state-and-accessory-visibility-st-c03-second-slice)), the shoes type (`Status.shoesType`, see [half-state meshes and indoor shoes](#half-state-meshes-and-indoor-shoes-st-c03-third-slice)) and face thumbnail, using the existing bounded card editor. Head/sex/bone type, asset IDs, saved resolver identities and opaque card plug-ins remain unchanged.
- Current camera and ten saved camera slots, preserving position, all three Euler angles, all three distance components and field of view. Only the 40-byte version-2 payload changes.
- A replacement scene PNG only when explicitly supplied. It must be one complete CRC-valid PNG; an embedded card cannot acquire a PNG prefix.

Transforms are expressed in the original Unity coordinate basis and Euler degrees. The native app must convert edited transforms back before export. Duplicate or unavailable destinations, invalid group counts, nonfinite values, invalid camera FOV and invalid PNGs reject the entire edit. Object IDs, root dictionary keys, unedited catalog choices/settings and trailing plug-in bytes are preserved, and so is record order except where a [topology edit](#topology-edits-deletion-and-reparenting-st-t03-st-s09) deletes or moves a record. Deleting records and moving them between the root and folders follow that section, and duplicating records and adding folders, cameras and lights follow [duplicates and added records](#duplicates-and-added-records-st-t03-st-s09-st-d03), and route point and setting edits and route copies follow [route points and settings](#route-points-and-settings-st-t11-st-t03). In those exports, [plug-in data](#plug-in-data-st-t03i) keeps, rewrites or refuses each ExtendedSave entry. Adding characters or items, other moves, object type, item identity and running plug-in code are outside this writer.

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

The app exports supported existing transforms, per-object visibility, folder/camera/route renames, camera active flags (only after the user switches the looked-through camera, then for every camera record), route play-state `active` flags, FK/IK and activation flags, animation, voice and cameras to a **new file** after checking the source SHA. It renders an explicit edited thumbnail. The app populates `edits.cards` with source face/body shape values and edited card colors that differ from the embedded card's saved values (ST-T06); shape and color edits on one character merge into a single `Edits`, and a value edited back to the saved rate or rgba writes nothing and the file stays byte-identical. Only colors that actually bound a material on the assembled character are exported; an edited color whose ID binds nothing still renders as saved. Its inspector diagnostic says it remains in the native document but is skipped by original-scene export. A selected outfit other than the card's saved one is merged into the same `Edits` as `coordinateType` (ST-C03); choosing the saved outfit again writes nothing. Clothes states, accessory flags and the shoes type that differ from the card's saved `Status` are merged the same way; a state edited back to the saved bytes writes nothing. Thumbnail and other card destinations remain unpopulated, and a native `object.card` override is rejected. Deleted objects and objects moved between the root and folders are exported as [topology edits](#topology-edits-deletion-and-reparenting-st-t03-st-s09), and copies of source records and new folders, cameras and lights as [inserted records](#duplicates-and-added-records-st-t03-st-s09-st-d03). Route point and setting edits, and route copies, are exported as [route edits](#route-points-and-settings-st-t11-st-t03).

The export validator rejects new characters and items, the topology and insertion cases those sections list as refused, type changes, and name edits for any record kind other than folder, camera or route (a renamed character keeps its name in its card), plus native assets/materials/cards/hand/appearance overrides, light/effect/timeline changes, live typed plugin state, and the plug-in data cases [plug-in data](#plug-in-data-st-t03i) refuses. A retained source file is not serialization for those edits.

Implement the missing field writers, new characters and items and the refused topology cases under `ST-T03`, a real source-card edit workflow under `ST-T06`, and GUID-specific plugin serialization under `ST-T13`. Each writer must preserve unknown siblings, verify a no-op byte match, reverse supported changes exactly where possible, and validate an edited file in the original loader before widening its compatibility claim.

## Topology edits: deletion and reparenting (ST-T03, ST-S09)

Reviewed 2026-10-25. `SourceSceneEdits.deletions` deletes source records with their whole subtree, and `SourceSceneEdits.reparents` moves records between the root and folders. `SourceSceneTopology` (`Packages/Engine/Sources/Studio/SourceSceneTopology.swift`) plans both edits, and `editedData` writes them. Every case the writer cannot reproduce the way CharaStudio would is refused before any byte is written, and the reason is shown in the app.

### Recovered rules

The rules come from the recovered CharaStudio `Assembly-CSharp.dll` (SHA-256 `902b9a23…`). Citations are `file:line` under `.local/reverse/managed-recovery/902b9a23…/77473a43…/project/Studio/`. The on-disk tree and key rules are in [Object tree and keys](scene-records.md#object-tree-and-keys).

- **Delete.** `TreeNodeCtrl.DeleteNode` (TreeNodeCtrl.cs:132) needs the node's `enableDelete`. It detaches the node, then runs `onDelete` for the node and for every node below it (`DeleteNodeLoop`, :320). Studio registers `OnDeleteNode` (Studio.cs:655), which runs the object's `OCI*.OnDelete`. That calls:
  - `parentInfo.OnDetachChild`, a `List.Remove` from the parent's child list. A character removes the child from the first accessory group that holds it (OCIChar.cs:577).
  - `Studio.DeleteInfo` (Studio.cs:714). It removes `_info.dicKey` from `sceneInfo.dicObject`, deletes the key, and calls `SetSunCaster(-1)` when the sun caster was that key. Only a root whose dictionary key equals its `dicKey` is removed this way.

  `Studio.DeleteCamera` (Studio.cs:386) clears the looked-through camera when the deleted object was that camera, so the next save writes no active camera. No other record changes. Keys live in a `HashSet` (SceneInfo.cs:99), so gaps are legal and nothing is renumbered.
- **Reparent.** `TreeNodeCtrl.SetParent` (:173) needs `enableChangeParent`. `Studio.OnParentage` (Studio.cs:669) finds both controllers (`FindLoop`, :946) and calls the new parent's `OnAttach`, or the child's `OnDetach` for a move to the root.
  - `OCIFolder.OnAttach` (OCIFolder.cs:38) takes a root child out of the root dictionary with `DeleteInfo(_delKey: false)`, which keeps the key. It takes any other child out of its list with `OnDetachChild`. It then appends the child with `folderInfo.child.Add` and parents its transform under the folder's child root. Finally it sets `changeAmount.pos`/`rot` from the new `localPosition`/`localEulerAngles`, so the world pose is kept and `changeAmount.scale` is not touched.
  - `OnDetach` (OCIFolder.cs:83 and the same method on the other kinds) moves the record to the root with `Studio.AddInfo` (Studio.cs:705), under its own `dicKey`, and re-authors the local placement the same way.
- **Restrictions.**
  - Cameras and lights cannot hold children: `enableAddChild = false` (AddObjectCamera.cs:61, AddObjectLight.cs:75).
  - Routes cannot be reparented: `enableChangeParent = false` (AddObjectRoute.cs:55).
  - A route's child root and its points can be neither moved nor deleted (AddObjectRoute.cs:66–67, :139–141).
  - A character's accessory point nodes can be neither moved nor deleted (AddObjectAssist.cs:173–191).
- **Root order.** `SceneInfo.Save` (SceneInfo.cs:299) writes `sceneInfo.dicObject` in enumeration order. In the Mono `Dictionary`, `Remove` frees a slot and the next `Add` reuses the most recently freed one. So after an interactive delete and move, the original's root order depends on that history. Our writer appends a record moved to the root after the remaining roots. The original player loads our order unchanged (VM run below).
- **Camera at load.** `AddObjectCamera.Load` calls `ChangeCamera(ocic, _info.active)` (AddObjectCamera.cs:82) in file load order (depth-first pre-order), so the last saved active camera wins.

### Writer behavior

- **Deletion** drops the record's bytes, subtree included, from the list that owns it. It rewrites that list's Int32 count: the root count, a folder, item or route child count, or a character's accessory group count. All other records keep their bytes and keys.
- **A move** cuts the record's bytes, subtree unchanged, and appends them to the end of the new parent's list: a folder's child list, or the root dictionary under the record's own key. A record that was already a root keeps its original root-key bytes. Both affected counts are rewritten.

  The caller pairs each move with an ordinary `.object` transform edit holding the re-authored local placement (`SourceStudioWorldTransform.reparented`: world position and rotation kept, scale unchanged), matching what `OnAttach`/`OnDetach` author. A record moved out of a folder that the same export deletes survives, like moving it out and then deleting the folder in CharaStudio. Records inside that moved subtree can still be deleted on their own: moving folder B out of folder A, deleting B's child C, then deleting A is the deletions {A, C} plus the move of B, and C is not "already deleted" with A.
- **Sun caster.** `sunCaster` is written as −1 when its record was deleted.
- **Looked-through camera.** If an export has topology edits and no explicit camera-active edit, the saved winner must stay the camera that was active at import. If that camera was deleted, there must be no winner, as `Studio.DeleteCamera` leaves it. When the edited file's load-order winner differs, the writer flips exactly the camera flags that differ.
- **Other edits.** All other destinations still apply, and their byte patches travel with the moved bytes. An edit to a deleted record is refused.
- **Verification.** The result is decoded again and checked against the planned tree (records, child order and root keys) before it is returned. An export without deletions or moves takes the previous patch path unchanged.

**Supported:**

- Deleting any record, with its subtree, that is not attached to a character's accessory point. This includes roots, and characters together with their accessory children.
- Moving any non-route record whose current parent is the root or a folder, either to the root or to a folder that is not being deleted.

**Refused.** Each of these rejects the whole export, with the stated reason:

| Case | Reason |
| --- | --- |
| Deleting an object attached to a character's accessory point on its own | CharaStudio allows it (OCIChar.cs:577 removes it from the group), but no such file has been reloaded in the original player yet. Deleting the character removes it with its subtree. |
| Listing a record whose ancestor is also deleted | Only the top of a deleted subtree is listed. The ancestor walk stops at the first moved ancestor, which takes the record out of the deleted subtree. |
| Deleting, or moving off the root, a root whose dictionary key differs from its `dicKey` | `DeleteInfo` removes roots by `dicKey`. |
| A deletion that the scene's plug-in data cannot follow | Plug-ins key their data by `dicKey` and rewrite it from live objects when CharaStudio saves. [Plug-in data](#plug-in-data-st-t03i) decides each KKEx entry, and refuses when a plug-in would lose or misplace data it reads, or when the entry has no recovered rule. With or without a trailer, it also refuses when NodesConstraints would turn a written character's card links into constraints. |
| A scene edit targeting a deleted record | The record is gone. |
| Moving a route | `enableChangeParent = false`. |
| Moving a route child | Its saved local placement depends on the route's playback position at the moment of the move. |
| Moving an item child, or moving anything under an item | An item's child root may be a named transform inside its prefab (`ItemLoadInfo.childRoot`) that the converted catalog does not record. |
| Moving an accessory child, or moving onto a character's accessory points | The attachment transform is a character bone that the writer does not re-author against. |
| Moving under a camera or light | `enableAddChild = false`. |
| Cycles, a record moved twice, a record both deleted and moved, a move under a deleted or unknown record | Invalid edit. |
| A record moving to the root whose key another root already uses | Root dictionary keys must stay unique. |
| Adding or duplicating objects | Now written by the insertion writer; its own refusals are listed in [duplicates and added records](#duplicates-and-added-records-st-t03-st-s09-st-d03). |

### App translation

`StudioModel.exportSourceScene` asks `SourceSceneExportValidation.topologyEdits(document, against: snapshot)` for the edits. Every document object must be a distinct source record.

- Records missing from the document become deletions, listed by the top of each missing subtree.
- The document's object order is the sibling order. In each parent's list, the longest prefix still in original order stays in place, and every other record becomes a move, in document order, because CharaStudio can only append.

The app's Delete and Set Parent commands (`deleteSelection`, `setParent`) are undoable. `setParent` puts the moved object at the end of the document, so the new parent's children read in the order CharaStudio would append them. The exported thumbnail is re-rendered when objects are deleted, so deleted objects do not stay in it. Native save and reload keep the edited tree, and an export after the reload carries it.

### Evidence

- **Engine.** `SourceSceneTopologyTests` (9 tests) builds scenes with an independent spec builder whose bytes must match the reader. The tests then assert each destination's bytes:
  - a no-op returns identical bytes, and edit-then-revert restores every byte;
  - subtree deletion, including the sun caster and camera rules;
  - root, character and nested deletions;
  - moves to a folder, to the root, root to folder, and a chain;
  - the looked-through camera after a move, with and without an explicit camera edit;
  - moving out of a folder and then deleting it;
  - the app derivation;
  - the plug-in trailer rule;
  - every refusal, including the root-key collision.

  Disabling the sun-caster and camera rules fails 4 of these tests (negative control). `SourceSceneExportValidationTests` covers the app boundary: deleting a route child is accepted; a detached accessory child, an added object, and a character moved under a route are refused.

  The full Engine suite with the shared fixture map ran 917 tests, and 915 passed. One failure is `sourceDynamicsOriginalHairMatchesIndependentOracleWhenRequested`: it reads `.local/reverse` relative to the checkout and passes once the worktree links it. The other is `liveSourceShadersMeetTheControlledOriginalFrameGates`, whose 6 expectations fail identically on main `aee4287` (a store-manifest fixture mismatch, not part of this slice).
- **Lanes.** Five `studio-scenarios` checks call the same `StudioModel` methods the UI uses. Each includes negative controls (`assertRejected`) or an export that is meant to fail (`exportRejected`):
  - `topology-delete.json` (scene-x): delete folder 1, undo and redo, export and reimport. Expects root `[0]`, keys 1 and 2 absent, and no active camera.
  - `topology-reparent.json` (koikatu_cs0002591): item 623 moves from folder 622 to folder 962, character 65 from the root to folder 626, and item 1129 from folder 962 to the root; folder 1298 is deleted with its character and items. Asserts the child lists and that world pose holds within 1e-4 m and 0.01°, through 4 undos and 4 redos. After export and reimport it holds within 5e-4 m and 0.05°.
  - `reload-save-topology.json` and `reload-load-topology.json` (scene-x): camera 2 moves to the root and folder 1 is deleted, then native save, a fresh process, load, export and reimport. Expects root `[0, 2]` with camera 2 still looked through.
  - `topology-refused.json` (mirrored-camera scene): moving item children and moving under items is refused with its reason and writes no file; deleting camera 3 then exports and reimports.

  The full `studio-scenarios` lane ran `--strict` on 2026-10-25 against the Debug build of this branch: passed=61 failed=3 skipped=0. All five topology checks passed, with 13/13, 38/38, 5/5, 7/7 and 12/12 steps. The three failures are the accessory-label checks: the shared fixture map has no `IKKOKU_ACCESSORY_NAMES_MANIFEST`. With that one key added in a private copy of the map, they pass 3/3. A rerun of the reparent scenario re-renders the thumbnail from a live animated scene, so the PNG prefix differs between runs, while the scene bytes after it stay identical (457,815 bytes).
- **Original player.** One `prlctl exec` (`original_scene_reload_probe.py --once`) loaded the four exports and their three unedited source scenes in an isolated player copy (Unity 5.6.2f1, probe source SHA-256 `3bc5e2ca…`). The probe recorded each object's parent, child lists, world position and rotation, change amounts, the root dictionary order and keys, the sun caster and the looked-through camera. `compare_scene_reload.py` then checked each load against the tree an independent reader takes from the loaded file, and against the scenario's intended tree. All 7 cases passed; the report is `.local/stt03g-topology/scene-reload-comparison.json`.

  | Case | Original player after load |
  | --- | --- |
  | topology-delete | 1 object, root `[0]`, keys 1 and 2 absent, no looked-through camera, sun caster −1 |
  | topology-moved | Root `[0, 2]`, camera 2 looked through, folder 1 absent, camera 2's world pose kept within 6.8e-8 m and 4.9e-6° |
  | topology-reparent | 27 of 32 objects. Root `[622, 962, 626, 1130, 794, 1540, 1129]`, folder 962 `[963, 1127, 1128, 623]`, folder 626 `[627, 791, 792, 793, 65]`, folder 622 `[0, 624, 625]`. 1298 and its subtree are absent. Every kept object's world pose is within 3.0e-8 m and 2.9e-6° of the unedited load. |
  | topology-item-delete | Item 0 `[2]`, item 1 `[]`, camera 3 absent, camera 2 looked through |

  In every case, root dictionary keys equal `dicKey`, loaded change amounts equal the record at float32 precision, and the unedited sources load as their files say. The probe prints floats as their shortest round-trip text, so the comparison reads both sides as float32; a decimal readback alone differs from the widened float32 by up to half a float32 step. The parallels.log errno-24 count was 0 before and after the run. The private root was removed, and no game process was left.
- **Performance.** Release `swift test -c release -Xswiftc -enable-testing` timing probe (`SourceSceneTopologyPerformanceTests`, opt-in with `IKKOKU_TOPOLOGY_PERF=1` and `IKKOKU_STUDIO_SCENARIO_SCENE`), on the 612 KB, 32-record scenario scene, median of 60 calls after 10 warmups. Each process ran the same test alone, during a quiet window:

  | Call | main `aee4287` | This branch |
  | --- | --- | --- |
  | `decodeDocument` | 2.592 / 2.653 ms | 2.608 / 2.654 ms |
  | `editedData`, one transform | 5.237 / 5.353 ms | 5.247 / 5.321 ms |
  | `editedData`, reparent scenario (3 moves, 1 subtree deletion) | — | 5.65 / 5.84 / 5.89 ms |

  A no-op edit returns the input bytes. The topology path costs about the same as one transform edit, because both are dominated by re-decoding the output. Recording the topology spans adds no measurable read cost. Nothing runs per frame.

Reproduce the VM run from the repository root (`.local/verification/scenario-exports/` is where the lanes write their exports):

```sh
.local/reverse/unitypy-venv/bin/python Tools/reverse/original_scene_reload_probe.py --once --errno-baseline "$(grep -c 'errno: 24' /Library/Logs/parallels.log)" \
  --output .local/stt03g-topology/probe \
  --topology-delete .local/verification/scenario-exports/topology-delete.png \
  --topology-delete-source .local/reverse/original-camera-object-probe/scene-x.png \
  --topology-moved .local/verification/scenario-exports/reload-load-topology.png \
  --topology-reparent .local/verification/scenario-exports/topology-reparent.png \
  --topology-reparent-source "$IKKOKU_STUDIO_SCENARIO_SCENE" \
  --topology-item-delete .local/verification/scenario-exports/topology-refused.png \
  --topology-item-source .local/vm-mirrored-camera/probe/scene-mirrored-camera.png
.local/reverse/unitypy-venv/bin/python Tools/reverse/compare_scene_reload.py \
  --probe .local/stt03g-topology/probe --output .local/stt03g-topology/scene-reload-comparison.json
```

**Not verified:**

- Deleting an accessory child alone and the other refused cases (none of them is written).
- Deletion in scenes carrying plug-in data other than Sideloader and StudioSceneSettings entries, in the original player ([plug-in data](#plug-in-data-st-t03i)).
- How the original orders the roots after an interactive remove and add (history-dependent; our order is documented above and loads as written).
- Rendering the edited scenes in the original player. The capture records state, not pixels.

## Duplicates and added records (ST-T03, ST-S09, ST-D03)

Reviewed 2026-10-25. `SourceSceneEdits.insertions` writes copies of source records and new folder, camera and light records into the exported scene. `SourceSceneInsertion` (`Packages/Engine/Sources/Studio/SourceSceneInsertion.swift`) plans, writes and verifies them. They combine with the [topology edits](#topology-edits-deletion-and-reparenting-st-t03-st-s09) and every leaf edit in one export. As with deletions and moves, every case the writer cannot reproduce the way CharaStudio would is refused before any byte is written, and the app shows the reason.

### Recovered rules

Citations are `file:line` under `.local/reverse/managed-recovery/902b9a23…/77473a43…/project/Studio/`, the same assembly as the topology rules.

- **Duplicate is save, then import.** `Studio.Duplicate` (Studio.cs:440) runs `SavePreprocessingLoop` on each selected node, writes the selected records with `SceneInfo.Save(writer, selection)`, and reads those bytes straight back with `SceneInfo.Import` (SceneInfo.cs:463). So a copy is the original's saved record: the same name, change amount, tree state, visibility, card, pose, catalog IDs and light values, and the same subtree, because every record saves its own children.
- **New keys.** `Import` builds each root with a fresh key, `Studio.GetNewIndex()` (SceneInfo.cs:470–489). `GetNewIndex` (SceneInfo.cs:194) returns the smallest key not in `hashIndex` and adds it. With `_import` true, `ObjectInfo.Load` reads the saved key and discards it (ObjectInfo.cs:43–50). Every sub-info is built the same way while its record loads, so keys are taken in byte order:
  - a character: the record, then each FK bone, each IK target, the accessory children group by group in file order, then the look-at target (OICharInfo.cs:246–288);
  - an item: the record, its FK bones, then its children (OIItemInfo.cs:117–173);
  - a route: the record, its children, then for each point the point's key and its aid's key. Points load with `_import: false` (OIRouteInfo.cs:73–83), so `SetNewIndex` (Studio.cs:807) finds the original's key taken and hands out a fresh one (OIRoutePointInfo.cs:57–82).

  Only these numbers change in the copied bytes. Gaps are filled first, and a key freed by a deletion earlier in the session can be reused.
- **Placement.** `Duplicate` then loads each copy with `AddObjectAssist.LoadChild(info, parent, node)` when the original had a parent, else at the root (Studio.cs:472–484). The parent's `OnLoadAttach` appends the copy to its child list: a folder (OCIFolder.cs:61), an item (OCIItem.cs:234), a route (OCIRoute.cs:111), or the same accessory group of a character (OCIChar.cs:516). The copy is parented with `worldPositionStays: false` and keeps its saved local change amount, so it lands exactly on its original. A root copy is added to `dicObject` under its new key.
- **Cameras.** A camera record's load calls `ChangeCamera(ocic, active)` (AddObjectCamera.cs:82). The looked-through camera saves `active = true` (`OCICamera.SetActive`, OCICamera.cs:32), so its copy takes the view.
- **Lights.** The `OILightInfo` constructor calls `Studio.AddLight()` (OILightInfo.cs:27–39), and `isLightCheck` is `lightCount < 2` (SceneInfo.cs:109). `Import` and the nested child load read that check before they build a light and drop the light when two already exist (SceneInfo.cs:483, ObjectInfoAssist.cs:32). The Add Light menu refuses a third light the same way (Studio.cs:297).
- **Add.** `AddObjectFolder.Add` (AddObjectFolder.cs:8–10), `AddObjectCamera.Add` and `AddObjectLight.Add` build the record with `GetNewIndex()` and add it at the root. The `ObjectInfo` constructor's defaults are a zero position and rotation, unit scale, `TreeState.Close` and visible (ObjectInfo.cs:20–30). With the default option `initialPosition = 0` (OptionSystem.cs:85), the position stays zero; option 1 moves it to the camera target.
  - A folder is named `フォルダー` (OIFolderInfo.cs:18).
  - A camera is named `カメラ` plus the session's camera count, and it is inactive (OICameraInfo.cs:17).
  - The `OILightInfo` constructor makes a light white with intensity 1, range 10, spot angle 30, and shadow, enable and draw-target on (OILightInfo.cs:27–39). Its number is the `Light_00` catalog entry: 0 directional, 1 point, 2 spot.
- **Plug-in data.** ExtendedSave and the plug-ins it serves key scene data by `dicKey`. What they do on a duplicate is their own code, recovered from the installed DLLs under [plug-in data](#plug-in-data-st-t03i).

### Writer behavior

The writer works in two phases. `KoikatsuSceneDocument.inserting(_:)` writes the insertions into a staged scene and decodes it. Then the staged scene's `editedData` applies the deletions, moves and leaf edits, keyed by the staged keys, with the topology writer above.

- **Keys.** Allocation follows `Import`: the smallest key that no record or sub-info of the source file uses, deleted records included, taken in the copy's byte order. So a deleted record's key is never reused within one export. After an interactive delete, CharaStudio may hand out other numbers; keys only need to be unique.
- **A copy** is its template's own bytes: the header, name, card, pose, and the item and light data. The writer patches the record key and every sub-info key in place, and forces a camera copy's `active` byte to 0. The template's children are not copied with it. A copied subtree is one insertion per record, each under the copy of its parent, so a copy whose child was deleted or moved is written as the document shows it.
- **Parents.** An insertion goes at the root (under its own key), into a source or inserted folder, or, for a copy, into its template's own list: an item's child list or the same character accessory group, either the original owner or that owner's copy.
- **New records** are serialized like the `ObjectInfo` defaults, closed, with the app's name, transform (Unity basis, Euler degrees) and visibility. A new camera is written inactive. A new light writes the app light's number, color, intensity, range, spot angle, shadow and enable flags, with draw-target on.
- **Changed lists.** Every list that gains a record gets its Int32 count rewritten. Insertions are appended after the list's original records, in insertion order. All other bytes are copied unchanged.
- **Cameras.** A camera copy is written inactive. When the user looks through a different camera than the one the file loads with (a copy included), the app writes every camera's `active` flag, so the saved winner is the camera the user looks through. Without a switch, the original keeps its flag and still wins.
- **Verification.** The staged scene is decoded and must match the plan: settings and trailer equal, every source record unchanged and in place, every changed list equal to its original list plus the planned insertions, each inserted record of the planned kind, parent, accessory point, name, header and light values, and no key used twice. An export without insertions takes the previous path unchanged, and a no-op stays byte-identical.

**Supported:**

- Duplicating any folder, item, light, camera, character or route record with its subtree, including a character with its accessory children, an item with its child items, and a route with its children and points ([route copies](#route-points-and-settings-st-t11-st-t03)). A route child can be duplicated beside its original.
- Adding folders, cameras and lights at the root or in a folder (the app adds them at the root, and Set Parent moves them). Copies and new records can be moved, renamed, hidden and edited like source records, and the deletions and moves above apply to them in the same export.

**Refused.** Each of these rejects the whole export, with the stated reason:

| Case | Reason |
| --- | --- |
| Duplicating a route without points, or placing a copy of a route child outside its route's list | See [route points and settings](#route-points-and-settings-st-t11-st-t03). |
| A duplicate or new record that the scene's plug-in data cannot follow | Plug-ins key that data by object, and some list objects by position. [Plug-in data](#plug-in-data-st-t03i) decides each KKEx entry for copies and new records alike, and refuses a copy when NodesConstraints would turn a written character's card links into constraints, with or without a trailer. Before ST-T03i, new records kept the trailer bytes in every scene, which could shift positional data. |
| Adding characters or items | A new character needs a card and an item needs catalog identity this writer does not author. Duplicating a source one is supported. |
| More than two lights after the export | `isLightCheck` drops a third light at load. |
| Adding under an item, onto accessory points, under a route, a camera or a light | The same rules as moves, except a copy beside its original. |
| A new record with non-unit scale, a camera field of view other than 30, a light spot blend, or native card, asset, material or pose data | CharaStudio's records have no field for these, or the app has no writer for them. |
| A new light number outside 0–2, a nonfinite value, a negative intensity, a range that is not positive, or a spot angle outside 0–180° | Invalid record. |

### App translation

`StudioModel.duplicateSelection` calls `duplicateSourceSubtree` for a source record or a copy in an imported scene. It copies the subtree with new IDs, the same names, transforms and list position, and sets each copy's `sourceDuplicateOf` to the record it shows (`sourceRecordKey`). A copy never takes `sourceObjectKey`. The copy renders from its original's camera and item caches, and a copy of the looked-through camera takes the view. Native save keeps `sourceDuplicateOf`, and source rehydration after a native reload restores each copy from its source record. Undo and redo restore the whole duplicate. Native objects still duplicate as before.

In an imported scene, Add Folder, Add Camera and Add Light add at the root, as CharaStudio does. A new camera is placed at the view position and takes the view's orientation, because a CharaStudio camera object looks through its own transform.

`SourceSceneExportValidation.stage(document, source:)` turns the document into insertions: each forest root in document order, then each added object's children depth first. Leaf edits, deletions and moves are then validated against the staged snapshot with the staged keys.

### Evidence

- **Engine.** `SourceSceneInsertionTests` (10 tests) build the expected scene with the independent `TopologyScene` spec builder from the topology tests, extended with copies, names, FK, IK, look-at and item bone keys, lights, tree states and visibility, and compare every byte:
  - a folder subtree, an item with its bones and a child, and a character with its FK, IK and look-at keys and an accessory child, each under the expected keys;
  - a camera copy written inactive, and the view handed to it only through an explicit `cameraActive` edit;
  - new folders, cameras and lights;
  - insertions combined with leaf edits, deletions and moves in one export, including edits addressed to the copy and its sub-infos;
  - edit-then-revert: deleting what was added restores the original bytes, and an empty insertion list is a no-op;
  - smallest-free-key allocation across sub-info keys, and a deleted key not reused;
  - the plug-in trailer rule;
  - every refusal, each with its reason.

  `SourceSceneExportValidationTests` adds the app translation: a document with a copy subtree, a new folder and a moved copy stages keys `[0, 4, 6, 7, 8]` and exports roots `[10, 20, 0, 6, 8]`. The full Engine suite (`swift test --package-path Packages/Engine` with every fixture of the shared map, after merging main at 872d2ec) ran 942 tests. 12 were skipped: opt-in timing probes and fixtures that are not present. 1 failed, the pre-existing `liveSourceShadersMeetTheControlledOriginalFrameGates`, whose local store fixture has 52 entries where the test expects 62.
- **Lanes.** Four new `studio-scenarios` checks drive the same `StudioModel` methods the UI uses, with negative controls:
  - `topology-duplicate.json` (koikatu_cs0002591): Duplicate folder 962 (a character and three items), item 1540 and item 1127, then Add Folder, Add Camera and Add Light (point). It asserts the tree labels, each copy's world position against its original within 1e-4 m and 0.01°, and six undos and redos. After export and reimport the roots are `[622, 65, 962, 626, 1130, 794, 1298, 1540, 113, 334, 336, 337, 338]`, copy 113 holds `[114, 331, 332, 333]` and folder 962 holds `[963, 1127, 1128, 1129, 335]`, the keys an independent Python allocation over the source file predicts. Every copy and new record is within 5e-4 m and 0.05° of its pre-export capture. Two `assertRejected` controls (a wrong position source and a wrong child order) must fail.
  - `topology-insert-refused.json` (mirrored-camera scene): a new character, and a new folder moved under an item, are each refused with their reason and write no file. Duplicating camera 2 inside item 0 hands it the view, and the reimport has item 0 `[2, 4]` with camera 4 looked through.
  - `reload-save-duplicate.json` and `reload-load-duplicate.json` (scene-x): duplicate camera 2, undo and redo, add a folder and save natively. A fresh process loads it with three camera cache entries after one rehydration, switches to the copy, exports and reimports root `[0, 1, 4]`, folder 1 `[2, 3]`, camera 3 looked through at camera 2's world position.

  The full `studio-scenarios` lane passed 68/68 with `--strict`, and `maker-scenarios` passed 10/10. After the negative controls moved ahead of the final asserts, and again after the merge of main at 872d2ec, the four new checks passed: topology-duplicate (56 steps), topology-insert-refused (16), reload-save-duplicate (11) and reload-load-duplicate (13). The reports are in `.local/stt03h-duplicate-insert/lanes/`.
- **Original player.** One `prlctl exec` (`original_scene_reload_probe.py --once`) loaded `topology-duplicate` and the camera copy (`topology-camera-copy`, the `topology-insert-refused` export), plus their two unedited source scenes, in an isolated player copy (Unity 5.6.2f1). The probe now also records the key index after the load (`SceneInfo.hashIndex`) and each object's content: an item's catalog IDs, whether its prefab loaded and its renderer and vertex counts, a light's values and the `Light` they drive, a character's card name, sex and renderer and vertex counts. `compare_scene_reload.py` checks each load against the tree the independent Python reader takes from the loaded file and against the scenario's intended tree. All 4 cases passed; the report is `.local/stt03h-duplicate-insert/scene-reload-comparison.json`.

  | Case | Original player after load |
  | --- | --- |
  | topology-duplicate | 42 objects (32 + 10). Roots, child lists, accessory groups, dicKeys and change amounts as written. 1,122 index keys, exactly the record's key list (977 in the source load), so no key was remapped. Every source object at its source-load world pose, and every copy at its original's: 0 m and under 1e-14°. Copies show their original's name and content: character 114 `春野 千佳` with 46 renderers and 50,224 vertices like 963, items 331–335 catalog `0/0/1` loaded like theirs. New folder, camera and light at their record placement within 3.4e-8 m and 6.7e-6°; the light loads as the point light written (intensity 0.5, range 3, spot angle 40). Names, tree states and visibility as written. |
  | topology-camera-copy | 5 objects. Item 0 `[2, 4]`, camera 4 `IKKOKU-MIRROR` looked through, cameras 2 and 3 inactive, copy 4 at camera 2's source-load world pose. |

  The parallels.log errno-24 count was 0 before and after the run. The private root was removed, and no game process was left.
- **Performance.** Export costs did not change. Duplicating a character in the app stalls the main thread for about 0.6 s per character. An item copy costs about 1.6 ms.

  The export was timed with `SourceSceneTopologyPerformanceTests`, in Release (`swift test -c release`) on koikatu_cs0002591, with one test per process and 60 calls each:

  | Call (median / p90 ms) | main d6b61a2 | this branch |
  | --- | --- | --- |
  | `decodeDocument` | 2.870 / 3.014 | 2.875 / 3.040 |
  | `editedData`, one transform | 5.791 / 6.037 | 5.823 / 5.966 |
  | `editedData`, reparent scenario (3 moves, 1 subtree deletion) | 5.676 / 5.844 | 5.508 / 5.656 |
  | `editedData`, duplicate scenario (7 copies, 3 new records) | — | 6.642 / 6.835 |
  | the same plus one transform on a copy | — | 13.535 / 13.822 |

  An export without insertions takes the unchanged path, so its cost is the same as on main. With a leaf edit, the leaf writer walks the staged scene a second time, the same walk any edited export makes (5.8 ms on main). Reusing the stage's decoded spans would touch every leaf destination, so this change leaves that walk in place.

  The app was timed with the Release build and the scenario op `timeDuplicate` (select, then `duplicateSelection()` timed, then undo; 20 rounds):

  | Duplicated object | Median | p90 |
  | --- | --- | --- |
  | item 1127 | 1.62 ms | 1.78 ms |
  | character 963 | 611 ms | 616 ms |
  | folder 962 (a character and three items) | 610 ms | 612 ms |
  | folder 962 holding 25 objects with 5 characters | 3.03 s | 3.05 s |

  An unmeasured Time Profiler run (10 duplicates of character 963) attributes the stall:
  - About 590 ms of each duplicate is `SourceStudioCharacterPreview.init`. `refresh()` calls it synchronously for the copy, which has no cached preview.
  - 522 ms of that re-parses the converted Maker rig JSON in `SourceMakerLibrary.prepare` (`SourceRig.decode`). The base body and head components take 336 ms, and the card's converted clothes, hair and accessories about 190 ms.
  - The rest is small:
    - the shape contract decode, 24 ms;
    - the `SourceRigPreview` init with mesh registration, 11 ms;
    - appearance, 11 ms;
    - the scene decode, 3 ms;
    - the first frame, 2 ms.

  The duplicate itself, the subtree copy and the copy's export add nothing per frame. `refresh()` and `Renderer.prepare` gain only the `sourceRecordKey` read. Reusing the decoded rigs (they are immutable for the same bytes) or building the preview off the main thread is the follow-up. It is [R7](../performance.md) phase 2, item 6, which owns source character preview construction at import, undo restore and duplicate.

Reproduce the VM run from the repository root:

```sh
.local/reverse/unitypy-venv/bin/python Tools/reverse/original_scene_reload_probe.py --once --errno-baseline "$(grep -c 'errno: 24' /Library/Logs/parallels.log)" \
  --output .local/stt03h-duplicate-insert/probe \
  --topology-duplicate .local/verification/scenario-exports/topology-duplicate.png \
  --topology-reparent-source "$IKKOKU_STUDIO_SCENARIO_SCENE" \
  --topology-camera-copy .local/verification/scenario-exports/topology-insert-refused.png \
  --topology-item-source .local/vm-mirrored-camera/probe/scene-mirrored-camera.png
.local/reverse/unitypy-venv/bin/python Tools/reverse/compare_scene_reload.py \
  --probe .local/stt03h-duplicate-insert/probe --output .local/stt03h-duplicate-insert/scene-reload-comparison.json
```

**Not verified:**

- New characters or items (refused). Duplicates and new records in scenes carrying plug-in data other than Sideloader and StudioSceneSettings entries, in the original player ([plug-in data](#plug-in-data-st-t03i)). Route copies were reloaded later ([route points and settings](#route-points-and-settings-st-t11-st-t03)).
- Lights: the reloaded scenes had one light, the new one. The two-light limit follows the recovered code and was not reloaded.
- A new record inside a folder, and a copy inside a character's accessory group, are covered by the Engine tests only, without a reload in the original player.
- Rendering in the original player. The capture records state and mesh counts, not pixels.

## Route points and settings (ST-T11, ST-T03)

Reviewed 2026-10-25. `SourceSceneEdits.routes` writes an imported route's edited points and settings into the exported scene. `SourceSceneEdits.insertions` writes copies of routes. `SourceStudioRouteState` (`Packages/Engine/Sources/Studio/SourceStudioRouteEditing.swift`) holds the editable state of one route and its CharaStudio rules. Route edits combine with the [topology edits](#topology-edits-deletion-and-reparenting-st-t03-st-s09), the [insertions](#duplicates-and-added-records-st-t03-st-s09-st-d03) and every leaf edit in one export. Every case the writer cannot reproduce the way CharaStudio would is refused before any byte is written, and the app shows the reason.

### Recovered rules

Citations are `file:line` under `.local/reverse/managed-recovery/902b9a23…/77473a43…/project/Studio/`, the same assembly as the sections above. The record layout is in [scene records, Routes](scene-records.md#routes).

- **Record.** `OIRouteInfo.Save` (OIRouteInfo.cs:50–71) writes the name, the children, the point count and each point, then `active`, `loop`, `visibleLine`, `orient` as an Int32, and the colour as `JsonUtility.ToJson(color)`. `OIRoutePointInfo.Save` (OIRoutePointInfo.cs:46–55) writes 94 bytes per point:
  - the point's key and change amount;
  - the speed (float), the ease and the connection (Int32 each);
  - the aid's key, change amount and `isInit` flag;
  - the `link` flag.
- **Add a point.** `OCIRoute.AddPoint` (OCIRoute.cs:219–228) returns null once the route has more than ten points (`limitNum = 10`, line 14) while the `routePointLimit` option is on, which is the default. So a route holds at most 11 points.
  - `AddObjectRoute.AddPoint` (AddObjectRoute.cs:106–114) builds `new OIRoutePointInfo(GetNewIndex())` and appends it to the list. It always goes after the last point, never after the selected one.
  - The constructor (OIRoutePointInfo.cs:38–44) sets speed 2 and linear. The connection is Line and there is no link.
  - `LoadPoint` (AddObjectRoute.cs:116–172), called with `_initialPosition 1`, places the new point at the last point's route-local position (`InverseTransformPoint` of its world position, :153–163).
  - `InitAid` (AddObjectRoute.cs:174–199) gives the new point's aid the next `GetNewIndex()` key. The aid starts at the `p_RoutePoint` prefab's `objAid.localPosition`, uninitialised. Every aid the route fixtures' `AddPoint` created reads back as (1, 1, 1).
- **Delete a point.** `OCIRoute.DeletePoint` (OCIRoute.cs:230–238) calls `Stop()` first. It then removes the point's node, controller and info, renumbers the names and redraws the line. The start point has no delete (`enableDelete = num != -1`, AddObjectRoute.cs:140).
- **Guides.** `LoadPoint` sets up the guides (AddObjectRoute.cs:130–133):
  - The start point's guide only rotates (`enableRot = num == -1`).
  - Every other point's guide only moves (`enablePos = num != -1`).
  - Nothing scales, and the guides work in world mode.
  - The aid's guide only moves (`enableRot`/`enableScale` false, :187–188). It is active only for a Curve connection.

  A point move or a start rotation calls only `OCIRoute.UpdateLine` (`onChangePosAfter`/`onChangeRot`, :166–169).
- **Point panel (`MPRoutePointCtrl`).**
  - **Speed.** A slider from 0.1 to 30, not whole numbers. These are prefab values, which the reload probe read from the loaded panel. `OnEndEditSpeed` (:234) clamps a typed value to the slider.
  - **Ease.** The six-entry list from `Awake` (:308): linear, easeInQuad, easeOutQuad, easeInQuart, easeOutQuart and easeOutBounce.
  - **Connection.** The `OCIRoutePoint.connection` setter (OCIRoutePoint.cs:138–153) runs `InitAidPos` (:313) when the point becomes Curve and its aid was never placed. The aid goes to the point-local midpoint toward the next point (point 0 after the last), and `isInit` becomes true. A placed aid keeps its position.
  - **Link.** `isLink` (:172) joins a curve point into the previous point's curve segment.
  - **Greyed-out controls.** `UpdateInteractable` (:180) greys out speed, ease, connection and link while the route plays. It also greys out speed and ease on a linked curve point that follows a curve point.
- **Route panel (`MPRouteCtrl`).** `UpdateInteractable` (MPRouteCtrl.cs:134–143) greys out Add Point, orient and loop while the route plays.
  - Loop (`OnValueChangedLoop`, :195) sets `routeInfo.loop` and redraws the line.
  - The line toggle (:213) sets `visibleLine`.
  - Orient (:225) sets `routeInfo.orient`.
  - The line colour palette opens with `_useAlpha: false` (:262), so only RGB changes.
- **Line.** `UpdateLine` (OCIRoute.cs:421–548) deletes the line when the route has fewer than two points. Otherwise it builds the line with Vectrosity `MakeSpline` through the point and aid transforms, 160 segments per curve. The line is active when `visibleLine` is, and `OnVisible` (:163–168) shows it only while the route is also visible. `SetVisible` (:179–190) hides the point guides together with the line.
- **Play and Stop.** `Play` (OCIRoute.cs:240) refuses a route with fewer than two points and places `childRoot` at point 0. `Stop` (:400–420) pins `childRoot` to point 0 in every `LateUpdate`.
- **A point moved while the route plays.** `Play` queues one `MoveTo` per segment (`SetPath`, OCIRoute.cs:338–398). Each holds the segment's point and aid `Transform`s and the speed and ease values of that moment. `StudioTween` reads the transforms' positions only when a segment starts: `TweenComplete` (StudioTween.cs:1982) calls `Next` (:3673), which calls `RetrieveArgs` and `Play`. `Play` calls `TweenStart` (:1865), which runs `GenerateMoveToPathTargets` (:1177).

  So the segment in progress keeps its targets, and every later segment, including the next loop, takes the moved positions. A segment whose first point moved away from `childRoot` (Unity's `Vector3 !=`, :1201) starts with the `movetopath` leg from `childRoot`'s position. That segment's time is the joined path's length over the queued speed (:1250). A start rotation changes nothing until the next `Play`.
- **Duplicate.** `Studio.Duplicate` saves the route and imports it again (see [duplicates](#duplicates-and-added-records-st-t03-st-s09-st-d03)).
  - Its points load with `_import: false` (OIRouteInfo.cs:73–83). `SetNewIndex` (Studio.cs:807) therefore finds each saved point and aid key taken and hands out a new one, after the keys of the copy's children (OIRoutePointInfo.cs:57–82).
  - `OCIRoute.OnLoadAttach` (OCIRoute.cs:111) parents each copied child under `childRoot` with `worldPositionStays: false`, so the child keeps its saved local placement.
  - The copy keeps the saved `active` flag, so the copy of a playing route plays from point 0 when it loads.

### Writer behavior

- **Points.** The writer replaces the point list, from its count through the last point, with the bytes `OIRouteInfo.Save` writes.
  - Kept points keep their point and aid keys and their saved order, and added points follow them.
  - Each added point takes the smallest free key and its aid the next one, as `GetNewIndex` would. Allocation runs in ascending route key order, after every insertion of the export. It never reuses a key the export frees, whether a deleted point's or a deleted record's.
- **Settings.** The `loop` and `visibleLine` bytes and the `orient` Int32 are patched in place. The colour string is rewritten only when the colour changes. The new string is `JsonUtility`'s `{"r":…,"g":…,"b":…,"a":…}` form, and each value reads back as the same float.
- **Copies.** A route copy is written from its template's bytes. The record key, the children's keys and the point and aid keys are patched in the order `Import` assigns them: the copy, its children, then point, aid, point, aid, and so on.
  - A copy of a route child stays in its route's child list or in the copy's.
  - The copy keeps its template's `active` byte. The app writes a copy's play state through `routeActive` like any route's.
  - A copy's own point edits address its staged key.
- **Verification.** After writing, every edited route must read back exactly as planned. No key may be used twice across records, sub-infos, route points and aids. An unchanged route state writes nothing, so a no-op stays byte-identical, and editing a route back to its saved values restores the original bytes.

`SourceStudioRouteState.validate(against:)` checks each state against its record before any byte is written.

**Supported:**

- Moving any point except the start point, rotating the start point, and moving a curve point's aid.
- Adding points, up to 11, and deleting any point except the start point.
- Speed (0.1–30), the six eases, connection and link on each point.
- Loop, line visibility, orient and the RGB line colour on the route.
- Duplicating a route with its children and points, and duplicating a route child beside its original. Copies can be edited like the original.

**Refused.** Each of these rejects the whole export or the edit, with the stated reason:

| Case | Reason |
| --- | --- |
| A 12th point | `routePointLimit` (`OCIRoute.AddPoint`). |
| Moving or deleting the start point; rotating or scaling another point; rotating or scaling an aid; moving the aid of a Line point | The guides cannot do it (`LoadPoint`, `InitAid`). |
| Points reordered, or a new point before a kept one | CharaStudio only appends points. |
| A speed outside 0.1–30, an ease outside the six-entry list, an unknown connection or orientation, a nonfinite value | The panels cannot produce it. A typed speed is clamped, as `OnEndEditSpeed` clamps it. |
| A curve point whose aid was never placed; an aid reset after it was placed; a never-placed aid that moved | `InitAidPos` places the aid once, when the point becomes Curve. |
| A colour alpha change, or a component outside 0–1 | The palette is opened with `_useAlpha: false`. |
| Adding or deleting route points that the scene's plug-in data cannot follow | Points are not plug-in objects: `AddObjectRoute.LoadPoint` registers each with `Studio.AddCtrlInfo` (AddObjectRoute.cs:151), which fills `dicInfo` only (Studio.cs:780), while plug-ins read `dicObjectCtrl` (filled by `AddObjectCtrlInfo`, Studio.cs:745). Points take keys from the same `hashIndex`, so [plug-in data](#plug-in-data-st-t03i) judges the keys the export writes, and an entry with no recovered rule refuses. |
| Duplicating a route that has no points | CharaStudio adds a start point when it loads such a route. |
| A copy of a route child placed outside its route's list or the copy's | Its saved local placement follows the route's playback position. |
| A new record under a route; moving a route or a route child | Unchanged from the sections above. |
| In the app, Add Point, orient, loop, speed, ease, connection and link while the route plays | Greyed out by the panels' `UpdateInteractable`. The app's message is "stop the route first". |

### App translation

- **Editing.** Selecting an imported route shows its point and aid handles, and `pickID` picks them like a gizmo. The route panel in the inspector holds Play/Stop, loop, line, orient, colour and Add Point. The point panel holds the selected point's speed, ease, connection, link and Delete.
- **Undo, save and the copy.** Every change goes through `editSourceRoute`, which pushes one undo snapshot per command (a guide drag pushes it at mouseDown). The change is stored in the document field `StudioObject.sourceRoute`, so undo/redo and native save/reload keep the edits, and the export writes them as `SourceSceneEdits.routes`. A route copy shares its original's runtime, carries its own `sourceRoute`, and plays from point 0 at the duplicate instant when the original plays.
- **Playback.** `applySourceRouteEdits` keeps each route runtime equal to the document. A point, aid or start-rotation move under a playing route retargets the route clock (`SourceStudioRouteClock.retarget`) with CharaStudio's segment-start rule above, so a drag never makes the playing route or its character jump. Any other change to the path stops being a live edit: the clock is dropped and the route plays the edited record from its play start. The panels lock those settings while the route plays, and Delete stops the route first.
- **Live step.** The app's 30 Hz live step also runs when a route plays and the scene has no character entry. A character riding a route keeps a folder-kind entry, so before 2026-10-25 a scene whose only character rides a route never played its routes in the app. A 3 s Release `studio-idle` run on scene-route-children.png presented 0.0 frames/s before the fix and 30.0 after. The lanes' `advance` op calls the live step directly, so it did not show the bug.
- **Differences from CharaStudio, all display-only:**
  - The drawn line is the path the playback follows, sampled from the tween's Catmull-Rom segments. CharaStudio draws Vectrosity's `MakeSpline` through the same transforms, which can differ on curves.
  - Handles show for the selected route only, and also while its line is off. CharaStudio hides the point guides together with the line.
  - The ease menu has no `OnValueChangedEase` quirk. In CharaStudio, selecting a point whose saved ease is not in the list can rewrite it to linear, because that handler does not check `isUpdateInfo`. The app keeps such an ease until the user picks one.

### Evidence

- **Engine.** `SourceSceneRouteEditTests` (12 tests) extend the independent `TopologyScene` builder with route points, aids and settings. They compare every byte of each export and read each destination back with the scene reader:
  - point moves, the start rotation and aid placement, with edit-then-revert returning the original bytes;
  - added points under the CharaStudio keys, and a deleted point's keys not reused;
  - every point and route setting, `InitAidPos` and the linked-point lock;
  - route edits combined with an insertion, a deletion, a rename and a play-state edit in one export;
  - route copies with their children's and points' keys, and a route child copied beside its original;
  - the panel and guide rules;
  - every refusal, including the plug-in trailer rule;
  - the path line;
  - the playing-route retarget: the stepper keeps the segment in progress, joins the next one with the `movetopath` leg, and replays the moved route at the next loop. A retarget that changes nothing is bit-identical, a queued setting is refused, and the clock keeps its frame and hands later rebuilds the moved route. Disabling the `movetopath` leg fails the first test (negative control).

  `SourceSceneTopologyTests` and `SourceSceneInsertionTests` were updated for the route copy and route child rules. With the shared fixture map, the Engine suite on the merged head `bfd6dd5` (main `ca17d8a`) ran 961 tests: 947 passed and 13 were skipped (opt-in timing probes and absent fixtures). The 1 failure is `liveSourceShadersMeetTheControlledOriginalFrameGates`, a known store-fixture mismatch that is unrelated to routes.
- **Lanes.** Four new `studio-scenarios` checks drive the same `StudioModel` methods the UI uses, with negative controls:
  - `route-edit-export.json` on the stt11c route scene:
    - a guide drag of point 2 while route 0 plays, and locked settings refused while it plays;
    - after Stop: Add Point at the CharaStudio defaults, moves, speed, ease, curve connections, link, loop, orient, colour and the line, with undo and redo;
    - on the second route: an aid drag, a start rotation and a point delete, which stops the route;
    - export and reimport, which read back points `[1, 6, 10, 14, 18]` with aids `[2, 7, 11, 15, 19]` and `[4, 8, 12]` with aids `[5, 9, 13]`.
  - `route-children-edit.json` on scene-route-children.png:
    - a guide drag and a point move with undo/redo, then Stop and Play;
    - Duplicate of the route with its folder and character, and the copy's settings locked while it plays;
    - native save and in-process load;
    - export and reimport as route 157 with points 306–313 after its children 158 and 159;
    - after each step, each child's world placement within 1e-3 m and 0.1° of its capture.
  - `route-children-edit-load.json`: a fresh process loads the saved document. Both routes rehydrate once with their edits, and both folders move.
  - `route-move-playing.json` (scene-route-children.png): route 0 and its copy play from the same instant. Moving route 0's point 1 mid-segment, then a guide drag of its point 2, leaves route 0's folder within 1e-5 m and 0.1° of the unedited copy's. In the next segment the two folders are 0.86 m apart (negative control). Exported and reimported, route 0 reads back its moved points, and its pre-drag capture is rejected at point 2 (negative control).
  - `undo-route`, `reload-save-route` and `reload-load-route` still pass unchanged.

  The full `studio-scenarios` lane passed 72/72 under `--strict` (0 skipped, 1,706.2 s, under the app lock) on the Debug build of `565040d` (main `2dc317f`). It passed 73/73 (1,193.2 s) on the merged head `bfd6dd5` (main `ca17d8a`), whose 73rd check is main's `background-build`. `maker-scenarios` passed 10/10 on both.
- **Original player.** One `prlctl exec` (`original_scene_reload_probe.py --once`, labels `route-edit` and `route-children-edit`) loaded the two exports in an isolated player copy (Unity 5.6.2f1, probe source SHA-256 `a2199f4a…`). For each route it recorded the loaded points (key, change amount, speed, ease, connection, link, aid key, aid change amount and flag), the route settings and the line `UpdateLine` built. It also traced `childRoot` and each child's world placement for 240 frames, at least 4 s, with each frame's `deltaTime`, and read the route point panel.

  `compare_scene_reload.py` checked the loads against the records an independent Python reader takes from the exported files and against the scenarios' intended keys, play states and children. It checked every traced frame against `ikkoku-inspect route-steps` over the trace's own `deltaTime`s. All claims passed; the report is `.local/stt11k-route-edit/scene-reload-comparison.json`.

  | Case | Original player after load |
  | --- | --- |
  | route-edit, route 0 `IKKOKU-A` | Points `[1, 6, 10, 14, 18]`, aids `[2, 7, 11, 15, 19]`, with speed, ease, connection, link and aid flags as written; change amounts equal; playing, no loop, orient Y, colour (0.2, 0.8, 0.4); no line shown. `childRoot` within 5.4e-7 m and 0.036° of the stepper over 435 frames (3.94 s), active flag equal in every frame. |
  | route-edit, route 3 `IKKOKU-B2` | Points `[4, 8, 12]`, aids `[5, 9, 13]`; stopped, pinned to point 0 in every frame (0 m, 0.023°); line shown. |
  | route-children-edit, route 0 | Points `[1, 3, 5, 7]` with the moved point 1; `childRoot`, folder 9 and character 10 within 6.7e-7 m of the stepper over 346 frames (3.98 s). |
  | route-children-edit, copy 157 | Points `[306, 308, 310, 312]`, aids `[307…313]`, children `[158, 159]`, curve point 3. `childRoot` within 7.3e-7 m, children within 7.7e-7 m. |

  In both loads the key index equals the file's key list, and every change amount equals its record at float32 precision. The point panel matches the app: speed 0.1–30, six eases, point limit on. The parallels.log errno-24 count was 0 before and after the run. The private root was removed, and no game process was left. The two exports' scene bytes after the PNG are identical to the current lanes' exports. A rerun re-renders only the thumbnail.
- **Performance.** Measured on Release builds in a quiet window, against origin/main `2dc317f`, with base and branch runs alternating. Evidence is in `.local/stt11k-route-edit/perf/` and `perf2/`.
  - **Export.** `sourceSceneRoutePerformance` runs 60 calls per case under `swift test -c release`. Medians from two runs per build:

    | Case | Base | Branch |
    | --- | --- | --- |
    | Route scene, no-op | 0.000 ms | 0.000 ms |
    | Route scene, one transform | 1.00, 0.99 ms | 0.91, 0.80 ms |
    | Route edit: 2 moves, 1 add, speed, ease, curve | n/a | 0.92, 0.83 ms |
    | Route copy with its folder and character, both routes edited | n/a | 3.15, 2.82 ms |
    | Topology scene, duplicate scenario | 7.58, 8.16 ms | 8.11, 7.42 ms |

    The no-op stays on the byte-identity fast path. The other topology cases also stay within run-to-run noise.
  - **Point move.** A guide drag event's median is 1.31 ms (max 1.37) while route 0 and its copy play (`route-move-playing`). On stopped routes it is 0.33–0.45 ms (`route-edit-export`), and the mouseUp is 0.00 ms.
  - **Duplicate stall.** Duplicating route 0 with its folder and character takes a median of 119.8 ms on the main thread (p90 123.4, 20 rounds `timeDuplicate`; Release `28b0eaf`, main `42fc588` merged). Before that merge it took 696 ms (p90 700). A folder copy takes 0.24 ms.
    - **Why it fell.** The copy's character preview is now built through `makeSourceCharacterPreview`, which borrows the original's converted assembly (R7 phase 2, item 6).
    - **Where the time goes.** A timed build of the same probe gave these medians: `assemble` with the borrowed assembly 1.9 ms, `SourceStudioCharacterPreview.init(assembly:resources:)` 111 ms (it registers the meshes and textures and evaluates the preview), and the subtree copy and runtime entries the remaining 2–3 ms. No export plan runs on Duplicate.
    - **Why a plain duplicate costs less.** A route character's copy is built synchronously inside the Duplicate command, in every mode. A plain character's duplicate builds through `SourceStudioCharacterBatch`, and in the interactive app that build's second half runs on `sourceBuildQueue`, so the main thread pays about 45 ms. The timing probe builds synchronously and times only the command, so it does not show the plain duplicate's build at all.
    - **Route-copy background build (done, R7 phase 2 item 6 follow-up).** In the interactive app, a route character copy now builds through `SourceStudioCharacterBatch` on `sourceBuildQueue` (`startSourceRouteCharacterBuilds`). It has pending, install and cancel handling like the document's characters, and it borrows the original's assembly. In the Release `studio-duplicate` workload on route 0 (`IKKOKU_PERF_ACTION_KEY=0`, live animation on, 22 and 23 actions), the Duplicate's call fell from 159 ms (153–165) to 2.4 ms. The copy's character is drawn 97 ms (88–101) after the command, and the main thread works 41 ms for it instead of 182 ms. The undo stays at about 2 ms. Captures and scenarios still build the copy inside the command, and `studio-scenario-background-build-route` checks that both builds give the same document and pixels. See [the follow-up](../performance.md#phase-2-item-6-follow-up-route-copies-prefetch-and-kept-donations).
  - **Idle with a playing route.** `studio-idle` ran on scene-route-children.png with route 0 playing and its character riding it, 10 s per run, two runs per build. Both builds carry the live-step fix, and `studio-idle` now counts a route's characters (`details.sourceRouteCharacters`).

    | Metric | Base | Branch |
    | --- | --- | --- |
    | Frames presented | 30.0/s | 30.0/s |
    | Main thread busy | 36, 38 ms/s | 33, 29 ms/s |
    | `studioTick` p50 | 1.05 ms | 1.03, 0.87 ms |
    | GPU | 13.3 ms/s | 13.3 ms/s |
    | Palette buffers created | 0 | 0 |

    In Time Profiler attaches, route frames on the main thread take 1.5 ms/s (base) and 1.3 ms/s (branch). On the branch, `applySourceRouteEdits`' unchanged check takes 0.4 ms/s. No allocation frame appears under the route code.

Reproduce the VM run from the repository root:

```sh
.local/reverse/unitypy-venv/bin/python Tools/reverse/original_scene_reload_probe.py --once --errno-baseline "$(grep -c 'errno: 24' /Library/Logs/parallels.log)" \
  --output .local/stt11k-route-edit/reload-probe \
  --route-edit .local/verification/scenario-exports/route-edit-export.png \
  --route-children-edit .local/verification/scenario-exports/route-children-edit.png
.local/reverse/unitypy-venv/bin/python Tools/reverse/compare_scene_reload.py \
  --probe .local/stt11k-route-edit/reload-probe --cli Packages/Engine/.build/debug/ikkoku-inspect \
  --output .local/stt11k-route-edit/scene-reload-comparison.json
```

**Not verified:**

- A point moved while the route plays: the segment-start rule follows the recovered `StudioTween` code and the Engine tests, but no original-player capture of a live edit exists.
- Route edits in scenes carrying plug-in data other than Sideloader and StudioSceneSettings entries, in the original player ([plug-in data](#plug-in-data-st-t03i)).
- The `routePointLimit` option turned off. The app always keeps the default limit.
- A route nested in a folder or an item. Every fixture route is a root.
- Rendering in the original player. The capture records state and positions, not pixels, and the line's Vectrosity shape is not compared.

## Plug-in data (ST-T03i)

Reviewed 2026-10-25. This covers deleting, duplicating and adding records, and adding or deleting route points, in a scene that carries ExtendedSave plug-in data. `SourceScenePluginData` (`Packages/Engine/Sources/Studio/SourceScenePluginData.swift`) decides every entry of the scene's KKEx trailer for each such export, after the [topology edits](#topology-edits-deletion-and-reparenting-st-t03-st-s09), [insertions](#duplicates-and-added-records-st-t03-st-s09-st-d03) and [route edits](#route-points-and-settings-st-t11-st-t03) are planned. Each entry is kept byte for byte or rewritten as its plug-in would write it. Otherwise the whole export is refused before any byte is written, and the reason names the plug-in. Moves and leaf edits keep the trailer as before.

### Recovered rules

The plug-ins are the installed DLLs of the [installed inventory](../mods/plugin-inventory.md) (243 DLLs), recovered with ilspycmd into `.local/stt03i-plugin-data/recovered/<SHA-256>/project/`. Each citation names the DLL by its hash prefix, then `file:line` in its project. The Studio citations are under `.local/reverse/managed-recovery/902b9a23…/77473a43…/project/Studio/`, as in the sections above. [Mods overview, scene plug-in data](../mods/overview.md#scene-plug-in-data-in-edited-original-scenes) records the plug-ins' own quirks.

- **ExtendedSave 21.1.2.1** (`7b1c7f04…`, ExtensibleSaveFormat/ExtendedSave.cs). `PluginData` is the MessagePack array `[version, data]`.
  - **Load.** `SceneInfoLoadHook` (:738–760) clears the scene dictionary, replaces it from the trailer, then raises `SceneBeingLoaded`.
  - **Save.** `SceneInfoSaveHook` (:846–871) raises `SceneBeingSaved`, removes nil entries and serializes the whole dictionary again. So an entry that no plug-in writes on save carries over verbatim, stale keys included, and a nil entry disappears.
- **KKAPI 1.46.1** (`7f4f50e1…`, KKAPI.Studio.SaveLoad/StudioSaveLoadApi.cs).
  - Scene controllers save from `SceneBeingSaved` (:250).
  - At load, they see `dicObjectCtrl` by saved key (:427).
  - A `Studio.Duplicate` postfix passes each original key and its copy's key to `OnObjectsCopied` (:45–63, :139–145, :423–436).
  - `OnObjectDeleted` hooks the `OnDelete` of items, characters, folders, lights, cameras and routes (:158–168), not of route points.
- **Route points are not plug-in objects.** `AddObjectRoute.LoadPoint` registers a point with `Studio.AddCtrlInfo` (AddObjectRoute.cs:151). That adds it to `dicInfo` only (Studio.cs:780); objects reach `dicObjectCtrl` through `AddObjectCtrlInfo` (Studio.cs:745).
  - No plug-in names a point, and no positional list counts one.
  - Points still take keys from the same `hashIndex`, so a point edit matters only through the keys it takes.
- **Sideloader 21.1.2.1** (`dc3b1c3d…`, `com.bepis.sideloader.universalautoresolver`).
  - **Save.** `SavePrefix` (Sideloader.AutoResolver/UniversalAutoResolver.cs:560–775) rebuilds the entry from the live objects, or writes nil when there is nothing. The entry holds:
    - `itemInfo` and `patternInfo`, lists of MessagePack-encoded records with `SceneDicKey` and `SceneObjectOrder`;
    - the scene-level map, filter, ramp and BGM GUIDs.
  - **Order.** `SceneObjectOrder` is the record's depth-first pre-order index among records of its own kind (items, lights or characters), from the root dictionary through the child lists (StudioObjectSearch.cs:46–110). A copy gets its template's records.
  - **Load.** It indexes the dictionary by `SceneDicKey` unchecked (:1334, :1342). A record for a deleted item throws inside `SceneBeingLoaded`, and every later record stays unresolved.
- **Positional lists.**
  - **KKPE 2.21.4** (`72d1b7b5…`, `kkpe`). `OnSceneSave` (HSPE/MainWindow.cs:1585–1608) writes one `itemInfo` element per item, in key order. `LoadSceneGeneric` (:1554) loads the i-th element onto the i-th item and ignores the saved `index`.
  - **NodesConstraints 1.6.2.1** (`817fd940…`, `nodesConstraints`). The save (NodesConstraints/NodesConstraints.cs:2393–2428) writes `parentObjectIndex` and `childObjectIndex` as indices into the key-sorted `dicObjectCtrl`, and the load reads them the same way (:2108–2146).
  - **Timeline** (`0d19f9cf…`, `timeline`). `SceneWrite` (Timeline/Timeline.cs:4361) gives each object interpolable an `objectIndex` into the same key-sorted list (:4622). Global interpolables carry none.
- **NodesConstraints' card fallback.** No installed DLL declares KK_AnimationController (`com.deathweasel.bepinex.animationcontroller`). So `NodesConstraints.OnSceneLoad` (:2061–2068, flag at :1025) runs `LoadDataFromKKAnimationController` (:2259) on every load, whether or not the scene has a `nodesConstraints` entry or any plug-in data.
  - **When.** A `KK_AnimationController` entry with an `AnimationInfo` list, even an empty one, is used instead and the cards are not read (:2263–2289). Without one, each character's card data is read (:2291–2306).
  - **Steps.** For each `Links` pair, `(string)key`, `(int)value` and `loadedObjects[...]` are evaluated before `AddLink` (:2316). `Eyes` follows through `AddEyeLink` (:2335).
  - **Aborts.** A failed cast or a missing key throws. The per-character `catch` (:2309) ends that character's remaining links and `Eyes`. Other characters still load.
  - **Objects.** `loadedObjects` is `dicObjectCtrl` (KKAPI StudioSaveLoadApi.cs:427). It holds every object of the walk, attached items included (Studio.cs:705–711, :745–749). Route points are only in `dicInfo` (AddObjectRoute.cs:151, Studio.cs:780–785).
  - **Int32 only.** The card's data is decoded by the game's MessagePack 1.x through `PrimitiveObjectFormatter` (Assembly-CSharp-firstpass, MessagePack.Formatters/PrimitiveObjectFormatter.cs:161–187). It boxes an `int` only for an Int32 (`0xd2`) value. Fixints and `0xcc`/`0xcd` box a `byte`/`ushort`, and `0xd0`/`0xd1` box an `sbyte`/`short`, so `(int)` throws on them. MessagePack-CSharp's own `int` writer never emits `0xd2` for a non-negative key (MessagePack/MessagePackBinary.cs:700–730). No installed DLL or game assembly replaces the default resolver. Links written that way are inert: the first one throws.
  - **Unreadable data.** ExtendedSave replaces card data it cannot decode with an empty dictionary (ExtensibleSaveFormat/ExtendedSave.cs:181–188).
  - **Copies.** `Studio.Duplicate` saves and imports the character (Studio.cs:440–485), so its card data travels verbatim. NodesConstraints' `Studio.Duplicate` patch (:648–734) copies a constraint only when both ends' objects are copied.
- **Lists keyed by object.** Each plug-in rebuilds its list from the live objects on save. Some also write data for copies.

  | Plug-in (hash prefix, entry ID) | Data naming objects | On a copy |
  | --- | --- | --- |
  | MaterialEditor 4.0.2 (`dde57f4f…`, `com.deathweasel.bepinex.materialeditor`) | nine property lists and `TextureDictionary` by item (KK_Plugins.MaterialEditor/SceneController.cs:378–463); `OnObjectDeleted` (:1041) | clones per key (:725) |
  | ItemLayerEdit (`bcf52291…`, `keelhauled.itemlayeredit`) | `SavedLayers[].ObjectId` (ItemLayerEdit.Koikatu/SceneDataController.cs:32) | copies (:56) |
  | RealPOV (`60b11ab2…`, `keelhauled.realpov`) | `PovData.CharaId`, −1 for none (RealPOV.Koikatu/SceneDataController.cs:27) | nothing |
  | MoarCamz (`71e3bfd2…`, `orange.spork.moarcamzplugin`) | each camera slot's `CenterTarget` (MoarCamz/MoarCamzStudioController.cs:69) | nothing |
  | BetterScaling (`c5214827…`, `BetterScalingData`) | `scaledOCI` keys (BetterScaling/BetterScalingDataController.cs:109) | copies (:147) |
  | LightSettings (`dc53863c…`, `LightSettingsData`) | one record per live light by `ObjectId`; −10 is the character light, −20 the map light (LightSettings.Koikatu/SceneDataController.cs:142) | a record for every light |
  | StudioItemIK (`c70ff74d…`, `org.njaecha.plugins.StudioItemIK`) | `activeIKs` keys and `objectTargetPairs` keys and values (StudioItemIK/SceneController.cs:13); the load throws on a missing key (:36) | copies (:73) |
  | ObjImport (`a823bb8b…`, `org.njaecha.plugins.objimport`) | `ids` (ObjImport/SceneController.cs:14); `OnObjectDeleted` (:116) | copies (:124) |
  | StudioCustomMasking (`d207e864…`, `com.deathweasel.bepinex.studiocustommasking`) | `MaskingFolders` (KK_Plugins.StudioCustomMasking/SceneController.cs:16) | copies (:56) |
  | SaveCameraObjectFov (`6d51babb…`, `com.rikkibalboa.bepinex.savecameraobjectfov`) | `cameras` (key to field of view), and `cameraIndex` and `previousCameraIndex`, positions in the camera selector where 0 is the main camera (Plugins/SceneController.cs:13, load :40) | nothing |

- **Scene-global entries** name no object:
  - StudioSceneSettings (`5ae7cd40…`, KK_Plugins.StudioSceneSettings/SceneController.cs:37);
  - StudioImageEmbed (`69024b7c…`, KK_Plugins/ImageEmbed.cs:171);
  - TwoLut (`87c58898…`, KK_Plugins/TwoLutPlugin.cs:61);
  - StudioCharaLightLinkedToCamera (`26c4d1e6…`, KK_StudioCharaLightLinkedToCamera/Patches.cs:90–92). It writes and accepts only version 3 (:129, :136).
- **Orphan IDs.** `KKVMDPlayExtSave`, `rendererEditor`, `com.rskoi.particleeditor`, `vnge_kfa` and `vnge_sss` occur in installed scenes. None of the 243 installed DLLs contains any of them as ASCII/UTF-8 or UTF-16LE, and no script host is installed. The scan is `.local/stt03i-plugin-data/inventory/orphan-scan.json` (coverage index SHA-256 `e146e45a…`, corpus digest `d81258cc…`). Nothing in this install reads or writes these entries, so CharaStudio's save carries them verbatim through any edit. **Parity holds for this pinned install only.** Once a plug-in that owns one is installed, its data may name objects the export changed.

### Plug-in data rewrites

Reviewed 2026-10-26 (ST-T03i, second change). `SourceScenePluginRewrites` (`Packages/Engine/Sources/Studio/SourceScenePluginRewrites.swift`) rewrites the KKPE, MaterialEditor and NodesConstraints entries after a delete or a copy, as CharaStudio's save writes them after the same interactive edit.

- **How the plans work.** Each plan reads its entry strictly. A form or an edit its rule does not cover refuses the export, naming the plug-in. Bytes the rewrite does not change are kept.
- **XML form.** KKPE and NodesConstraints each store one XML string, written by .NET's `XmlTextWriter` with default settings: elements and double-quoted attributes only, and ` />` for an empty element.
  - The writer reads exactly that form. Text, comments, declarations and repeated attributes refuse.
  - An integer attribute must read as `XmlConvert.ToString(int)` writes it.
  - A rewritten element keeps its own bytes. Only the attribute values that change are patched, and a removed child is left out.

- **KKPE 2.21.4** (`72d1b7b5…`, `kkpe`).
  - **What it saves.** `OnSceneSave` (HSPE/MainWindow.cs:1585–1608) writes `sceneInfo`: a `<root version=…>` with one `itemInfo` per item in key order. Each carries `index` (the key) and its controller's state, with `uniqueId` set to the controller's instance ID (PoseController.cs:409).
  - **Load.** `LoadSceneGeneric` (:1554–1583) loads the i-th `itemInfo` onto the i-th item and ignores `index`.
  - **Characters.** A character's pose data is not scene data. It is the `characterInfo` of its card's `kkpe` entry (`OnCharaSave`, :1484–1504).
  - **References.** A lone collider is an item named "Collider" (HSPE.AMModules/CollidersEditor.cs:561–575). It names the dynamic bones it acts on by their controller's ID, `poseControllerId` (:1037, :1048). The load matches those IDs by equality (:1128–1185).
  - **After a delete**, CharaStudio writes no element for a deleted item, and no reference to a deleted controller. A lone collider drops those references in `Update` (:615–657).
  - **After a copy**, the copy gets its template's element under its own key and a new instance ID (`OnDuplicate`, MainWindow.cs:1274, through `LoadFrom`). References are not remapped: `ColliderDataBase`'s copy keeps the template's (CollidersEditor.cs:274–291). A copied character's card gets its template's `characterInfo` under the copy's new controller ID.
  - **Writer.**
    - The kept items' elements stay in key order. Each copy gets its template's element with the copy's `index` and a fresh `uniqueId`. References to deleted controllers are dropped.
    - **Copied characters.** A copied character's card gets a fresh ID, patched in place. The ID has the template's number of digits and sign, so the card keeps its length. It is not 0, and no `uniqueId` or `poseControllerId` in the scene or its cards uses it.
    - The writer reads each patched card back.
    - A card is patched only when the scene has a `kkpe` entry and the card has KKPE data. Any other card stays byte-identical.
  - **Instance IDs** are new in every session, so this writer's IDs are deterministic. Comparisons with CharaStudio rename IDs in order of first appearance, as for phase B.
  - **Refused:**
    - an added item: CharaStudio writes a default element for it, which this writer does not;
    - a copy of an object a lone collider names. Every controller with dynamic bones registers them with each lone collider (DynamicBonesEditor.cs:1799, BoobsEditor.cs:401), so CharaStudio adds entries for the copy;
    - a delete together with an item copy: the copies' keys can differ from CharaStudio's ([#278](https://github.com/grabbiel/ikkoku/issues/278));
    - a dropped reference whose controller ID more than one object has;
    - a copied character whose KKPE data is in a legacy ExtendedSave trailer rather than the card's current block;
    - an `itemInfo` count that is not the item count, an `index` that is not the item at that position, or an element without a `uniqueId`.
- **MaterialEditor 4.0.2** (`dde57f4f…`, `com.deathweasel.bepinex.materialeditor`), data version 1.
  - **What it saves.** Nine record lists and `TextureDictionary`, each nil or MessagePack bytes (KK_Plugins.MaterialEditor/SceneController.cs:20–330). A record's `ID` is an item's key.
  - **Load.** It binds records to items only (`ExtractGameObject`, :501–508), so a record that names no item loads nowhere.
  - **After a delete**, the item's records are gone (`OnObjectDeleted`, :1041–1062).
  - **After a copy**, each list gains its template's records with the copy's key, after the existing ones, copy by copy (`OnObjectsCopied`, :725–855).
  - **Save** (:378–466) purges textures that no `TexID` or animation frame uses (`PurgeUnusedTextures`, :469–500), and writes nil for an empty list or dictionary.
  - **Writer.**
    - Each list gets the records of kept items in order, then each copy's clones of its template's records. The `ID` is written in MessagePack-CSharp's shortest form, and every other byte of a record is kept.
    - Records that name no item are dropped once a list is rewritten. They are also dropped when a copy's new key could be theirs.
    - Unused textures are purged.
  - **Textures.** Only the Bundled form is read: an int-to-bytes map (`SaveBundled`, KK_Plugins.MaterialEditor/TextureSaveHandler.cs:80–88). KKAPI picks the form from `Local Textures/Scene Save Type`, Bundled by default (KKAPI `7f4f50e1…`, KKAPI.Studio/SceneLocalTextures.cs:52–60, :89). The installed `marco.kkapi.cfg` sets Bundled (read in phase C). A Deduped or Local key refuses.
  - **Refused:**
    - version 0 data that needs a rewrite (CharaStudio writes version 1);
    - a delete together with a copy of an item that has records (#278);
    - a purge when Timeline data has texture tracks;
    - a record key the writer does not know.
- **NodesConstraints 1.6.2.1** (`817fd940…`, `nodesConstraints`).
  - **What it saves.** `OnSceneSave` (NodesConstraints/NodesConstraints.cs:2393–2490) writes one empty `constraint` per entry of `_constraints`. Each has:
    - `parentObjectIndex` (−2 for the main camera) and `childObjectIndex`, the ends' indices in the key-sorted `dicObjectCtrl`;
    - `uniqueLoadId`, its position.
  - **Load.** `LoadSceneGeneric` (:2141–2258) reads them back by index.
  - **After a delete**, a constraint with a deleted end is removed (`ApplyConstraints` → `RemoveConstraintAt`, :1166–1205, :1951–1984). The others are written with their objects' new indices and their new positions.
  - **After a copy**, `Studio_Duplicate_Patches` (:649–734) gives a constraint whose two ends are both copied a copy of its own. It walks `_constraints` in order and throws at the first camera-parented constraint. `AddConstraint` (:1874) skips a pair already present in either direction.
  - **Writer.** The kept constraints, in order, with their ends' new indices and their new positions.
  - **Refused:**
    - a copy of both ends of a constraint before the first camera-parented one: this writer does not write constraint copies;
    - a delete together with a copy while any constraint is kept (#278);
    - removed or renumbered constraints when Timeline data mentions NodesConstraints, whose tracks address constraints by number;
    - two constraints between the same transforms;
    - an index the scene does not have.
- **Verification.** The rewritten entries are parsed again. KKPE's items must be in key order, with the planned `index` and `uniqueId` and the planned references left out. MaterialEditor's lists must decode to the planned records and its textures to the kept ones. NodesConstraints' constraints must carry the planned indices and positions.

### Writer behavior

- **When.** The rules run on the final written document: its records, their keys, kinds and parents, and each copy's template. A rule that depends on positions therefore sees exactly what CharaStudio would load. An export that only moves records or edits leaves keeps every entry, as before.
- **Per entry.** Each row keeps or rewrites the entry, or refuses the export naming the plug-in:

  | Entry | Rule |
  | --- | --- |
  | Nil | Inert. It is dropped when the trailer is rewritten, as ExtendedSave's save drops it, and kept otherwise. |
  | An orphan ID | Kept verbatim. |
  | Scene-global | Kept, for the recovered versions. |
  | Sideloader | Rewritten in CharaStudio's order: kept records with their order recomputed, each copy's records cloned from its template's with the copy's key and order, deleted records dropped. Scene-level keys are kept. An empty result removes the entry. A record for an object the scene does not have, for one of the wrong kind, or a second record for the same object refuses. |
  | KKPE | Kept when no item is deleted, copied or added and no character is deleted or copied. Otherwise [rewritten](#plug-in-data-rewrites), and a copied character's card gets a fresh controller ID. |
  | MaterialEditor | Kept when every list is nil, or no item with records is deleted or copied. Otherwise [rewritten](#plug-in-data-rewrites). |
  | NodesConstraints | The empty `<constraints …/>` form is kept. A non-empty one is kept when every existing object keeps its index in the key-sorted object list and nothing is copied. Otherwise it is [rewritten](#plug-in-data-rewrites). |
  | Timeline | Kept when no interpolable has an `objectIndex`, or when positions hold as for NodesConstraints. |
  | KK_AnimationController | `[0, {}]` and an empty `AnimationInfo` list are kept. Links are refused when the edit deletes or copies objects. |
  | Lists keyed by object | Kept unless the edit deletes an object the data names, or copies one when the plug-in writes data for copies. LightSettings also refuses any added or copied light, because it writes a record per live light. SaveCameraObjectFov refuses a camera add, copy or delete when a camera index is not 0. An unknown field or an undecodable value refuses. |
  | Anything else, or an unknown version or shape | Refused when objects or route points come or go, additions included. Unknown data is not assumed inert. |

  **Card fallback.** This check reads the cards, not the trailer. So it also runs in a scene with no `nodesConstraints` entry, an empty map or no plug-in data at all.
  - **When it applies.** The edit deletes or copies objects, and the scene's KK_AnimationController entry, if any, has no `AnimationInfo`.
  - **Steps.** For each written character whose card names KKAnimationController data, the writer reads the card's wire bytes (`cardLinkSteps`). The steps are the targets of its Int32 `Links` values in wire order, then an Int32 `Eyes`, up to the first certain abort: a non-map `Links`, a non-string key or a non-Int32 value.
  - **Live steps.** A step is live while it and every earlier step name an object of the source scene (`dicObjectCtrl`). At the first missing object the fallback throws.
  - **Refused when** the edit:
    - deletes a live target. On reload the fallback throws there and drops the character's later links, which CharaStudio's export would restore from its `nodesConstraints` data;
    - copies a linked character together with a live target. NodesConstraints' duplicate patch gives the copy a constraint to the copied target, while the copy's card still names the original;
    - both deletes and copies, when any card has steps. The copies' keys can differ from CharaStudio's (#278), and links name keys;
    - writes a character whose card names the data but does not decode here. A decoder difference must not hide live links.

    The reason names NodesConstraints and the character and object.
  - **Carried verbatim** in every other case, with the trailer as before:
    - a copied linked character alone: its card names the same targets, which the reload attaches as CharaStudio's does;
    - a copied target alone: no constraint is copied, because both ends must be;
    - a delete of an object that no live step names;
    - any edit of a scene whose cards are inert.

    A scene whose links the edit does not touch exports byte-identical to the same edit without plug-in data.
- **Bytes.** Kept entries keep their bytes. The map header is written as MessagePack-CSharp 1.x writes it (shortest forms), and so are the rewritten Sideloader records. A trailer with nothing to change is returned as it was.
- **Verification.** The written trailer is parsed again. It must have the source's framing and the planned entries in order with the planned bytes. The Sideloader records must decode to their planned keys and positions.
- **Keys.** Insertions take the smallest free keys, then added route points take theirs. Keys freed in the same export are not reused, unlike CharaStudio after an interactive delete ([#278](https://github.com/grabbiel/ikkoku/issues/278)).

**Before ST-T03i**, delete, duplicate and route point add and delete were refused in any scene whose KKEx map held an entry, nil entries included. Additions were accepted in every scene, with the trailer kept verbatim. That was a latent bug: a new folder below the highest key shifts NodesConstraints' and Timeline's indices. Additions now follow the rules above. In scenes without plug-in data, deletes and copies were accepted. Now the card fallback check refuses only a delete of a live link's target, a copy of a linked character together with its target, or a delete with a copy when a card has steps.

### App translation

The refusal is the engine's message, which names each plug-in and its reason. The app shows it in the export status. An export that carries an orphan entry says so in its status line, with the IDs.

### Evidence

- **Engine.** Three test files cover the rules:
  - `SourceScenePluginDataTests` (10 tests) builds trailers with an independent canonical MessagePack encoder (`PluginMP`) on the `TopologyScene` builder. The tests cover:
    - Sideloader records in CharaStudio's order, and records it cannot place;
    - kept bytes with canonical framing;
    - nil entries dropped only by a rewrite;
    - unreadable trailers and unknown entries refused by name;
    - positional data kept only while positions hold;
    - route points and new objects judged on the written keys: a folder filling a key hole refuses NodesConstraints, and a folder above the keys does not;
    - the object-keyed rules;
    - the KK_AnimationController links and the card fallback. This covers Int32 versus compact link values, steps past a missing object or an aborted cast, `Eyes`, undecodable card data, and an `AnimationInfo` list switching the cards off. It also covers a trailer-less scene where deleting an object no link names gives exactly the `TopologyScene` bytes of the same deletion;
    - the writer's MessagePack-CSharp encodings.
  - Disabling three of the rules fails 15 expectations (negative control). Disabling the card fallback fails 15. Letting steps continue past a missing object fails 2.
  - `SourceSceneTopologyTests`, `SourceSceneInsertionTests`, `SourceSceneRouteEditTests` and `SourceSceneExportValidationTests` carry the new refusal texts and the accepted cases.
- **Survey port and parity gate.** The scene survey judges installed scenes with `Tools/reverse/fixtures/PluginSceneRules.cs`, a C# 5 port of these rules. `Tools/reverse/plugin_rule_parity.py` gates it:
  - It runs `sourceScenePluginDataWritesTheRuleParityCorpus`: 107 synthetic scenes, with every entry form alone, with a key hole, with linked cards, all together, and as unreadable trailers. Six trailer-less scenes carry cards with live, cut-off, inert, `Eyes`-only and undecodable links, and one carries a character linked to its own attached item.
  - It requires the port to reach the same verdict and name the same entry IDs for all 2,462 single-target edits: 0 mismatches.
  - Two rule mutations in the port give 56 mismatches. Letting the port's card steps continue past a missing object gives 1.
  - The player's run repeats the check with the player's own compiler before the survey counts anything.
- **Original player, phase A.** One `prlctl exec` (`Tools/reverse/original_plugin_scene_probe.py`) set up a private player root (Unity 5.6.2f1). It copied in ExtendedSave, Sideloader (with SharpZipLib and XUnity.ResourceRedirector), KKAPI and StudioSceneSettings, each checked against the inventory's SHA-256, and one installed studio-item zipmod (`[E625] Nan Chakram v1.zipmod`, SHA-256 `3d79a6fe…`).
  - **Fixture.** The probe authored a fixture: a folder, mod and vanilla items in and out of it, a route with three points, a camera, a light and StudioSceneSettings values.
  - **Edits.** CharaStudio made each supported edit from a fresh load and saved it with `SceneInfo.Save`: delete, delete-folder, duplicate, delete-duplicate, move, route-add and route-delete.
  - **Comparison.** `sourceScenePluginDataMatchesCharaStudioEdits` makes the same edits with our writer.
    - With CharaStudio's thumbnail, six of the seven exports are byte-identical to CharaStudio's whole file.
    - delete-duplicate is decoded-equal. CharaStudio's copy takes the key the delete freed, in that record's dictionary slot (#278). Ours takes a new key at the end, so the Sideloader records match field for field apart from key and position, and the trailers have the same length.
  - **Pass-through.** A control entry under an ID no plug-in owns keeps its bytes through CharaStudio's delete. Our writer refuses that delete by name.
  - **Coverage.** Phase A loaded only those four plug-ins, so its byte identity covers the Sideloader and StudioSceneSettings entries only.
  - **VM hygiene.** The errno-24 count was 0 before and after. The root was removed, and no game process was left.
- **Original player, phase B and survey 2** (2026-10-26, one `prlctl exec`, `.local/stt03i-plugin-data/phase-b/run-1`).
  - **Setup.** The player root got every installed plug-in, copied and checked against its SHA-256, and phase A's zipmod. Only `abdata` and `CharaStudio_Data` are junctions. Their file counts and newest modification times were scanned before setup and after cleanup and were unchanged (abdata 4,565 files, CharaStudio_Data 102). `-logFile` pointed into the root. KKPE's "Disable advanced mode on copied objects" reads `false` in the install's config, read-only.
  - **Fixture and edits.** CharaStudio saved phase A's fixture again, now with KKPE, NodesConstraints (empty) and MaterialEditor entries. It then saved each phase-A edit plus delete-light and add-folder, and the load-then-save of every file: the fixture, each edit, our seven phase-A exports, and the fixture with nil entries.
  - **KKPE instance IDs.** KKPE writes each pose controller's Unity instance ID as `uniqueId` (HSPE/PoseController.cs:409), and CollidersEditor writes references to them as `poseControllerId` (HSPE.AMModules/CollidersEditor.cs:1037, :1048). The values change every session. The load uses them only to match references within the same file (`_oldInstanceId` with `_loadId`, :1140–1176). So no two CharaStudio saves of a KKPE scene are byte-identical, its own load-then-save included.
    - `sourceScenePluginDataMatchesCharaStudioWithEveryPlugin` compares files with those IDs renamed in order of first appearance. Everything else must be identical, every other entry's bytes included.
    - Two negative controls still differ: another edit, and one KKPE attribute changed at the same length.
  - **Results.**
    - CharaStudio's load-then-save is a fixed point on those terms.
    - Our move, route-add, route-delete, delete-light and add-folder exports are CharaStudio's files on those terms: the empty NodesConstraints form, MaterialEditor and KKPE kept, and Sideloader rewritten.
    - Delete, delete-folder, duplicate and delete-duplicate are refused by KKPE. Its rewrite is a later change.
    - Our phase-A exports, loaded and saved by this player, are CharaStudio's own edits apart from KKPE's instance IDs. The exception is delete-duplicate, whose copy keeps our key (#278).
    - The fixture with nil entries saves as the fixture does.
  - **Parity on the player.** The C# port, compiled by the player's own compiler, agreed on all 2,462 corpus edits before the survey ran.
  - **Survey 2** (read-only, counts only, 168 s, not truncated). It read 361 files: 61 scenes with entries, 121 without (80 with no trailer, 41 with an empty map), and 179 without an end marker. Every scene loaded.

    | Edit kind | Before ST-T03i (all/some/none of 61) | Now | Change |
    | --- | --- | --- | --- |
    | Delete | 0/0/61 | 9/35/17 | 9 scenes fully and 35 partly unlocked |
    | Duplicate | 0/0/61 | 9/35/17 | 9 fully and 35 partly unlocked |
    | Add a folder | 61/0/0 | 50/0/11 | 11 refused: the latent-bug fix |
    | Add a light | 61/0/0 | 47/0/14 | 14 refused: the latent-bug fix and LightSettings |
    | Add a camera | 61/0/0 | 50/0/11 | 11 refused: the latent-bug fix |
    | Route point add or delete | none of the 61 has a route | — | — |

    - **Blockers.** A second read-only run (`run-2`) counted refusal reasons per scene, with numbers masked. Its counts equal the first run's.
      - KKPE refuses deletes and copies in 51 scenes, MaterialEditor's item-keyed data in 23, LightSettings an added or copied light in 3, non-empty NodesConstraints and Timeline data in 3 each, and ItemLayerEdit in 2. No scene is refused only by unknown IDs.
      - Sideloader refuses every edit kind in 8 scenes, all for one reason: a record names an object the scene does not have. This is not a gap in recognizing the data.
        - This Sideloader's save never writes such a record. It rebuilds the lists from the same objects our walk visits, by each object's own `dicKey` (StudioObjectSearch.cs, UniversalAutoResolver.cs:560–775).
        - Its load throws at the first such record (`dictionary[item2.DicKey]`, :1342). ExtendedSave catches that per subscriber (ExtensibleSaveFormat/ExtendedSave.cs:1381–1395). Every later record then stays unresolved, and so do the map, filter, ramp and BGM (:474–481).
        - So these scenes already load partly unresolved in CharaStudio with this install. Its next save drops the unresolved items' records, and those items lose their mod identity. There is no faithful output to match, and the export is refused.
    - **Card links.** No character card in the 182 loaded scenes names KKAnimationController `Links` or `Eyes`, so the card check refuses nothing. The detection reads each card's ExtendedSave data as `OICharInfo.Load` loads it (OICharInfo.cs:250–251). It had no positive control on the player.

- **Performance** (Release, quiet window, 2026-10-26; `SourceScenePluginDataPerformanceTests`, 60 calls each, median).
  - **Showoff scene.** `koikatu_cs0002591` has no plug-in data. A one-transform export takes 5.63 ms and a subtree deletion 5.54 ms. The plug-in step takes 0.049 and 0.046 ms of that: one search of the written bytes for KKAnimationController data, then a return.
  - **Fix found by the probe.** Before that early exit, the step built its edit model for every export: 0.85 ms in Debug, now 0.05 ms.
  - **Phase-A fixture.** A delete with the Sideloader rewrite exports in 0.64 ms and a move in 0.69 ms. The plug-in step takes 0.013 and 0.016 ms.
  - **Phase-B fixture** (every plug-in's entries). A light delete exports in 0.66 ms and a move in 0.71 ms. The plug-in step takes 0.026 and 0.027 ms. An item delete is refused by KKPE after 0.62 ms.
  - **Import.** The import path is unchanged: nothing on it runs these rules.

**Limits:**

- Keys freed by a delete in the same export are not reused, so a delete with a duplicate gives the copy a different key than CharaStudio after the same interactive edit (#278). The scene loads the same way, and the Sideloader records follow the key.
- KKPE data, and non-empty NodesConstraints and MaterialEditor data, are kept only when what they read is unchanged. Otherwise they are refused, not rewritten.
- Entry IDs with no recovered rule refuse every export that adds, deletes or copies objects or edits route points, and so do unknown versions.
- Entries kept under a rule keep their loaded bytes. CharaStudio's save rebuilds them from its live state, which decodes to the same data when nothing they name changed. Byte identity with CharaStudio is shown only for the entries the original-player runs loaded.
- A move keeps every entry as before. StudioItemIK stores world-space bone poses, so a moved IK chain loads from its old pose ([mods overview](../mods/overview.md#scene-plug-in-data-in-edited-original-scenes)).
- The orphan rule holds for the pinned install only.
- KKPE writes per-session instance IDs, so an export of a scene with KKPE data matches CharaStudio's only up to those IDs, as CharaStudio's own saves match each other.
- A Sideloader record that names an object the scene does not have refuses every export that adds, deletes or copies objects or edits route points. Such records are stale: this install's Sideloader neither writes them nor loads past them. Eight installed scenes have one.
- Survey 2 found no card with KKAnimationController links, and its card detection had no positive control on the player. The rule is proven on synthetic cards and by the parity gate.

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

(The fallbacks and stand-in listed below describe this slice; the
[third slice](#half-state-meshes-and-indoor-shoes-st-c03-third-slice) renders
converted half states and indoor shoes natively.)

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

The [third slice](#half-state-meshes-and-indoor-shoes-st-c03-third-slice)
closes the half-state meshes and the indoor shoes.

## Half-state meshes and indoor shoes (ST-C03 third slice)

Reviewed 2026-10-24. Before this slice, a visible half state of a top,
bottom, bra, shorts or pantyhose drew the dressed meshes and the dressed body
mask with a fallback diagnostic, and with `shoesType` 0 the outdoor shoes
stood in for the indoor ones.

**Recovered rules.** Sources: the private decompiled `ChaControl`
(`ChaControl.Koikatu.cs`), `ChaReference`, `Studio.OCIChar` and the managed
recovery of `Studio.MPCharCtrl` under `.local/reverse`; none of it is
committed.

- **Switch nodes.** `ChaReference.CreateReferenceInfo` looks up, inside each
  loaded garment, the GameObjects `ChaControl.UpdateVisible` switches:
  top `S_CTOP_T_DEF`/`_NUGE` = `n_top_a`/`n_top_b` and `S_CTOP_B_DEF`/`_NUGE` =
  `n_bot_a`/`n_bot_b`; bottom `S_CBOT_B_DEF`/`_NUGE` = `n_bot_a`/`n_bot_b` and
  `S_CBOT_T_DEF`/`_NUGE` = `n_top_a`/`n_top_b`; bra `S_UWT_T_DEF`/`_NUGE` =
  `n_top_a`/`n_top_b` and `S_UWT_B_DEF`/`_NUGE` = `n_bot_a`/`n_bot_b`; shorts
  `S_UWB_B_DEF`/`_NUGE`/`_NUGE2` = `n_bot_a`/`n_bot_b`/`n_bot_c`; pantyhose
  `S_PANST_DEF`/`_NUGE` = `n_panst_a`/`n_panst_b`. The shorts' `S_UWB_T_*`
  nodes are mapped but never switched.
- **Mesh selection.** `UpdateVisible` calls `YS_Assist.SetActiveControl` on
  each node with these conditions. A renderer draws only while its garment
  object (`objClothes[kind]`) and every switch node above it are active.

  | Garment | Node | Active while |
  | --- | --- | --- |
  | top (0) | `n_top_a` | top on |
  | top (0) | `n_top_b` | top half |
  | top (0) | `n_bot_a` | bottom on and top not off |
  | top (0) | `n_bot_b` | bottom not on and top not off |
  | bottom (1) | `n_bot_a` | bottom on |
  | bottom (1) | `n_bot_b` | bottom half |
  | bottom (1) | `n_top_a` | top on and bottom not half 2 |
  | bottom (1) | `n_top_b` | top not on and bottom not half 2 |
  | bra (2) | `n_top_a` / `n_top_b` | bra on / bra half |
  | bra (2) | `n_bot_a` / `n_bot_b` | shorts on / shorts not on, and bra not off |
  | shorts (3) | `n_bot_a` / `n_bot_b` / `n_bot_c` | shorts on / half / half 2 |
  | pantyhose (5) | `n_panst_a` / `n_panst_b` | pantyhose on / half |

  So half state 1 swaps the `_a` meshes for the `_b` meshes. Half 2 is
  allowed only for `StateType` 2; no top, bottom or bra row of the installed
  vanilla catalog has it, while most shorts do. Half 2 leaves neither `_a` nor
  `_b` active for a top, bottom or bra, and selects `n_bot_c` for the shorts.
  The pantyhose object itself hides at half 2 and off.
- **Body mask.** `ChaControl.ChangeAlphaMask(a, b)` writes `_alpha_a` and
  `_alpha_b` to the body material (`customMatBody`) and to the bra
  (`rendBra`) and top-part inner (`rendInner`) materials. `UpdateVisible`
  calls it with row `top state` of `{ {1,1}, {0,1}, {0,1}, {0,0} }` whenever a
  top switch node changed activity, or when `updateAlphaMask` is set after
  `ChangeClothesTop`. Half and half 2 therefore keep only the `_alpha_b`
  channel of the top's `OverBodyMask`.
- **Shoes.** `ChangeClothes(kind 7)` calls `ChangeClothesShoesAsync(0, id)`,
  which loads `ct_shoes_inner` into `objClothes[7]`; kind 8 calls
  `ChangeClothesShoesAsync(1, id)`, which loads `ct_shoes_outer` into
  `objClothes[8]`. Both read catalog category 112 (504 for a male with
  `exType` 1) by their own slot's saved ID, and each slot keeps its own
  `ChaFileClothes.parts[7/8]` colors. `UpdateVisible` activates
  `objClothes[7]` only while `shoesType` is 0 and kind 7 is on, and
  `objClothes[8]` only while `shoesType` is 1 and kind 8 is on. There is no
  `ChangeShoesType`. CharaStudio's `MPCharCtrl.StateInfo.OnClickShoesType`
  calls `OCIChar.SetShoesType(type)`, which only writes
  `fileStatus.shoesType`, then refreshes the clothing-detail rows.
  `ChaControl.IsShoesStateKind` reads kind 7 or 8 by `shoesType`.

**Conversion.** `Tools/reverse/maker_asset_library.py` tags each drawable
renderer under an alternate switch node (`n_top_b`, `n_bot_b`, `n_bot_c`,
`n_panst_b`) of a top, bottom, bra, shorts or pantyhose prefab as an
`alternates` row: `meshName`, the switch nodes above it, and `activeWhen`,
the conjunction of the table's conditions over those nodes (one clause per
clothes kind with its allowed states). A node without a recovered rule, or
nodes that are never active together, reject the build. The half-state
library loader also rejects empty visibility conjunctions, duplicate clothes-kind
clauses or states, empty mesh/switch names, and unsupported alternate categories.
An empty conjunction must not make a half-state mesh unconditionally visible in
the shader-binding derivation. These checks run when loading the library, not
during frame updates. The half-state
renderers' material evidence goes to a separate `alternates.json`, so each
dressed entry's `materials.json`, rig and recipes keep their bytes.
`maker_asset_materials.py` composes their `wearAppearance` /
`wearCardBindings` (the dressed parts and recipes unchanged, then the
alternate ones; an alternate renderer of the dressed material reuses the
dressed composed texture). The default selection adds bottom 106-1
(`n_bot_b`), pantyhose 110-1 (`n_panst_b`) and the indoor shoes 112-2
(uwabaki); tops 105-3, 105-38 and 105-39 gain their `n_top_b` T-shirt. No bra
or shorts is converted: the original masks a bra under the top with the
top's `OverBraMask`, which is not converted, and the Studio fixture's dressed
character wears bra 1 and shorts 1, so converting them would change its
dressed render. The retained library's 186 files stay byte-identical except
`material-inputs.json`, which gains the new entries' inputs; retained entries,
their order and the head assemblies are unchanged.

**Native port.**

- **Assembly.** `SourceMakerLibrary.prepare(card:coordinate:baseURL:wear:)`
  with `wear` true (Studio) assembles each converted garment's half-state
  meshes with its wear appearance, and the indoor shoes as clothing kind 7:
  the same category 112 entry loaded by `parts[7]`'s ID, whose recipes
  `SourceAppearanceBindings.contextualizedIndoorShoes` rebinds from slot 8 to
  slot 7 (`ClothesShoesInner`). The indoor shoes never replace the top's body
  cut-out. `Prepared.indoorShoes` says whether they were assembled, are the
  catalog's empty row, or are unconverted. The Maker assembly (`wear` false)
  is unchanged: dressed meshes and outdoor shoes only, byte-identical output.
- **Selection.** `SourceStudioWearLayout` maps each alternate renderer to its
  switch-node ancestors, and `evaluate` draws a renderer only while its
  garment is visible and every switch node above it is active, so a half
  state draws the `_b` mesh and hides the `_a` mesh, with the body mask from
  the `ChangeAlphaMask` row. Converted indoor shoes follow kind 7 and the
  outdoor shoes kind 8 by `shoesType`. Hidden renderers are not drawn, and
  the frame bounds still cover every assembled part as before.
- **Shoes type.** `StudioModel.setSourceShoesType` serves the Clothes tab's
  Indoor/Outdoor picker (CharaStudio's State panel shoes buttons) and the
  scenario op `setShoesType`. It records one undo snapshot and persists
  `StudioObject.sourceShoesType` (nil, or a value equal to the saved one,
  means the card's saved `shoesType`). Export writes `Status.shoesType`
  through `SourceCharacterCard.Edits.shoesType`, replacing the token or
  appending the field when the card does not save it and the value is not
  the `MemberInit` default 0. Since #149 the Studio live step applies wear
  on worker threads, so `shoesType` travels in
  `SourceStudioLiveTick.FrameRequest` with the clothes state and accessory
  flags, and `setWear(clothesState:showAccessory:shoesType:)` keeps the
  state inside the preview.
- **Tools.** `ikkoku-inspect card-model … --studio-wear` selects the saved
  wear's renderers through `SourceStudioWearLayout.saved` (the
  [neutral-model gate](../character/neutral-model-parity.md) then compares
  the half-state meshes). The live fixture probe's
  `IKKOKU_LIVE_SOURCE_MAKER_WEAR=1` builds the Studio wear assembly with the
  card's saved hidden parts and body mask. The source-shader binding
  derivation reads `alternates.json` and marks an alternate renderer
  visible by its `activeWhen` clauses; an unsaved `shoesType` reads as the
  `MemberInit` 0.

**Original-player reference (VM, read-only, 2026-10-24).**
`Tools/reverse/original_wear_probe.py` drives
`Tools/reverse/fixtures/OriginalCharacterProbe.cs`, whose settings TSV now
takes `clothes`, `clothesState` and `shoesType`: the player loads the
fixture card with top 105-38, bottom 106-1, pantyhose 110-1, indoor shoes
112-2 and outdoor shoes 112-3 in clothes state `1,1,0,0,0,1,0,0,0` with
`shoesType` 0, keeps the loaded state (no `SetClothesStateAll(0)`), and
records `objClothes` activity and the body `_alpha_a/_alpha_b`. One
`prlctl exec` bootstraps `run.ps1` from a host-only endpoint, which also
serves `plugins\shader-properties.tsv` (built from the translated programs'
`program.json` properties) so the capture records every material property;
the first capture lacked it, so `_Texture3` was unbound in the live
comparison, and was kept only as the geometry repeat. The probe root was
removed, no game process remained, and the Parallels errno-24 count stayed 5
before and after both phases. The captures remain under ignored `.local/`.

**Evidence, 2026-10-24.** Limits are the existing ones, unchanged.

- **Geometry.** `compare_original_model.py` on `card-model --studio-wear`
  passes against both captures: 20 selected parts, 33,882 vertices, maximum
  vertex error 7.15e-7 and matrix error 7.30e-7, silhouette IoU 1.0. The
  selection draws `o_top_tsyats_b`, `o_bot_pants01_b`, `o_panst_00_b` and
  `o_shoes_uwabaki01` and switches off their `_a` meshes and the outdoor
  shoes. The player's capture holds exactly those four garment meshes, with
  the outdoor-shoe object inactive and body `_alpha_a/_alpha_b` (0,1).
- **Colour.** The live probe with `IKKOKU_LIVE_SOURCE_MAKER_WEAR=1`
  (`compare_original_frame.py`) uses captured texture pixels matched by native
  material identity (`IKKOKU_LIVE_SOURCE_TEXTURE_PROVIDER=capture`), a validation
  input. It verifies independently evaluated native geometry, wear/body-mask
  selection and translated shaders; it does not establish native texture
  production or production colour parity. Geometry IoU 1.0; depth-normals pass;
  translated garments (the half top, half bottom and uwabaki) mean 0.059,
  p99 1, maximum 19 channel bytes, pass; `main_opaque` mean 0.073, p99 1,
  pass. `main_skin` as a whole fails, because the untranslated pantyhose
  (`main_alpha`, no translated program) covers the legs in the original.
  `Tools/reverse/compare_wear_frame.py` repeats the family comparison
  outside the pantyhose's BakeMesh silhouette (12,145 pixels, not depth
  tested): `main_skin` on 53,885 pixels has mean 0.038, p99 1, maximum 10,
  pass, which validates the half-top body mask (0,1). Hair, eyes and the
  production colour keep their known residuals (the eye families from the
  look-settings iris input, not from wear). The pantyhose colour is not
  established; only its geometry is verified.
- **Dressed identity.** With every garment on, the scenario scene (outdoor
  shoes) and the accessory and FK scenes (indoor shoes of the same prefab as
  their outdoor shoes) render RGBA8 captures byte-identical to the
  pre-change app with the retained library, with either library.
- **Lanes.** `half-state.json` (42 steps) on the probe's fixture card built
  into a Studio scene (`studio_selection_fixture.py --card`, env key
  `IKKOKU_STUDIO_HALF_STATE_SCENE`): the saved half states draw exactly the
  three `_b` meshes and the uwabaki with body mask (0,1) and no fallback.
  Top on changes 3,499 pixels by more than 2/255, bottom on 134 (the half
  bottom is mostly under the top), pantyhose on 5,844, and `shoesType` 1
  604. Undo and redo restore every capture exactly. Editing back to the half
  states and indoor shoes clears the edit and exports the source SHA. The
  changed export differs from the source body in four bytes (three
  `clothesState` bytes and `shoesType`) and reimports with them saved.
  `reload-save-half-state` / `reload-load-half-state` keep a top-on,
  outdoor-shoes edit across a native save and a fresh process (4,107 and
  3,499 changed pixels; undo restores the loaded frame). `accessory-toggle`
  now draws `o_top_tsyats_b` for top half (3,545 pixels from the
  bottom-off capture) and the converted indoor shoes 112-1.
- **Tests.** `sourceStudioWearHalfStateMeshesFollowUpdateVisible`,
  `sourceStudioWearAlternatesWithoutMeshesStillReportTheFallback`,
  `sourceStudioWearLibraryAlternatesMatchUpdateVisibleAndKeepTheDressedParts`
  (fixture), `sourceShaderBindingsFollowTheSavedHalfStateOverAlternateRenderers`
  (fixture), `sourceCardEditingShoesTypePatchesOrAppendsOnlyItsToken`; Python
  `test_maker_asset_library.py` (switch rules, alternate tagging, the compact
  rig writer), `test_original_wear_probe.py` and `test_compare_wear_frame.py`.

**Continuation checks (2026-10-24).** A fresh Release build of `72e7af6`
and the continued half-state branch reproduce the dressed control on three
scenes, each with the retained and expanded library: all twelve RGBA8 captures
are identical within their scene. Fresh independent native model evaluation
again passes the two retained original-player captures (20 parts, 33,882
vertices, maximum vertex error 7.1542e-7, skin-bone matrix error 7.2988e-7,
silhouette IoU 1.0). The Release live capture uses the same validation-only
texture provider described above: garment mean 0.0592 and p99 1 pass; the
complete colour gate still fails. Outside the same 12,145-pixel pantyhose
exclusion, skin mean 0.03845 and p99 1 pass on 53,886 pixels.

The full Engine run reported 773 tests with two named skips (absent appearance
oracle root and opt-in expression timing). Its only failure was an expansion
fixture's stale 13-selection assertion: Studio now selects both saved shoe
slots (14 selections). The corrected fixture passes separately and asserts
both shoe properties; the other tests are unchanged. CoreMath's 21 tests pass.
The new public malformed-alternate test passes, as do the 49 focused Python
checks with the private geometry fixture, the reverse-tool suite (434 passed,
six optional fixture skips), and verification tools (187 passed). The strict
Release app lanes on `7f2bbdb` pass **56/56 Studio checks** (465.36 s) and
**5/5 Maker checks** (33.75 s), with no skipped checks. This includes the
half-state edit's 42/42 steps, native save's 8/8 and fresh-process load's 7/7.
Reports and exact input/binary hashes are retained under
`.local/codex-continue-2026-10-24/half-state/`; `perf/` and `perf-control/`
hold the quiet measurements below.

**Resource cost (Release, 2026-10-24).** The selected complete library trees,
including their head registry and textures but excluding historical audit
scratch files, grow from 578,832,148 to 593,592,294 bytes: **14,760,146 bytes
added** across 46 files. Of the 725 retained files, 723 keep their bytes;
only `library.json` and `material-inputs.json` change. The independent Unity
geometry audit passes all 18 converted geometry entries (75,782 selected
vertices, five alternate meshes).

On the dressed-card control, Maker assembly stays at 774 nodes, 20 parts and
37,094 stored vertices with either library. Studio assembly has 780 nodes:
21 parts / 40,148 vertices with the retained library (indoor shoe added),
22 parts / 41,341 vertices with the expanded library (shirt alternate also
added). Both Studio cases select the same 19 visible parts / 37,052 vertices.
Hidden parts are skipped before draw-item and skin-palette construction.

Two interleaved 10-second quiet windows per library and workload, each in a
fresh process after three seconds of warmup, use Release binary
`cb235f15c6ca816c1db004cb9f183d56a82ce4e26864db4b884afad99aaaed0c`.
These are warm-filesystem measurements on the retained source Studio fixture;
the ranges below are the two observed samples, not confidence intervals.

| Current runtime, source Studio idle | Retained library | Expanded library |
| --- | ---: | ---: |
| Source scene import | 4.164–4.191 s | 4.468–4.503 s |
| Peak Metal allocation | 468.063 MiB | 477.641 MiB |
| End process footprint | 754.095–754.752 MiB | 764.627–766.783 MiB |
| Peak process footprint | 796.861–798.189 MiB | 801.111–838.220 MiB |
| Draw CPU p50 | 1.197–1.355 ms | 1.186–1.214 ms |
| Draw CPU p95 | 2.176–3.134 ms | 2.731–3.022 ms |

The extra converted content costs **9.578 MiB of Metal allocation and about
0.31 s of scene import** in this fixture. Across both libraries and the native
Studio control, actual presentation is 119.30–119.80 FPS; presentation p50/p95
is 8.3334/8.3335 ms. The native control keeps 457.844 MiB of Metal allocation.
Every measured draw creates zero palette buffers and has no palette overflow.
The earlier baseline's source draw p95 is lower than both current-library
ranges, so four further fresh launches interleave the clean `72e7af6` baseline
and the current runtime, both using the same retained library, fixture map,
10-second recording and three-second warmup. The baseline binary's SHA-256 is
`5e4d1d9cd4143dd71eaba4df14cfdd8b4f26fed2a871b087c3d27ee5f7502fd2`.

| Same retained library, Studio idle | Baseline runtime | Current runtime |
| --- | ---: | ---: |
| Draw CPU p50 | 1.117–1.191 ms | 1.125–1.147 ms |
| Draw CPU p95 | 1.434–1.692 ms | 1.489–1.595 ms |
| Process CPU | 0.433–0.450 cores | 0.419–0.459 cores |
| Live-step job wall p95 | 1.196–1.213 ms | 1.076–1.409 ms |
| Source scene import | 4.214–4.256 s | 4.182–4.213 s |

All four windows are unoccluded and present at 119.30–119.80 FPS, with
8.3335 ms presentation p95. The overlapping draw and process CPU ranges do
not isolate a repeatable runtime regression; the earlier source draw p95
difference does not persist in this interleaved control. Two samples per
variant do not prove equivalence or bound rare stalls. The expanded-content
memory and import costs above remain, and this check covers only the retained
Studio fixture, not larger scenes or every garment combination.

**Fallbacks that remain.** These still draw dressed with a diagnostic:

- A converted garment whose library entry has no half-state meshes (an
  older library, or a prefab without alternate renderers).
- Half states of an unconverted (reference) garment.
- Unconverted indoor shoes: with `shoesType` 0 the outdoor-shoe geometry
  stands in for them and follows their state, as before.

**Still open.** Bra and shorts (not converted, pending `OverBraMask`; the
converter would tag their half-state meshes); the pantyhose `main_alpha` program and
colour parity; half 2 has no installed top, bottom or bra row to test;
composite-top sub-parts; `visibleSimple`/`visibleBodyAlways`; CharaStudio
reload of a changed export; and mouse-driven use of the new picker.

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

**Hidden-character export follow-up (PR #135).** Final review reproduced a
missing-preview error after editing a character, hiding it and reloading the
native scene. Export now prepares a temporary preview only when an
expression-edited character has no live preview; it preserves resource-block,
reference and outfit validation and applies combined shape/color/wear/face
edits. The temporary preview never enters the live cache, so hidden characters
add no frame-loop work. The regression fails at export on the old Release app
and passes on the fix; Debug and Release builds succeed. The paired scenarios
now save key 65 hidden, export in a fresh process, reimport and verify visibility
and all eleven fields, then reload the native file again for the existing
Reset/Undo and exact-pixel checks: **7/7 save and 16/16 load steps pass**; the
83-step edit scenario also passes again. This does not generalize support to hidden
characters carrying only older shape/wear edits.

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
