import Foundation
import XCTest
import JarvisCore
@testable import JarvisInterpreter

final class AdvancedCommandCorpusTests: InterpreterTestCase {
    func testReminderMetadataPrecedesContent() async throws {
        let examples: [(String, String, String, String?)] = [
            ("En la lista Compra, añade comprar huevos", "Comprar huevos", "Compra", nil),
            ("En la lista de la compra, dentro de la sección Mercadona, añade dos paquetes de arroz", "Dos paquetes de arroz", "la compra", "Mercadona"),
            ("En la lista Universidad, añade revisar la documentación mañana", "Revisar la documentación", "Universidad", nil),
            ("In the list Shopping, add buy eggs", "Buy eggs", "Shopping", nil),
            ("Pon en la lista Casa, en la sección Cosas pendientes, que tengo que llamar al electricista mañana", "Llamar al electricista", "Casa", "Cosas pendientes")
        ]
        for (text, title, list, section) in examples {
            let call = try await single(text)
            XCTAssertEqual(call.tool, .remindersCreate, text)
            XCTAssertEqual(call.arguments["title"], .string(title), text)
            XCTAssertEqual(call.arguments["list"], .string(list), text)
            XCTAssertEqual(call.arguments["section"]?.stringValue, section, text)
        }
    }

    func testShoppingBatchCreatesSeparateItemsAndKeepsQuotedDictation() async throws {
        let batch = try await plan("Añade comprar leche, huevos y pan a la compra")
        XCTAssertEqual(batch.map { $0.arguments["title"]?.stringValue }, ["Comprar leche", "Huevos", "Pan"])
        XCTAssertTrue(batch.allSatisfy { $0.arguments["list"] == "compra" })
        let quoted = try await single("Añade \"comprar leche, huevos y pan\" a la lista Compra")
        XCTAssertEqual(quoted.arguments["title"], "Comprar leche, huevos y pan")
    }

    func testLocalUtilitiesInBothLanguages() async throws {
        let spanish = try await single("Cuánto es el 17,5% de 2.450")
        assertCall(spanish, "utilities.calculate", ["expression": "17.5/100*2450.0"])
        assertCall(try await single("Calculate (2+3)^4"), "utilities.calculate", ["expression": "(2+3)^4"])
        assertCall(try await single("Convierte 10 km a mi"), "utilities.convert", ["value": .double(10), "from": "km", "to": "mi"])
    }

    func testWeatherDateAndLocationResolvedWithoutGuessing() async throws {
        let call = try await single("¿Va a llover mañana en Londres?")
        assertCall(call, "weather.forecast", ["location": "Londres", "date": "2026-10-18"])
        let english = try await single("weather in Madrid tomorrow")
        assertCall(english, "weather.forecast", ["location": "Madrid", "date": "2026-10-18"])
    }

    func testFollowupUsesStableReminderIDAndPreservesDate() async throws {
        var input = request("Put it in the list Shopping")
        input.conversation = [ConversationTurn(text: "remind me", results: [ToolResult(callID: UUID(), tool: .remindersCreate, status: .completed, message: "Created", data: ["id": "R-stable", "due": "2026-10-18T09:00:00+01:00"])], summary: "Created")]
        guard case .plan(let plan) = try await DeterministicInterpreter().interpret(input) else { return XCTFail() }
        XCTAssertEqual(plan.steps[0].arguments, ["id": "R-stable", "new_list": "Shopping"])
        input.text = "Change the time to 5 PM"
        guard case .plan(let time) = try await DeterministicInterpreter().interpret(input) else { return XCTFail() }
        XCTAssertEqual(time.steps[0].arguments["new_due"], "2026-10-18T17:00:00+01:00")
    }

    func testFollowupAfterMultipleResultsAsksInsteadOfEditingArbitraryItem() async throws {
        var input = request("ponlo en la lista Compra")
        input.conversation = [ConversationTurn(text: "list", results: [ToolResult(callID: UUID(), tool: .remindersList, status: .completed, message: "2", data: ["reminders": [["id": "R1"], ["id": "R2"]]])], summary: "Two")]
        guard case .clarification = try await DeterministicInterpreter().interpret(input) else { return XCTFail() }
    }

    func testShuffleOffIsAControlRatherThanAMusicSearch() async throws {
        assertCall(try await single("Quita el shuffle"), "music.set_shuffle", ["enabled": false])
    }

    func testFindTwoHourStudySlot() async throws {
        let call = try await single("Busca un hueco de dos horas para estudiar el viernes")
        XCTAssertEqual(call.tool, "calendar.find_free_slots")
        XCTAssertEqual(call.arguments["duration_minutes"], 120)
    }
    func testFollowupAfterBatchCreatesAsksWhichReminder() async throws {
        var input = request("Put it in the list Shopping")
        input.conversation = [ConversationTurn(text: "create two", results: [
            ToolResult(callID: UUID(), tool: .remindersCreate, status: .completed, message: "A", data: ["id": "R1"]),
            ToolResult(callID: UUID(), tool: .remindersCreate, status: .completed, message: "B", data: ["id": "R2"])
        ], summary: "Two reminders")]
        guard case .clarification = try await DeterministicInterpreter().interpret(input) else { return XCTFail("Multiple created reminders cannot resolve to the first arbitrarily") }
    }

    func testSubtaskContentAndParentAreSeparatedBeforeUnsupportedExecution() async throws {
        let call = try await single("En la lista de Universidad, añade como subtarea de Proyecto Final que tengo que revisar la documentación")
        XCTAssertEqual(call.arguments["title"], "Revisar la documentación")
        XCTAssertEqual(call.arguments["parent_title"], "Proyecto Final")
        XCTAssertEqual(call.arguments["list"], "Universidad")
    }

}
