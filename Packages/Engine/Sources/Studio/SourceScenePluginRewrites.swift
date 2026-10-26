import Foundation
import Character
import Assets

// ST-T03i PR 2: rewrites of the positional and item-keyed plug-in data that
// PR 1 refused (KKPE, MaterialEditor, NodesConstraints). Each plan reads its
// entry strictly, refuses a form or an edit its recovered rule does not
// cover with the plug-in's reason, writes what CharaStudio's save writes
// after the same edit, and keeps every byte it does not change. The rules
// and their sources are in docs/reference/studio/scene-editing.md,
// "Plug-in data rewrites".

// MARK: - XML as XmlTextWriter writes it

/// Plug-in scene XML in the form .NET's `XmlTextWriter` writes with its
/// default settings (no formatting): one root element, elements with
/// double-quoted attributes, `<name a="v">` and `<name a="v" />` with single
/// spaces, end tags `</name>`, and no text, whitespace, comments,
/// declarations or processing instructions. KKPE (HSPE `MainWindow`
/// `OnSceneSave`/`OnCharaSave`, `PoseController.SaveXml` and its modules) and
/// NodesConstraints (`OnSceneSave`) write only attributes and elements.
/// Anything else is a form this writer does not read.
struct PluginXML {
    struct Failure: Error { let reason: String }
    struct Attribute { let name: String; let value: Range<Int> }
    struct Element {
        let name: String
        /// The start tag's `<`, the end of its attributes (where `>` or
        /// ` />` begins), the end of the start tag, and the element's end.
        let start: Int, attributesEnd: Int, headEnd: Int
        var end: Int
        let selfClosing: Bool
        let attributes: [Attribute]
        let parent: Int?
        var children: [Int] = []
    }
    let bytes: [UInt8]
    /// In document order; the root is element 0.
    private(set) var elements: [Element] = []

    init(_ bytes: [UInt8]) throws {
        self.bytes = bytes
        var offset = 0, open: [Int] = []
        func fail(_ what: String) -> Failure { Failure(reason: "\(what) at byte \(offset)") }
        func isNameStart(_ byte: UInt8) -> Bool {
            (byte >= 0x41 && byte <= 0x5a) || (byte >= 0x61 && byte <= 0x7a) || byte == 0x5f
        }
        func isName(_ byte: UInt8) -> Bool {
            isNameStart(byte) || (byte >= 0x30 && byte <= 0x39) || byte == 0x2d || byte == 0x2e || byte == 0x3a
        }
        func name() throws -> String {
            let start = offset
            guard offset < bytes.count, isNameStart(bytes[offset]) else { throw fail("a missing name") }
            offset += 1
            while offset < bytes.count, isName(bytes[offset]) { offset += 1 }
            return String(decoding: bytes[start..<offset], as: UTF8.self)
        }
        guard !bytes.isEmpty else { throw Failure(reason: "it is empty") }
        while offset < bytes.count {
            guard bytes[offset] == 0x3c else { throw fail("text outside a tag") }
            offset += 1
            guard offset < bytes.count else { throw fail("a truncated tag") }
            if bytes[offset] == 0x2f {
                offset += 1
                let name = try name()
                guard offset < bytes.count, bytes[offset] == 0x3e else { throw fail("a malformed end tag") }
                offset += 1
                guard let index = open.popLast(), elements[index].name == name else { throw fail("an unmatched end tag") }
                elements[index].end = offset
                continue
            }
            guard !open.isEmpty || elements.isEmpty else { throw fail("a second root element") }
            let start = offset - 1
            let elementName = try name()
            var attributes: [Attribute] = []
            while offset + 1 < bytes.count, bytes[offset] == 0x20, isNameStart(bytes[offset + 1]) {
                offset += 1
                let attributeName = try name()
                guard offset + 1 < bytes.count, bytes[offset] == 0x3d, bytes[offset + 1] == 0x22 else {
                    throw fail("an attribute that is not name=\"value\"")
                }
                offset += 2
                let valueStart = offset
                while offset < bytes.count, bytes[offset] != 0x22 {
                    guard bytes[offset] != 0x3c else { throw fail("'<' in an attribute value") }
                    offset += 1
                }
                guard offset < bytes.count else { throw fail("an unterminated attribute value") }
                guard !attributes.contains(where: { $0.name == attributeName }) else { throw fail("a repeated attribute") }
                attributes.append(Attribute(name: attributeName, value: valueStart..<offset))
                offset += 1
            }
            let attributesEnd = offset
            let selfClosing: Bool
            if bytes.count - offset >= 3, bytes[offset] == 0x20, bytes[offset + 1] == 0x2f, bytes[offset + 2] == 0x3e {
                selfClosing = true; offset += 3
            } else if offset < bytes.count, bytes[offset] == 0x3e {
                selfClosing = false; offset += 1
            } else {
                throw fail("a malformed start tag")
            }
            let index = elements.count
            elements.append(Element(name: elementName, start: start, attributesEnd: attributesEnd, headEnd: offset, end: offset,
                                    selfClosing: selfClosing, attributes: attributes, parent: open.last))
            if let parent = open.last { elements[parent].children.append(index) }
            if !selfClosing { open.append(index) }
            guard open.count <= 256, elements.count <= 1_000_000 else { throw fail("more nesting or elements than this writer reads") }
        }
        guard open.isEmpty else { throw Failure(reason: "it ends inside an element") }
    }

    func attribute(_ element: Int, _ name: String) -> Range<Int>? {
        elements[element].attributes.first { $0.name == name }?.value
    }

    /// An attribute holding `XmlConvert.ToString(int)`: nil when absent, a
    /// failure when not canonical (`-?[0-9]+`, no leading zero, no "-0").
    func integer(_ element: Int, _ name: String) throws -> Int32? {
        guard let range = attribute(element, name) else { return nil }
        guard let value = Self.int32(bytes[range]) else {
            throw Failure(reason: "\(elements[element].name) has a \(name) that is not a canonical Int32")
        }
        return value
    }

    static func int32(_ text: ArraySlice<UInt8>) -> Int32? {
        var index = text.startIndex, negative = false
        if index < text.endIndex, text[index] == 0x2d { negative = true; index += 1 }
        guard index < text.endIndex else { return nil }
        if text[index] == 0x30 { return text.endIndex - index == 1 && !negative ? 0 : nil }
        var value: Int64 = 0
        for byte in text[index...] {
            guard byte >= 0x30, byte <= 0x39 else { return nil }
            value = value * 10 + Int64(byte - 0x30)
            guard value <= 2_147_483_648 else { return nil }
        }
        return Int32(exactly: negative ? -value : value)
    }

