//
//  MALDebugTokenExport.swift
//  MangaCarta
//
//  `-debug-export-mal-token` (issue #360), for `scripts/mal_live_write.py`. That harness
//  records and restores a real MAL list entry around the one live write test, so it needs an
//  access token — and MAL refuses to approve an OAuth request made outside the app's own
//  sign-in sheet. So the harness borrows the app's: launched with this flag, the app asks its
//  token manager for a token (refreshing and saving it first if it is near expiry, exactly as
//  a progress push would) and writes only the access token to its `tmp/`. The harness reads
//  the file and deletes it at once. DEBUG only: a release build has no way to emit a token.
//

#if DEBUG
import Foundation

enum MALDebugTokenExport {
    static let flag = "-debug-export-mal-token"
    /// In the app's `tmp/`. `scripts/mal_live_write.py` names it too.
    static let fileName = "mal-debug-token.json"

    static var fileURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
    }

    static func isRequested(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        arguments.contains(flag)
    }

    /// Writes `{"access_token": …}`, or `{"error": …}` when no token can be had. Never the
    /// refresh token: the harness only reads and restores one entry, and a refresh token in a
    /// file would outlive the run that needed it. Atomic, so the harness, which polls for the
    /// file, can never read half of it.
    static func export(token: () async throws -> String, to file: URL) async {
        let payload: [String: String]
        do {
            payload = ["access_token": try await token()]
        } catch {
            payload = ["error": String(describing: error)]
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            try data.write(to: file, options: [.atomic, .completeFileProtection])
        } catch {
            NSLog("[debug] MAL token export could not be written: %@", "\(error)")
        }
    }
}
#endif
