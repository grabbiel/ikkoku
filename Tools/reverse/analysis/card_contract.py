#!/usr/bin/env python3
"""Bounded, independent character-card framing oracle; never executes plugins.

Reads original byte framing and retains the complete input plus exact block and
plugin slices. Generated fixtures contain synthetic values and a blank PNG only.
MessagePack is used for fixture encoding; the parser below reads tokens itself.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
import json
import math
from pathlib import Path
import struct
import zlib


REPO = Path(__file__).resolve().parents[3]
PNG = b"\x89PNG\r\n\x1a\n"
MAGIC = "【KoiKatuChara】"
ABMX = "KKABMPlugin.ABMData"
VERSIONS = {"card": "0.0.0", "Custom": "0.0.0", "face": "0.0.2", "body": "0.0.2",
            "hair": "0.0.4", "Coordinate": "0.0.0", "Parameter": "0.0.5", "Status": "0.0.0"}


@dataclass(frozen=True)
class Limits:
    card_bytes: int = 128 * 1024 * 1024
    png_bytes: int = 16 * 1024 * 1024
    header_bytes: int = 4 * 1024 * 1024
    payload_bytes: int = 64 * 1024 * 1024
    scalar_bytes: int = 16 * 1024 * 1024
    string_bytes: int = 1024 * 1024
    container_items: int = 100000
    nodes: int = 200000
    depth: int = 64
    blocks: int = 256
    plugins: int = 4096
    png_chunks: int = 4096


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class Cursor:
    def __init__(self, data: bytes, offset: int = 0):
        self.data, self.offset = data, offset

    def take(self, count: int) -> bytes:
        if count < 0 or count > len(self.data) - self.offset:
            raise ValueError("Truncated or negative byte range")
        result = self.data[self.offset:self.offset + count]
        self.offset += count
        return result

    def number(self, fmt: str):
        return struct.unpack(fmt, self.take(struct.calcsize(fmt)))[0]

    def dotnet_string(self, bound: int = 1024) -> str:
        size = 0
        for index in range(5):
            byte = self.number("B")
            if index == 4 and byte > 7:
                raise ValueError("Invalid .NET string length")
            size |= (byte & 127) << (index * 7)
            if byte < 128:
                if size > bound:
                    raise ValueError(".NET string exceeds bound")
                return self.take(size).decode("utf-8")
        raise ValueError("Invalid .NET string length")


@dataclass
class Node:
    kind: str
    value: object
    start: int
    end: int


class MessagePackReader(Cursor):
    """Token reader with absolute spans, depth/count bounds and no type loading."""
    def __init__(self, data: bytes, limits: Limits):
        super().__init__(data)
        self.limits, self.node_count = limits, 0

    def node(self, depth: int = 0) -> Node:
        self.node_count += 1
        if depth > self.limits.depth or self.node_count > self.limits.nodes:
            raise ValueError("MessagePack nesting or node budget exceeded")
        start, code = self.offset, self.number("B")
        kind, count = None, None
        if code <= 0x7f:
            kind, value = "int", code
        elif code >= 0xe0:
            kind, value = "int", code - 256
        elif 0xa0 <= code <= 0xbf:
            kind, count = "str", code & 31
        elif 0x90 <= code <= 0x9f:
            kind, count = "array", code & 15
        elif 0x80 <= code <= 0x8f:
            kind, count = "map", code & 15
        elif code in (0xc0, 0xc2, 0xc3):
            kind, value = ("nil", None) if code == 0xc0 else ("bool", code == 0xc3)
        elif code in (0xcc, 0xcd, 0xce, 0xcf, 0xd0, 0xd1, 0xd2, 0xd3, 0xca, 0xcb):
            fmt = {0xcc: ">B", 0xcd: ">H", 0xce: ">I", 0xcf: ">Q", 0xd0: ">b", 0xd1: ">h",
                   0xd2: ">i", 0xd3: ">q", 0xca: ">f", 0xcb: ">d"}[code]
            kind, value = ("float" if code in (0xca, 0xcb) else "int"), self.number(fmt)
        elif code in (0xd9, 0xda, 0xdb, 0xc4, 0xc5, 0xc6, 0xdc, 0xdd, 0xde, 0xdf, 0xc7, 0xc8, 0xc9):
            kind, fmt = {0xd9: ("str", ">B"), 0xda: ("str", ">H"), 0xdb: ("str", ">I"),
                         0xc4: ("bin", ">B"), 0xc5: ("bin", ">H"), 0xc6: ("bin", ">I"),
                         0xdc: ("array", ">H"), 0xdd: ("array", ">I"), 0xde: ("map", ">H"), 0xdf: ("map", ">I"),
                         0xc7: ("ext", ">B"), 0xc8: ("ext", ">H"), 0xc9: ("ext", ">I")}[code]
            count = self.number(fmt)
        elif 0xd4 <= code <= 0xd8:
            kind, count = "ext", 1 << (code - 0xd4)
        else:
            raise ValueError(f"Reserved MessagePack token {code:#x}")
        if count is not None:
            if kind in ("array", "map"):
                if count > self.limits.container_items:
                    raise ValueError("MessagePack container exceeds bound")
                value = ([self.node(depth + 1) for _ in range(count)] if kind == "array" else
                         [(self.node(depth + 1), self.node(depth + 1)) for _ in range(count)])
            else:
                if count > (self.limits.string_bytes if kind == "str" else self.limits.scalar_bytes):
                    raise ValueError("MessagePack scalar exceeds bound")
                extension = self.number("b") if kind == "ext" else None
                value = self.take(count)
                if kind == "str":
                    value = value.decode("utf-8")
                elif kind == "ext":
                    value = (extension, value)
        return Node(kind, value, start, self.offset)


def unpack(data: bytes, limits: Limits) -> Node:
    reader = MessagePackReader(data, limits)
    value = reader.node()
    if reader.offset != len(data):
        raise ValueError("Trailing bytes after MessagePack value")
    return value


def mapping(node: Node, *, duplicate_last: bool = False) -> dict[str, Node]:
    if node.kind != "map":
        raise ValueError("Expected MessagePack map")
    result = {}
    for key, value in node.value:
        if key.kind != "str" or (key.value in result and not duplicate_last):
            raise ValueError("Non-string or duplicate map key")
        result[key.value] = value
    return result


def field(values: dict, key: str, kind: str):
    node = values.get(key)
    if node is None or node.kind != kind:
        raise ValueError(f"Missing or invalid {key}")
    return node.value


def png_end(data: bytes, limits: Limits) -> int:
    if not data.startswith(PNG):
        return 0
    reader = Cursor(data, 8)
    for index in range(limits.png_chunks):
        count, kind = reader.number(">I"), reader.take(4)
        if count > limits.png_bytes or reader.offset + count + 4 > limits.png_bytes:
            raise ValueError("PNG chunk range exceeds bound")
        chunk, crc = reader.take(count), reader.number(">I")
        if zlib.crc32(kind + chunk) & 0xffffffff != crc:
            raise ValueError("PNG CRC mismatch")
        if index == 0:
            if kind != b"IHDR" or count != 13:
                raise ValueError("PNG must begin with IHDR")
            width, height = struct.unpack(">II", chunk[:8])
            if not 0 < width <= 16384 or not 0 < height <= 16384:
                raise ValueError("PNG dimensions exceed bound")
        if kind == b"IEND":
            if count:
                raise ValueError("PNG IEND must be empty")
            return reader.offset
    raise ValueError("PNG chunk count exceeded or IEND missing")


def shape_values(node: Node, count: int) -> list[float]:
    if node.kind != "array" or len(node.value) != count:
        raise ValueError(f"Expected {count} shape values")
    result = []
    for item in node.value:
        if item.kind not in ("int", "float") or not math.isfinite(item.value) or abs(item.value) > 3.4028234663852886e38:
            raise ValueError("Shape values must be finite float32 numbers")
        result.append(struct.unpack("<f", struct.pack("<f", item.value))[0])
    return result


def parse_plugins(data: bytes, offset: int, limits: Limits) -> list[dict]:
    root = unpack(data, limits)
    if root.kind == "nil":
        return []
    entries = mapping(root)
    if len(entries) > limits.plugins:
        raise ValueError("Plugin count exceeds bound")
    result = []
    for name, node in entries.items():
        item = {"id": name, "offset": offset + node.start, "size": node.end - node.start,
                "raw": data[node.start:node.end], "isNull": node.kind == "nil", "version": None,
                "dataIsNull": True, "dataKeys": [], "binaryValues": {}, "trailingSlots": 0}
        if node.kind != "nil":
            if node.kind != "array":
                raise ValueError("PluginData must be an integer-key array or nil")
            members = node.value
            version = members[0] if members else Node("int", 0, 0, 0)
            if version.kind != "int" or not -(2**31) <= version.value < 2**31:
                raise ValueError("PluginData version must fit Int32")
            values = members[1] if len(members) > 1 else Node("nil", None, 0, 0)
            item.update(version=version.value, dataIsNull=values.kind == "nil", trailingSlots=max(0, len(members) - 2))
            if values.kind != "nil":
                properties = mapping(values)
                item["dataKeys"] = list(properties)
                item["dataNodes"] = properties
                for key, value in properties.items():
                    if value.kind == "bin":
                        # The raw binary contents begin after the MessagePack bin header.
                        item["binaryValues"][key] = {"offset": offset + value.end - len(value.value),
                                                     "size": len(value.value), "sha256": sha(value.value), "raw": value.value}
        result.append(item)
    return result


@dataclass
class ParsedCard:
    raw: bytes
    blocks: list[dict]
    plugins: list[dict]
    footer: bytes
    report: dict


def parse_card(data: bytes, limits: Limits = Limits()) -> ParsedCard:
    if len(data) > limits.card_bytes:
        raise ValueError("Card exceeds byte bound")
    png_size = png_end(data, limits)
    reader, offsets = Cursor(data, png_size), {"pngEnd": png_size, "productNo": png_size}
    product = reader.number("<i")
    if product != 100:
        raise ValueError("Oracle supports installed product100 framing only")
    offsets["magic"] = reader.offset
    if reader.dotnet_string() != MAGIC:
        raise ValueError("Unexpected card magic")
    offsets["version"] = reader.offset
    version = reader.dotnet_string()
    if version != VERSIONS["card"]:
        raise ValueError("Unsupported card version")
    offsets["facePngLength"] = reader.offset
    face_size = reader.number("<i")
    if not 0 <= face_size <= limits.png_bytes:
        raise ValueError("Face PNG length exceeds bound")
    offsets["facePngStart"] = reader.offset
    face_png = reader.take(face_size)
    offsets["headerLength"] = reader.offset
    header_size = reader.number("<i")
    if not 0 < header_size <= limits.header_bytes:
        raise ValueError("Header length exceeds bound")
    offsets["headerStart"] = reader.offset
    header_raw = reader.take(header_size)
    header = mapping(unpack(header_raw, limits), duplicate_last=True)
    infos = field(header, "lstInfo", "array")
    if len(infos) > limits.blocks:
        raise ValueError("Block count exceeds bound")
    offsets["payloadLength"] = reader.offset
    payload_size = reader.number("<q")
    if not 0 <= payload_size <= limits.payload_bytes:
        raise ValueError("Payload length exceeds bound")
    offsets["payloadStart"] = reader.offset
    payload = reader.take(payload_size)
    offsets["payloadEnd"] = reader.offset
    blocks = []
    for index, info in enumerate(infos):
        values = mapping(info, duplicate_last=True)
        name, block_version = field(values, "name", "str"), field(values, "version", "str")
        pos, size = field(values, "pos", "int"), field(values, "size", "int")
        if pos < 0 or size < 0 or pos > payload_size or size > payload_size - pos:
            raise ValueError("Block lies outside declared payload")
        blocks.append({"ordinal": index, "name": name, "version": block_version, "pos": pos, "size": size,
                       "offset": offsets["payloadStart"] + pos, "raw": payload[pos:pos + size],
                       "headerOffset": offsets["headerStart"] + info.start, "headerSize": info.end - info.start})
    by_name = {}
    for block in blocks:
        by_name.setdefault(block["name"], block)  # BlockHeader.SearchInfo uses first Find.
    diagnostics, custom, parameter = [], None, None
    if "Custom" in by_name:
        block = by_name["Custom"]
        if block["version"] != VERSIONS["Custom"]:
            diagnostics.append("unsupported-custom-version")
        else:
            custom_reader, maps = Cursor(block["raw"]), {}
            for name in ("face", "body", "hair"):
                size = custom_reader.number("<i")
                if not 0 < size <= limits.payload_bytes:
                    raise ValueError("Custom submessage exceeds bound")
                local_offset = custom_reader.offset
                raw = custom_reader.take(size)
                values = mapping(unpack(raw, limits), duplicate_last=True)
                maps[name] = (values, raw)
                offsets[name + "MessagePack"] = block["offset"] + local_offset
            if custom_reader.offset != len(block["raw"]):
                diagnostics.append("custom-trailing-bytes-preserved")
            face, body, hair = (maps[name][0] for name in ("face", "body", "hair"))
            custom = {"faceVersion": field(face, "version", "str"), "bodyVersion": field(body, "version", "str"),
                      "hairVersion": field(hair, "version", "str"), "headId": field(face, "headId", "int"),
                      "shapeValueFace": shape_values(face.get("shapeValueFace", Node("nil", None, 0, 0)), 52),
                      "shapeValueBody": shape_values(body.get("shapeValueBody", Node("nil", None, 0, 0)), 44)}
    if "Parameter" in by_name:
        block = by_name["Parameter"]
        if block["version"] != VERSIONS["Parameter"]:
            diagnostics.append("unsupported-parameter-version")
        else:
            values = mapping(unpack(block["raw"], limits), duplicate_last=True)
            parameter = {"version": field(values, "version", "str"), "sex": field(values, "sex", "int")}
            if not 0 <= parameter["sex"] <= 255:
                raise ValueError("Parameter sex exceeds byte range")
            for key in ("firstname", "lastname", "nickname"):
                if key in values and values[key].kind == "str":
                    parameter[key] = values[key].value
    selected, plugins, current = "none", [], by_name.get("KKEx")
    if current is not None:
        if current["version"] != "3":
            diagnostics.append("unsupported-current-kkex-version")
        else:
            # Match the hook's unusual end-minus-sizes base, not guessed payloadStart.
            hook_offset = offsets["payloadEnd"] - sum(block["size"] for block in blocks) + current["pos"]
            offsets["currentExtendedData"] = hook_offset
            if hook_offset < 0:
                diagnostics.append("current-kkex-hook-range-invalid")
            else:
                try:
                    # BinaryReader.ReadBytes uses the complete stream, can cross
                    # the declared payload boundary, and returns fewer bytes at
                    # EOF. The complete input was bounded before this seek.
                    plugins = parse_plugins(data[hook_offset:hook_offset + current["size"]], hook_offset, limits)
                    selected = "current-v3"
                except ValueError:
                    diagnostics.append("current-kkex-invalid-preserved")
    legacy = None
    if reader.offset < len(data):
        original_end = reader.offset
        try:
            marker, legacy_version = reader.dotnet_string(), reader.number("<i")
            if marker == "KKEx" and legacy_version == 2:
                count = reader.number("<i")
                if not 0 < count <= limits.payload_bytes:
                    raise ValueError("Legacy extension count exceeds bound")
                legacy_offset = reader.offset
                # The source uses ReadBytes, which returns available bytes at EOF.
                raw = reader.take(min(count, len(data) - reader.offset))
                replacement = parse_plugins(raw, legacy_offset, limits)
                legacy = {"offset": original_end, "payloadOffset": legacy_offset,
                          "size": len(raw), "declaredSize": count, "sha256": sha(raw)}
                offsets["legacyStart"], offsets["legacyExtendedData"] = original_end, legacy_offset
                plugins, selected = replacement, "legacy-v2"
            else:
                reader.offset = original_end
        except (ValueError, UnicodeError):
            diagnostics.append("unparsed-footer-preserved")
            reader.offset = original_end
    footer = data[reader.offset:]
    if footer:
        diagnostics.append("unknown-footer-preserved")
    report = {"schemaVersion": 1, "kind": "koikatsu-character-card-oracle", "sha256": sha(data), "bytes": len(data),
              "productNo": product, "magic": MAGIC, "version": version, "offsets": offsets,
              "pngBytes": png_size, "facePngBytes": face_size, "facePngSHA256": sha(face_png),
              "headerBytes": header_size, "headerSHA256": sha(header_raw), "payloadBytes": payload_size,
              "blocks": [{**{k: v for k, v in b.items() if k != "raw"}, "sha256": sha(b["raw"])} for b in blocks],
              "custom": custom, "parameter": parameter, "extendedDataSource": selected, "legacy": legacy,
              "plugins": [], "footer": {"offset": reader.offset, "size": len(footer), "sha256": sha(footer)},
              "diagnostics": diagnostics}
    for item in plugins:
        report["plugins"].append({**{k: v for k, v in item.items() if k not in ("raw", "binaryValues", "dataNodes")},
                                  "sha256": sha(item["raw"]), "binaryValues": {
                                      key: {k: v for k, v in value.items() if k != "raw"}
                                      for key, value in item["binaryValues"].items()}})
    return ParsedCard(data, blocks, plugins, footer, report)


def dotnet_string(value: str) -> bytes:
    data, length = value.encode("utf-8"), len(value.encode("utf-8"))
    prefix = bytearray()
    while length >= 128:
        prefix.append((length & 127) | 128)
        length >>= 7
    return bytes(prefix + bytes([length])) + data


def blank_png() -> bytes:
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
    return PNG + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 6, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(b"\0\0\0\0\0")) + chunk(b"IEND", b"")


def fixture_bytes(bone_data: bytes, *, current: bool = True, legacy: bool = False,
                  footer: bytes = b"", png: bool = True) -> bytes:
    import msgpack
    pack = lambda value: msgpack.packb(value, use_bin_type=True, use_single_float=True)
    face = {"version": VERSIONS["face"], "headId": 0, "shapeValueFace": [i / 51 for i in range(52)],
            "syntheticUnknownFaceField": b"preserve-face-field"}
    body = {"version": VERSIONS["body"], "shapeValueBody": [i / 43 for i in range(44)]}
    hair = {"version": VERSIONS["hair"], "syntheticHairMarker": "preserved"}
    custom = b"".join(struct.pack("<i", len(raw)) + raw for raw in map(pack, (face, body, hair)))
    blocks = [("Custom", VERSIONS["Custom"], custom), ("Coordinate", VERSIONS["Coordinate"], pack([])),
              ("Parameter", VERSIONS["Parameter"], pack({"version": VERSIONS["Parameter"], "sex": 1,
                  "firstname": "Synthetic", "lastname": "Fixture", "nickname": "Test"})),
              ("Status", VERSIONS["Status"], pack({"version": VERSIONS["Status"]}))]
    def plugins(origin):
        return {ABMX: [2, {"boneData": bone_data}], "example.unknown": [7, {"origin": origin, "opaque": b"\x00\xffunknown\x00"}]}
    if current:
        blocks.append(("KKEx", "3", pack(plugins("current"))))
    blocks.append(("FixtureUnknown", "9.2", b"\x00opaque unknown block\xff"))
    infos, payload = [], bytearray()
    for name, version, raw in blocks:
        infos.append({"name": name, "version": version, "pos": len(payload), "size": len(raw)})
        payload.extend(raw)
    # The installed hook inserts its header entry before the base save loop.
    infos.sort(key=lambda info: info["name"] != "KKEx")
    header = pack({"lstInfo": infos})
    output = (blank_png() if png else b"") + struct.pack("<i", 100) + dotnet_string(MAGIC) + dotnet_string(VERSIONS["card"])
    output += struct.pack("<i", 0) + struct.pack("<i", len(header)) + header + struct.pack("<q", len(payload)) + payload
    if legacy:
        raw = pack(plugins("legacy"))
        output += dotnet_string("KKEx") + struct.pack("<ii", 2, len(raw)) + raw
    return bytes(output) + footer


def evidence() -> dict:
    paths = [".local/reverse/mods/source/BepInEx/plugins/KK_BepisPlugins/ExtensibleSaveFormat.dll",
             ".local/reverse/source/Koikatu_Data/Managed/Assembly-CSharp.dll",
             ".local/reverse/managed/CharaStudio/Assembly-CSharp-firstpass.dll",
             ".local/reverse/decompiled/Character/Koikatu/ChaFile.cs", ".local/reverse/decompiled/Character/Koikatu/BlockHeader.cs",
             ".local/reverse/decompiled/Character/Koikatu/ChaFileCustom.cs", ".local/reverse/decompiled/Character/Koikatu/ChaFileDefine.cs",
             ".local/reverse/cards/decompiled/ExtensibleSaveFormat.ExtendedSave.decompiled.cs",
             ".local/reverse/cards/decompiled/ExtensibleSaveFormat.PluginData.decompiled.cs",
             ".local/reverse/cards/decompiled/MessagePack.Formatters.VersionFormatter.decompiled.cs",
             ".local/reverse/cards/decompiled/MessagePack.Internal.DynamicObjectTypeBuilder.decompiled.cs",
             ".local/reverse/cards/decompiled/ChaFileParameter.decompiled.cs", ".local/reverse/cards/decompiled/PngFile.decompiled.cs"]
    return {"schemaVersion": 1, "kind": "koikatsu-character-card-contract", "productNo": 100, "magic": MAGIC,
            "versions": VERSIONS, "endianness": "little-endian for BinaryWriter integers; MessagePack uses its own encoding",
            "baseFraming": ["optional PNG through IEND+CRC", "i32 productNo", ".NET 7-bit UTF8 magic", ".NET 7-bit UTF8 version",
                            "i32 facePngBytes + raw", "i32 headerBytes + MessagePack map{lstInfo:[{name,version,pos,size}]}",
                            "i64 totalPayloadBytes", "raw block payload"],
            "customFraming": ["i32 faceSize + MessagePack map", "i32 bodySize + MessagePack map", "i32 hairSize + MessagePack map"],
            "currentExtendedData": {"blockName": "KKEx", "blockVersion": "3", "compression": "none",
                "hookOffset": "payloadEnd - sum(all header sizes) + first KKEx.pos",
                "headerOrder": "KKEx before base entries; its bytes follow base bytes"},
            "legacyExtendedData": {"marker": "KKEx", "version": 2, "framing": ".NET string + i32 version + i32 positive size + raw MessagePack",
                                   "precedence": "successful legacy v2 replaces current v3 plugin dictionary"},
            "pluginData": {"encoding": "map<string,array[version:Int32,data:map<string,object>|nil] | nil>",
                           "missingSlots": "version defaults to0; data defaults to null even though constructor initializes dictionary",
                           "trailingSlots": "skipped", "duplicateDictionaryKeys": "source Dictionary.Add throws",
                           "nullEntries": "accepted on read; removed from dictionary before source save"},
            "abmx": {"id": ABMX, "version": 2, "field": "boneData", "type": "MessagePack binary; nested ABMX raw/LZ4 extension99"},
            "bounds": Limits().__dict__, "evidence": [{"path": path, "sha256": sha((REPO / path).read_bytes())} for path in paths],
            "scope": "Static framing and selected field extraction only; no plugin execution, full character application or source-compatible writer."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--card", type=Path, help="Explicit card to parse without rendering")
    parser.add_argument("--output", type=Path, default=REPO / ".local/reverse/cards")
    args = parser.parse_args()
    output = args.output.resolve()
    if not output.is_relative_to(REPO / ".local"):
        parser.error("Evidence output must remain under ignored .local")
    output.mkdir(parents=True, exist_ok=True)
    if args.card:
        with args.card.open("rb") as stream:
            card = parse_card(stream.read(Limits().card_bytes + 1))
        (output / "card-report.json").write_text(json.dumps(card.report, ensure_ascii=False, allow_nan=False, indent=2) + "\n")
        print(json.dumps({"report": str(output / "card-report.json"), "sha256": card.report["sha256"]}))
        return
    bone_data = (REPO / ".local/reverse/mods/abmx/synthetic.boneData.bin").read_bytes()
    cases = [("current", {}), ("legacy", {"current": False, "legacy": True}),
             ("precedence", {"legacy": True}), ("unknown-footer", {"footer": b"fixture opaque footer\x00\xff"}),
             ("without-png", {"png": False}),
             ("broken-legacy", {"footer": dotnet_string("KKEx") + struct.pack("<ii", 2, 1) + b"\xc1"})]
    fixtures = []
    for name, options in cases:
        data = fixture_bytes(bone_data, **options)
        path = output / ("synthetic-" + name + ".png")
        path.write_bytes(data)
        report = parse_card(data).report
        (output / ("synthetic-" + name + ".json")).write_text(json.dumps(report, ensure_ascii=False, allow_nan=False, indent=2) + "\n")
        fixtures.append({"name": name, "path": str(path.relative_to(REPO)), "sha256": sha(data), "bytes": len(data),
                         "oracle": str((output / ("synthetic-" + name + ".json")).relative_to(REPO))})
    contract = evidence()
    contract["fixtures"] = fixtures
    (output / "contract.json").write_text(json.dumps(contract, ensure_ascii=False, allow_nan=False, indent=2) + "\n")
    print(json.dumps({"contract": str(output / "contract.json"), "fixtures": fixtures}, indent=2))


if __name__ == "__main__":
    main()