    /// What a rendering changes: elements left out, and elements whose
    /// children are replaced by a list of (element, attribute patches).
    struct Rendering {
        var removed = Set<Int>()
        var children: [Int: [(element: Int, patches: [Int: [UInt8]])]] = [:]
        fileprivate var touched = Set<Int>()

        /// Marks every element with a change inside it.
        mutating func prepare(_ document: PluginXML) {
            touched = []
            for index in Array(removed) + Array(children.keys) {
                var current = document.elements[index].parent
                if children[index] != nil { touched.insert(index) }
                while let parent = current, touched.insert(parent).inserted { current = document.elements[parent].parent }
            }
        }
    }

    /// Element `index` as XmlTextWriter would write it after `rendering`:
    /// its own bytes when nothing in it changes; otherwise its start tag with
    /// `patches` (new attribute values by value offset), then its children,
    /// and ` />` when none is left.
    func render(_ index: Int, _ patches: [Int: [UInt8]] = [:], _ rendering: Rendering, into out: inout [UInt8]) {
        let element = elements[index]
        if patches.isEmpty, !rendering.touched.contains(index) { out += bytes[element.start..<element.end]; return }
        var cursor = element.start
        for attribute in element.attributes {
            guard let value = patches[attribute.value.lowerBound] else { continue }
            out += bytes[cursor..<attribute.value.lowerBound]
            out += value
            cursor = attribute.value.upperBound
        }
        out += bytes[cursor..<element.attributesEnd]
        let children = rendering.children[index]
            ?? element.children.filter { !rendering.removed.contains($0) }.map { (element: $0, patches: [Int: [UInt8]]()) }
        if children.isEmpty { out += [0x20, 0x2f, 0x3e]; return }
        out.append(0x3e)
        for child in children { render(child.element, child.patches, rendering, into: &out) }
        out += [0x3c, 0x2f] + Array(element.name.utf8) + [0x3e]
    }

    /// Element `a` here and element `b` of `other` have the same name,
    /// attributes (names and value bytes, apart from `ignoring` on these two
    /// elements) and children, `other`'s children in `skipping` left out.
    func same(_ a: Int, as b: Int, in other: PluginXML, ignoring: Set<String> = [], skipping: Set<Int> = []) -> Bool {
        let left = elements[a], right = other.elements[b]
        guard left.name == right.name else { return false }
        let leftAttributes = left.attributes.filter { !ignoring.contains($0.name) }
        let rightAttributes = right.attributes.filter { !ignoring.contains($0.name) }
        guard leftAttributes.count == rightAttributes.count else { return false }
        for (x, y) in zip(leftAttributes, rightAttributes) {
            guard x.name == y.name, bytes[x.value].elementsEqual(other.bytes[y.value]) else { return false }
        }
        let rightChildren = right.children.filter { !skipping.contains($0) }
        guard left.children.count == rightChildren.count else { return false }
        return zip(left.children, rightChildren).allSatisfy { same($0, as: $1, in: other, skipping: skipping) }
    }
}

/// A plug-in entry `[version, {key: string}]` whose one field is an XML
/// string: the field and the string's bytes.
private func xmlField(_ trailer: SourceSceneKKEx, _ entry: SourceSceneKKEx.Entry, key: String) throws -> (field: SourceMessagePackSpans.Field, text: Range<Int>)? {
    guard let data = entry.data, data.upperBound == entry.value.upperBound,
          let fields = try trailer.fields(entry), fields.count == 1, fields[0].key == key,
          fields[0].value.upperBound == data.upperBound else { return nil }
    var cursor = SourceMessagePackSpans(trailer.bytes, range: fields[0].value)
    guard case .string(let count) = try cursor.head() else { return nil }
    let text = try cursor.payload(count)
    guard cursor.offset == fields[0].value.upperBound else { return nil }
    return (fields[0], text)
}

/// The entry's value with its one XML field replaced by `xml`.
private func xmlValue(_ trailer: SourceSceneKKEx, _ entry: SourceSceneKKEx.Entry, _ field: SourceMessagePackSpans.Field, _ xml: [UInt8]) -> [UInt8] {
    var value = Array(trailer.bytes[entry.value.lowerBound..<field.value.lowerBound])
    SourceMessagePackWriter.header(.string, count: xml.count, into: &value)
    value += xml
    return value
}

private func failure(_ reason: String) -> SourceScenePluginData.RuleFailure { .init(reason: reason) }

extension SourceScenePluginData {
    /// A rule's refusal reason, after the plug-in's label.
    struct RuleFailure: Error { let reason: String }
}

// MARK: - KKPE

/// KKPE (HSPE 2.21.4, `com.joan6694.illusionplugins.kkposeeditor`):
///
/// - Scene: `MainWindow.OnSceneSave` (MainWindow.cs:1585-1608) writes
///   `{"sceneInfo": "<root version=…>"}` with one `itemInfo` per item of the
///   key-sorted `dicObjectCtrl`, carrying `name`, `index` (the key) and its
///   controller's state (`PoseController.SaveXml`, PoseController.cs:409,
///   `uniqueId` = the controller's instance ID). `LoadSceneGeneric`
///   (:1554-1583) loads the i-th `itemInfo` onto the i-th item and ignores
///   `index`: positional.
/// - Cards: each character's controller state is the card's `kkpe`
///   `characterInfo` (`OnCharaSave`, :1484-1504), not scene data.
/// - References: a lone collider (an item named "Collider",
///   CollidersEditor.cs:561-575) names the dynamic bones it acts on by
///   their controller's saved `uniqueId` (`dynamicBoneData`/`dynamicBoneData2`
///   `poseControllerId`, :1036-1050), resolved on load by equality only
///   (:1128-1185; `_lastLoadId` is never assigned, so always 0).
///
/// After a delete CharaStudio writes no element for the deleted items and no
/// reference to a deleted controller (lone colliders drop them in `Update`,
/// :615-657; other colliders skip a destroyed bone at save). A copied item
/// gets its template's element (`Studio_Duplicate_Patches` → `OnDuplicate`
/// → `LoadFrom`; references are not remapped, ColliderDataBase :274-291)
/// under its own key and controller ID; a copied character's card gets its
/// template's `characterInfo` under the copy's controller ID. Every
/// controller with dynamic bones registers them with each lone collider
/// (DynamicBonesEditor.cs:1799, BoobsEditor.cs:401), so a copy of an object
/// a lone collider names gains entries this writer does not write: refused.
///
/// IDs are instance IDs, new in every session; this writer gives each copy
/// a deterministic fresh ID (`freshID`) of the template's length and sign
/// that no `uniqueId` or `poseControllerId` in the scene or its cards uses.
struct KKPEPlan {
    typealias Failure = SourceScenePluginData.RuleFailure
    /// A same-length patch of a copied character's card: the copy's key,
    /// the ID string's offset in the card bytes, the bytes there (the
    /// template's ID) and the copy's ID.
    struct CardPatch { let key: Int32, offset: Int, old: [UInt8], new: [UInt8], id: Int32 }
    /// The controller ID in a character's card and where it lies.
    struct Card { let id: Int32; let offset: Int? }
    struct Planned { let key: Int32, element: Int, id: Int32 }

