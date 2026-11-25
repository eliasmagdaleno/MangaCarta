import Foundation

enum AnalyticsUploadResult: Equatable { case accepted, rejected, retry }

@MainActor
protocol AnalyticsTransport: AnyObject {
    func sendBatch(_ body: Data) async -> AnalyticsUploadResult
    func deleteInstall(_ id: UUID) async -> AnalyticsUploadResult
}

@MainActor
final class URLSessionAnalyticsTransport: AnalyticsTransport {
    private let host: String
    private let session: URLSession

    init(host: String, configuration: URLSessionConfiguration = .ephemeral) {
        self.host = host
        session = URLSession(configuration: Self.hardened(configuration))
    }

    static func hardened(_ configuration: URLSessionConfiguration) -> URLSessionConfiguration {
        let safe = configuration.copy() as? URLSessionConfiguration ?? .ephemeral
        safe.httpCookieStorage = nil
        safe.httpShouldSetCookies = false
        safe.urlCache = nil
        safe.requestCachePolicy = .reloadIgnoringLocalCacheData
        safe.timeoutIntervalForRequest = 30
        safe.timeoutIntervalForResource = 30
        return safe
    }

    func sendBatch(_ body: Data) async -> AnalyticsUploadResult {
        var request = URLRequest(url: URL(string: "https://\(host)/v1/events")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return await perform(request)
    }

    func deleteInstall(_ id: UUID) async -> AnalyticsUploadResult {
        var request = URLRequest(url: URL(string: "https://\(host)/v1/installs/\(id.uuidString)")!)
        request.httpMethod = "DELETE"
        return await perform(request)
    }

    private func perform(_ request: URLRequest) async -> AnalyticsUploadResult {
        do {
            let (_, response) = try await session.data(for: request)
            guard let status = (response as? HTTPURLResponse)?.statusCode else { return .retry }
            if (200..<300).contains(status) { return .accepted }
            // Request Timeout and Too Many Requests are temporary, not a verdict on the body.
            if status == 408 || status == 429 { return .retry }
            if (400..<500).contains(status) { return .rejected }
            return .retry
        } catch { return .retry }
    }
}

@MainActor
enum AnalyticsTransportSelection {
    static func make(host: String?, arguments: [String], isDebug: Bool) -> URLSessionAnalyticsTransport? {
        guard let host, !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !host.contains("$("), host.range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression) != nil,
              !arguments.contains(where: { $0.hasPrefix("-uitest-") }),
              !isDebug || arguments.contains("-analytics-debug-uploads") else { return nil }
        return URLSessionAnalyticsTransport(host: host)
    }

    nonisolated static func current() -> URLSessionAnalyticsTransport? {
        #if DEBUG
        let debug = true
        #else
        let debug = false
        #endif
        let host = Bundle.main.object(forInfoDictionaryKey: "AnalyticsHost") as? String
        let arguments = ProcessInfo.processInfo.arguments
        return MainActor.assumeIsolated { make(host: host, arguments: arguments, isDebug: debug) }
    }
}
