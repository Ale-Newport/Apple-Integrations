import Foundation
import JarvisCore

/// SSE transport exposes text deltas only; model tool calls remain untrusted JSON handled after completion.
public protocol ModelStreamingTransport: ModelHTTPTransport {
    func stream(_ request: URLRequest, onDelta: @escaping @Sendable (String) -> Void) async throws -> String
}

extension ModelURLSessionTransport: ModelStreamingTransport {
    public func stream(_ request: URLRequest, onDelta: @escaping @Sendable (String) -> Void) async throws -> String {
        let session = URLSession(configuration: .ephemeral, delegate: NoModelRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw ModelProviderError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw ModelProviderError.http(http.statusCode) }
        // Some compatible servers ignore stream=true; parse a bounded ordinary response in that case.
        if !(http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased().contains("text/event-stream") {
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < 1_048_576 else { throw ModelProviderError.responseTooLarge }
                data.append(byte)
            }
            let value = try JSONDecoder().decode(JSONValue.self, from: data)
            guard let text = value["choices"]?[0]?["message"]?["content"]?.stringValue, !text.isEmpty else {
                throw ModelProviderError.emptyResponse
            }
            onDelta(text)
            return text
        }
        var decoder = ChatSSEDecoder()
        var line = Data()
        var total = 0
        for try await byte in bytes {
            try Task.checkCancellation()
            total += 1
            guard total < 2_097_152, line.count < 131072 else { throw ModelProviderError.responseTooLarge }
            if byte == 10 {
                guard let text = String(data: line, encoding: .utf8) else { throw ModelProviderError.invalidResponse }
                line.removeAll(keepingCapacity: true)
                if let delta = try decoder.consume(text.trimmingCharacters(in: .newlines)), !delta.isEmpty {
                    onDelta(delta)
                }
                if decoder.done { break }
            } else {
                line.append(byte)
            }
        }
        guard decoder.done, !decoder.text.isEmpty else { throw ModelProviderError.invalidResponse }
        return decoder.text
    }
}

struct ChatSSEDecoder {
    private(set) var text = ""
    private(set) var done = false
    mutating func consume(_ line: String) throws -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let data = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
        if data == "[DONE]" {
            done = true
            return nil
        }
        guard let bytes = data.data(using: .utf8) else { throw ModelProviderError.invalidResponse }
        let value = try JSONDecoder().decode(JSONValue.self, from: bytes)
        if value["error"] != nil { throw ModelProviderError.invalidResponse }
        if let reason = value["choices"]?[0]?["finish_reason"]?.stringValue, reason != "stop" {
            throw ModelProviderError.invalidResponse
        }
        guard let delta = value["choices"]?[0]?["delta"]?["content"]?.stringValue else { return nil }
        guard text.utf8.count + delta.utf8.count < 1_048_576 else { throw ModelProviderError.responseTooLarge }
        text += delta
        return delta
    }
}

/// Only stream an explicitly final reply envelope. Arguments, IDs and planning JSON are never displayed.
enum ReplyStreamDecoder {
    static func replyPrefix(_ raw: String) -> String? {
        guard
            let prefix = raw.range(
                of: #"^\s*\{\s*"calls"\s*:\s*\[\s*\]\s*,\s*"reply"\s*:\s*""#, options: .regularExpression)
        else { return nil }
        let suffix = String(raw[prefix.upperBound...])
        var escaped = false
        var content = ""
        for character in suffix {
            if character == "\"" && !escaped { break }
            content.append(character)
            if character == "\\" { escaped.toggle() } else { escaped = false }
        }
        // A chunk may stop midway through a JSON escape or surrogate pair. Keep the last valid prefix.
        for _ in 0..<13 {
            if let data = ("\"" + content + "\"").data(using: .utf8),
                let text = try? JSONDecoder().decode(String.self, from: data)
            {
                return text
            }
            guard !content.isEmpty else { return "" }
            content.removeLast()
        }
        return nil
    }
}