    static let references: Set<String> = ["dynamicBoneData", "dynamicBoneData2", "ignoredDynamicBone", "ignoredDynamicBone2"]

    let decision: SourceScenePluginData.Plan.Decision
    let cardPatches: [CardPatch]
    /// For the verifier: the source document, the final items' elements in
    /// key order and the references left out.
    let document: PluginXML?
    let planned: [Planned]
    let removed: Set<Int>

    init(trailer: SourceSceneKKEx, entry: SourceSceneKKEx.Entry, edit: SourceScenePluginData.Edit, scene: Data) throws {
        var sourceItems: [Int32] = [], sourceCharacters: [Int32] = []
        for (key, record) in edit.sourceRecords {
            if record.kind == .item { sourceItems.append(key) } else if record.kind == .character { sourceCharacters.append(key) }
        }
        sourceItems.sort(); sourceCharacters.sort()
        var finalItems: [Int32] = [], copies: [(key: Int32, template: Int32)] = []
        for record in edit.finalRecords where record.kind == .item || record.kind == .character {
            guard let origin = edit.origins[record.sourceKey] else {
                if record.kind == .item {
                    throw failure("matches its pose data to items by their position in key order, and this edit adds an item, for which CharaStudio writes pose data this writer does not")
                }
                continue
            }
            if record.kind == .item { finalItems.append(record.sourceKey) }
            if origin != record.sourceKey { copies.append((record.sourceKey, origin)) }
        }
        finalItems.sort(); copies.sort { $0.key < $1.key }
        let deletedItems = sourceItems.filter(edit.deletedKeys.contains)
        let deletedCharacters = sourceCharacters.filter(edit.deletedKeys.contains)
        let itemCopied = copies.contains { edit.sourceRecords[$0.template]?.kind == .item }
        guard let found = try xmlField(trailer, entry, key: "sceneInfo") else {
            throw failure("has data other than one 'sceneInfo' XML string, which this writer does not read")
        }
        let (field, text) = found
        let xml = Array(trailer.bytes[text])
        let names = Self.contains(xml, Array("poseControllerId".utf8))
        // IDs a copy's new ID avoids: every one in the source scene (its
        // KKPE XML and every card), and those read below.
        var used = Self.ids(in: scene)
        func card(_ key: Int32) throws -> Card? {
            guard let data = edit.sourceRecords[key]?.character?.cardData else { return nil }
            return try Self.card(data, key: key)
        }
        func freshID(_ template: Int32, of key: Int32, referenced: Set<Int32>) throws -> Int32 {
            if referenced.contains(template) {
                throw failure("registers a copy's dynamic bones with every lone collider, and a lone collider names those of object \(key), so CharaStudio would add entries for its copy that this writer does not write")
            }
            guard let fresh = Self.freshID(template, avoiding: used) else {
                throw failure("has no free controller ID of the length of \(template) for the copy of object \(key)")
            }
            used.insert(fresh)
            return fresh
        }
        /// A copied character's card patch: its template's controller ID
        /// replaced by a fresh one. Nil when the card has no KKPE data.
        func characterPatch(_ copy: (key: Int32, template: Int32), referenced: Set<Int32>) throws -> CardPatch? {
            guard let read = try card(copy.template) else { return nil }
            let fresh = try freshID(read.id, of: copy.template, referenced: referenced)
            guard let offset = read.offset else {
                throw failure("keeps character \(copy.template)'s pose data in a card whose Extended Save is not the current block, which this writer does not patch")
            }
            return CardPatch(key: copy.key, offset: offset, old: Array(String(read.id).utf8), new: Array(String(fresh).utf8), id: fresh)
        }
        // No item's position changes and no reference can lose or gain a
        // controller: the XML stays as it is; copied characters' cards get
        // fresh IDs.
        if deletedItems.isEmpty, !itemCopied, !names || (deletedCharacters.isEmpty && copies.isEmpty) {
            var patches: [CardPatch] = []
            for copy in copies { if let patch = try characterPatch(copy, referenced: []) { patches.append(patch) } }
            decision = .keep; cardPatches = patches; document = nil; planned = []; removed = []; return
        }
        let document: PluginXML
        do { document = try PluginXML(xml) } catch let error as PluginXML.Failure {
            throw failure("has pose data that is not in the XML form KKPE writes (\(error.reason))")
        }
        guard document.elements[0].name == "root", document.attribute(0, "version") != nil else {
            throw failure("has pose data whose root is not KKPE's <root version=…>")
        }
        let elements = document.elements[0].children
        guard elements.allSatisfy({ document.elements[$0].name == "itemInfo" }) else {
            throw failure("has pose data with an element other than itemInfo under its root")
        }
        guard elements.count == sourceItems.count else {
            throw failure("has \(elements.count) item pose entries for the scene's \(sourceItems.count) items, so they do not load one to one")
        }
        var elementOf: [Int32: Int] = [:], idOf: [Int32: Int32] = [:]
        do {
            for (element, key) in zip(elements, sourceItems) {
                guard try document.integer(element, "index") == key else {
                    throw failure("has an item pose entry whose index is not item \(key), the item at its position in key order")
                }
                guard let id = try document.integer(element, "uniqueId"), id != 0 else {
                    throw failure("has the pose entry of item \(key) without a controller ID (uniqueId)")
                }
                elementOf[key] = element; idOf[key] = id
            }
        } catch let error as PluginXML.Failure { throw failure("has pose data KKPE does not write (\(error.reason))") }
        var referenceIDs: [Int: Int32] = [:]
        for (index, element) in document.elements.enumerated() where Self.references.contains(element.name) {
            guard let id = try? document.integer(index, "poseControllerId"), id != 0 else {
                throw failure("has a dynamic bone reference (\(element.name)) without a canonical non-zero poseControllerId")
            }
            referenceIDs[index] = id
        }
        let referenced = Set(referenceIDs.values)
        used.formUnion(idOf.values); used.formUnion(referenced)
        // Deletes: the deleted controllers' IDs, to drop their references.
        var removedIDs = Set(deletedItems.compactMap { idOf[$0] })
        if !referenced.isEmpty {
            for key in deletedCharacters { if let id = try card(key)?.id { removedIDs.insert(id) } }
            let dropped = removedIDs.intersection(referenced)
            if !dropped.isEmpty {
                var owners: [Int32: Int] = [:]
                for id in idOf.values { owners[id, default: 0] += 1 }
                for key in sourceCharacters { if let id = try card(key)?.id { owners[id, default: 0] += 1 } }
                if let shared = dropped.sorted().first(where: { owners[$0, default: 0] > 1 }) {
                    throw failure("names the dynamic bones of controller \(shared), an ID more than one object has, so which references CharaStudio drops is not known here")
                }
            }
        }
        // Copies: each gets its template's data under a fresh ID, in key order.
        if edit.deleted, itemCopied {
            throw failure("writes each item's key and matches pose data to items by position, and this edit both deletes objects and copies items, so the copies' keys can differ from CharaStudio's")
        }
        var patches: [Int32: [Int: [UInt8]]] = [:], cardPatches: [CardPatch] = [], ids: [Int32: Int32] = [:]
        for copy in copies {
            guard edit.sourceRecords[copy.template]?.kind == .item else {
                if let patch = try characterPatch(copy, referenced: referenced) { cardPatches.append(patch) }
                continue
            }
            let element = elementOf[copy.template]!
            let fresh = try freshID(idOf[copy.template]!, of: copy.template, referenced: referenced)
            patches[copy.key] = [document.attribute(element, "index")!.lowerBound: Array(String(copy.key).utf8),
                                 document.attribute(element, "uniqueId")!.lowerBound: Array(String(fresh).utf8)]
            ids[copy.key] = fresh
        }
        var rendering = PluginXML.Rendering()
        for key in deletedItems { rendering.removed.insert(elementOf[key]!) }
        for (element, id) in referenceIDs where removedIDs.contains(id) { rendering.removed.insert(element) }
        var planned: [Planned] = []
        rendering.children[0] = finalItems.map { key in
            let origin = edit.origins[key]!
            planned.append(Planned(key: key, element: elementOf[origin]!, id: ids[key] ?? idOf[origin]!))
            return (element: elementOf[origin]!, patches: patches[key] ?? [:])
        }
        rendering.prepare(document)
        var out: [UInt8] = []
        out.reserveCapacity(xml.count + 64)
        document.render(0, [:], rendering, into: &out)
        decision = out == xml ? .keep : .replace(xmlValue(trailer, entry, field, out))
        self.cardPatches = cardPatches; self.document = document; self.planned = planned; removed = rendering.removed
    }

