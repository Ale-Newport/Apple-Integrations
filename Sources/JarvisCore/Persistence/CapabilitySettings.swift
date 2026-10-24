import Foundation

public struct CapabilitySettings: Codable, Sendable, Hashable {
    public var fileRoots: [String] = []
    public var approvedWorkflows: [String] = []
    public var focusShortcut = "Jarvis Set Focus"
    public var searchEndpoint = ""
    public var searchProvider = "searxng"
    public var remindersAccessibilityEnabled = false
    public var backgroundConditionsEnabled = false
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case fileRoots, approvedWorkflows, focusShortcut, searchEndpoint, searchProvider, remindersAccessibilityEnabled,
            backgroundConditionsEnabled
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fileRoots = try c.decodeIfPresent([String].self, forKey: .fileRoots) ?? []
        approvedWorkflows = try c.decodeIfPresent([String].self, forKey: .approvedWorkflows) ?? []
        focusShortcut = try c.decodeIfPresent(String.self, forKey: .focusShortcut) ?? "Jarvis Set Focus"
        searchEndpoint = try c.decodeIfPresent(String.self, forKey: .searchEndpoint) ?? ""
        searchProvider = try c.decodeIfPresent(String.self, forKey: .searchProvider) ?? "searxng"
        remindersAccessibilityEnabled =
            try c.decodeIfPresent(Bool.self, forKey: .remindersAccessibilityEnabled) ?? false
        backgroundConditionsEnabled = try c.decodeIfPresent(Bool.self, forKey: .backgroundConditionsEnabled) ?? false
    }
}
