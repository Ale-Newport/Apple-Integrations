import Foundation

/// Validates and normalises tool-call arguments against a ``ToolDescriptor``.
///
/// This is the single gate every call passes through, whether it came from the deterministic parser, an
/// LLM or a local IPC client. Nothing reaches an integration without being checked here first.
public struct ToolValidator: Sendable {
    public static let maxStringLength = 100_000

    public init() {}

    public func validate(_ call: ToolCall, against descriptor: ToolDescriptor) throws -> ValidatedToolCall {
        var issues: [ValidationIssue] = []
        var normalized: JSONObject = [:]

        let known = Set(descriptor.parameters.map(\.name))
        for key in call.arguments.keys.sorted() where !known.contains(key) {
            issues.append(ValidationIssue(.unknownParameter, parameter: key, "Unknown parameter '\(key)' for \(descriptor.name)."))
        }

        for parameter in descriptor.parameters {
            let raw = call.arguments[parameter.name]
            switch normalize(raw, for: parameter) {
            case .absent:
                if parameter.required {
                    issues.append(ValidationIssue(.missingRequired, parameter: parameter.name, "Missing required parameter '\(parameter.name)'."))
                } else if let fallback = parameter.defaultValue {
                    normalized[parameter.name] = fallback
                }
            case .value(let value):
                normalized[parameter.name] = value
            case .invalid(let issue):
                issues.append(issue)
            }
        }

        if issues.isEmpty {
            for constraint in descriptor.constraints {
                // Defaults must not satisfy "at least one" constraints, so look at what the caller supplied.
                let present = constraint.parameterNames.filter { name in
                    guard let value = normalized[name] else { return false }
                    return call.arguments[name] != nil && !value.isNull
                }
                switch constraint {
                case .atLeastOne(let names) where present.isEmpty:
                    issues.append(ValidationIssue(.constraintViolated, "Provide at least one of: \(names.joined(separator: ", "))."))
                case .exactlyOne(let names) where present.count != 1:
                    issues.append(ValidationIssue(.constraintViolated, "Provide exactly one of: \(names.joined(separator: ", "))."))
                case .atMostOne(let names) where present.count > 1:
                    issues.append(ValidationIssue(.constraintViolated, "Provide at most one of: \(names.joined(separator: ", "))."))
                default:
                    break
                }
            }
        }

        guard issues.isEmpty else { throw JarvisError.validation(issues) }
        return ValidatedToolCall(call: call, descriptor: descriptor, arguments: normalized)
    }

    // MARK: Per-parameter normalisation

    private enum Normalized {
        case absent
        case value(JSONValue)
        case invalid(ValidationIssue)
    }

    private func normalize(_ raw: JSONValue?, for parameter: ToolParameter) -> Normalized {
        guard let raw, !raw.isNull else { return .absent }
        let name = parameter.name

        func wrongType(_ expected: String) -> Normalized {
            .invalid(ValidationIssue(.wrongType, parameter: name, "'\(name)' must be \(expected)."))
        }

        switch parameter.kind {
        case .string(let maxLength):
            guard let text = coerceString(raw) else { return wrongType("a string") }
            let clean = Self.sanitizeText(text)
            if clean.isEmpty { return .absent }
            if clean.count > min(maxLength, Self.maxStringLength) {
                return .invalid(ValidationIssue(.tooLong, parameter: name, "'\(name)' is too long (maximum \(maxLength) characters)."))
            }
            return .value(.string(clean))

        case .integer(let minimum, let maximum):
            guard let number = coerceInt(raw) else { return wrongType("an integer") }
            if let minimum, number < minimum { return .invalid(ValidationIssue(.outOfRange, parameter: name, "'\(name)' must be at least \(minimum).")) }
            if let maximum, number > maximum { return .invalid(ValidationIssue(.outOfRange, parameter: name, "'\(name)' must be at most \(maximum).")) }
            return .value(.int(number))

        case .number(let minimum, let maximum):
            guard let number = coerceDouble(raw) else { return wrongType("a number") }
            if let minimum, number < minimum { return .invalid(ValidationIssue(.outOfRange, parameter: name, "'\(name)' must be at least \(minimum).")) }
            if let maximum, number > maximum { return .invalid(ValidationIssue(.outOfRange, parameter: name, "'\(name)' must be at most \(maximum).")) }
            return .value(.double(number))

        case .boolean:
            guard let flag = coerceBool(raw) else { return wrongType("true or false") }
            return .value(.bool(flag))

        case .dateTime:
            guard let text = raw.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) else { return wrongType("an ISO-8601 date-time string") }
            guard let parsed = ISODates.parse(text, timeZone: .gmt), case .dateTime = parsed else {
                return .invalid(ValidationIssue(.invalidValue, parameter: name, "'\(name)' must be an ISO-8601 date-time such as 2026-10-18T18:00:00-04:00."))
            }
            return .value(.string(text))

        case .date:
            guard let text = raw.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) else { return wrongType("a yyyy-MM-dd date string") }
            guard ISODates.isDate(text) else {
                return .invalid(ValidationIssue(.invalidValue, parameter: name, "'\(name)' must be a calendar date such as 2026-10-18."))
            }
            return .value(.string(text))

