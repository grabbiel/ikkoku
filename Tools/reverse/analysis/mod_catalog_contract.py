#!/usr/bin/env python3
"""Independent catalog/lookup oracle derived from bounded original C# methods.

Reads ignored ILSpy output and preserved source CSV bytes, never Swift code or
plugin entry points. Runtime slot counters are explicit fixture inputs because
source slots depend on startup state, randomization and registration order.
"""
from __future__ import annotations

import argparse
import copy
from functools import cmp_to_key
import hashlib
import json
from pathlib import Path
import re


REPO = Path(__file__).resolve().parents[3]
SOURCE = REPO / ".local/reverse/mods/decompiled"
CONTROL = REPO / ".local/reverse/decompiled/Character/Koikatu/ChaControl.cs"
PACKAGE = REPO / ".local/reverse/mods/packages/no-hair-accessories/manifest.json"
ACCESSORY_PROPERTY = "ChaFileAccessory.PartsInfo.id"
WHITESPACE = "\t\n\v\f\r \u0085\u00a0\u1680\u2000\u2001\u2002\u2003\u2004\u2005\u2006\u2007\u2008\u2009\u200a\u2028\u2029\u202f\u205f\u3000"


def trim(value: str) -> str:
    return value.strip(WHITESPACE)


def int32(value: str) -> int:
    value = trim(value)
    if not re.fullmatch(r"[+-]?[0-9]+", value):
        raise ValueError("Source Int32 parse failed")
    number = int(value)
    if not -(2**31) <= number < 2**31:
        raise ValueError("Source Int32 overflow")
    return number


def stream_reader_text(data: bytes) -> tuple[str, str]:
    # StreamReader(stream, Encoding.UTF8) defaults to BOM detection and decoder
    # replacement. It does not try CP932. Native readers may reject unsupported
    # encodings instead; the original bytes must remain available in that case.
    for bom, encoding in ((b"\xff\xfe\0\0", "utf-32-le"), (b"\0\0\xfe\xff", "utf-32-be"),
                          (b"\xef\xbb\xbf", "utf-8"), (b"\xff\xfe", "utf-16-le"),
                          (b"\xfe\xff", "utf-16-be")):
        if data.startswith(bom):
            return data[len(bom):].decode(encoding, errors="replace"), encoding + "-bom"
    return data.decode("utf-8", errors="replace"), "utf-8"


def source_csv(data: bytes) -> dict:
    text, encoding = stream_reader_text(data)
    # .NET ReadLine recognizes CR, LF and CRLF, not every Unicode separator.
    lines = re.split(r"\r\n|\r|\n", text)
    if text.endswith(("\n", "\r")):
        lines.pop()
    if len(lines) < 4:
        raise ValueError("Source LoadCSV requires four initial lines")
    category = int32(trim(lines[0].split(",")[0]))
    distribution = int32(trim(lines[1].split(",")[0]))
    target = trim(lines[2].split(",")[0])
    columns = trim(lines[3]).split(",")
    rows = []
    stopped = None
    for line_number, line in enumerate(lines[4:], 5):
        line = trim(line)
        if "," not in line:
            stopped = line_number
            break
        rows.append(line.split(","))
    return {"categoryNo": category, "distributionNo": distribution, "filePath": target,
            "encoding": encoding, "containsReplacementCharacter": "\ufffd" in text,
            "columns": columns, "rows": rows, "stoppedAtLine": stopped}


def set_possess_new(catalog: dict) -> dict:
    result = copy.deepcopy(catalog)
    if "Possess" in result["columns"]:
        index = result["columns"].index("Possess")
        for row in result["rows"]:
            if index >= len(row):
                raise ValueError("Source SetPossessNew row index out of range")
            row[index] = "1"
    return result


def enum_values(source: str, enum_name: str) -> dict[str, int]:
    match = re.search(r"public enum " + re.escape(enum_name) + r"\s*\{([^}]+)\}", source)
    if not match:
        raise ValueError(f"Missing recovered enum {enum_name}")
    result, current = {}, -1
    for item in match.group(1).split(","):
        item = item.strip()
        if not item:
            continue
        key, _, explicit = item.partition("=")
        current = int(explicit.strip()) if explicit else current + 1
        result[key.strip()] = current
    return result


