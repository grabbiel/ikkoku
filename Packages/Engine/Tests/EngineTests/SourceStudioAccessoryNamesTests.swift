import Foundation
import Testing
import Studio

@Test func sourceAccessoryNamesPreserveSlotCountingAndOrdinalNames() {
    typealias Row = SourceStudioAccessoryNamesPlugin.Row
    let rows = [Row(text: nil, buttonX: [100,130,99]), Row(text: "Accessories"), Row(text: "Slot 9"), Row(text: "②"), Row(text: "Arabic ١"), Row(text: "Astral 𝟏"), Row(text: "03", active: false)]
    let result = SourceStudioAccessoryNamesPlugin.update(rows, accessoryNames: [0:"Name e\u{301}", 1:"Second"])
    #expect(result.map(\.text) == [nil,"Accessories","01 Name e\u{301}","②","02 Second","Astral 𝟏","スロット03"])
    #expect(result[0].buttonX == [160,190,99] && result[0].offsetMaxX == nil)
    #expect(result[1].offsetMaxX == 150 && result[1].text == "Accessories")
    #expect(Array(result[2].text!.utf8).suffix(3) == Array("e\u{301}".utf8).suffix(3))
    #expect(SourceStudioAccessoryNamesPlugin.guid == "KK_StudioAccessoryNames" && SourceStudioAccessoryNamesPlugin.version == "1.1.0")
}

@Test func sourceAccessoryNamesMatchUntouchedRecoveredCoroutine() throws {
    guard let path = ProcessInfo.processInfo.environment["IKKOKU_ACCESSORY_NAMES_ORACLE"] else { return }
    struct Case: Decodable { let name: String, rows: [SourceStudioAccessoryNamesPlugin.Row], names: [Int:String] }
    struct Result: Decodable { let name: String, deferred: Bool, completed: Bool, before: [String?], rows: [SourceStudioAccessoryNamesPlugin.Row] }
    struct Oracle: Decodable { let cases: [Case], results: [Result] }
    let oracle = try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    #expect(oracle.cases.count == oracle.results.count)
    for (input, expected) in zip(oracle.cases, oracle.results) {
        #expect(input.name == expected.name && expected.deferred && expected.completed)
        #expect(input.rows.map(\.text) == expected.before)
        #expect(SourceStudioAccessoryNamesPlugin.update(input.rows, accessoryNames: input.names) == expected.rows)
    }
}
