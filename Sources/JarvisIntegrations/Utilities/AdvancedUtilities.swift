import Foundation
import JarvisCore

extension UtilitiesIntegration {
    var advancedTools: [ToolDescriptor] {
        func tool(_ name: String, _ summary: String, _ parameters: [ToolParameter]) -> ToolDescriptor {
            ToolDescriptor(
                name: ToolName("utilities." + name), integration: id,
                title: name.replacingOccurrences(of: "_", with: " ").capitalized, summary: summary,
                parameters: parameters, safety: .readOnly, timeout: 35)
        }
        let expression = ToolParameter.string(
            "expression",
            "Math expression in x. + - * / ^, sin,cos,tan,ln,exp,sqrt,pi,e; multiplication may be implicit. Radians.",
            required: true, maxLength: 1000)
        let rows = ToolParameter.strings(
            "rows", "Matrix rows, each containing comma/space-separated numbers. At most 32 rows/columns.",
            required: true, maxItems: 32, maxLength: 1500)
        return [
            tool(
                "differentiate",
                "Computes an analytic symbolic derivative using a local expression tree; optionally evaluates it at x. No language-model arithmetic.",
                [expression, .number("at", "Optional evaluation point.")]),
            tool(
                "integrate",
                "Integrates polynomials analytically. Definite non-polynomial integrals use bounded adaptive Simpson quadrature with an error estimate; refuses non-convergence. Supply both bounds or neither.",
                [expression, .number("from", "Lower bound."), .number("to", "Upper bound.")]),
            tool(
                "solve_equation",
                "Solves degree-1 or degree-2 polynomial equations in x. Returns real/complex roots from actual coefficients. Refuses unsupported degrees rather than claiming a general solution.",
                [.string("equation", "Equation, e.g. x^2-5*x+6=0.", required: true, maxLength: 1000)]),
            tool(
                "linear_system",
                "Solves a square real linear system by pivoted Gaussian elimination. Each row is coefficients followed by right-hand side. Refuses singular/underdetermined systems and returns a residual.",
                [rows]),
            tool(
                "matrix",
                "Real matrix transpose, determinant, inverse, multiplication or addition. Dimension limit 32; arithmetic results are floating-point approximations.",
                [
                    rows,
                    .choice(
                        "operation", ["transpose", "determinant", "inverse", "multiply", "add"], "Operation.",
                        required: true),
                    .strings("other_rows", "Second matrix for multiply/add.", maxItems: 32, maxLength: 1500),
                ]),
            tool(
                "statistics",
                "Computes count, sum, mean, median, extrema, population/sample variance and standard deviation locally. Sample variance requires at least two values.",
                [
                    .string(
                        "values", "Comma/space-separated finite numbers, at most 1000.", required: true,
                        maxLength: 20000)
                ]),
            tool(
                "probability",
                "Calculates binomial PMF/CDF or normal PDF/CDF using stable local numerical routines. Distributions and assumptions are explicit.",
                [
                    .choice(
                        "distribution", ["binomial_pmf", "binomial_cdf", "normal_pdf", "normal_cdf"], "Distribution.",
                        required: true), .number("x", "Observed value or integer successes.", required: true),
                    .integer("trials", "Binomial trials.", min: 0, max: 10000),
                    .number("probability", "Binomial success probability.", min: 0, max: 1),
                    .number("mean", "Normal mean.", default: 0),
                    .number("standard_deviation", "Normal standard deviation, greater than zero.", min: 0, default: 1),
                ]),
            tool(
                "finance",
                "Future value of initial savings plus fixed periodic deposits, or level loan payment. Fixed nominal annual rate, monthly compounding; excludes fees, tax, inflation and variable rates. Returns formula assumptions.",
                [
                    .choice("operation", ["savings", "loan_payment"], "Calculation.", required: true),
                    .number("principal", "Initial savings or loan amount.", required: true, min: 0, max: 1e15),
                    .number(
                        "annual_rate_percent", "Nominal annual interest percent.", required: true, min: 0, max: 100),
                    .integer("months", "Monthly periods.", required: true, min: 1, max: 1200),
                    .number("monthly_deposit", "End-of-month savings deposit.", min: 0, max: 1e12, default: 0),
                    .boolean("beginning_of_month", "Deposit at beginning of month.", default: false),
                ]),
            tool(
                "random",
                "Uses the system random generator for coin flips, dice, integer picks or an actual choice among supplied options.",
                [
                    .choice("operation", ["coin", "dice", "integer", "choose"], "Random action.", required: true),
                    .integer("count", "Number of results.", min: 1, max: 100, default: 1),
                    .integer("sides", "Dice sides.", min: 2, max: 1_000_000, default: 6),
                    .integer("minimum", "Minimum integer.", min: -1_000_000_000, max: 1_000_000_000, default: 0),
                    .integer("maximum", "Maximum integer.", min: -1_000_000_000, max: 1_000_000_000, default: 100),
                    .strings("options", "Choices for choose.", maxItems: 100, maxLength: 500),
                ]),
            tool(
                "currency",
                "Converts with the latest dated daily reference exchange rate from Frankfurter v2 (official/central-bank sources). Not an intraday/tradable quote. Never invents rates; network failure is an error.",
                [
                    .number("amount", "Amount.", required: true),
                    .string("from", "Three-letter currency code, e.g. EUR.", required: true, maxLength: 3),
                    .string("to", "Target currency code, e.g. GBP.", required: true, maxLength: 3),
                ]),
        ]
    }
    func advanced(_ call: ValidatedToolCall, context: ExecutionContext) async throws -> ToolOutcome {
        func number(_ key: String, _ fallback: Double = 0) -> Double { call.arguments[key]?.doubleValue ?? fallback }
        func vector(_ values: [Double]) -> JSONValue { .array(values.map(JSONValue.double)) }
        func matrixJSON(_ values: [[Double]]) -> JSONValue { .array(values.map(vector)) }
        var data: JSONObject = [:]
        var message = ""
        switch call.descriptor.name.rawValue {
        case "utilities.differentiate":
            let derivative = try MathExpression.parse(call.string("expression") ?? "").derivative
            data = [
                "expression": .string(derivative.text), "method": "symbolic_chain_product_quotient_rules",
                "exact_symbolic": true,
            ]
            message = derivative.text
            if let point = call.arguments["at"]?.doubleValue {
                let result = try derivative.value(at: point)
                data["value"] = .double(result)
                data["evaluation_is_approximate"] = true
                message += "\nx=\(point): ≈ \(result)"
            }
        case "utilities.integrate":
            let expression = try MathExpression.parse(call.string("expression") ?? "")
            let lower = call.arguments["from"]?.doubleValue
            let upper = call.arguments["to"]?.doubleValue
            guard (lower == nil) == (upper == nil) else { throw Calculator.Failure.invalidExpression }
            if let coefficients = expression.polynomial {
                let antiderivative = coefficients.enumerated().reduce(MathExpression.number(0)) { result, pair in
                    .sum(
                        result,
                        .product(
                            .number(pair.element / Double(pair.offset + 1)),
                            .power(.x, .number(Double(pair.offset + 1)))))
                }
                message = antiderivative.text + " + C"
                data = [
                    "antiderivative": .string(message), "method": "analytic_polynomial",
                    "coefficient_arithmetic": "IEEE-754 double",
                ]
                if let lower, let upper {
                    let result = try antiderivative.value(at: upper) - antiderivative.value(at: lower)
                    data["value"] = .double(result)
                    message = "≈ \(result)\n" + message
                }
            } else {
                guard let lower, let upper else {
                    throw integrationFailure(
                        "integral_bounds",
                        "For this non-polynomial expression, supply finite bounds for numerical integration.",
                        "Para esta expresión no polinómica, indica límites finitos para integrar numéricamente.")
                }
                let result = try Mathematics.integrate(expression, from: lower, to: upper)
                message = "≈ \(result.0) · estimated error \(result.1)"
                data = [
                    "value": .double(result.0), "estimated_absolute_error": .double(result.1),
                    "method": "adaptive_simpson", "approximate": true,
                ]
            }
        case "utilities.solve_equation":
            let parts = (call.string("equation") ?? "").components(separatedBy: "=")
            guard parts.count == 2,
                var coefficients = MathExpression.sum(try .parse(parts[0]), .product(.number(-1), try .parse(parts[1])))
                    .polynomial
            else { throw Calculator.Failure.invalidExpression }
            while coefficients.count > 1 && coefficients.last == 0 { coefficients.removeLast() }
            guard (2...3).contains(coefficients.count) else {
                throw integrationFailure(
                    "equation_degree",
                    "Only degree-one/two polynomial equations are supported. Use linear_system for linear systems.",
                    "Se admiten ecuaciones polinómicas de grado uno o dos. Para sistemas lineales usa linear_system.")
            }
            let roots: [JSONValue]
            if coefficients.count == 2 {
                roots = [["real": .double(-coefficients[0] / coefficients[1]), "imaginary": 0]]
            } else {
                let a = coefficients[2]
                let b = coefficients[1]
                let c = coefficients[0]
                let d = b * b - 4 * a * c
                if d < 0 {
                    roots = [-1.0, 1.0].map {
                        ["real": .double(-b / (2 * a)), "imaginary": .double($0 * sqrt(-d) / (2 * abs(a)))]
                    }
                } else if d == 0 {
                    roots = [["real": .double(-b / (2 * a)), "imaginary": 0]]
                } else {
                    let q = -0.5 * (b + (b >= 0 ? sqrt(d) : -sqrt(d)))
                    roots = [q / a, c / q].sorted().map { ["real": .double($0), "imaginary": 0] }
                }
            }
            guard
                roots.allSatisfy({
                    $0["real"]?.doubleValue?.isFinite == true && $0["imaginary"]?.doubleValue?.isFinite == true
                })
            else { throw Calculator.Failure.nonFinite }
            data = [
                "roots": .array(roots), "coefficients_ascending": vector(coefficients), "method": "polynomial_formula",
                "approximate": true,
            ]
            message = roots.map {
                "x ≈ \($0["real"]!.doubleValue!)"
                    + ($0["imaginary"]!.doubleValue! == 0 ? "" : " + \($0["imaginary"]!.doubleValue!)i")
            }.joined(separator: "\n")
        case "utilities.linear_system":
            let a = try Mathematics.matrix(call.strings("rows"))
            let solution = try Mathematics.solve(a)
            let residual =
                a.map { row in abs(zip(row.dropLast(), solution).map(*).reduce(0, +) - row.last!) }.max() ?? 0
            data = ["solution": vector(solution), "maximum_residual": .double(residual), "approximate": true]
            message = "≈ " + solution.map(String.init(describing:)).joined(separator: ", ")
        case "utilities.matrix":
            let a = try Mathematics.matrix(call.strings("rows"))
            let n = a.count
            let m = a[0].count
            var output: [[Double]] = []
            switch call.string("operation") {
            case "transpose": output = (0..<m).map { j in (0..<n).map { a[$0][j] } }
            case "determinant":
                let result = try Mathematics.determinant(a)
                data["value"] = .double(result)
                message = "≈ \(result)"
            case "inverse":
                guard n == m else { throw Calculator.Failure.invalidExpression }
                let columns = try (0..<n).map { j in
                    try Mathematics.solve(a.enumerated().map { i, row in row + [i == j ? 1 : 0] })
                }
                output = (0..<n).map { i in (0..<n).map { columns[$0][i] } }
            case "multiply", "add":
                let b = try Mathematics.matrix(call.strings("other_rows"))
                if call.string("operation") == "add" {
                    guard n == b.count, m == b[0].count else { throw Calculator.Failure.invalidExpression }
                    output = (0..<n).map { i in (0..<m).map { a[i][$0] + b[i][$0] } }
                } else {
                    guard m == b.count else { throw Calculator.Failure.invalidExpression }
                    output = (0..<n).map { i in
                        (0..<b[0].count).map { j in (0..<m).reduce(0.0) { $0 + a[i][$1] * b[$1][j] } }
                    }
                }
            default: throw Calculator.Failure.invalidExpression
            }
            guard output.flatMap({ $0 }).allSatisfy(\.isFinite) else { throw Calculator.Failure.nonFinite }
            if !output.isEmpty {
                data["matrix"] = matrixJSON(output)
                message = output.map { $0.map(String.init(describing:)).joined(separator: ", ") }.joined(
                    separator: "\n")
            }
            data["approximate"] = true
        case "utilities.statistics":
            let values = try Mathematics.numbers(call.string("values") ?? "")
            let sorted = values.sorted()
            let n = values.count
            var mean = 0.0
            var m2 = 0.0
            for (index, value) in values.enumerated() {
                let delta = value - mean
                mean += delta / Double(index + 1)
                m2 += delta * (value - mean)
            }
            let median = n % 2 == 0 ? (sorted[n / 2 - 1] / 2 + sorted[n / 2] / 2) : sorted[n / 2]
            guard mean.isFinite, m2.isFinite else { throw Calculator.Failure.nonFinite }
            data = [
                "count": .int(n), "sum": .double(values.reduce(0, +)), "mean": .double(mean), "median": .double(median),
                "min": .double(sorted[0]), "max": .double(sorted[n - 1]),
                "population_variance": .double(m2 / Double(n)),
                "population_standard_deviation": .double(sqrt(m2 / Double(n))),
                "sample_variance": n > 1 ? .double(m2 / Double(n - 1)) : .null,
                "sample_standard_deviation": n > 1 ? .double(sqrt(m2 / Double(n - 1))) : .null, "approximate": true,
            ]
            message = "n=\(n) · mean ≈ \(mean) · median \(median) · σ ≈ \(sqrt(m2/Double(n)))"
        case "utilities.probability":
            let x = number("x")
            let distribution = call.string("distribution") ?? ""
            let result: Double
            if distribution.hasPrefix("normal") {
                let mean = number("mean")
                let sd = number("standard_deviation", 1)
                guard sd > 0 else { throw Calculator.Failure.invalidExpression }
                let z = (x - mean) / sd
                result =
                    distribution == "normal_cdf"
                    ? 0.5 * erfc(-z / sqrt(2)) : exp(-0.5 * z * z) / (sd * sqrt(2 * Double.pi))
            } else {
                guard let n = call.int("trials"), let p = call.arguments["probability"]?.doubleValue, x.rounded() == x,
                    x >= 0, x <= Double(n)
                else { throw Calculator.Failure.invalidExpression }
                let k = Int(x)
                func pmf(_ k: Int) -> Double {
                    if p == 0 { return k == 0 ? 1 : 0 }
                    if p == 1 { return k == n ? 1 : 0 }
                    return exp(
                        lgamma(Double(n + 1)) - lgamma(Double(k + 1)) - lgamma(Double(n - k + 1)) + Double(k) * log(p)
                            + Double(n - k) * log1p(-p))
                }
                result = distribution == "binomial_cdf" ? min(1, (0...k).reduce(0) { $0 + pmf($1) }) : pmf(k)
            }
            guard result.isFinite else { throw Calculator.Failure.nonFinite }
            data = ["value": .double(result), "distribution": .string(distribution), "approximate": true]
            message = "≈ \(result)"
        case "utilities.finance":
            let principal = number("principal")
            let r = number("annual_rate_percent") / 1200
            let n = Double(call.int("months") ?? 1)
            let deposit = number("monthly_deposit")
            let growth = pow(1 + r, n)
            let savings = call.string("operation") == "savings"
            let value =
                savings
                ? principal * growth + deposit * (r == 0 ? n : (growth - 1) / r)
                    * (call.bool("beginning_of_month") == true ? 1 + r : 1)
                : r == 0 ? principal / n : principal * r / (1 - pow(1 + r, -n))
            guard value.isFinite else { throw Calculator.Failure.nonFinite }
            data = [
                "value": .double(value), "approximate": true, "compounding": "monthly",
                "nominal_annual_rate_percent": .double(number("annual_rate_percent")),
                "excludes": "taxes, fees, inflation, variable rates",
            ]
            message =
                "≈ \(value)"
                + context.language.pick(" · fixed rate, monthly compounding", " · tipo fijo, capitalización mensual")
        case "utilities.random":
            var results: [JSONValue] = []
            let count = call.int("count") ?? 1
            for _ in 0..<count {
                switch call.string("operation") {
                case "coin": results.append(.string(Bool.random() ? "heads" : "tails"))
                case "dice": results.append(.int(Int.random(in: 1...(call.int("sides") ?? 6))))
                case "integer":
                    let lo = call.int("minimum") ?? 0
                    let hi = call.int("maximum") ?? 100
                    guard lo <= hi else { throw Calculator.Failure.invalidExpression }
                    results.append(.int(Int.random(in: lo...hi)))
                case "choose":
                    guard let choice = call.strings("options").randomElement() else {
                        throw Calculator.Failure.invalidExpression
                    }
                    results.append(.string(choice))
                default: throw Calculator.Failure.invalidExpression
                }
            }
            data = ["results": .array(results), "source": "system_random"]
            message = results.map { $0.stringValue ?? $0.canonicalString() }.joined(separator: ", ")
        case "utilities.currency":
            let from = (call.string("from") ?? "").uppercased()
            let to = (call.string("to") ?? "").uppercased()
            guard [from, to].allSatisfy({ $0.utf8.count == 3 && $0.utf8.allSatisfy { (65...90).contains($0) } }) else {
                throw Calculator.Failure.invalidExpression
            }
            let quote = try await currencyRates.load(
                URL(string: "https://api.frankfurter.dev/v2/rate/\(from.lowercased())/\(to.lowercased())")!,
                now: context.now)
            guard let rate = quote["rate"]?.doubleValue, rate > 0, let date = quote["date"]?.stringValue,
                quote["base"]?.stringValue?.uppercased() == from, quote["quote"]?.stringValue?.uppercased() == to
            else { throw URLError(.cannotParseResponse) }
            let value = number("amount") * rate
            guard value.isFinite else { throw Calculator.Failure.nonFinite }
            data = [
                "value": .double(value), "rate": .double(rate), "date": .string(date), "from": .string(from),
                "to": .string(to), "source": "https://frankfurter.dev/", "quote_type": "daily_reference",
            ]
            message = "≈ \(value) \(to) · \(date) · Frankfurter"
        default: throw Calculator.Failure.invalidExpression
        }
        return .done(
            ToolOutput(
                message: message, data: .object(data),
                verification: .verified(
                    call.descriptor.name.rawValue == "utilities.currency"
                        ? "Retrieved a dated reference exchange rate from Frankfurter."
                        : "Computed by bounded local mathematics routines.")))
    }
}
