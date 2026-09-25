# CharaStudio binary contracts recovered locally

Reviewed 2026-09-25 against the working tree. The [Studio audit](../../component-audit/studio.md) is the feature-status and actionable-backlog index; this page records the narrower source contract and its evidence.

The local installation uses Mono. Its managed assembly contains readable Studio
type names and IL; an IL2CPP/Ghidra route is unnecessary for these contracts.
This is a bounded interoperability investigation, not recovery of the complete
game or proof of visual or behavioral parity.

## Evidence and provenance

Observed on 2026-09-24 UTC from `C:\Illusion\Koikatsu` in the user's Parallels VM:

| Evidence | Observed value |
| --- | --- |
| Player | `CharaStudio_Data` |
| Backend | `Managed` and `Mono` directories; no `il2cpp_data` |
| Unity version | `5.6.2f1`, recorded by installation inventory |
| Managed input | `CharaStudio_Data/Managed/Assembly-CSharp.dll` |
| Input size | 5,385,216 bytes |
| Input SHA-256 | `902b9a237337b17a64514bdb0d857b460ece4fb6a57c658375dd32c5fa504c45` |
| Decompiled writer's scene version | `1.0.4.2` (`Studio.SceneInfo.m_Version`) |
| Decompiler | ILSpy command 11.1.0.9782 on .NET 10.0.10 arm64 |

The scene format version is **not** the application release version. The latter
has not been established. `KoikatuVR_Data` was separately observed as Unity
5.6.3f1; do not assume every executable has an identical assembly or engine build.

Input binaries and recovered source remain ignored under `.local/reverse`.
`inventory.json` contains source assembly hashes. `decompiled/Studio/manifest.json`
records exact decompiler outputs, hashes, and command versions. None of those
proprietary files is a checked-in dependency.

