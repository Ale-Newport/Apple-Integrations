import Foundation

/// No credentials or conversation content are persisted here. Models are opt-in.
public struct ModelConfiguration: Codable, Sendable, Hashable {
    public var enabled = false
    public var endpoint = "http://localhost:11434/v1"
    public var model = ""
    public var maxRounds = 8
    public init() {}

    public var credentialAccount: String { "model." + endpoint.trimmingCharacters(in: .whitespacesAndNewlines) }

    public func completionURL() throws -> URL {
        guard let url = URL(string: endpoint), let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased(), components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.scheme == "https" || (components.scheme == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host)),
              !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ModelConfigurationError.invalidEndpoint
        }
        return url.appendingPathComponent("chat/completions")
    }
}

public enum ModelConfigurationError: Error, Sendable { case invalidEndpoint }