    /// The rewritten entry holds, per final item in key order, its source
    /// element (its template's for a copy) without the dropped references,
    /// under the planned `index` and `uniqueId`.
    func verify(_ check: SourceSceneKKEx, _ entry: SourceSceneKKEx.Entry) throws {
        guard let document else { return }
        guard let text = try xmlField(check, entry, key: "sceneInfo")?.text else { throw Failure(reason: "no sceneInfo") }
        let written = try PluginXML(Array(check.bytes[text]))
        let children = written.elements[0].children
        // The root's start tag as it was, then the planned items.
        guard written.bytes[0..<written.elements[0].attributesEnd].elementsEqual(document.bytes[0..<document.elements[0].attributesEnd]),
              children.count == planned.count else { throw Failure(reason: "item entries") }
        for (child, plan) in zip(children, planned) {
            guard try written.integer(child, "index") == plan.key, try written.integer(child, "uniqueId") == plan.id,
                  written.same(child, as: plan.element, in: document, ignoring: ["index", "uniqueId"], skipping: removed) else {
                throw Failure(reason: "the entry of item \(plan.key)")
            }
        }
    }

    /// KKPE's `characterInfo` in a character's card (`OnCharaSave`): its
    /// controller ID and, in the current Extended Save block, the ID
    /// string's offset in `data`. Nil when the card holds no KKPE data.
    static func card(_ data: Data, key: Int32) throws -> Card? {
        let extensions: SourceCharacterCard.Extensions
        do { extensions = try SourceCharacterCard.decode(data).extensions() } catch {
            throw failure("cannot read character \(key)'s card (\(error.localizedDescription))")
        }
        guard let payload = extensions.payload else { return nil }
        let bytes = [UInt8](payload)
        let unreadable = failure("has KKPE data in character \(key)'s card in a form this writer does not read")
        do {
            var cursor = SourceMessagePackSpans(bytes, range: 0..<bytes.count)
            guard let entry = try cursor.fields()?.first(where: { $0.key == "kkpe" }) else { return nil }
            var plugin = SourceMessagePackSpans(bytes, range: entry.value)
            let head = try plugin.head()
            if head == .null { return nil }
            guard case .array(2) = head else { throw unreadable }
            try plugin.skip()
            guard let field = try plugin.fields()?.first(where: { $0.key == "characterInfo" }) else { throw unreadable }
            var value = SourceMessagePackSpans(bytes, range: field.value)
            guard case .string(let count) = try value.head() else { throw unreadable }
            let text = try value.payload(count)
            let document = try PluginXML(Array(bytes[text]))
            guard document.elements[0].name == "characterInfo", let range = document.attribute(0, "uniqueId"),
                  let id = try document.integer(0, "uniqueId"), id != 0 else { throw unreadable }
            let offset = extensions.format == "block-v3" ? extensions.payloadRange.map { $0.lowerBound + text.lowerBound + range.lowerBound } : nil
            return Card(id: id, offset: offset)
        } catch let error as SourceScenePluginData.RuleFailure { throw error } catch { throw unreadable }
    }