def list_info(category: int, distribution: int, columns: list[str], row: list[str], keys: dict[str, int]) -> dict:
    values = {keys["Category"]: str(category), keys["DistributionNo"]: str(distribution)}
    for index, column in enumerate(columns):
        if index >= len(row):
            raise ValueError("Source ListInfoBase.Set row index out of range")
        # Names.Check returns the enum-name index. Unknown columns share -1.
        values[keys.get(column, -1)] = row[index]
    names = {number: name for name, number in keys.items()}
    return {names.get(number, "<unknown-key:-1>"): value for number, value in values.items()}


def generate_resolution(catalog: dict, guid: str, start_counter: int, properties: list[str], keys: dict[str, int]) -> dict:
    source = set_possess_new(catalog)
    rows, records = [], []
    counter = start_counter
    for ordinal, original in enumerate(source["rows"]):
        counter += 1
        slot = int32(original[0])
        generated = list(original)
        generated[0] = str(counter)
        for property_name in (["Ramp"] if source["categoryNo"] == 432 else properties):
            records.append({"GUID": trim(guid), "Slot": slot, "LocalSlot": counter,
                            "Property": property_name, "CategoryNo": source["categoryNo"], "rowOrdinal": ordinal})
        rows.append({"ordinal": ordinal, "sourceSlot": slot, "runtimeLocalSlot": counter,
                     "values": generated, "fields": list_info(source["categoryNo"], source["distributionNo"], source["columns"], generated, keys)})
    return {"startCounter": start_counter, "endCounter": counter, "rows": rows, "resolveInfos": records}


def lookup(records: list[dict], *, slot: int | None = None, local_slot: int | None = None,
           category: int | None = None, guid: str | None = None, property_name: str | None = None) -> dict | None:
    for record in records:
        if slot is not None and record["Slot"] != slot:
            continue
        if local_slot is not None and record["LocalSlot"] != local_slot:
            continue
        if category is not None and record["CategoryNo"] != category:
            continue
        if guid is not None and record["GUID"] != trim(guid):
            continue
        if property_name is not None and record["Property"] != property_name:
            continue
        return record
    return None


def get_info(fields: dict[str, str], key: str) -> str:
    return fields.get(key, "0")


def bundle_registration_key(archive_path: str) -> str:
    # Exact ZipmodInfo behavior, not an invented case-insensitive normalization.
    return archive_path.split("/", 1)[1] if "/" in archive_path else archive_path


def clothes_texture_reference(fields: dict[str, str], bundle_key: str, asset_key: str) -> dict:
    bundle = get_info(fields, bundle_key)
    if bundle == "0":
        bundle = get_info(fields, "MainAB")
    asset = get_info(fields, asset_key)
    manifest = get_info(fields, "MainManifest")
    return {"bundle": bundle, "asset": asset, "manifest": manifest if manifest else "abdata",
            "sourceAttemptsLoad": bundle != "0" and asset != "0"}


