import Foundation

/// Bounded expression tree. Expressions are parsed as mathematics, never evaluated as executable code.
indirect enum MathExpression: Sendable {
    case number(Double)
    case x
    case add(Self, Self)
    case multiply(Self, Self)
    case divide(Self, Self)
    case power(Self, Self)
    case function(String, Self)
    var hasFiniteConstants: Bool {
        switch self {
        case .number(let number): return number.isFinite
        case .x: return true
        case .add(let a, let b), .multiply(let a, let b), .divide(let a, let b), .power(let a, let b):
            return a.hasFiniteConstants && b.hasFiniteConstants
        case .function(_, let argument): return argument.hasFiniteConstants
        }
    }
    static func sum(_ a: Self, _ b: Self) -> Self {
        if case .number(0) = a { return b }
        if case .number(0) = b { return a }
        if case .number(let u) = a, case .number(let v) = b { return .number(u + v) }
        return .add(a, b)
    }
    static func product(_ a: Self, _ b: Self) -> Self {
        if case .number(0) = a { return .number(0) }
        if case .number(0) = b { return .number(0) }
        if case .number(1) = a { return b }
        if case .number(1) = b { return a }
        if case .number(let u) = a, case .number(let v) = b { return .number(u * v) }
        return .multiply(a, b)
    }
    var text: String {
        switch self {
        case .number(let n): return n.rounded() == n && abs(n) < 1e15 ? String(Int64(n)) : String(n)
        case .x: return "x"
        case .add(let a, let b): return "(\(a.text) + \(b.text))"
        case .multiply(let a, let b): return "(\(a.text) * \(b.text))"
        case .divide(let a, let b): return "(\(a.text) / \(b.text))"
        case .power(let a, let b): return "(\(a.text) ^ \(b.text))"
        case .function(let f, let a): return "\(f)(\(a.text))"
        }
    }
    func value(at x: Double) throws -> Double {
        let result: Double
        switch self {
        case .number(let n): result = n
        case .x: result = x
        case .add(let a, let b): result = try a.value(at: x) + b.value(at: x)
        case .multiply(let a, let b): result = try a.value(at: x) * b.value(at: x)
        case .divide(let a, let b): result = try a.value(at: x) / b.value(at: x)
        case .power(let a, let b): result = try pow(a.value(at: x), b.value(at: x))
        case .function(let f, let a):
            let n = try a.value(at: x)
            switch f {
            case "sin": result = sin(n)
            case "cos": result = cos(n)
            case "tan": result = tan(n)
            case "ln": result = log(n)
            case "exp": result = exp(n)
            case "sqrt": result = sqrt(n)
            default: throw Calculator.Failure.invalidExpression
            }
        }
        guard result.isFinite else { throw Calculator.Failure.nonFinite }
        return result
    }
    var derivative: Self {
        switch self {
        case .number: return .number(0)
        case .x: return .number(1)
        case .add(let a, let b): return .sum(a.derivative, b.derivative)
        case .multiply(let a, let b): return .sum(.product(a.derivative, b), .product(a, b.derivative))
        case .divide(let a, let b):
            return .divide(
                .sum(.product(a.derivative, b), .product(.number(-1), .product(a, b.derivative))), .power(b, .number(2))
            )
        case .power(let a, .number(let n)):
            return .product(.product(.number(n), .power(a, .number(n - 1))), a.derivative)
        case .power(let a, let b):
            return .product(
                self, .sum(.product(b.derivative, .function("ln", a)), .divide(.product(b, a.derivative), a)))
        case .function(let f, let a):
            let outer: Self
            switch f {
            case "sin": outer = .function("cos", a)
            case "cos": outer = .product(.number(-1), .function("sin", a))
            case "tan": outer = .divide(.number(1), .power(.function("cos", a), .number(2)))
            case "ln": outer = .divide(.number(1), a)
            case "exp": outer = self
            default: outer = .divide(.number(1), .product(.number(2), .function("sqrt", a)))
            }
            return .product(outer, a.derivative)
        }
    }
    /// Coefficients in ascending degree; nil means this is not a bounded polynomial.
    var polynomial: [Double]? {
        switch self {
        case .number(let n): return [n]
        case .x: return [0, 1]
        case .add(let a, let b):
            guard let u = a.polynomial, let v = b.polynomial else { return nil }
            return (0..<max(u.count, v.count)).map { ($0 < u.count ? u[$0] : 0) + ($0 < v.count ? v[$0] : 0) }
        case .multiply(let a, let b):
            guard let u = a.polynomial, let v = b.polynomial, u.count + v.count <= 34 else { return nil }
            var out = Array(repeating: 0.0, count: u.count + v.count - 1)
            for i in u.indices { for j in v.indices { out[i + j] += u[i] * v[j] } }
            return out
        case .divide(let a, .number(let b)): return b == 0 ? nil : a.polynomial?.map { $0 / b }
        case .power(let a, .number(let n)):
            guard n >= 0, n <= 16, n.rounded() == n else { return nil }
            var out: Self = .number(1)
            for _ in 0..<Int(n) { out = .multiply(out, a) }
            return out.polynomial
        default: return nil
        }
    }
    static func parse(_ text: String) throws -> Self {
        var parser = MathParser(text)
        let value = try parser.expression()
        parser.space()
        guard parser.index == parser.chars.count else { throw Calculator.Failure.invalidExpression }
        return value
    }
}

