import Foundation

/// Validates ZIP paths, local headers, file types and expansion bounds before calling the system extractor.
/// Deliberately refuses ZIP64, encryption, symlinks and unusual encodings rather than guessing.
enum ZipInspection {
    struct Entry: Equatable {
        let path: String
        let size: Int
    }
    enum Failure: Error { case invalid, unsafePath, unsupported, expansionLimit }
    static func entries(in data: Data) throws -> [Entry] {
        guard data.count <= 100_000_000, data.count >= 22 else { throw Failure.invalid }
        func word(_ at: Int) throws -> Int {
            guard at >= 0, at + 2 <= data.count else { throw Failure.invalid }
            return Int(data[at]) | (Int(data[at + 1]) << 8)
        }
        func long(_ at: Int) throws -> Int { try word(at) | (word(at + 2) << 16) }
        var end: Int?
        for offset in stride(from: data.count - 22, through: max(0, data.count - 65557), by: -1) {
            if try long(offset) == 0x0605_4b50, offset + 22 + (try word(offset + 20)) == data.count {
                end = offset
                break
            }
        }
        guard let end else { throw Failure.invalid }
        guard try word(end + 4) == 0, (try word(end + 6)) == 0, (try word(end + 8)) == (try word(end + 10)) else {
            throw Failure.unsupported
        }
        let count = try word(end + 10)
        guard count <= 1000, count != 65535 else { throw Failure.expansionLimit }
        let centralSize = try long(end + 12)
        let centralOffset = try long(end + 16)
        guard centralOffset + centralSize == end else { throw Failure.invalid }
        var offset = centralOffset
        var total = 0
        var seen = Set<String>()
        var output: [Entry] = []
        for _ in 0..<count {
            guard try long(offset) == 0x0201_4b50 else { throw Failure.invalid }
            let flags = try word(offset + 8)
            let method = try word(offset + 10)
            guard flags & 1 == 0, [0, 8].contains(method) else { throw Failure.unsupported }
            let compressed = try long(offset + 20)
            let expanded = try long(offset + 24)
            let nameLength = try word(offset + 28)
            let extraLength = try word(offset + 30)
            let commentLength = try word(offset + 32)
            let external = try long(offset + 38)
            let local = try long(offset + 42)
            guard nameLength > 0, offset + 46 + nameLength + extraLength + commentLength <= end else {
                throw Failure.invalid
            }
            let nameData = data.subdata(in: offset + 46..<offset + 46 + nameLength)
            guard let name = String(data: nameData, encoding: .utf8), !name.contains("\u{0000}") else {
                throw Failure.unsupported
            }
            let components = name.split(separator: "/", omittingEmptySubsequences: false)
            guard !name.hasPrefix("/"), !name.contains("\\"), !name.contains(":"), !components.contains(".."),
                !components.contains("."), !components.dropLast().contains("")
            else { throw Failure.unsafePath }
            let type = (external >> 16) & 0o170000
            guard [0, 0o100000, 0o040000].contains(type) else { throw Failure.unsafePath }
            let normalized = name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                .precomposedStringWithCanonicalMapping.lowercased()
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { throw Failure.unsafePath }
            guard try long(local) == 0x0403_4b50, (try word(local + 6)) == flags, (try word(local + 8)) == method else {
                throw Failure.invalid
            }
            let localLength = try word(local + 26)
            let localExtra = try word(local + 28)
            guard localLength == nameLength, local + 30 + localLength + localExtra + compressed <= centralOffset,
                local + 30 + localLength <= data.count,
                data.subdata(in: local + 30..<local + 30 + localLength) == nameData
            else { throw Failure.invalid }
            total += expanded
            guard total <= 200_000_000, expanded < 0xffff_ffff, compressed < 0xffff_ffff else {
                throw Failure.expansionLimit
            }
            output.append(Entry(path: name, size: expanded))
            offset += 46 + nameLength + extraLength + commentLength
        }
        guard offset == end else { throw Failure.invalid }
        return output
    }
}