def fixtures(keys: dict[str, int]) -> list[dict]:
    cases = []
    text = '122,ignored\n0,ignored\n Assets/list.bytes ,ignored\nID,Name,Possess\n 7,"a,b",0 \nstop\n8,ignored,0\n'
    parsed = source_csv(text.encode())
    assert parsed["rows"] == [["7", '"a', 'b"', "0"]] and parsed["stoppedAtLine"] == 6
    generated = generate_resolution(parsed, "fixture.mod", 100000000, [ACCESSORY_PROPERTY], keys)
    assert generated["rows"][0]["fields"]["Name"] == '"a'
    assert generated["rows"][0]["fields"]["Possess"] == "1"
    cases.append({"name": "plain-split-not-rfc-quotes-and-stop", "csvUTF8": text, "parsed": parsed, "generated": generated})
    text = '122\n0\nignored-target\nID,Name\n7,first\n7,second\n'
    parsed = source_csv(text.encode())
    generated = generate_resolution(parsed, "fixture.mod", 100000000, [ACCESSORY_PROPERTY], keys)
    queries = [{"slot": 7, "category": 122, "guid": "fixture.mod", "property_name": ACCESSORY_PROPERTY},
               {"slot": 7, "category": 122, "guid": " fixture.mod "},
               {"slot": 7, "category": 122, "guid": "Fixture.mod"},
               {"slot": 7, "category": 123, "guid": "fixture.mod"},
               {"local_slot": 100000002, "category": 122}]
    results = [lookup(generated["resolveInfos"], **query) for query in queries]
    assert results[0]["rowOrdinal"] == 0 and results[1]["rowOrdinal"] == 0
    assert results[2] is None and results[3] is None and results[4]["rowOrdinal"] == 1
    cases.append({"name": "duplicate-original-slot-first-resolution", "csvUTF8": text, "parsed": parsed,
                  "generated": generated, "lookups": [{"query": q, "expected": r} for q, r in zip(queries, results)]})
    text = '122\n3\nignored-target\nID, Name,Name,Name,Possess,Possess\n8,unknown,first,last,0,9\n'
    parsed = source_csv(text.encode())
    generated = generate_resolution(parsed, "fixture.mod", 100000000, [ACCESSORY_PROPERTY], keys)
    fields = generated["rows"][0]["fields"]
    assert fields["Name"] == "last" and fields["Possess"] == "9" and fields["<unknown-key:-1>"] == "unknown"
    cases.append({"name": "untrimmed-header-and-last-key-write", "csvUTF8": text, "parsed": parsed, "generated": generated})
    base = {"MainAB": "chara/base.unity3d", "MainManifest": "", "MainTex": "tex"}
    refs = []
    for value in (None, "0", "", "chara/alternate.unity3d"):
        fields = dict(base)
        if value is not None:
            fields["MainTexAB"] = value
        refs.append({"fields": fields, "expected": clothes_texture_reference(fields, "MainTexAB", "MainTex")})
    assert refs[0]["expected"]["bundle"] == refs[1]["expected"]["bundle"] == base["MainAB"]
    assert refs[2]["expected"]["bundle"] == "" and refs[2]["expected"]["sourceAttemptsLoad"]
    cases.append({"name": "clothes-exact-zero-fallback-empty-preserved", "references": refs,
                  "missingField": get_info({}, "MainTex"), "emptyField": get_info({"MainTex": ""}, "MainTex")})
    paths = ["abdata/chara/X.unity3d", "ABDATA/Chara/X.unity3d", "other/chara/x.unity3d", "x.unity3d"]
    cases.append({"name": "source-bundle-registration-path", "paths": [{"archivePath": p, "expectedKey": bundle_registration_key(p)} for p in paths]})
    return cases


def evidence(path: Path, methods: list[str]) -> dict:
    data = path.read_bytes()
    text = data.decode("utf-8")
    anchors = []
    for method in methods:
        index = text.find(method)
        if index < 0:
            raise ValueError(f"Missing source evidence {method} in {path}")
        anchors.append({"text": method, "line": text[:index].count("\n") + 1})
    return {"path": str(path.relative_to(REPO)), "sha256": hashlib.sha256(data).hexdigest(), "anchors": anchors}


def category_properties(source: str, categories: dict[str, int], clothes_source: str) -> list[dict]:
    properties = {number: [] for number in categories.values()}
    # The same order as CollatedGenerator; literal keys come from each original
    # method, not a reconstruction based on native model field names.
    for prefix in ("ChaFileFace", "ChaFileBody", "ChaFileHair", "ChaFileClothes", "ChaFileMakeup"):
        start = source.index(" " + prefix + "Generator()\n\t{")
        end = source.find("\n\tprivate static ", start)
        body = source[start:end if end >= 0 else len(source)]
        if prefix == "ChaFileClothes":
            if not re.search(r"public int emblemeId2\s*\{", clothes_source):
                raise ValueError("Conditional second-emblem source property not verified")
        for number, name, explicit_prefix in re.findall(r'new CategoryProperty\(\(CategoryNo\)(\d+), "([^"]+)"(?:, "([^"]*)")?', body):
            property_name = (explicit_prefix or prefix) + "." + name
            properties[int(number)].append(property_name)
        patterns = re.findall(r'new CategoryProperty\(\(CategoryNo\)(\d+), \$"([^"]+)"\s*, "([^"]+)"', body)
        if patterns:
            assert prefix == "ChaFileClothes" and "for (int num = 0; num < 4; num++)" in body
            for index in range(4):
                for number, name, explicit_prefix in patterns:
                    assert "{index}" in name
                    properties[int(number)].append(explicit_prefix + "." + name.replace("{index}", str(index)))
    for number in properties:
        properties[number].append(ACCESSORY_PROPERTY)
    properties[432] = ["Ramp"]
    assert properties[122] == [ACCESSORY_PROPERTY]
    assert len([p for p in properties[430] if "Pattern" in p]) == 36
    return [{"number": number, "name": name, "properties": properties[number]}
            for name, number in sorted(categories.items(), key=lambda pair: pair[1])]


