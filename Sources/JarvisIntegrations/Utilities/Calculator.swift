import Foundation

/// A small numeric grammar, never NSExpression, JavaScript, shell, or model arithmetic.
public enum Calculator {
    public enum Failure: Error, Equatable { case invalidExpression, tooComplex, nonFinite }

    public static func evaluate(_ expression: String) throws -> Double {
        guard expression.count <= 2000 else { throw Failure.tooComplex }
        var parser = Parser(expression)
        let value = try parser.expression()
        parser.skipSpace()
        guard parser.index == parser.characters.count else { throw Failure.invalidExpression }
        guard value.isFinite else { throw Failure.nonFinite }
        return value
    }

    private struct Parser {
        let characters: [Character]
        var index = 0
        var depth = 0
        init(_ value: String) { characters = Array(value.lowercased().replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/").replacingOccurrences(of: "−", with: "-").replacingOccurrences(of: "π", with: "pi")) }
        mutating func skipSpace() { while index < characters.count, characters[index].isWhitespace { index += 1 } }
        mutating func take(_ value: Character) -> Bool {
            skipSpace()
            if index < characters.count, characters[index] == value { index += 1; return true }
            return false
        }
        mutating func expression() throws -> Double {
            depth += 1
            defer { depth -= 1 }
            guard depth < 64 else { throw Failure.tooComplex }
            var value = try term()
            while true {
                if take("+") { value += try term() }
                else if take("-") { value -= try term() }
                else { return value }
            }
        }
        mutating func term() throws -> Double {
            var value = try unary()
            while true {
                if take("*") { value *= try unary() }
                else if take("/") { value /= try unary() }
                else { return value }
            }
        }
        mutating func unary() throws -> Double {
            depth += 1
            defer { depth -= 1 }
            guard depth < 64 else { throw Failure.tooComplex }
            if take("+") { return try unary() }
            if take("-") { return -(try unary()) }
            return try power()
        }
        mutating func power() throws -> Double {
            var value = try primary()
            while take("%") { value /= 100 }
            if take("^") { value = pow(value, try unary()) }
            return value
        }
        mutating func primary() throws -> Double {
            if take("(") {
                let value = try expression()
                guard take(")") else { throw Failure.invalidExpression }
                return value
            }
            skipSpace()
            let start = index
            while index < characters.count, characters[index].isLetter || (index > start && characters[index].isNumber) { index += 1 }
            if index > start {
                let name = String(characters[start..<index])
                if name == "pi" { return .pi }
                if name == "e" { return M_E }
                guard take("(") else { throw Failure.invalidExpression }
                var values = [try expression()]
                while take(",") { values.append(try expression()) }
                guard take(")") else { throw Failure.invalidExpression }
                if values.count == 1 {
                    let x = values[0]
                    switch name {
                    case "sqrt": return sqrt(x)
                    case "sin": return sin(x)
                    case "cos": return cos(x)
                    case "tan": return tan(x)
                    case "ln": return log(x)
                    case "log", "log10": return log10(x)
                    case "exp": return exp(x)
                    case "abs": return abs(x)
                    case "floor": return floor(x)
                    case "ceil": return ceil(x)
                    default: break
                    }
                }
                switch name {
                case "sum": return values.reduce(0, +)
                case "mean": return values.reduce(0, +) / Double(values.count)
                case "min": return values.min()!
                case "max": return values.max()!
                default: throw Failure.invalidExpression
                }
            }
            while index < characters.count, characters[index].isNumber || characters[index] == "." { index += 1 }
            if index < characters.count, characters[index] == "e" {
                index += 1
                if index < characters.count, characters[index] == "+" || characters[index] == "-" { index += 1 }
                while index < characters.count, characters[index].isNumber { index += 1 }
            }
            guard index > start, let value = Double(String(characters[start..<index])) else { throw Failure.invalidExpression }
            return value
        }
    }
}

public enum UnitConversion {
    public enum Failure: Error { case incompatibleUnits }
    private struct Unit { var dimension: String; var factor: Double; var offset: Double = 0 }
    private static let units: [String: Unit] = [
        "m": Unit(dimension: "length", factor: 1), "km": Unit(dimension: "length", factor: 1000),
        "cm": Unit(dimension: "length", factor: 0.01), "mm": Unit(dimension: "length", factor: 0.001),
        "mi": Unit(dimension: "length", factor: 1609.344), "ft": Unit(dimension: "length", factor: 0.3048), "in": Unit(dimension: "length", factor: 0.0254),
        "kg": Unit(dimension: "mass", factor: 1), "g": Unit(dimension: "mass", factor: 0.001), "lb": Unit(dimension: "mass", factor: 0.45359237),
        "oz": Unit(dimension: "mass", factor: 0.028349523125),
        "s": Unit(dimension: "time", factor: 1), "min": Unit(dimension: "time", factor: 60), "h": Unit(dimension: "time", factor: 3600), "day": Unit(dimension: "time", factor: 86400),
        "c": Unit(dimension: "temperature", factor: 1, offset: 273.15), "k": Unit(dimension: "temperature", factor: 1),
        "f": Unit(dimension: "temperature", factor: 5/9, offset: 255.3722222222222),
        "l": Unit(dimension: "volume", factor: 1), "ml": Unit(dimension: "volume", factor: 0.001),
        "m/s": Unit(dimension: "speed", factor: 1), "km/h": Unit(dimension: "speed", factor: 1/3.6), "mph": Unit(dimension: "speed", factor: 0.44704)
    ]
    public static func convert(_ value: Double, from: String, to: String) throws -> Double {
        let clean: (String) -> String = { $0.lowercased().replacingOccurrences(of: "°", with: "").trimmingCharacters(in: .whitespaces) }
        guard let a = units[clean(from)], let b = units[clean(to)], a.dimension == b.dimension else { throw Failure.incompatibleUnits }
        let result = (value * a.factor + a.offset - b.offset) / b.factor
        guard result.isFinite else { throw Calculator.Failure.nonFinite }
        return result
    }
}