    /// Every `uniqueId="…"` and `poseControllerId="…"` value in `data` (the
    /// source scene: its KKPE XML and every card's, a superset of the
    /// written scene's), whatever element holds it.
    static func ids(in data: Data) -> Set<Int32> {
        var result = Set<Int32>()
        data.withUnsafeBytes { bytes in
            for marker in ["uniqueId=\"", "poseControllerId=\""].map({ Array($0.utf8) }) {
                var start = 0
                while let found = find(bytes, marker, from: start) {
                    let valueStart = found + marker.count
                    var end = valueStart
                    while end < bytes.count, bytes[end] != 0x22, end - valueStart <= 11 { end += 1 }
                    if end < bytes.count, bytes[end] == 0x22, let value = PluginXML.int32(ArraySlice(bytes[valueStart..<end])) {
                        result.insert(value)
                    }
                    start = valueStart
                }
            }
        }
        return result
    }

    /// A controller ID for a copy of `template`'s controller: the same
    /// number of digits and sign, so the decimal string keeps its length,
    /// not 0 and not in `used`. Tried in order: magnitudes above the
    /// template's up to the largest of its digit count, then below it down
    /// to the smallest. Nil when every one is used.
    static func freshID(_ template: Int32, avoiding used: Set<Int32>) -> Int32? {
        let negative = template < 0
        let magnitude = Int64(template).magnitude
        let digits = String(magnitude).count
        var power: UInt64 = 1
        for _ in 0..<digits { power *= 10 }
        let low: UInt64 = digits == 1 ? 1 : power / 10
        let high = min(power - 1, negative ? UInt64(2_147_483_648) : UInt64(Int32.max))
        func value(_ candidate: UInt64) -> Int32? {
            let signed = negative ? -Int64(candidate) : Int64(candidate)
            guard let id = Int32(exactly: signed), !used.contains(id) else { return nil }
            return id
        }
        var candidate = magnitude
        while candidate < high { candidate += 1; if let id = value(candidate) { return id } }
        candidate = magnitude
        while candidate > low { candidate -= 1; if let id = value(candidate) { return id } }
        return nil
    }

    static func contains(_ bytes: [UInt8], _ needle: [UInt8]) -> Bool {
        bytes.withUnsafeBytes { find($0, needle, from: 0) != nil }
    }

    /// The offset of the first `needle` in `bytes` at or after `start`.
    static func find(_ bytes: UnsafeRawBufferPointer, _ needle: [UInt8], from start: Int) -> Int? {
        guard !needle.isEmpty, let base = bytes.baseAddress, start >= 0, start <= bytes.count - needle.count else { return nil }
        return needle.withUnsafeBytes { pattern -> Int? in
            guard let found = memmem(base + start, bytes.count - start, pattern.baseAddress, pattern.count) else { return nil }
            return base.distance(to: UnsafeRawPointer(found))
        }
    }
}

extension SourceScenePluginData {
    /// Writes each planned card ID into `scene` (bytes up to the end of the
    /// object section and settings) in place, the same number of bytes, and
    /// reads each patched card back.
    static func patchCards(_ scene: inout Data, _ patches: [KKPEPlan.CardPatch]) throws {
        guard !patches.isEmpty else { return }
        func mismatch(_ what: String) -> SourceSceneTopologyError {
            .unsupported("The rewritten KKPE card data differs from its plan (\(what)).")
        }
        var reader = try KoikatsuBinaryReader(scene)
        try reader.skipPNG()
        _ = try reader.string()
        for _ in 0..<(try reader.count()) {
            let key = try reader.int32()
            _ = try reader.object(depth: 0, rootKey: key)
        }
        let cards = reader.editSpans.cards
        for patch in patches {
            guard let span = cards[patch.key] else { throw mismatch("no card for object \(patch.key)") }
            let start = scene.startIndex + span.lowerBound + patch.offset
            let range = start..<(start + patch.old.count)
            guard patch.old.count == patch.new.count, range.upperBound <= scene.startIndex + span.upperBound,
                  scene[range].elementsEqual(patch.old) else { throw mismatch("the card of object \(patch.key)") }
            scene.replaceSubrange(range, with: patch.new)
            let card = scene.subdata(in: (scene.startIndex + span.lowerBound)..<(scene.startIndex + span.upperBound))
            guard try KKPEPlan.card(card, key: patch.key)?.id == patch.id else { throw mismatch("the card of object \(patch.key)") }
        }
    }
}

// MARK: - MaterialEditor

/// MaterialEditor (KK_Plugins `SceneController`, version 1): ten fields,
/// `TextureDictionary` and nine record lists, each nil or bytes. A list is
/// `MessagePackSerializer.Serialize(List<T>)` of string-keyed maps whose
/// `ID` is an item's key (SceneController.cs:20-330). Records of objects that
/// are not loaded items are dropped on load (`ExtractGameObject`, :499-508).
///
/// After a delete (`OnObjectDeleted`, :1041-1062) an item's records are gone.
/// After a copy (`OnObjectsCopied`, :725-855; KKAPI passes each copied
/// item's template key with the copy, in copy order) each list gains, per
/// copy, its template's records with the copy's key, after the existing
/// ones. The save (:378-466) purges textures no record's `TexID` or
/// animation frame uses (`PurgeUnusedTextures`, :469-500), except those
/// Timeline uses, and writes nil for an empty list or dictionary. The
/// Bundled texture form (KKAPI `Scene Save Type`, default Bundled) is an
/// `int → bytes` map (TextureSaveHandler.cs:80-93); Deduped and Local keys
/// are not read here.
struct MaterialEditorPlan {
    typealias Failure = SourceScenePluginData.RuleFailure
    static let recordKeys: [String: Set<String>] = {
        let property: Set<String> = ["ID", "MaterialName", "Property", "Value", "ValueOriginal"]
        return [
            "RendererPropertyList": ["ID", "RendererName", "Property", "Value", "ValueOriginal"],
            "ProjectorPropertyList": ["ID", "ProjectorName", "Property", "Value", "ValueOriginal"],
            "MaterialNamePropertyList": ["ID", "Renderer", "MaterialName", "Value", "ValueOriginal"],
            "MaterialFloatPropertyList": property, "MaterialKeywordPropertyList": property, "MaterialColorPropertyList": property,
            "MaterialTexturePropertyList": ["ID", "MaterialName", "Property", "TexID", "Offset", "OffsetOriginal",
                                            "Scale", "ScaleOriginal", "TexAnimationDef"],
            "MaterialShaderList": ["ID", "MaterialName", "ShaderName", "ShaderNameOriginal", "RenderQueue", "RenderQueueOriginal"],
            "MaterialCopyList": ["ID", "MaterialName", "MaterialCopyName"],
        ]
    }()
    static let textures = "TextureDictionary"

