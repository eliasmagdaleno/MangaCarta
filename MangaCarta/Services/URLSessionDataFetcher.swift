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
    private final class CancellationState: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionDataTask?
        private var isCancelled = false

        func setTask(_ task: URLSessionDataTask) {
            lock.lock()
            self.task = task
            let shouldCancel = isCancelled
            lock.unlock()
            if shouldCancel { task.cancel() }
        }

        func cancel() {
            lock.lock()
            isCancelled = true
            let task = self.task
            lock.unlock()
            task?.cancel()
        }
    }

    private struct Pending {
        var data = Data()
        var response: URLResponse?
        var peerAddress: String?
        var continuation: CheckedContinuation<URLSessionFetchResult, Error>
    }

    private let lock = NSLock()
    private let configuration: URLSessionConfiguration
    // Task identifiers restart from zero for each URLSession. This is safe because the
    // session is invalidated as soon as it becomes idle; alternatively key by
    // (ObjectIdentifier(session), taskIdentifier).
    private var session: URLSession?
    private var pending: [Int: Pending] = [:]
    private let redirectHandler: @Sendable (URLRequest) -> URLRequest?

    init(configuration: URLSessionConfiguration,
         redirectHandler: @escaping @Sendable (URLRequest) -> URLRequest?) {
        self.configuration = configuration
        self.redirectHandler = redirectHandler
    }

    func fetch(_ request: URLRequest) async throws -> URLSessionFetchResult {
        let cancellation = CancellationState()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if session == nil {
                    session = URLSession(configuration: configuration,
                                         delegate: self,
                                         delegateQueue: nil)
                }
                let task = session!.dataTask(with: request)
                pending[task.taskIdentifier] = Pending(continuation: continuation)
                lock.unlock()
                cancellation.setTask(task)
                task.resume()
            }
        }, onCancel: {
            cancellation.cancel()
        })
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
        invalidateSessionIfIdle()
        if let error {
            state.continuation.resume(throwing: error)
        } else if let response = state.response {
            state.continuation.resume(returning: URLSessionFetchResult(
                data: state.data, response: response, connectedPeerAddress: state.peerAddress))
        } else {
            state.continuation.resume(throwing: URLError(.badServerResponse))
        }
    }

    private func invalidateSessionIfIdle() {
        lock.lock()
        guard pending.isEmpty, let session else {
            lock.unlock()
            return
        }
        self.session = nil
        lock.unlock()
        session.finishTasksAndInvalidate()
    }
}
