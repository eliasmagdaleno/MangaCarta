import Foundation

struct URLSessionFetchResult: Sendable {
    let data: Data
    let response: URLResponse
    let connectedPeerAddress: String?
}

protocol URLSessionDataFetching: Sendable {
    func fetch(_ request: URLRequest) async throws -> URLSessionFetchResult
}

/// URLSession's async convenience API does not expose task metrics. This delegate-backed
/// adapter keeps the metrics attached to the exact task whose response it returns.
final class URLSessionDataFetcher: NSObject, URLSessionDataFetching, URLSessionDataDelegate,
                                   @unchecked Sendable {
    private struct Pending {
        var data = Data()
        var response: URLResponse?
        var peerAddress: String?
        var continuation: CheckedContinuation<URLSessionFetchResult, Error>
    }

    private let lock = NSLock()
    private lazy var session: URLSession = URLSession(configuration: configuration,
                                                       delegate: self,
                                                       delegateQueue: nil)
    private let configuration: URLSessionConfiguration
    private var pending: [Int: Pending] = [:]
    private let redirectHandler: @Sendable (URLRequest) -> URLRequest?

    init(configuration: URLSessionConfiguration,
         redirectHandler: @escaping @Sendable (URLRequest) -> URLRequest?) {
        self.configuration = configuration
        self.redirectHandler = redirectHandler
    }

    func fetch(_ request: URLRequest) async throws -> URLSessionFetchResult {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request)
            lock.lock()
            pending[task.taskIdentifier] = Pending(continuation: continuation)
            lock.unlock()
            task.resume()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        lock.lock(); pending[dataTask.taskIdentifier]?.data.append(data); lock.unlock()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock(); pending[dataTask.taskIdentifier]?.response = response; lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(redirectHandler(request))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didFinishCollecting metrics: URLSessionTaskMetrics) {
        let peer = metrics.transactionMetrics.last?.remoteAddress
        lock.lock(); pending[task.taskIdentifier]?.peerAddress = peer; lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        lock.lock()
        guard let state = pending.removeValue(forKey: task.taskIdentifier) else {
            lock.unlock(); return
        }
        lock.unlock()
        if let error {
            state.continuation.resume(throwing: error)
        } else if let response = state.response {
            state.continuation.resume(returning: URLSessionFetchResult(
                data: state.data, response: response, connectedPeerAddress: state.peerAddress))
        } else {
            state.continuation.resume(throwing: URLError(.badServerResponse))
        }
    }
}
