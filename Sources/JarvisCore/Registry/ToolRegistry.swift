import Foundation

/// The catalogue of every tool the engine can run, built from the registered integrations.
///
/// The registry is immutable once created. It resolves tool names to descriptors and integrations,
/// validates calls (see ``ToolValidator``) and can describe itself to LLM interpreters.
public final class ToolRegistry: Sendable {
    public let integrations: [any AppIntegration]
    private let descriptorsByName: [ToolName: ToolDescriptor]
    private let integrationsByID: [IntegrationID: any AppIntegration]
    private let validator = ToolValidator()

    /// Creates a registry. Duplicate integration ids or tool names are programmer errors and trap in debug
    /// builds; in release builds the first registration wins.
    public init(integrations: [any AppIntegration]) {
        var byName: [ToolName: ToolDescriptor] = [:]
        var byID: [IntegrationID: any AppIntegration] = [:]
        var accepted: [any AppIntegration] = []
        for integration in integrations {
            if byID[integration.id] != nil {
                assertionFailure("Duplicate integration id \(integration.id)")
                continue
            }
            byID[integration.id] = integration
            accepted.append(integration)
            for descriptor in integration.tools {
                if byName[descriptor.name] != nil {
                    assertionFailure("Duplicate tool \(descriptor.name)")
                    continue
                }
                byName[descriptor.name] = descriptor
            }
        }
        self.integrations = accepted
        self.descriptorsByName = byName
        self.integrationsByID = byID
    }

    public var descriptors: [ToolDescriptor] { descriptorsByName.values.sorted { $0.name < $1.name } }

    public func descriptor(for name: ToolName) -> ToolDescriptor? { descriptorsByName[name] }

    public func integration(withID id: IntegrationID) -> (any AppIntegration)? { integrationsByID[id] }

    public func integration(for name: ToolName) -> (any AppIntegration)? {
        descriptorsByName[name].flatMap { integrationsByID[$0.integration] }
    }

    public func descriptors(for integration: IntegrationID) -> [ToolDescriptor] {
        descriptors.filter { $0.integration == integration }
    }

    /// Validates `call` against its descriptor.
    /// - Throws: ``JarvisError/validation(_:)`` listing every problem found.
    public func validate(_ call: ToolCall) throws -> ValidatedToolCall {
        guard let descriptor = descriptorsByName[call.tool] else {
            throw JarvisError.validation([ValidationIssue(.unknownTool, "Unknown tool '\(call.tool.rawValue)'.")])
        }
        return try validator.validate(call, against: descriptor)
    }

    // MARK: Self-description (for AI interpreters and documentation)

    /// A JSON description of all supported tools, suitable for embedding in an LLM prompt.
    public func schemaDescription(includeUnsupported: Bool = false) -> JSONValue {
        let tools: [JSONValue] = descriptors
            .filter { includeUnsupported || $0.isSupported }
            .map { descriptor in
                var parameters: JSONObject = [:]
                for parameter in descriptor.parameters {
                    var entry: JSONObject = [
                        "type": .string(parameter.kind.typeName),
                        "required": .bool(parameter.required),
                        "description": .string(parameter.summary),
                    ]
                    if let value = parameter.defaultValue { entry["default"] = value }
                    parameters[parameter.name] = .object(entry)
                }
                var object: JSONObject = [
                    "name": .string(descriptor.name.rawValue),
                    "description": .string(descriptor.summary),
                    "safety": .string(descriptor.safety.rawValue),
                    "parameters": .object(parameters),
                ]
                if !descriptor.constraints.isEmpty {
                    object["constraints"] = .array(descriptor.constraints.map { constraint in
                        switch constraint {
                        case .atLeastOne(let names): return .string("at least one of: " + names.joined(separator: ", "))
                        case .exactlyOne(let names): return .string("exactly one of: " + names.joined(separator: ", "))
                        case .atMostOne(let names): return .string("at most one of: " + names.joined(separator: ", "))
                        }
                    })
                }
                return .object(object)
            }
        return .array(tools)
    }
}
