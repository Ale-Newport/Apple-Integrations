import JarvisCore
import XCTest

@testable import JarvisIntegrations

final class FilesSafetyTests: XCTestCase {
    func testLargeCopyRequiresFreshConfirmationBeforeAnyDestinationExists() async throws {
        let root = try fixture()
        let folder = root.appendingPathComponent("many")
        let target = root.appendingPathComponent("copied")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        for i in 0..<21 { try Data("x".utf8).write(to: folder.appendingPathComponent("\(i).txt")) }
        let registry = ToolRegistry(integrations: [FilesIntegration()])
        let outcome = try await registry.run(
            "files.copy", ["path": .string(folder.path), "destination": .string(target.path)], context: context(root))
        let review = try XCTUnwrap(outcome.confirmation)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        try Data("different".utf8).write(to: folder.appendingPathComponent("0.txt"))
        let changed = try await registry.run(
            "files.copy", review.call.arguments, context: context(root, confirmed: true))
        let current = try XCTUnwrap(changed.confirmation)
        XCTAssertNotEqual(review.call.arguments["revision"], current.call.arguments["revision"])
        _ = try await registry.run("files.copy", current.call.arguments, context: context(root, confirmed: true))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path).count, 21)
    }
    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "jarvis-files-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func context(_ root: URL, confirmed: Bool = false) -> ExecutionContext {
        var settings = JarvisSettings()
        settings.capabilities.fileRoots = [root.path]
        return executionContext(confirmed: confirmed, settings: settings)
    }
    func testCanonicalScopeRejectsTraversalOutsideLinksRootMutationsAndSiblingPrefixes() throws {
        let root = try fixture()
        let outside = try fixture()
        let scope = FileScope(paths: [root.path])
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("internal-link"), withDestinationURL: root.appendingPathComponent("target"))
        XCTAssertThrowsError(try scope.resolve(root.path + "/../outside"))
        XCTAssertThrowsError(try scope.resolve(root.path + "-other/data"))
        XCTAssertThrowsError(try scope.resolve(root.path + "/escape/file"))
        XCTAssertThrowsError(try scope.resolve(root.path, modifying: true))
        XCTAssertThrowsError(try scope.resolve(root.path + "/internal-link", modifying: true))
        XCTAssertEqual(try scope.resolve(root.path + "/new/data").path, root.path + "/new/data")
    }
    func testNoFileAccessBeforeUserApprovesFolder() async throws {
        let registry = ToolRegistry(integrations: [FilesIntegration()])
        do {
            _ = try await registry.run("files.list", ["path": "/tmp"])
            XCTFail()
        } catch let error as JarvisError { XCTAssertEqual(error.code, "setup_required") }
    }
    func testCopyMoveReadAndNoOverwriteUseActualFilesystem() async throws {
        let root = try fixture()
        let source = root.appendingPathComponent("input.txt")
        let copy = root.appendingPathComponent("copy.txt")
        let moved = root.appendingPathComponent("moved.txt")
        try Data("line one\nline two".utf8).write(to: source)
        let registry = ToolRegistry(integrations: [FilesIntegration()])
        let ctx = context(root)
        let read = try await registry.run("files.read", ["path": .string(source.path)], context: ctx)
        XCTAssertEqual(read.output?.data?["text"]?.stringValue, "line one\nline two")
        _ = try await registry.run(
            "files.copy", ["path": .string(source.path), "destination": .string(copy.path)], context: ctx)
        do {
            _ = try await registry.run(
                "files.copy", ["path": .string(source.path), "destination": .string(copy.path)], context: ctx)
            XCTFail()
        } catch {}
        _ = try await registry.run(
            "files.move", ["path": .string(copy.path), "destination": .string(moved.path)], context: ctx)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertEqual(try Data(contentsOf: source), try Data(contentsOf: moved))
    }
    func testOrganizeReconfirmsChangedFileSetAndFindsExactDuplicates() async throws {
        let root = try fixture()
        let a = root.appendingPathComponent("a.txt")
        let b = root.appendingPathComponent("b.txt")
        try Data("same".utf8).write(to: a)
        try Data("same".utf8).write(to: b)
        let registry = ToolRegistry(integrations: [FilesIntegration()])
        let ctx = context(root)
        let groups = try await registry.run("files.duplicates", ["path": .string(root.path)], context: ctx)
        XCTAssertEqual(groups.output?.data?["duplicate_groups"]?.arrayValue?.count, 1)
        let review = try await registry.run("files.organize", ["path": .string(root.path)], context: ctx)
        let original = try XCTUnwrap(review.confirmation)
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
        try Data("changed and longer".utf8).write(to: b)
        let changed = try await registry.run(
            "files.organize", original.call.arguments, context: context(root, confirmed: true))
        let latest = try XCTUnwrap(changed.confirmation)
        XCTAssertNotEqual(original.call.arguments["revision"], latest.call.arguments["revision"])
        _ = try await registry.run("files.organize", latest.call.arguments, context: context(root, confirmed: true))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("TXT/a.txt"), encoding: .utf8), "same")
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.path))
    }
    func testZipRoundtripRequiresReviewAndPreservesContent() async throws {
        let root = try fixture()
        let source = root.appendingPathComponent("sample.txt")
        let archive = root.appendingPathComponent("sample.zip")
        let extracted = root.appendingPathComponent("extracted")
        try Data("zip roundtrip".utf8).write(to: source)
        let registry = ToolRegistry(integrations: [FilesIntegration()])
        _ = try await registry.run(
            "files.compress", ["path": .string(source.path), "destination": .string(archive.path)],
            context: context(root))
        XCTAssertEqual(try ZipInspection.entries(in: Data(contentsOf: archive)).map(\.path), ["sample.txt"])
        let review = try await registry.run(
            "files.extract", ["path": .string(archive.path), "destination": .string(extracted.path)],
            context: context(root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: extracted.path))
        _ = try await registry.run(
            "files.extract", try XCTUnwrap(review.confirmation).call.arguments, context: context(root, confirmed: true))
        XCTAssertEqual(
            try String(contentsOf: extracted.appendingPathComponent("sample.txt"), encoding: .utf8), "zip roundtrip")
    }
    func testZipRejectsMalformedAndTraversalHeaders() throws {
        XCTAssertThrowsError(try ZipInspection.entries(in: Data()))
        // A valid uncompressed zero-byte ZIP whose central and local names agree.
        func archive(_ name: String, mode: Int = 0o100644) -> Data {
            var bytes = Data()
            func w(_ v: Int) {
                bytes.append(UInt8(v & 255))
                bytes.append(UInt8((v >> 8) & 255))
            }
            func l(_ v: Int) {
                w(v)
                w(v >> 16)
            }
            let n = Array(name.utf8)
            l(0x0403_4b50)
            w(20)
            w(0)
            w(0)
            w(0)
            w(0)
            l(0)
            l(0)
            l(0)
            w(n.count)
            w(0)
            bytes.append(contentsOf: n)
            let offset = bytes.count
            l(0x0201_4b50)
            w(0x0314)
            w(20)
            w(0)
            w(0)
            w(0)
            w(0)
            l(0)
            l(0)
            l(0)
            w(n.count)
            w(0)
            w(0)
            w(0)
            w(0)
            l(mode << 16)
            l(0)
            bytes.append(contentsOf: n)
            let size = bytes.count - offset
            l(0x0605_4b50)
            w(0)
            w(0)
            w(1)
            w(1)
            l(size)
            l(offset)
            w(0)
            return bytes
        }
        XCTAssertEqual(try ZipInspection.entries(in: archive("safe.txt")).count, 1)
        for name in ["../escape", "/absolute", "a/../../escape", "a\\escape", "a:fork", "a//bad"] {
            XCTAssertThrowsError(try ZipInspection.entries(in: archive(name)), name)
        }
        XCTAssertThrowsError(try ZipInspection.entries(in: archive("link", mode: 0o120777)))
    }
}
