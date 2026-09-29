import Foundation
import Testing

@Test func sourceFixtureSupportShouldRunReturnsTrueWhenAllVariablesPresentAndNonempty() {
    let environment = ["IKKOKU_A": "/tmp/a.json", "IKKOKU_B": "/tmp/b.json"]
    #expect(SourceFixtureSupport.shouldRun(["IKKOKU_A", "IKKOKU_B"], environment: environment))
    #expect(SourceFixtureSupport.shouldRun(["IKKOKU_A"], environment: environment))
}

@Test func sourceFixtureSupportShouldRunReturnsFalseWhenAnyVariableMissing() {
    let environment = ["IKKOKU_A": "/tmp/a.json"]
    #expect(!SourceFixtureSupport.shouldRun(["IKKOKU_A", "IKKOKU_B"], environment: environment))
    #expect(!SourceFixtureSupport.shouldRun(["IKKOKU_MISSING"], environment: environment))
}

@Test func sourceFixtureSupportShouldRunReturnsFalseWhenAnyVariableEmpty() {
    let environment = ["IKKOKU_A": "/tmp/a.json", "IKKOKU_B": ""]
    #expect(!SourceFixtureSupport.shouldRun(["IKKOKU_A", "IKKOKU_B"], environment: environment))
    #expect(!SourceFixtureSupport.shouldRun(["IKKOKU_B"], environment: environment))
}

@Test func sourceFixtureSupportShouldRunReturnsTrueInStrictModeEvenWhenVariablesMissing() {
    let environment = ["IKKOKU_REQUIRE_SOURCE_FIXTURES": "1"]
    #expect(SourceFixtureSupport.shouldRun(["IKKOKU_A", "IKKOKU_B"], environment: environment))
    #expect(SourceFixtureSupport.shouldRun([], environment: environment))
}

@Test func sourceFixtureSupportShouldRunReturnsTrueInStrictModeEvenWhenVariablesEmpty() {
    let environment = ["IKKOKU_REQUIRE_SOURCE_FIXTURES": "1", "IKKOKU_A": ""]
    #expect(SourceFixtureSupport.shouldRun(["IKKOKU_A"], environment: environment))
}

@Test func sourceFixtureSupportRequireReturnsValueWhenPresentAndNonempty() throws {
    let environment = ["IKKOKU_A": "/tmp/a.json"]
    #expect(try SourceFixtureSupport.require("IKKOKU_A", environment: environment) == "/tmp/a.json")
}

@Test func sourceFixtureSupportRequireThrowsDescriptiveErrorForMissingVariable() {
    let environment = ["IKKOKU_A": "/tmp/a.json"]
    #expect(throws: SourceFixtureError.missing("IKKOKU_B")) {
        _ = try SourceFixtureSupport.require("IKKOKU_B", environment: environment)
    }
}

@Test func sourceFixtureSupportRequireThrowsDescriptiveErrorForEmptyVariable() {
    let environment = ["IKKOKU_A": ""]
    #expect(throws: SourceFixtureError.missing("IKKOKU_A")) {
        _ = try SourceFixtureSupport.require("IKKOKU_A", environment: environment)
    }
}

@Test func sourceFixtureSupportRequireErrorIdentifiesMissingName() {
    let environment: [String: String] = [:]
    #expect(throws: SourceFixtureError.missing("IKKOKU_ORIGINAL_ANIMATOR_REFERENCE")) {
        _ = try SourceFixtureSupport.require("IKKOKU_ORIGINAL_ANIMATOR_REFERENCE", environment: environment)
    }
}