    struct Record {
        let span: Range<Int>
        let id: Int32, idSpan: Range<Int>
        /// Texture IDs the purge keeps: `TexID` and animation frames' `texID`.
        let textures: [Int32]
    }
    struct Texture { let key: Int32; let span: Range<Int> }
    /// A list's planned records: a source record, and the ID it is written with.
    struct Planned { let record: Record; let id: Int32 }

    let decision: SourceScenePluginData.Plan.Decision
    let sourceBytes: [UInt8]
    let plannedLists: [String: [Planned]]
    let keptTextures: [Texture]?

    init(trailer: SourceSceneKKEx, entry: SourceSceneKKEx.Entry, edit: SourceScenePluginData.Edit,
         timelineMentions: (String) -> Bool) throws {
        let bytes = trailer.bytes
        sourceBytes = bytes
        guard let fields = try trailer.fields(entry) else {
            decision = .keep; plannedLists = [:]; keptTextures = nil; return
        }
        var lists: [String: [Record]] = [:], textures: [Texture]?
        for field in fields {
            guard field.key == Self.textures || Self.recordKeys[field.key] != nil else {
                throw failure("has a data key '\(field.key)' this writer does not read (textures saved Deduped or Local, or a newer MaterialEditor)")
            }
            var cursor = SourceMessagePackSpans(bytes, range: field.value)
            let head = try cursor.head()
            if head == .null { continue }
            guard case .binary(let count) = head else { throw failure("has a '\(field.key)' value that is not serialized bytes") }
            let payload = try cursor.payload(count)
            if field.key == Self.textures { textures = try Self.textures(bytes, payload) } else {
                lists[field.key] = try Self.records(bytes, payload, field.key)
            }
        }
        var sourceItems = Set<Int32>()
        for (key, record) in edit.sourceRecords where record.kind == .item { sourceItems.insert(key) }
        var copies: [(key: Int32, template: Int32)] = [], newKeys = Set<Int32>()
        for record in edit.finalRecords {
            let origin = edit.origins[record.sourceKey]
            if origin != record.sourceKey { newKeys.insert(record.sourceKey) }
            if let origin, origin != record.sourceKey, record.kind == .item { copies.append((record.sourceKey, origin)) }
        }
        copies.sort { $0.key < $1.key }
        var named = Set<Int32>()
        for records in lists.values { for record in records { named.insert(record.id) } }
        let stale = named.filter { !sourceItems.contains($0) }
        let copied = copies.filter { named.contains($0.template) }
        guard !named.isDisjoint(with: edit.deletedKeys) || !copied.isEmpty || !stale.isDisjoint(with: newKeys) else {
            decision = .keep; plannedLists = [:]; keptTextures = nil; return
        }
        guard entry.version == 1 else {
            throw failure("has version \(entry.version ?? -1) data, which CharaStudio's save rewrites in its version 1 form; this writer rewrites version 1 only")
        }
        if edit.deleted, !copied.isEmpty {
            throw failure("keys its material edits by item, and this edit both deletes objects and copies items with material edits, so the copies' keys can differ from CharaStudio's")
        }
        // Each list: the records of items still in the scene, then each
        // copy's clones of its template's records.
        var plannedLists: [String: [Planned]] = [:], used = Set<Int32>()
        for (name, records) in lists {
            var planned: [Planned] = []
            for record in records where sourceItems.contains(record.id) && !edit.deletedKeys.contains(record.id) {
                planned.append(Planned(record: record, id: record.id))
            }
            for copy in copies { for record in records where record.id == copy.template { planned.append(Planned(record: record, id: copy.key)) } }
            if name == "MaterialTexturePropertyList" { for plan in planned { used.formUnion(plan.record.textures) } }
            plannedLists[name] = planned
        }
        var keptTextures: [Texture]?
        if let textures {
            let kept = textures.filter { used.contains($0.key) }
            if kept.count != textures.count {
                if timelineMentions("textureProperty") {
                    throw failure("purges textures no item uses on save except those Timeline's texture tracks use, and this scene's Timeline data has texture tracks this writer does not read")
                }
                keptTextures = kept
            }
        }
        self.plannedLists = plannedLists; self.keptTextures = keptTextures
        // The data map, field by field in the source order.
        guard let data = entry.data else { throw failure("has no data map") }
        var map: [UInt8] = []
        SourceMessagePackWriter.header(.map, count: fields.count, into: &map)
        var changed = false
        for field in fields {
            map += bytes[field.entry.lowerBound..<field.value.lowerBound]
            if field.key == Self.textures, let kept = keptTextures {
                changed = true
                guard !kept.isEmpty else { map.append(0xc0); continue }
                var payload: [UInt8] = []
                SourceMessagePackWriter.header(.map, count: kept.count, into: &payload)
                for texture in kept { payload += bytes[texture.span] }
                SourceMessagePackWriter.header(.binary, count: payload.count, into: &map)
                map += payload
                continue
            }
            guard let planned = plannedLists[field.key], let records = lists[field.key],
                  planned.count != records.count || zip(planned, records).contains(where: { $0.record.span != $1.span || $0.id != $1.id }) else {
                map += bytes[field.value]; continue
            }
            changed = true
            guard !planned.isEmpty else { map.append(0xc0); continue }
            var payload: [UInt8] = []
            SourceMessagePackWriter.header(.array, count: planned.count, into: &payload)
            for plan in planned {
                payload += bytes[plan.record.span.lowerBound..<plan.record.idSpan.lowerBound]
                SourceMessagePackWriter.integer(Int64(plan.id), into: &payload)
                payload += bytes[plan.record.idSpan.upperBound..<plan.record.span.upperBound]
            }
            SourceMessagePackWriter.header(.binary, count: payload.count, into: &map)
            map += payload
        }
        guard changed else { decision = .keep; return }
        decision = .replace(Array(bytes[entry.value.lowerBound..<data.lowerBound]) + map)
    }

