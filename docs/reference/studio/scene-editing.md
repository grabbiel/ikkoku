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
- Embedded card body/face values, supported color fields and face thumbnail, using the existing bounded card editor. Head/sex/bone type, asset IDs, saved resolver identities and opaque card plug-ins remain unchanged.
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

## App boundary and remaining work

The app exports supported existing transforms, per-object visibility, folder/camera/route renames, camera active flags (only after the user switches the looked-through camera, then for every camera record), route play-state `active` flags, FK/IK and activation flags, animation, voice and cameras to a **new file** after checking the source SHA. It renders an explicit edited thumbnail. The app populates `edits.cards` only with source face/body shape values that differ from the embedded card's saved values (ST-T06 first slice); an array edited back to the saved rate writes nothing and the file stays byte-identical. Color, thumbnail and other card destinations remain unpopulated, and a native `object.card` override is rejected.

The export validator rejects added/deleted/duplicated objects, reparenting, type changes, and name edits for any record kind other than folder, camera or route (a renamed character keeps its name in its card), plus native assets/materials/cards/hand/appearance overrides, light/effect/timeline changes and live typed plugin state. A retained source file is not serialization for those edits.

Implement missing field/topology writers and source-key remapping under `ST-T03`, a real source-card edit workflow under `ST-T06`, and GUID-specific plugin serialization under `ST-T13`. Each writer must preserve unknown siblings, verify a no-op byte match, reverse supported changes exactly where possible, and validate an edited file in the original loader before widening its compatibility claim.
