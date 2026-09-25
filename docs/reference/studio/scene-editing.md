# Edited original Studio scenes

Reviewed 2026-09-25 against the working tree. The [Studio audit](../../component-audit/studio.md) is the feature-status and actionable-backlog index; this page records the narrower source contract and its evidence.

`KoikatsuSceneDocument.editedData(SourceSceneEdits)` produces a new original-format 1.0.4.2 scene by replacing bounded byte spans recorded by the source reader. An empty edit returns the exact original bytes. The writer performs no file I/O.

Supported edits are:

- Object transforms identified by original object source key, including nested accessory children.
- Character FK bones, IK targets and look-at target transforms; item FK transforms identified by their original ordinal bone name.
- Character `enableFK`, `enableIK`, seven `activeFK` flags and five `activeIK` flags. Flags are written literally; source loading gives IK precedence if both modes are enabled.
- Character animation catalog IDs, speed, pattern, force-loop, options and normalized time; ordered voice playlists and repeat mode, including variable-length replacement.
- Embedded card body/face values, supported color fields and face thumbnail, using the existing bounded card editor. Head/sex/bone type, asset IDs, saved resolver identities and opaque card plug-ins remain unchanged.
- Current camera and ten saved camera slots, preserving position, all three Euler angles, all three distance components and field of view. Only the 40-byte version-2 payload changes.
- A replacement scene PNG only when explicitly supplied. It must be one complete CRC-valid PNG; an embedded card cannot acquire a PNG prefix.

Transforms are expressed in the original Unity coordinate basis and Euler degrees. The native app must convert edited transforms back before export. Duplicate or unavailable destinations, invalid group counts, nonfinite values, invalid camera FOV and invalid PNGs reject the entire edit. Object IDs, root dictionary keys, ordering, unedited catalog choices/settings and trailing plug-in bytes are preserved. Changing hierarchy, object type, item identity or plug-in behavior is outside this writer.

The writer validates complete output framing after applying patches in source byte order. Variable-length embedded card, voice-list and thumbnail edits therefore shift following records without reconstructing their bytes. Tests cover modifications both before and after a resized card, nested objects, ordinal Unicode bone identities, unknown trailers and source `Data` slices with nonzero start indices. Reversing transform, flag and camera edits restores every original byte.

The retained local evidence includes three independent synthetic scenes and two recovered original scenes containing seven embedded characters. Native test exports combine object, camera, card and kinematic edits. `Tools/reverse/analysis/scene_editing_oracle.py` independently re-reads five exports, verifies four changed cards and checks all nonedited scene fields, original thumbnails, unedited card records and scene/card extension bytes. It never decodes original image pixels.

Generate the optional native evidence by setting `IKKOKU_STUDIO_EDIT_OUTPUT` to an ignored `.local/` directory when running `SourceSceneEditingTests`, alongside `IKKOKU_STUDIO_SCENE_FIXTURES` and `IKKOKU_STUDIO_ORIGINAL_SCENES`. Then run:

```sh
.local/reverse/unitypy-venv/bin/python Tools/reverse/analysis/scene_editing_oracle.py
```

The default report is `.local/reverse/studio-edited/verification.json`. Rendering an edited scene still depends on the separately converted geometry, materials, animation and native plug-in adapters; serialization coverage does not imply execution of the original plug-ins.

## App boundary and remaining work

The app exports supported existing transforms, FK/IK and activation flags, animation, voice and cameras to a **new file** after checking the source SHA. It renders an explicit edited thumbnail. The engine supports embedded card edits, but the app does not populate `edits.cards`; a native `object.card` override is rejected. Source Pose/Face/Clothes controls are also blocked by the source-inspector gate (`ST-B01`).

The export validator rejects added/deleted/duplicated objects, reparenting, visibility/name/type changes, native assets/materials/cards/hand/appearance overrides, light/effect/timeline changes and live typed plugin state. A retained source file is not serialization for those edits.

Implement missing field/topology writers and source-key remapping under `ST-T03`, a real source-card edit workflow under `ST-T06`, and GUID-specific plugin serialization under `ST-T13`. Each writer must preserve unknown siblings, verify a no-op byte match, reverse supported changes exactly where possible, and validate an edited file in the original loader before widening its compatibility claim.