    /// A list: an array of string-keyed maps with an Int32 `ID`.
    private static func records(_ bytes: [UInt8], _ range: Range<Int>, _ name: String) throws -> [Record] {
        let keys = recordKeys[name]!
        let malformed = failure("has a '\(name)' that is not a list of MaterialEditor records")
        var cursor = SourceMessagePackSpans(bytes, range: range)
        guard case .array(let count) = try cursor.head() else { throw malformed }
        var result: [Record] = []
        for _ in 0..<count {
            let start = cursor.offset
            guard let fields = try cursor.fields() else { throw malformed }
            var id: (Int32, Range<Int>)?, textures: [Int32] = []
            for field in fields {
                guard keys.contains(field.key) else { throw failure("has a '\(name)' record key '\(field.key)' this writer does not know") }
                var value = SourceMessagePackSpans(bytes, range: field.value)
                switch field.key {
                case "ID":
                    guard let number = SourceMessagePackSpans.integer(try value.head()), let key = Int32(exactly: number) else { throw malformed }
                    id = (key, field.value)
                case "TexID":
                    let head = try value.head()
                    if head == .null { continue }
                    guard let number = SourceMessagePackSpans.integer(head), let texture = Int32(exactly: number) else { throw malformed }
                    textures.append(texture)
                case "TexAnimationDef":
                    textures += try animationTextures(bytes, field.value, malformed)
                default: continue
                }
            }
            guard let id else { throw malformed }
            result.append(Record(span: start..<cursor.offset, id: id.0, idSpan: id.1, textures: textures))
        }
        guard cursor.offset == range.upperBound else { throw malformed }
        return result
    }

    /// `MEAnimationDefine` (string-keyed): each `frames` entry's `texID`,
    /// key 0 of `MEAnimationFrame` (an int-keyed array).
    private static func animationTextures(_ bytes: [UInt8], _ range: Range<Int>, _ malformed: Failure) throws -> [Int32] {
        var cursor = SourceMessagePackSpans(bytes, range: range)
        guard let fields = try cursor.fields() else { return [] }
        guard let frames = fields.first(where: { $0.key == "frames" }) else { throw malformed }
        var list = SourceMessagePackSpans(bytes, range: frames.value)
        guard case .array(let count) = try list.head() else { throw malformed }
        var result: [Int32] = []
        for _ in 0..<count {
            guard case .array(let size) = try list.head(), size >= 1,
                  let number = SourceMessagePackSpans.integer(try list.head()), let texture = Int32(exactly: number) else { throw malformed }
            for _ in 1..<max(size, 1) { try list.skip() }
            result.append(texture)
        }
        return result
    }

    /// The Bundled `TextureDictionary`: an `int → bytes` map.
    private static func textures(_ bytes: [UInt8], _ range: Range<Int>) throws -> [Texture] {
        let malformed = failure("has a TextureDictionary that is not MaterialEditor's Bundled int-to-bytes map")
        var cursor = SourceMessagePackSpans(bytes, range: range)
        guard case .map(let count) = try cursor.head() else { throw malformed }
        var result: [Texture] = [], keys = Set<Int32>()
        for _ in 0..<count {
            let start = cursor.offset
            guard let number = SourceMessagePackSpans.integer(try cursor.head()), let key = Int32(exactly: number),
                  keys.insert(key).inserted else { throw malformed }
            guard case .binary(let size) = try cursor.head() else { throw malformed }
            _ = try cursor.payload(size)
            result.append(Texture(key: key, span: start..<cursor.offset))
        }
        guard cursor.offset == range.upperBound else { throw malformed }
        return result
    }

    /// The rewritten entry's lists decode to the planned records (each its
    /// source record with the planned `ID`) and its textures to the kept ones.
    func verify(_ check: SourceSceneKKEx, _ entry: SourceSceneKKEx.Entry) throws {
        guard let fields = try check.fields(entry) else { throw Failure(reason: "no data") }
        for field in fields {
            var cursor = SourceMessagePackSpans(check.bytes, range: field.value)
            let head = try cursor.head()
            if field.key == Self.textures {
                guard let kept = keptTextures else { continue }
                if kept.isEmpty { guard head == .null else { throw Failure(reason: "TextureDictionary") }; continue }
                guard case .binary(let count) = head else { throw Failure(reason: "TextureDictionary") }
                let written = try Self.textures(check.bytes, try cursor.payload(count))
                guard written.count == kept.count,
                      zip(written, kept).allSatisfy({ $0.key == $1.key && check.bytes[$0.span].elementsEqual(sourceBytes[$1.span]) }) else {
                    throw Failure(reason: "TextureDictionary")
                }
                continue
            }
            guard let planned = plannedLists[field.key] else { continue }
            if planned.isEmpty { guard head == .null else { throw Failure(reason: field.key) }; continue }
            guard case .binary(let count) = head else { throw Failure(reason: field.key) }
            let written = try Self.records(check.bytes, try cursor.payload(count), field.key)
            guard written.count == planned.count else { throw Failure(reason: field.key) }
            for (record, plan) in zip(written, planned) {
                var after = try SourceMessagePack.decode(Data(check.bytes[record.span])).stringKeyedMap()
                var before = try SourceMessagePack.decode(Data(sourceBytes[plan.record.span])).stringKeyedMap()
                guard record.id == plan.id else { throw Failure(reason: "\(field.key) record for item \(plan.id)") }
                after["ID"] = nil; before["ID"] = nil
                guard after == before else { throw Failure(reason: "\(field.key) record for item \(plan.id)") }
            }
        }
    }
}

// MARK: - NodesConstraints

/// NodesConstraints 1.6.2.1: `OnSceneSave` (NodesConstraints.cs:2393-2490)
/// writes `{"constraints": "<constraints version=…>"}`, one self-closing
/// `constraint` per entry of `_constraints` in order, whose
/// `parentObjectIndex` (-2: the main camera) and `childObjectIndex` are the
/// owning objects' indices in the key-sorted `dicObjectCtrl` and whose
/// `uniqueLoadId` is its position. `LoadSceneGeneric` (:2141-2258) reads
/// them back by index and skips an index past the end.
///
/// After a delete, a constraint with a deleted end is removed
/// (`ApplyConstraints` → `RemoveConstraintAt`, :1166-1205, :1951-1984) and
/// the others are written with their objects' new indices and positions.
/// After a copy, `Studio_Duplicate_Patches` (:648-734) gives the copies of
/// both ends of each constraint a copy of it, walking `_constraints` in
/// order until the first camera-parented one, where it throws: refused
/// here. AddConstraint (:1874) skips a pair already present in either
/// direction, so repeated pairs are refused too.
struct NodesConstraintsPlan {
    typealias Failure = SourceScenePluginData.RuleFailure
    struct Planned { let element: Int, parent: Int32, child: Int32, load: Int32 }

    let decision: SourceScenePluginData.Plan.Decision
    let document: PluginXML?
    let planned: [Planned]

