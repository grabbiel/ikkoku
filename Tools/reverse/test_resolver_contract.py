#!/usr/bin/env python3
"""Source resolver wire, selection, lookup and migration oracle regressions."""
import struct
import unittest

from analysis import card_contract as card
from analysis import resolver_contract as resolver


class ResolverContractTests(unittest.TestCase):
    def parse(self, plugins, **kwargs):
        return resolver.extract(card.parse_card(resolver.fixture_card(plugins, **kwargs)))

    def test_current_plugin_raw_blob_hash_and_defaults(self):
        blobs = resolver.fixture_records()
        report = self.parse({resolver.KK_ID: [0, {"info": blobs}]})
        self.assertEqual(report["pluginID"], resolver.KK_ID)
        self.assertEqual(len(report["records"]), 4)
        self.assertEqual(report["records"][0]["sha256"], card.sha(blobs[0]))
        self.assertEqual(report["records"][0]["ModID"], "fixture.pupil")
        self.assertEqual(report["records"][3]["Slot"], 0)
        self.assertIsNone(report["records"][3]["Property"])

    def test_ec_precedence_and_source_ignores_plugin_version(self):
        plugins = {resolver.KK_ID: [0, {"info": resolver.fixture_records()}], resolver.EC_ID: [999, {"info": []}]}
        report = self.parse(plugins)
        self.assertEqual((report["pluginID"], report["pluginVersion"], report["records"]), (resolver.EC_ID, 999, []))

    def test_ec_missing_info_does_not_fall_back(self):
        report = self.parse({resolver.KK_ID: [0, {"info": resolver.fixture_records()}], resolver.EC_ID: [0, {}]})
        self.assertEqual(report["records"], [])
        self.assertEqual(report["diagnostics"], ["selected-plugin-has-no-info-marker"])

    def test_null_ec_falls_back_but_null_data_does_not(self):
        plugins = {resolver.KK_ID: [0, {"info": []}], resolver.EC_ID: None}
        self.assertEqual(self.parse(plugins)["pluginID"], resolver.KK_ID)
        plugins[resolver.EC_ID] = [0, None]
        with self.assertRaisesRegex(ValueError, "data is null"):
            self.parse(plugins)

    def test_legacy_replaces_entire_plugin_dictionary_before_id_selection(self):
        current = {resolver.EC_ID: [0, {"info": resolver.fixture_records()}]}
        legacy = {resolver.KK_ID: [22, {"info": []}]}
        report = self.parse(current, legacy_plugins=legacy)
        self.assertEqual(report["extensionFormat"], "legacy-v2")
        self.assertEqual((report["pluginID"], report["pluginVersion"]), (resolver.KK_ID, 22))

    def test_known_duplicate_keys_last_wins_but_invalid_earlier_still_fails(self):
        raw = b"\x82" + resolver.pack("Slot") + resolver.pack(2) + resolver.pack("Slot") + resolver.pack(7)
        self.assertEqual(resolver.record(raw)["Slot"], 7)
        self.assertEqual(resolver.record(raw)["duplicateKeys"], ["Slot"])
        invalid = b"\x82" + resolver.pack("Slot") + resolver.pack(None) + resolver.pack("Slot") + resolver.pack(7)
        with self.assertRaisesRegex(ValueError, "Int32"):
            resolver.record(invalid)

    def test_source_accepts_trailing_record_bytes_native_strict_rejects(self):
        raw = resolver.pack({"Slot": 7}) + b"\xc1unread"
        self.assertEqual(resolver.record(raw)["trailingBytes"], 7)
        with self.assertRaisesRegex(ValueError, "Trailing"):
            resolver.record(raw, strict=True)

    def test_exact_dotnet_whitespace_trim(self):
        self.assertEqual(resolver.record(resolver.pack({"ModID": "\u0085\u00a0id\u3000"}))["ModID"], "id")
        for char in ("\u200b", "\ufeff", "\x1c"):
            value = char + "id" + char
            self.assertEqual(resolver.record(resolver.pack({"ModID": value}))["ModID"], value)

    def test_bad_record_types_overflows_null_records_and_truncations(self):
        for value in (None, [], 1, {"Slot": None}, {"Slot": True}, {"Slot": 2**31}, {"LocalSlot": -2**31 - 1},
                      {"CategoryNo": 1.0}, {"Property": b"x"}, {None: 1}):
            with self.subTest(value=value), self.assertRaises(ValueError):
                resolver.record(resolver.pack(value))
        raw = resolver.fixture_records()[0]
        for end in range(len(raw)):
            with self.subTest(end=end), self.assertRaises(ValueError):
                resolver.record(raw[:end])

    def test_bad_info_array_and_entries(self):
        for value in (None, b"x", {}, [None], ["x"], [resolver.pack(None)]):
            with self.subTest(value=value), self.assertRaises(ValueError):
                self.parse({resolver.KK_ID: [0, {"info": value}]})

    def test_original_int32_decoder_rejects_64_bit_wire_tokens(self):
        for token in (b"\xcf", b"\xd3"):
            with self.subTest(token=token), self.assertRaisesRegex(ValueError, "Int32"):
                resolver.record(b"\x81" + resolver.pack("Slot") + token + struct.pack(">q", 7))
        raw = b"\x81" + resolver.pack("Slot") + b"\xce" + struct.pack(">I", 7)
        self.assertEqual(resolver.record(raw)["Slot"], 7)

    def test_record_count_and_size_bounds(self):
        with self.assertRaisesRegex(ValueError, "byte bound"):
            resolver.record(b"\x80" + b"x" * resolver.MAX_RECORD_BYTES)
        with self.assertRaisesRegex(ValueError, "bounded array"):
            self.parse({resolver.KK_ID: [0, {"info": [b"\x80"] * (resolver.MAX_RECORDS + 1)}]})

    def test_known_string_byte_bound_before_guid_trimming(self):
        self.assertEqual(resolver.record(resolver.pack({"Name": "x" * 65536}))["Name"], "x" * 65536)
        for fields in ({"Name": "x" * 65537}, {"Property": "\u00e9" * 32769}, {"ModID": " " * 65537}):
            with self.subTest(fields=list(fields)), self.assertRaisesRegex(ValueError, "known-string"):
                resolver.record(resolver.pack(fields))

    def test_current_category_and_first_full_property_win_over_metadata_category(self):
        records = self.parse({resolver.KK_ID: [0, {"info": resolver.fixture_records()}]})["records"]
        target = resolver.destination("ChaFileFace.Pupil1", 408, 500)
        entries = [{"GUID": "fixture.pupil", "Slot": 17, "LocalSlot": 100000001, "CategoryNo": 408, "Property": "ChaFileFace.Pupil1"}]
        result = resolver.direct_resolution(records, [target], entries)[0]
        self.assertEqual(result["status"], "resolved")
        self.assertEqual(result["recordOrdinal"], 0)
        self.assertFalse(result["recordedCategoryMatches"])
        self.assertEqual(result["selected"]["LocalSlot"], 100000001)

    def test_source_guid_and_property_are_case_sensitive_and_first_loaded_wins(self):
        item = resolver.record(resolver.pack({"ModID": "id", "Slot": 17, "Property": "ChaFileFace.Pupil1"}))
        target = resolver.destination(item["Property"], 408, 17)
        entry = {"GUID": "id", "Slot": 17, "CategoryNo": 408, "Property": item["Property"], "LocalSlot": 1}
        loaded = [entry, {**entry, "LocalSlot": 2}]
        self.assertEqual(resolver.direct_resolution([item], [target], loaded)[0]["selected"]["LocalSlot"], 1)
        for replacement in ({"GUID": "ID"}, {"Property": "chafileface.Pupil1"}, {"CategoryNo": 122}, {"Slot": item["LocalSlot"]}):
            self.assertEqual(resolver.direct_resolution([item], [target], [{**entry, **replacement}])[0]["status"], "missing-exact-reference")

    def test_blank_or_absent_marker_requires_compatibility(self):
        target = resolver.destination("ChaFileFace.Pupil1", 408, 3)
        for records in ([], [resolver.record(resolver.pack({"ModID": " ", "Slot": 888, "Property": target["property"]}))]):
            result = resolver.direct_resolution(records, [target], [])[0]
            self.assertEqual(result["status"], "requires-compatibility-resolution")
            self.assertEqual(result["destination"]["sourceSlot"], 3)

    def test_prefixes_keep_coordinate_and_accessory_identity(self):
        target = resolver.destination("outfit12.accessory3.ChaFileAccessory.PartsInfo.id", 122, 1080)
        self.assertEqual((target["coordinateIndex"], target["accessoryIndex"], target["catalogProperty"]), (12, 3, "ChaFileAccessory.PartsInfo.id"))
        standalone = resolver.destination("accessory3.ChaFileAccessory.PartsInfo.id", 122, 1080)
        self.assertIsNone(standalone["coordinateIndex"])
        self.assertEqual(standalone["accessoryIndex"], 3)

    def test_migration_strip_wins_and_specific_uses_recorded_category(self):
        item = resolver.record(resolver.pack({"ModID": "old", "Slot": 17, "CategoryNo": 122}))
        specific = {"MigrationType": "Migrate", "GUIDOld": "old", "GUIDNew": "new", "IDOld": 17, "IDNew": 23, "Category": 122}
        strip = {"MigrationType": "StripAll", "GUIDOld": "old", "GUIDNew": ""}
        self.assertEqual(resolver.migrate_record(item, [specific, strip], {"new"})["ModID"], "")
        migrated = resolver.migrate_record(item, [specific], {"new"})
        self.assertEqual((migrated["ModID"], migrated["Slot"]), ("new", 23))
        self.assertEqual(resolver.migrate_record(item, [{**specific, "Category": 408}], {"new"}), item)

    def test_migration_first_installed_target_and_no_recursive_chain(self):
        item = resolver.record(resolver.pack({"ModID": "old", "Slot": 17, "CategoryNo": 122}))
        rules = [{"MigrationType": "MigrateAll", "GUIDOld": "old", "GUIDNew": "missing"},
                 {"MigrationType": "MigrateAll", "GUIDOld": "old", "GUIDNew": "next"},
                 {"MigrationType": "MigrateAll", "GUIDOld": "next", "GUIDNew": "last"}]
        actual = resolver.migrate_record(item, rules, {"next", "last"})
        self.assertEqual((actual["ModID"], actual["Slot"]), ("next", 17))


if __name__ == "__main__":
    unittest.main()