def reference_rules(families: list[dict]) -> list[dict]:
    clothes = list(range(105, 113)) + [200, 201, 202, 210, 211, 212, 503, 504]
    prefabs = list(range(100, 113)) + list(range(121, 131)) + [200, 201, 202, 210, 211, 212, 501, 502, 503, 504]
    def rule(role, categories, bundle, asset, expected, manifest=None, fallback=None, disabled=(), disabled_bundle=()):
        return {"role": role, "categories": categories, "bundleField": bundle, "assetField": asset,
                "manifestField": manifest, "fallbackBundleField": fallback, "disabledAssetValues": list(disabled),
                "disabledBundleValues": list(disabled_bundle), "expectedType": expected}
    result = [rule("mainPrefab", prefabs, "MainAB", "MainData", "GameObject", "MainManifest", disabled=("",)),
              rule("extendedBodyPrefab", [500], "MainAB", "MainData", "GameObject", "MainManifest"),
              rule("accessoryThumbnail", list(range(121, 131)), "ThumbAB", "ThumbTex", "Texture2D"),
              rule("headMaterial", [100], "MatAB", "MatData", "Material", "MatManifest"),
              rule("headDiffuse", [100], "MainTexAB", "MainTex", "Texture2D", "MainManifest"),
              rule("headColorMask", [100], "ColorMaskAB", "ColorMaskTex", "Texture2D", "MainManifest")]
    for bundle, asset in (("MainTexAB", "MainTex"), ("MainTex02AB", "MainTex02"), ("MainTex03AB", "MainTex03"),
                          ("ColorMaskAB", "ColorMaskTex"), ("ColorMask02AB", "ColorMask02Tex"), ("ColorMask03AB", "ColorMask03Tex")):
        result.append(rule("clothes:" + asset, clothes, bundle, asset, "Texture2D", "MainManifest", "MainAB", ("0",), ("0",)))
    for family in families:
        result.append(rule(family["consumer"] + ":" + family["assetColumn"], [family["categoryNo"]], family["bundleColumn"],
                           family["assetColumn"], "Texture2D", disabled=("0",), disabled_bundle=("0",)))
    # These pairs are explicit source consumers, not an AB/Tex suffix heuristic.
    result += [rule("patternTexture", [430], "MainTexAB", "MainTex", "Texture2D", disabled=("0",), disabled_bundle=("0",)),
               rule("emblemTexture", [431], "MainTexAB", "MainTex", "Texture2D", disabled=("0",), disabled_bundle=("0",)),
               rule("expressionTexture", [2], "EpsTexAB", "EpsTex", "Texture2D", disabled=("0",), disabled_bundle=("0",))]
    return result


def version_tokens(version: str) -> list[int | str]:
    version = trim(version).lstrip("vVrR ") or "0"
    tokens = []
    for section in re.split(r"[. ,_\-]", trim(version)):
        if not section:
            tokens.append(0)
        for part in re.findall(r"[0-9]+|[^0-9]+", section):
            try:
                tokens.append(int32(part))
            except ValueError:
                tokens.append(part)
    return tokens


def version_compare_fixture(first: str, second: str) -> int:
    """Source comparisons for culture-independent numeric/mixed-token fixtures.

    Two distinct string tokens use source CurrentCulture.CompareTo. Refuse that
    wider comparison instead of quietly substituting Python/ordinal collation.
    """
    left, right = version_tokens(first), version_tokens(second)
    for index in range(max(len(left), len(right))):
        a = left[index] if index < len(left) else 0
        b = right[index] if index < len(right) else 0
        if a == b:
            continue
        if isinstance(a, int) and isinstance(b, int):
            return (a > b) - (a < b)
        if isinstance(a, str) and isinstance(b, str):
            raise ValueError("Distinct string tokens require original CurrentCulture collation")
        a, b = str(a), str(b)
        if a == "0" and b != "0":
            return -1
        if b == "0" and a != "0":
            return 1
        return (a > b) - (a < b)
    return 0