    init(trailer: SourceSceneKKEx, entry: SourceSceneKKEx.Entry, edit: SourceScenePluginData.Edit,
         timelineMentions: (String) -> Bool) throws {
        guard let found = try xmlField(trailer, entry, key: "constraints") else {
            throw failure("has data other than one 'constraints' XML string, which this writer does not read")
        }
        let (field, text) = found
        let xml = Array(trailer.bytes[text])
        let document: PluginXML
        do { document = try PluginXML(xml) } catch let error as PluginXML.Failure {
            throw failure("has constraints that are not in the XML form NodesConstraints writes (\(error.reason))")
        }
        guard document.elements[0].name == "constraints", document.attribute(0, "version") != nil else {
            throw failure("has constraints whose root is not NodesConstraints' <constraints version=…>")
        }
        let sourceKeys = edit.keys(Array(edit.sourceRecords.values), nil)
        var finalIndex: [Int32: Int32] = [:]
        for (index, key) in edit.keys(edit.finalRecords, nil).enumerated() { finalIndex[key] = Int32(index) }
        struct Constraint { let element: Int, parent: Int32?, child: Int32, load: Int32 }
        var constraints: [Constraint] = [], pairs = Set<String>()
        for element in document.elements[0].children {
            let node = document.elements[element]
            guard node.name == "constraint", node.children.isEmpty else {
                throw failure("has an element other than an empty constraint under its root")
            }
            let parentIndex: Int32, childIndex: Int32, load: Int32
            do {
                guard let parent = try document.integer(element, "parentObjectIndex"), let child = try document.integer(element, "childObjectIndex"),
                      let unique = try document.integer(element, "uniqueLoadId") else {
                    throw failure("has a constraint without parentObjectIndex, childObjectIndex and uniqueLoadId")
                }
                parentIndex = parent; childIndex = child; load = unique
            } catch let error as PluginXML.Failure { throw failure("has constraints NodesConstraints does not write (\(error.reason))") }
            guard parentIndex == -2 || (parentIndex >= 0 && Int(parentIndex) < sourceKeys.count) else {
                throw failure("has a constraint on object index \(parentIndex), which this scene does not have")
            }
            guard childIndex >= 0, Int(childIndex) < sourceKeys.count else {
                throw failure("has a constraint on object index \(childIndex), which this scene does not have")
            }
            // The pair of transforms: each end's object index and path.
            func end(_ index: Int32, _ path: String) -> String {
                let text = document.attribute(element, path).map { String(decoding: document.bytes[$0], as: UTF8.self) }
                return "\(index)\u{0}" + (text.map { "p" + $0 } ?? "-")
            }
            let parentEnd = end(parentIndex, "parentPath"), childEnd = end(childIndex, "childPath")
            guard !pairs.contains(childEnd + "\u{1}" + parentEnd), pairs.insert(parentEnd + "\u{1}" + childEnd).inserted else {
                throw failure("has two constraints between the same transforms, of which NodesConstraints loads only the first")
            }
            constraints.append(Constraint(element: element, parent: parentIndex == -2 ? nil : sourceKeys[Int(parentIndex)],
                                          child: sourceKeys[Int(childIndex)], load: load))
        }
        if edit.copied {
            for constraint in constraints {
                guard let parent = constraint.parent else { break }
                if edit.copiedKeys.contains(parent), edit.copiedKeys.contains(constraint.child) {
                    throw failure("gives the copies of objects \(parent) and \(constraint.child) a copy of their constraint when both are copied, which this writer does not write")
                }
            }
        }
        let kept = constraints.filter { constraint in
            !(constraint.parent.map(edit.deletedKeys.contains) ?? false) && !edit.deletedKeys.contains(constraint.child)
        }
        if edit.deleted, edit.copied, !kept.isEmpty {
            throw failure("addresses objects by their position in key order, and this edit both deletes and copies objects, so the copies' keys, and the positions after them, can differ from CharaStudio's")
        }
        let renumbered = kept.count != constraints.count || kept.enumerated().contains { Int32($0.offset) != $0.element.load }
        if renumbered, timelineMentions("NodesConstraints") {
            throw failure("numbers its constraints by position, and this edit removes or renumbers constraints that this scene's Timeline data may animate by number")
        }
        var rendering = PluginXML.Rendering(), planned: [Planned] = []
        rendering.children[0] = kept.enumerated().map { position, constraint in
            let parent = constraint.parent.map { finalIndex[$0]! } ?? -2
            let child = finalIndex[constraint.child]!, load = Int32(position)
            planned.append(Planned(element: constraint.element, parent: parent, child: child, load: load))
            var patches: [Int: [UInt8]] = [:]
            for (name, value) in [("parentObjectIndex", parent), ("childObjectIndex", child), ("uniqueLoadId", load)] {
                let range = document.attribute(constraint.element, name)!
                if PluginXML.int32(document.bytes[range]) != value { patches[range.lowerBound] = Array(String(value).utf8) }
            }
            return (element: constraint.element, patches: patches)
        }
        rendering.prepare(document)
        var out: [UInt8] = []
        out.reserveCapacity(xml.count)
        document.render(0, [:], rendering, into: &out)
        decision = out == xml ? .keep : .replace(xmlValue(trailer, entry, field, out))
        self.document = document; self.planned = planned
    }

    /// The rewritten entry holds the kept constraints in order, each its
    /// source element with the planned indices and position.
    func verify(_ check: SourceSceneKKEx, _ entry: SourceSceneKKEx.Entry) throws {
        guard let document else { return }
        guard let text = try xmlField(check, entry, key: "constraints")?.text else { throw Failure(reason: "no constraints") }
        let written = try PluginXML(Array(check.bytes[text]))
        let children = written.elements[0].children
        guard written.bytes[0..<written.elements[0].attributesEnd].elementsEqual(document.bytes[0..<document.elements[0].attributesEnd]),
              children.count == planned.count else { throw Failure(reason: "constraint count") }
        let ignoring: Set<String> = ["parentObjectIndex", "childObjectIndex", "uniqueLoadId"]
        for (child, plan) in zip(children, planned) {
            guard try written.integer(child, "parentObjectIndex") == plan.parent, try written.integer(child, "childObjectIndex") == plan.child,
                  try written.integer(child, "uniqueLoadId") == plan.load,
                  written.same(child, as: plan.element, in: document, ignoring: ignoring) else {
                throw Failure(reason: "constraint \(plan.load)")
            }
        }
    }
}