private struct MathParser {
    let chars: [Character]
    var index = 0
    var depth = 0
    init(_ text: String) {
        chars = Array(
            text.lowercased().replacingOccurrences(of: "²", with: "^2").replacingOccurrences(of: "³", with: "^3")
                .replacingOccurrences(of: "π", with: "pi").replacingOccurrences(of: "−", with: "-")
                .replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/"))
    }
    mutating func space() { while index < chars.count && chars[index].isWhitespace { index += 1 } }
    mutating func take(_ c: Character) -> Bool {
        space()
        guard index < chars.count && chars[index] == c else { return false }
        index += 1
        return true
    }
    mutating func expression() throws -> MathExpression {
        depth += 1
        defer { depth -= 1 }
        guard depth <= 32, chars.count <= 1000 else { throw Calculator.Failure.tooComplex }
        var out = try term()
        while true {
            if take("+") {
                out = .sum(out, try term())
            } else if take("-") {
                out = .sum(out, .product(.number(-1), try term()))
            } else {
                return out
            }
        }
    }
    mutating func term() throws -> MathExpression {
        var out = try unary()
        while true {
            if take("*") {
                out = .product(out, try unary())
            } else if take("/") {
                out = .divide(out, try unary())
            } else {
                space()
                if index < chars.count && (chars[index] == "(" || chars[index].isLetter) {
                    out = .product(out, try unary())
                } else {
                    return out
                }
            }
        }
    }
    mutating func unary() throws -> MathExpression {
        depth += 1
        defer { depth -= 1 }
        guard depth <= 32 else { throw Calculator.Failure.tooComplex }
        if take("-") { return .product(.number(-1), try unary()) }
        if take("+") { return try unary() }
        var value = try primary()
        if take("^") { value = .power(value, try unary()) }
        return value
    }
    mutating func primary() throws -> MathExpression {
        if take("(") {
            let v = try expression()
            guard take(")") else { throw Calculator.Failure.invalidExpression }
            return v
        }
        space()
        let start = index
        while index < chars.count && chars[index].isLetter { index += 1 }
        if start < index {
            let name = String(chars[start..<index])
            if name == "x" { return .x }
            if name == "pi" { return .number(.pi) }
            if name == "e" { return .number(M_E) }
            guard ["sin", "cos", "tan", "ln", "exp", "sqrt"].contains(name), take("(") else {
                throw Calculator.Failure.invalidExpression
            }
            let a = try expression()
            guard take(")") else { throw Calculator.Failure.invalidExpression }
            return .function(name, a)
        }
        while index < chars.count && (chars[index].isNumber || chars[index] == ".") { index += 1 }
        if index < chars.count && chars[index] == "e" {
            index += 1
            if index < chars.count && (chars[index] == "+" || chars[index] == "-") { index += 1 }
            while index < chars.count && chars[index].isNumber { index += 1 }
        }
        guard index > start, let n = Double(String(chars[start..<index])), n.isFinite else {
            throw Calculator.Failure.invalidExpression
        }
        return .number(n)
    }
}

enum Mathematics {
    static func numbers(_ text: String, max: Int = 1000) throws -> [Double] {
        let parts = text.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace })
        guard !parts.isEmpty, parts.count <= max else { throw Calculator.Failure.tooComplex }
        return try parts.map {
            guard let n = Double($0), n.isFinite else { throw Calculator.Failure.invalidExpression }
            return n
        }
    }
    static func matrix(_ rows: [String]) throws -> [[Double]] {
        guard !rows.isEmpty, rows.count <= 32 else { throw Calculator.Failure.tooComplex }
        let values = try rows.map { try numbers($0, max: 33) }
        guard values.allSatisfy({ $0.count == values[0].count }) else { throw Calculator.Failure.invalidExpression }
        return values
    }
    static func solve(_ augmented: [[Double]]) throws -> [Double] {
        let n = augmented.count
        guard augmented.allSatisfy({ $0.count == n + 1 }) else { throw Calculator.Failure.invalidExpression }
        var a = augmented
        for col in 0..<n {
            let pivot = (col..<n).max { abs(a[$0][col]) < abs(a[$1][col]) }!
            let scale = a[pivot].prefix(n).map(abs).max() ?? 0
            guard abs(a[pivot][col]) > max(1e-14 * scale, Double.leastNormalMagnitude) else {
                throw Calculator.Failure.invalidExpression
            }
            a.swapAt(col, pivot)
            let divisor = a[col][col]
            for k in col...n { a[col][k] /= divisor }
            for row in 0..<n where row != col {
                let factor = a[row][col]
                for k in col...n { a[row][k] -= factor * a[col][k] }
            }
        }
        let result = a.map { $0[n] }
        guard result.allSatisfy(\.isFinite) else { throw Calculator.Failure.nonFinite }
        return result
    }
    static func determinant(_ input: [[Double]]) throws -> Double {
        let n = input.count
        guard input.allSatisfy({ $0.count == n }) else { throw Calculator.Failure.invalidExpression }
        var a = input
        var determinant = 1.0
        for col in 0..<n {
            let pivot = (col..<n).max { abs(a[$0][col]) < abs(a[$1][col]) }!
            if a[pivot][col] == 0 { return 0 }
            if pivot != col {
                a.swapAt(pivot, col)
                determinant *= -1
            }
            let divisor = a[col][col]
            determinant *= divisor
            if col + 1 < n {
                for row in col + 1..<n {
                    let factor = a[row][col] / divisor
                    for k in col + 1..<n { a[row][k] -= factor * a[col][k] }
                }
            }
        }
        guard determinant.isFinite else { throw Calculator.Failure.nonFinite }
        return determinant
    }
    static func integrate(_ f: MathExpression, from a: Double, to b: Double, tolerance: Double = 1e-8) throws -> (
        Double, Double
    ) {
        // Adaptive Simpson with an evaluation/depth budget. Refuses unconverged or nonfinite integrals.
        var evaluations = 0
        func value(_ x: Double) throws -> Double {
            evaluations += 1
            guard evaluations < 20000 else { throw Calculator.Failure.tooComplex }
            return try f.value(at: x)
        }
        func recur(
            _ a: Double, _ b: Double, _ fa: Double, _ fm: Double, _ fb: Double, _ whole: Double, _ eps: Double,
            _ depth: Int
        ) throws -> (Double, Double) {
            let mid = (a + b) / 2
            let leftMid = (a + mid) / 2
            let rightMid = (mid + b) / 2
            let fl = try value(leftMid)
            let fr = try value(rightMid)
            let left = (mid - a) / 6 * (fa + 4 * fl + fm)
            let right = (b - mid) / 6 * (fm + 4 * fr + fb)
            let delta = left + right - whole
            if abs(delta) <= 15 * eps { return (left + right + delta / 15, abs(delta) / 15) }
            guard depth > 0 else { throw Calculator.Failure.tooComplex }
            let l = try recur(a, mid, fa, fl, fm, left, eps / 2, depth - 1)
            let r = try recur(mid, b, fm, fr, fb, right, eps / 2, depth - 1)
            return (l.0 + r.0, l.1 + r.1)
        }
        if a == b { return (0, 0) }
        let lo = min(a, b)
        let hi = max(a, b)
        let fa = try value(lo)
        let fb = try value(hi)
        let fm = try value((lo + hi) / 2)
        let result = try recur(lo, hi, fa, fm, fb, (hi - lo) / 6 * (fa + 4 * fm + fb), tolerance, 20)
        return (a < b ? result.0 : -result.0, result.1)
    }
}
