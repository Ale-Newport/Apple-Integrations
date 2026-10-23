import Foundation
import JarvisCore

public protocol ModelHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Ephemeral networking: no cookies, cache or credentials on disk; bounded responses and cancellation.
public struct ModelURLSessionTransport: ModelHTTPTransport {
    public init() {}
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let session = URLSession(configuration: .ephemeral, delegate: NoModelRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw ModelProviderError.invalidResponse }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 1_048_576 else { throw ModelProviderError.responseTooLarge }
            data.append(byte)
        }
        return (data, http)
    }
}

private final class NoModelRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public enum ModelProviderError: Error, Sendable, Equatable {
    case invalidResponse, responseTooLarge, http(Int), emptyResponse
}

/// OpenAI-compatible Chat Completions, including Ollama /v1, llama.cpp and hosted services.
/// Model names are supplied by the user; there is no paid-provider dependency.
public struct CompatibleModelProvider: LLMTextProvider {
    public let identifier = "compatible"
    private let configuration: ModelConfiguration
    private let secret: String?
    private let transport: any ModelHTTPTransport

    public init(configuration: ModelConfiguration, secret: String? = nil, transport: any ModelHTTPTransport = ModelURLSessionTransport()) {
        self.configuration = configuration; self.secret = secret; self.transport = transport
    }

    public func complete(system: String, user: String) async throws -> String {
        var request = URLRequest(url: try configuration.completionURL())
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let secret, !secret.isEmpty { request.setValue("Bearer " + secret, forHTTPHeaderField: "Authorization") }
        let body: JSONValue = .object([
            "model": .string(configuration.model), "stream": false,
            "messages": .array([
                .object(["role": "system", "content": .string(system)]),
                .object(["role": "user", "content": .string(user)])
            ])
        ])
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else { throw ModelProviderError.http(response.statusCode) }
        guard data.count <= 1_048_576 else { throw ModelProviderError.responseTooLarge }
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let text = json["choices"]?[0]?["message"]?["content"]?.stringValue, !text.isEmpty else {
            throw ModelProviderError.emptyResponse
        }
        return text
    }
}

/// Reads configuration per request so settings changes take effect without relaunching the app.
public struct ConfiguredAgentInterpreter: CommandInterpreting {
    public let identifier = "agent"
    private let secrets: any SecretStoring
    private let transport: any ModelHTTPTransport
    public init(secrets: any SecretStoring = KeychainSecretStore(), transport: any ModelHTTPTransport = ModelURLSessionTransport()) {
        self.secrets = secrets; self.transport = transport
    }

    public func interpret(_ request: InterpretationRequest) async throws -> Interpretation {
        if request.settings.model.enabled {
            do {
                let configuration = request.settings.model
                let provider = CompatibleModelProvider(configuration: configuration,
                    secret: try secrets.secret(for: configuration.credentialAccount), transport: transport)
                let proposal = try await LLMToolCallInterpreter(provider: provider).propose(request)
                if let question = proposal.clarifyingQuestion { return .clarification(Clarification(question: question)) }
                if !proposal.calls.isEmpty {
                    let descriptors = Dictionary(uniqueKeysWithValues: request.tools.map { ($0.name.rawValue, $0) })
                    guard proposal.calls.allSatisfy({ descriptors[$0.tool]?.isSupported == true }) else {
                        return .clarification(Clarification(question: request.language.pick(
                            "That request needs an unavailable capability. Which supported action should I use?",
                            "Esa petición necesita una función no disponible. ¿Qué acción compatible quieres usar?")))
                    }
                    // No model-supplied executable code or validation bypass. Validate the entire batch before effects.
                    let calls = proposal.calls.map { ToolCall(tool: ToolName($0.tool), arguments: $0.arguments, sourceText: request.text) }
                    for call in calls { _ = try ToolValidator().validate(call, against: descriptors[call.tool.rawValue]!) }
                    let writes = calls.filter { descriptors[$0.tool.rawValue]?.isMutating == true }
                    guard writes.isEmpty || calls.count == 1 else {
                        throw ModelProviderError.invalidResponse
                    }
                    var plan = ToolPlan(steps: calls, language: request.language, interpreter: "agent.compatible")
                    plan.continues = true
                    return .plan(plan)
                }
                if let reply = proposal.reply { return .reply(reply) }
                if !request.observations.isEmpty { throw ModelProviderError.emptyResponse }
            } catch is CancellationError { throw CancellationError() }
            catch {
                if !request.observations.isEmpty {
                    return .unrecognized(hint: request.language.pick(
                        "The model is unavailable or returned an invalid next step. The workflow stopped.",
                        "El modelo no está disponible o devolvió un paso inválido. El flujo se ha detenido."))
                }
            }
        }
        return try await DeterministicInterpreter().interpret(request)
    }
}