        case .dateOrDateTime:
            guard let text = raw.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) else { return wrongType("a date or date-time string") }
            guard ISODates.isDateOrDateTime(text) else {
                return .invalid(ValidationIssue(.invalidValue, parameter: name, "'\(name)' must be 2026-10-18 or 2026-10-18T18:00:00-04:00."))
            }
            return .value(.string(text))

        case .time:
            guard let text = raw.stringValue, let parts = ISODates.parseTime(text) else {
                return .invalid(ValidationIssue(.invalidValue, parameter: name, "'\(name)' must be a 24-hour time such as 07:30."))
            }
            return .value(.string(ISODates.timeString(hour: parts.hour, minute: parts.minute)))

        case .enumeration(let allowed):
            guard let text = coerceString(raw) else { return wrongType("one of: \(allowed.joined(separator: ", "))") }
            let folded = TextFolding.fold(text).replacingOccurrences(of: " ", with: "_")
            guard let match = allowed.first(where: { TextFolding.fold($0).replacingOccurrences(of: " ", with: "_") == folded }) else {
                return .invalid(ValidationIssue(.invalidValue, parameter: name, "'\(name)' must be one of: \(allowed.joined(separator: ", "))."))
            }
            return .value(.string(match))

        case .stringList(let maxItems, let maxLength):
            let items: [JSONValue]
            if case .array(let array) = raw { items = array } else if raw.stringValue != nil { items = [raw] } else { return wrongType("a list of strings") }
            var output: [JSONValue] = []
            for item in items {
                guard let text = coerceString(item) else { return wrongType("a list of strings") }
                let clean = Self.sanitizeText(text)
                if clean.isEmpty { continue }
                if clean.count > maxLength {
                    return .invalid(ValidationIssue(.tooLong, parameter: name, "An item of '\(name)' is too long (maximum \(maxLength) characters)."))
                }
                output.append(.string(clean))
            }
            if output.count > maxItems {
                return .invalid(ValidationIssue(.outOfRange, parameter: name, "'\(name)' accepts at most \(maxItems) items."))
            }
            return output.isEmpty ? .absent : .value(.array(output))
        }
    }

    // MARK: Coercion helpers

    private func coerceString(_ value: JSONValue) -> String? {
        switch value {
        case .string(let text): return text
        case .int(let number): return String(number)
        case .double(let number): return String(number)
        case .bool(let flag): return flag ? "true" : "false"
        default: return nil
        }
    }

    private func coerceInt(_ value: JSONValue) -> Int? {
        switch value {
        case .int(let number): return number
        case .double(let number) where number.rounded() == number && abs(number) < 9e15: return Int(number)
        case .string(let text): return Int(text.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    private func coerceDouble(_ value: JSONValue) -> Double? {
        switch value {
        case .int(let number): return Double(number)
        case .double(let number): return number.isFinite ? number : nil
        case .string(let text): return Double(text.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    private func coerceBool(_ value: JSONValue) -> Bool? {
        switch value {
        case .bool(let flag): return flag
        case .string(let text):
            switch TextFolding.fold(text) {
            case "true", "yes", "si", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        case .int(let number) where number == 0 || number == 1: return number == 1
        default: return nil
        }
    }

    /// Trims whitespace and removes control characters (except newline and tab) that have no place in user text.
    public static func sanitizeText(_ text: String) -> String {
        let scalars = text.unicodeScalars.filter { scalar in
            if scalar == "\n" || scalar == "\t" { return true }
            if scalar == "\r" { return false }
            return !(scalar.properties.generalCategory == .control || scalar.value == 0x2028 || scalar.value == 0x2029)
        }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
