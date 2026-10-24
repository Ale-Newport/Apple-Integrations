import JarvisCore
import XCTest

@testable import JarvisIntegrations

final class MathematicsTests: XCTestCase {
    func testSymbolicDerivativeProductAndChainRulesAgainstKnownResults() throws {
        let d = try MathExpression.parse("x³ sin(x)").derivative
        for x in [-2.0, -0.1, 0, 0.5, 3] {
            XCTAssertEqual(try d.value(at: x), 3 * x * x * sin(x) + x * x * x * cos(x), accuracy: 1e-10)
        }
        let log = try MathExpression.parse("ln(x^2+1)").derivative
        XCTAssertEqual(try log.value(at: 2), 0.8, accuracy: 1e-12)
        XCTAssertEqual(try MathExpression.parse("-x^2").value(at: 3), -9)
    }
    func testIntegralAdaptiveQuadratureAndDivergence() throws {
        let integral = try Mathematics.integrate(.parse("sin(x)"), from: 0, to: .pi)
        XCTAssertEqual(integral.0, 2, accuracy: 1e-8)
        XCTAssertLessThan(integral.1, 1e-8)
        XCTAssertThrowsError(try Mathematics.integrate(.parse("1/x"), from: -1, to: 1))
        XCTAssertThrowsError(
            try MathExpression.parse(String(repeating: "(", count: 40) + "x" + String(repeating: ")", count: 40)))
        XCTAssertThrowsError(try MathExpression.parse("system('touch file')"))
    }
    func testPolynomialQuadraticAndComplexRoots() async throws {
        let registry = ToolRegistry(integrations: [UtilitiesIntegration()])
        let roots = try await registry.run("utilities.solve_equation", ["equation": "x² - 5x + 6 = 0"])
        XCTAssertEqual(roots.output?.data?["roots"]?[0]?["real"]?.doubleValue, 2)
        XCTAssertEqual(roots.output?.data?["roots"]?[1]?["real"]?.doubleValue, 3)
        let complex = try await registry.run("utilities.solve_equation", ["equation": "x^2+1=0"])
        XCTAssertEqual(complex.output?.data?["roots"]?[0]?["imaginary"]?.doubleValue, -1)
        let integral = try await registry.run("utilities.integrate", ["expression": "x²", "from": 0, "to": 3])
        XCTAssertEqual(integral.output?.data?["value"]?.doubleValue, 9)
    }
    func testPivotedLinearSystemAndMatrixInverse() async throws {
        XCTAssertEqual(try Mathematics.solve([[0, 2, 4], [1, 1, 3]]), [1, 2])
        XCTAssertThrowsError(try Mathematics.solve([[1, 2, 3], [2, 4, 6]]))
        let registry = ToolRegistry(integrations: [UtilitiesIntegration()])
        let inverse = try await registry.run("utilities.matrix", ["rows": ["1 2", "3 4"], "operation": "inverse"])
        XCTAssertEqual(try XCTUnwrap(inverse.output?.data?["matrix"]?[0]?[0]?.doubleValue), -2, accuracy: 1e-12)
        let product = try await registry.run(
            "utilities.matrix", ["rows": ["1 2", "3 4"], "other_rows": ["5", "6"], "operation": "multiply"])
        XCTAssertEqual(product.output?.data?["matrix"]?[1]?[0]?.doubleValue, 39)
        XCTAssertEqual(try Mathematics.determinant([[1, 2], [3, 4]]), -2, accuracy: 1e-12)
    }
    func testStatisticsFinanceProbabilityAndRandomHaveActualComputedOutputs() async throws {
        let registry = ToolRegistry(integrations: [UtilitiesIntegration()])
        let stats = try await registry.run("utilities.statistics", ["values": "1,2,3,4"])
        XCTAssertEqual(stats.output?.data?["mean"]?.doubleValue, 2.5)
        XCTAssertEqual(stats.output?.data?["population_variance"]?.doubleValue, 1.25)
        let savings = try await registry.run(
            "utilities.finance",
            ["operation": "savings", "principal": 0, "monthly_deposit": 200, "annual_rate_percent": 5, "months": 120])
        XCTAssertEqual(try XCTUnwrap(savings.output?.data?["value"]?.doubleValue), 31056.4558891334, accuracy: 1e-6)
        let binomial = try await registry.run(
            "utilities.probability", ["distribution": "binomial_pmf", "x": 2, "trials": 4, "probability": 0.5])
        XCTAssertEqual(try XCTUnwrap(binomial.output?.data?["value"]?.doubleValue), 0.375, accuracy: 1e-12)
        let normal = try await registry.run("utilities.probability", ["distribution": "normal_cdf", "x": 0])
        XCTAssertEqual(normal.output?.data?["value"]?.doubleValue, 0.5)
        let dice = try await registry.run("utilities.random", ["operation": "dice", "count": 100])
        XCTAssertEqual(dice.output?.data?["results"]?.arrayValue?.count, 100)
        XCTAssertTrue(dice.output!.data!["results"]!.arrayValue!.allSatisfy { (1...6).contains($0.intValue ?? 0) })
    }
}
