import Foundation
import Testing
@testable import MangaCarta

private struct ExportPayload: Decodable {
    let accessToken: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case error
    }
}

/// `-debug-export-mal-token` (issue #360): the live-write harness reads the app's own access
/// token from a file, because MAL will not approve the harness's own OAuth request.
@Suite("MAL debug token export")
struct MALDebugTokenExportTests {
    /// The app's `tmp/` always exists; a `TestDirectory` path does not until made.
    private func exportFile(in dir: TestDirectory) throws -> URL {
        try FileManager.default.createDirectory(at: dir.url, withIntermediateDirectories: true)
        return dir.url.appendingPathComponent("token.json")
    }

    private func payload(at url: URL) throws -> ExportPayload {
        try JSONDecoder().decode(ExportPayload.self, from: Data(contentsOf: url))
    }

    @Test("runs only when the flag is passed")
    func requestedOnlyByFlag() {
        #expect(MALDebugTokenExport.isRequested(arguments: ["MangaCarta", "-debug-export-mal-token"]))
        #expect(!MALDebugTokenExport.isRequested(arguments: ["MangaCarta"]))
        #expect(!MALDebugTokenExport.isRequested(arguments: ["MangaCarta", "-uitest-mal-offline"]))
    }

    @Test("writes the token the manager hands out")
    func writesToken() async throws {
        let dir = TestDirectory("mal-token-export")
        defer { dir.remove() }
        let file = try exportFile(in: dir)

        await MALDebugTokenExport.export(token: { "fresh-access" }, to: file)

        let written = try payload(at: file)
        #expect(written.accessToken == "fresh-access")
        #expect(written.error == nil)
    }

    @Test("a signed-out account writes an error, never a token")
    func signedOutWritesError() async throws {
        let dir = TestDirectory("mal-token-export")
        defer { dir.remove() }
        let file = try exportFile(in: dir)

        await MALDebugTokenExport.export(token: { throw MALTokenError.signedOut }, to: file)

        let written = try payload(at: file)
        #expect(written.accessToken == nil)
        #expect(written.error == "signedOut")
    }

    @Test("replaces a token left by an earlier export")
    func replacesStaleFile() async throws {
        let dir = TestDirectory("mal-token-export")
        defer { dir.remove() }
        let file = try exportFile(in: dir)

        await MALDebugTokenExport.export(token: { "old" }, to: file)
        await MALDebugTokenExport.export(token: { throw MALTokenError.signedOut }, to: file)

        #expect(try payload(at: file).accessToken == nil)
    }
}
