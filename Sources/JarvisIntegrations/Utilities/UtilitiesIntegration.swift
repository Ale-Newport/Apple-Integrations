import Foundation
import JarvisCore

public struct UtilitiesIntegration: AppIntegration {
    public let id: IntegrationID = "utilities"
    public let displayName = LocalizedText(en: "Utilities", es: "Utilidades")
    public let summary = LocalizedText(en: "Verified local calculations, unit conversions and date differences.", es: "Cálculos locales, conversiones de unidades y diferencias entre fechas.")
    public let symbolName = "function"
    public let permissionRequirements: [PermissionRequirement] = []
    public init() {}
    public var tools: [ToolDescriptor] { [
        ToolDescriptor(name: "utilities.calculate", integration: id, title: "Calculate", summary: "Evaluates numeric expressions: + - * / ^ %, parentheses, pi/e, sqrt, sin/cos/tan (radians), ln/log, exp, abs, floor/ceil, sum/mean/min/max. Decimal dot; comma separates arguments. No symbolic algebra.", parameters: [.string("expression", "Numeric expression.", required: true, maxLength: 2000)], safety: .readOnly),
        ToolDescriptor(name: "utilities.convert", integration: id, title: "Convert units", summary: "Converts compatible length, mass, time, temperature, volume or speed units. No currency conversion.", parameters: [.number("value", "Value.", required: true), .string("from", "Unit: m,km,cm,mm,mi,ft,in,kg,g,lb,oz,s,min,h,day,C,F,K,l,ml,m/s,km/h,mph.", required: true, maxLength: 20), .string("to", "Target unit.", required: true, maxLength: 20)], safety: .readOnly),
        ToolDescriptor(name: "utilities.date_difference", integration: id, title: "Date difference", summary: "Elapsed seconds and calendar days between two ISO dates in the user's timezone.", parameters: [.dateOrDateTime("from", "Start.", required: true), .dateOrDateTime("to", "End.", required: true)], safety: .readOnly)
    ] }
    public func status() async -> IntegrationStatus { IntegrationStatus(state: .ready) }
    public func authorization(for tool: ToolDescriptor) async -> AuthorizationState { .authorized }
    public func requestAuthorization(for tool: ToolDescriptor) async -> AuthorizationState { .authorized }
    public func execute(_ call: ValidatedToolCall, context: ExecutionContext) async throws -> ToolOutcome {
        do {
            let value: Double
            var data: JSONObject = [:]
            switch call.descriptor.name.rawValue {
            case "utilities.calculate": value = try Calculator.evaluate(call.string("expression") ?? "")
            case "utilities.convert":
                value = try UnitConversion.convert(call.arguments["value"]?.doubleValue ?? 0, from: call.string("from") ?? "", to: call.string("to") ?? "")
                data["unit"] = call.arguments["to"]
            case "utilities.date_difference":
                guard let start = ISODates.date(from: call.string("from") ?? "", timeZone: context.timeZone), let end = ISODates.date(from: call.string("to") ?? "", timeZone: context.timeZone) else { throw Calculator.Failure.invalidExpression }
                value = end.timeIntervalSince(start)
                data["calendar_days"] = .int(context.calendar.dateComponents([.day], from: context.calendar.startOfDay(for: start), to: context.calendar.startOfDay(for: end)).day ?? 0)
                data["unit"] = "seconds"
            default: throw Calculator.Failure.invalidExpression
            }
            data["value"] = .double(value)
            let formatter = NumberFormatter()
            formatter.locale = Locale(identifier: context.language == .es ? "es_ES" : "en_GB")
            formatter.maximumFractionDigits = 10
            let formatted = formatter.string(from: NSNumber(value: value)) ?? String(value)
            return .done(ToolOutput(message: formatted + (data["unit"]?.stringValue.map { " " + $0 } ?? ""), data: .object(data), verification: .verified(context.language.pick("Calculated locally.", "Calculado localmente."))))
        } catch {
            throw JarvisError.failed("calculation_failed", en: "I couldn't calculate that expression or conversion. Check the numbers, units and supported functions.", es: "No pude calcular esa expresión o conversión. Revisa los números, las unidades y las funciones compatibles.")
        }
    }
}
