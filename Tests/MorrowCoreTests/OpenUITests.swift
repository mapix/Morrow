import XCTest
@testable import MorrowCore

final class OpenUITests: XCTestCase {
    private var fixtures: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/OpenUI") }
    func testParsesPinnedOfficialGrammarStateAndActionInputsWithoutExecutingFunctions() throws {
        let files = try XCTUnwrap(FileManager.default.enumerator(at: fixtures, includingPropertiesForKeys: nil)).compactMap { $0 as? URL }.filter { $0.lastPathComponent == "input.oui" }
        XCTAssertGreaterThan(files.count, 10)
        for file in files { let source = try String(contentsOf: file, encoding: .utf8); XCTAssertNoThrow(try OpenUILang.parse(source), file.path) }
    }
    func testOfficialPrecedenceAndNumericMemberProjection() throws {
        let arithmetic = try OpenUILang.parse(String(contentsOf: fixtures.appendingPathComponent("grammar/008-expr-precedence-and-keys/input.oui"), encoding: .utf8))
        guard case .node(let col) = try arithmetic.evaluate(.reference("c")) else { return XCTFail("Missing column") }
        XCTAssertEqual(try col.arguments[1].json(), .array([.number(5),.number(6),.number(3),.number(5),.bool(true),.string("ok"),.number(1),.number(9)]))
        let projection = try OpenUILang.parse(String(contentsOf: fixtures.appendingPathComponent("grammar/009-member-digits-field/input.oui"), encoding: .utf8))
        guard case .node(let projected) = try projection.evaluate(.reference("c")) else { return XCTFail("Missing column") }
        XCTAssertEqual(try projected.arguments[1].json(), .array([.number(3),.string("zero"),.array([.number(1),.number(3)])]))
    }
    func testForwardReferencesPreserveEditedBindingsAndProduceUnexecutedAction() throws {
        let source = #"""
        root = Form("compose", [field, button])
        field = Input("body", "Write a reply", $body, {required: true})
        button = Button("Prepare", @ToAssistant("Prepare a reply", {choice: $body}), "primary")
        $body = "Original"
        """#
        let program = try OpenUILang.parse(source)
        guard case .node(let form) = try program.root(state: ["$body":.string("User edit")]), case .node(let input) = form.arguments[1].children[0], case .node(let button) = form.arguments[1].children[1] else { return XCTFail("Invalid form") }
        XCTAssertEqual(input.arguments[2].text,"User edit")
        XCTAssertEqual(button.arguments[1].actions.first?.name,"ToAssistant")
        XCTAssertEqual(try button.arguments[1].actions.first?.arguments[1].json(), .object(["choice":.string("User edit")]))
    }
    func testActionEventUsesScopedFieldsAndAnyContextAndStateWritesCannotRegress() async throws {
        let event = OpenUIActionEvent(type: "continue_conversation", humanFriendlyMessage: "确认", params: ["context":.array([.number(1),.bool(true)])], formName:"compose", formState:["compose":["body":.init(value:.string("Reply"))]])
        let encoded = try JSONEncoder().encode(event); let decoded = try JSONDecoder().decode(OpenUIActionEvent.self,from:encoded)
        XCTAssertEqual(decoded.formState?["compose"]?["body"]?.value,.string("Reply")); XCTAssertNil(decoded.formState?["other"])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
        let store = try MailStore(root:root); let page = OpenUIInteraction(source:"root = TextContent(\"Hi\")")
        try await store.save(page,kind:"openui-interaction",id:page.id)
        try await store.updateOpenUIState(["$body":.string("new")],id:page.id,revision:2)
        try await store.updateOpenUIState(["$body":.string("old")],id:page.id,revision:1)
        let actual = try await store.object(OpenUIInteraction.self,kind:"openui-interaction",id:page.id)
        XCTAssertEqual(actual?.values["$body"],.string("new"))
    }
    func testUnsupportedExecutionAndCyclicOrTruncatedProgramsFailSafely() throws {
        XCTAssertThrowsError(try OpenUILang.parse("root = Stack([a])\na = a").root())
        XCTAssertThrowsError(try OpenUILang.parse("root = Stack([TextContent(\"unfinished)").root())
        XCTAssertThrowsError(try OpenUILang.parse("root = TextContent(@Query(\"remote\"))").root())
        let spec = try JSONDecoder().decode(OpenUIJSON.self, from:OpenUINativeLibrary.librarySpecData)
        XCTAssertEqual(spec.object["id"],.string("morrow-native")); XCTAssertEqual(OpenUINativeLibrary.components["Input"], ["name","placeholder","value","rules"])
    }
}