Recovery uses [ILSpy's official command-line frontend](https://github.com/icsharpcode/ILSpy).
After fetching the assembly and its dependencies locally, reproduce with:

```sh
dotnet tool install ilspycmd --version 11.1.0.9782 --tool-path .local/reverse/tools
python3 Tools/reverse/analysis/decompile_studio.py
```

For a single contract, pass `--type Studio.OIItemInfo`. The wrapper writes only
under `.local`, disables update checks, and preserves the input hash and result
status. The equivalent underlying invocation is:

```sh
.local/reverse/tools/ilspycmd --disable-updatecheck \
  -r .local/reverse/managed/CharaStudio -t Studio.OIItemInfo \
  .local/reverse/managed/CharaStudio/Assembly-CSharp.dll
```

## Observed binary format

All integer and float fields below use .NET BinaryWriter little-endian encoding.
`bool` occupies one byte; `string` is a seven-bit encoded **UTF-8 byte count**
followed by those bytes. This is an explicitly serialized stream, not a dump of
CLR object layout. Reproducing native struct padding would not reproduce it.

`Studio.SceneInfo.Save(string)` writes a complete 320×180 PNG, then immediately
appends the scene version string and the object dictionary. There is no iTXt JSON
payload. `SceneInfo.Load` skips the PNG before reading the version. The current
Ikkoku `CardIO` remains an independent format; its files are not original cards.

| Record | Serialized order | Recovered evidence |
| --- | --- | --- |
| Root dictionary | i32 count; for each root: i32 dictionary key, object record | `SceneInfo.Save(BinaryWriter, Dictionary)` and `Load` |
| Common object | i32 kind, i32 object key, ChangeAmount, i32 tree state, bool visible | `ObjectInfo.Save/Load` |
| ChangeAmount | 9 float32: position XYZ, rotation XYZ, scale XYZ | `ChangeAmount.Save/Load` |
| Folder, kind 3 | common object, string name, child list | `OIFolderInfo.Save/Load` |
| Camera object, kind 5 | common object, string name, bool active | `OICameraInfo.Save/Load` |
| Child list | i32 count, direct object records; no root dictionary key | `ObjectInfoAssist.LoadChild` |
| Bone/IK target | i32 object key, ChangeAmount; no kind, tree state, or visible | `OIBoneInfo.Save/Load`, `OIIKTargetInfo` |
| Pattern | i32 key, string path, bool clamp, string JSON Vector4, float32 rotation | `PatternInfo.Save/Load` |
| Light, kind 2 | common object, i32 catalog number, 4 float32 RGBA, float32 intensity/range/spot angle, bool shadow/enable/drawTarget | `OILightInfo.Save/Load`, `Utility.SaveColor/LoadColor` |
| CameraData v2 | i32 2, float32 position XYZ, rotation XYZ, distance XYZ, field of view | nested `CameraControl.CameraData.Save/Load` |

Item kind 1 follows its common header with:

1. i32 group/category/number and float32 animation speed.
2. Eight JSON color strings and three Pattern records.
3. float32 alpha, JSON line color, float32 line width, JSON emission color,
   float32 emission power, float32 light cancel, and one panel Pattern.
4. bool FK enabled; i32 bone count; each bone is a string name plus a Bone record.
5. bool dynamic bone enabled, float32 normalized animation time, then a child list.

This item order is specific to the observed 1.0.4.2 writer. Its loader includes
older-version branches that this native reader deliberately does not support.
Light `no` and item `(group, category, no)` identify catalog entries; they are
not native mesh IDs or Unity LightType values. Resolving those catalogs is a
separate asset-pipeline step.

The observed scene continues after the root object section with map settings,
effects, saved viewport camera, ten camera slots, character/map light settings,
sound settings, background/frame strings, and a `【KStudio】` marker. Plugins may
append additional data. `KoikatsuSceneReader.decode` returns the exact end offset of the object section.
The separate `decodeDocument` API now parses this full installed settings layout
and retains the plugin trailer; see [scene records](scene-records.md). Parsed
settings are not all applied by the Studio preview.

## Transform and camera implications

`GuideObject.CalcPosition` assigns ChangeAmount position to localPosition in the
usual path, or parent.TransformPoint in its nonconnect path. `CalcRotation` uses
`Quaternion.Euler(changeAmount.rot)` and `CalcScale` writes localScale. Thus
rotations are Unity Euler **degrees**, not the existing Ikkoku Euler XYZ matrix
order. Import must use `UnityCoordinates.eulerDegrees` and convert the basis;
copying the three angle numbers directly would give incorrect mixed-axis poses.

`CameraControl` evaluates the world camera as rotation multiplied by its stored
three-component distance, plus its target position; when `transBase` exists it
also applies that transform. The camera's stored `parse` is used as fieldOfView.
The raw reader retains distance X/Y and roll. `SourceStudioCamera` now maps the
full distance vector and retains a native orientation override, including roll;
the current camera and ten saved slots are applied and have bounded export support. A scene
camera object and saved viewport CameraData are different records.

`FKCtrl`, `IKCtrl`, `OIBoneInfo`, and `OIIKTargetInfo` establish pose record
semantics. The original bone group enum is a bit mask; records use numeric keys,
and IK target serialization inherits the bone record. Separate [FK](pose.md) and
[schema-2 full-body IK](full-body-ik.md) translations consume these records in
converted source-character previews. Prototype pose deltas and named skeletons
remain separate and are not substitutes for those source adapters.

## Native implementation and validation

`Packages/Engine/Sources/Studio/KoikatsuBinary.swift` provides:

- `KoikatsuSceneReader.decode(Data)` for the 1.0.4.2 object section, retaining
  root dictionary keys, object keys, hierarchy, names, transforms, materials,
  item bone records, lights, and camera-object active state.
- Isolated 36-byte ChangeAmount and 44-byte CameraData v2 decoders.
- Explicit rejection of unsupported versions, unknown kinds, invalid UTF-8/lengths,
  negative counts, duplicate object keys, nonfinite floats and truncated records.
  Character (kind 0) and route (kind 4) parsing now resides in the companion
  `KoikatsuSceneRecordReader.swift`; all six observed kinds are supported.
- Limits of 256 MiB per input, 1 MiB per string, 100,000 objects per scene or
  entries per collection, and hierarchy depth 64.

The binary reader never follows paths in a source Pattern record, loads assets
or executes source code. `KoikatsuSceneDocument.extensions()` separately exposes
recognized KKEx MessagePack without executing handlers. PNG framing is checked,
but PNG CRC and image pixels are not decoded. Success from `decode` means the
object section parsed; success from
`decodeDocument` additionally validates the installed settings framing. Neither
establishes complete scene-runtime parity.

The initial object-section regression fixtures are synthetic; retained real-file
record comparisons and full-document tests are described in
[scene records](scene-records.md). They check multibyte seven-bit string lengths,
nested objects, item field alignment through bone records and children, light
binary colors versus item JSON colors, exact end offset before an opaque tail,
camera roll/distance preservation, nonzero Data slice offsets, unsupported kinds,
bad counts and lengths, depth limits, and rejection at every truncated byte prefix.

The observed binary framing is fully implemented within its version bounds. Next
work belongs to the mixed runtime importer and broader edited writer (`ST-T03`,
`ST-T04`), not re-decoding characters/routes already supported by this reader.
Historical format versions remain explicit exclusions until independently tested.

```sh
swift test --package-path Packages/Engine --filter Koikatsu
```