def version_fixtures() -> dict:
    comparisons = [("1.10", "1.2", 1), ("v1.2", "1.2", 0), ("1.0", "1", 0),
                   ("1.0-beta", "1.0", 1), ("r2_0", "2.0", 0), ("", "0", 0)]
    for first, second, expected in comparisons:
        assert version_compare_fixture(first, second) == expected
    groups = [
        [{"fileName": "short.zipmod", "version": "1.2", "lastWriteTime": 2},
         {"fileName": "later-version.zipmod", "version": "1.10", "lastWriteTime": 1}],
        [{"fileName": "short.zipmod", "version": "1", "lastWriteTime": 2},
         {"fileName": "longer-name.zipmod", "version": "1.0", "lastWriteTime": 1}],
        [{"fileName": "named-version.zipmod", "version": "99", "lastWriteTime": 1},
         {"fileName": "missing-version.zipmod", "version": "", "lastWriteTime": 2}],
    ]
    selections = []
    for group in groups:
        if all(entry["version"] for entry in group):
            def compare(a, b):
                version = version_compare_fixture(a["version"], b["version"])
                return -version if version else len(b["fileName"]) - len(a["fileName"])
            ordered = sorted(group, key=cmp_to_key(compare))
        else:
            ordered = sorted(group, key=lambda entry: -entry["lastWriteTime"])
        selections.append({"candidates": group, "expectedFileName": ordered[0]["fileName"]})
    assert [x["expectedFileName"] for x in selections] == ["later-version.zipmod", "longer-name.zipmod", "missing-version.zipmod"]
    return {"comparisons": [{"first": a, "second": b, "expectedSign": sign} for a, b, sign in comparisons],
            "duplicateGuidSelections": selections,
            "scope": "Numeric/equal-string/mixed-token comparisons only; source CurrentCulture string collation is not emulated."}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-dir", type=Path, default=SOURCE)
    parser.add_argument("--control", type=Path, default=CONTROL)
    parser.add_argument("--package", type=Path, default=PACKAGE)
    parser.add_argument("--output", type=Path, default=REPO / ".local/reverse/mods/catalog-contract.json")
    args = parser.parse_args()
    define = (args.source_dir / "ChaListDefine.decompiled.cs").read_text()
    keys, categories = enum_values(define, "KeyType"), enum_values(define, "CategoryNo")
    package = json.loads(args.package.read_text())
    catalogs = []
    for entry in package["catalogs"]:
        data = (args.package.parent / entry["path"]).read_bytes()
        assert hashlib.sha256(data).hexdigest() == entry["sha256"]
        parsed = source_csv(data)
        if parsed["categoryNo"] != 122:
            raise ValueError("This bounded sample oracle expects accessory category 122")
        generated = generate_resolution(parsed, package["source"]["guid"], 100000000, [ACCESSORY_PROPERTY], keys)
        deps = []
        for row in generated["rows"]:
            fields = row["fields"]
            for role, bundle_column, asset_column in (("mainPrefab", "MainAB", "MainData"), ("thumbnail", "ThumbAB", "ThumbTex")):
                bundle, asset = get_info(fields, bundle_column), get_info(fields, asset_column)
                manifest = get_info(fields, "MainManifest") if role == "mainPrefab" else ""
                deps.append({"guid": package["source"]["guid"], "categoryNo": 122, "sourceSlot": row["sourceSlot"],
                             "role": role, "bundleColumn": bundle_column, "assetColumn": asset_column,
                             "sourceBundleKey": bundle, "canonicalArchivePath": "abdata/" + bundle,
                             "assetName": asset, "manifest": manifest or "abdata",
                             "sourceAttemptsLoad": role != "mainPrefab" or asset != "",
                             "includedInThisArchive": False})
        catalogs.append({"sourcePath": entry["sourcePath"], "sha256": entry["sha256"], "parsed": parsed,
                         "fixtureCounterIsSynthetic": True, "generated": generated, "dependencies": deps})
    control = args.control.read_text()
    call_pattern = r"(SetCreateTexture|ChangeTexture)\([^\n;]*?ChaListDefine.CategoryNo\.(\w+),[^\n;]*?ChaListDefine.KeyType\.(\w+), ChaListDefine.KeyType\.(\w+),"
    families = [{"consumer": call, "categoryName": category, "categoryNo": categories[category],
                 "bundleColumn": bundle, "assetColumn": asset, "manifest": "abdata",
                 "guard": "both tokens differ from exact string 0"}
                for call, category, bundle, asset in sorted(set(re.findall(call_pattern, control)))]
    methods = {
        "Sideloader.ListLoader.Lists.decompiled.cs": ["internal static ChaListData LoadCSV", "internal static void LoadListInternal", "internal static void LoadList(this ChaListControl instance, CategoryNo"],
        "Sideloader.ZipmodInfo.decompiled.cs": ["private static void SetPossessNew", 'name.StartsWith("abdata/list/characustom"', "text.Remove(0, text.IndexOf('/') + 1)"],
        "Sideloader.AutoResolver.UniversalAutoResolver.decompiled.cs": ["internal static void GenerateResolutionInfo", "public static ResolveInfo TryGetResolutionInfo(int slot, CategoryNo", "public static int GetUniqueSlotID"],
        "Sideloader.AutoResolver.StructReference.decompiled.cs": ["private static Dictionary<CategoryProperty, StructValue<int>> ChaFileAccessoryPartsInfoGenerator"],
        "Sideloader.Sideloader.decompiled.cs": ["orderby x.Key", "item3.OrderByDescending", "private static void AddAllLists", "private static void AddBundles"],
        "Sideloader.ManifestVersionComparer.decompiled.cs": ["public static int CompareVersions"],
        "ListInfoBase.decompiled.cs": ["public bool Set", "public string GetInfo"],
        "Illusion.Extensions.ValueExtensions.decompiled.cs": ["public static int Check<T>(this T[] array, T value)"],
        "Illusion.Utils.Value.decompiled.cs": ["public static int Check(int len, Func<int, bool> func)"],
        "ChaFileClothes.decompiled.cs": ["public int emblemeId2"],
        "AssetBundleManager.decompiled.cs": ["public static AssetBundleLoadAssetOperation LoadAsset(string"],
        "ChaCustom.CustomAcsSelectKind.decompiled.cs": ["ChaListDefine.KeyType.ThumbAB"],
        "ChaCustom.CustomSelectListCtrl.decompiled.cs": ["CommonLib.LoadAsset<Texture2D>"],
    }
    category_records = category_properties((args.source_dir / "Sideloader.AutoResolver.StructReference.decompiled.cs").read_text(),
                                          categories, (args.source_dir / "ChaFileClothes.decompiled.cs").read_text())
    base_path = REPO / ".local/reverse/mods/no-hair-base-etc-objects.json"
    base = json.loads(base_path.read_text())
    base_bundle = REPO / ".local/reverse/mods/source/abdata/chara/etc.unity3d"
    assert hashlib.sha256(base_bundle.read_bytes()).hexdigest() == base["sha256"]
    source_assets = [{"manifest": "abdata", "bundlePath": "chara/etc.unity3d", "assetName": item["name"],
                      "type": item["type"], "sourcePathID": item["pathID"], "sourceSHA256": base["sha256"]}
                     for item in base["objects"] if item["type"] in ("GameObject", "Texture2D")]
    report = {"schemaVersion": 1, "kind": "koikatsu-mod-catalog-contract", "scope": "source CSV, accessory sample, character resolver identity, explicit asset-reference consumers",
              "sourceArchive": package["source"], "categories": category_records,
              "keyTypes": [name for name, _ in sorted(keys.items(), key=lambda pair: pair[1])],
              "referenceRules": reference_rules(families),
              "sourceAssets": source_assets, "versionSelectionFixtures": version_fixtures(),
              "sourceBinaries": [{"path": str(path.relative_to(REPO)), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
                                 for path in (REPO / ".local/reverse/mods/source/BepInEx/plugins/KK_BepisPlugins/Sideloader.dll",
                                              REPO / ".local/reverse/source/Koikatu_Data/Managed/Assembly-CSharp.dll")],
              "catalogs": catalogs, "sourceTextureFamilies": families, "fixtures": fixtures(keys),
              "evidence": [evidence(args.source_dir / name, anchors) for name, anchors in methods.items()] +
                          [evidence(args.control, ["private bool SetCreateTexture", "protected bool InitBaseCustomTextureClothes", "public bool LoadAlphaMaskTexture"])],
              "limitations": ["Synthetic LocalSlot counter is not a prediction of installed runtime IDs.",
                              "Registration ordering uses source .NET culture and zip entry order; no native archive sorting equivalence is claimed.",
                              "Dependency provider GUIDs cannot be inferred from asset paths alone.",
                              "No plugin execution or native-runtime implementation is used as the oracle."]}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"output": str(args.output), "catalogs": len(catalogs), "rows": sum(len(c["parsed"]["rows"]) for c in catalogs),
                      "lookupFixtureGroups": len(report["fixtures"]), "explicitTextureFamilies": len(families)}))


if __name__ == "__main__":
    main()
