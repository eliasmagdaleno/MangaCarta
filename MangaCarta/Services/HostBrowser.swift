//
//  HostBrowser.swift
//  MangaCarta
//
//  Production host.browser.extract. It deliberately does not reuse WebViewService:
//  compiled WeebCentral still uses the shared default store, while Extension Sources
//  receive persistent identified stores partitioned by qualified Source id.
//

import Foundation
import WebKit
import CryptoKit
import Combine

@MainActor
enum ExtensionBrowserStore {
    /// Permanent. Changing this value orphans every reader's stored browser clearance.
    private static let namespace = UUID(
        uuidString: "1A4F4172-8B42-4B3E-9C24-5E7D8B6A91F0"
    )!

    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"

    static func identifier(for sourceID: QualifiedSourceID) -> UUID {
        var hasher = Insecure.SHA1()
        var namespaceBytes = namespace.uuid
        withUnsafeBytes(of: &namespaceBytes) { hasher.update(bufferPointer: $0) }
        hasher.update(data: Data(sourceID.rawValue.utf8))
        var bytes = Array(hasher.finalize().prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return bytes.withUnsafeBufferPointer { buffer in
            NSUUID(uuidBytes: buffer.baseAddress) as UUID
        }
    }

    /// Constructing a real WKWebView against the store is required for cookies to
    /// become durable; retaining the WKWebsiteDataStore alone is insufficient.
    static func makeWebView(for sourceID: QualifiedSourceID) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(
            forIdentifier: identifier(for: sourceID)
        )
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844),
                                configuration: configuration)
        webView.customUserAgent = userAgent
        return webView
    }

    /// A store is materialised lazily. Awaiting one operation closes the creation race,
    /// but callers must still never treat an immediate cookie read as authoritative.
    static func warmUp(_ store: WKWebsiteDataStore) async {
        _ = await withCheckedContinuation { continuation in
            store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) {
                continuation.resume(returning: $0)
            }
        }
    }

    static func removeData(for sourceID: QualifiedSourceID) async {
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.remove(forIdentifier: identifier(for: sourceID)) { _ in
                continuation.resume()
            }
        }
    }
}

@MainActor
struct ExtensionBrowserChallenge: Identifiable {
    let id: UUID
    let sourceName: String
    let origin: String
    let webView: WKWebView
}

struct HostBrowserCapability {
    private let sourceID: QualifiedSourceID
    private let sourceName: String
    private let allowedOrigins: [String]
    private let context: HostInvocationContext
    private let manager: ExtensionBrowserManager

    @MainActor
    init(sourceID: QualifiedSourceID,
         sourceName: String,
         allowedOrigins: [String],
         context: HostInvocationContext,
         manager: ExtensionBrowserManager) {
        self.sourceID = sourceID
        self.sourceName = sourceName
        self.allowedOrigins = allowedOrigins
        self.context = context
        self.manager = manager
    }

    @MainActor
    func extract(_ request: HostBrowserRequest) async throws -> HostBrowserResult {
        try await manager.extract(sourceID: sourceID,
                                  sourceName: sourceName,
                                  allowedOrigins: allowedOrigins,
                                  request: request,
                                  context: context)
    }
}

@MainActor
final class ExtensionBrowserManager: ObservableObject {
    static let shared = ExtensionBrowserManager()

    @Published private(set) var activeChallenge: ExtensionBrowserChallenge?

    private let resolver: any HostNameResolving
    private var drivers: [QualifiedSourceID: HostBrowserDriver] = [:]
    private var lockBusy = false
    private var waiters: [BrowserWaiter] = []

    init(resolver: any HostNameResolving = SystemHostResolver()) {
        self.resolver = resolver
    }

    func extract(sourceID: QualifiedSourceID,
                 sourceName: String,
                 allowedOrigins: [String],
                 request: HostBrowserRequest,
                 context: HostInvocationContext) async throws -> HostBrowserResult {
        let waiterID = UUID()
        try await acquire(waiterID)
        defer { release() }
        try Task.checkCancellation()

        let driver: HostBrowserDriver
        if let existing = drivers[sourceID], existing.allowedOrigins == allowedOrigins {
            driver = existing
        } else {
            let created = HostBrowserDriver(sourceID: sourceID,
                                            allowedOrigins: allowedOrigins,
                                            resolver: resolver)
            created.manager = self
            drivers[sourceID] = created
            driver = created
        }
        return try await driver.extract(request,
                                        sourceName: sourceName,
                                        context: context)
    }

    func cancelActiveChallenge() {
        guard let challenge = activeChallenge,
              let driver = drivers.values.first(where: { $0.webView === challenge.webView }) else {
            return
        }
        driver.cancelChallenge()
    }

    fileprivate func present(_ challenge: ExtensionBrowserChallenge) {
        activeChallenge = challenge
    }

    fileprivate func dismiss(_ challengeID: UUID) {
        guard activeChallenge?.id == challengeID else { return }
        activeChallenge = nil
    }

    private func acquire(_ id: UUID) async throws {
        if !lockBusy {
            lockBusy = true
            return
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(BrowserWaiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func release() {
        if waiters.isEmpty {
            lockBusy = false
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }
}

private struct BrowserWaiter {
    let id: UUID
    let continuation: CheckedContinuation<Void, Error>
}

@MainActor
private final class HostBrowserDriver: NSObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    let allowedOrigins: [String]
    weak var manager: ExtensionBrowserManager?

    private let navigationGuard: HostBrowserNavigationGuard
    private var loadContinuation: CheckedContinuation<Void, Error>?
    private var scriptContinuation: CheckedContinuation<Any, Error>?
    private var challengeContinuation: CheckedContinuation<Void, Error>?
    private var currentNavigation: WKNavigation?
    private var sawChallengeHeader = false
    private var scriptGeneration = 0
    private var challengeID: UUID?

    init(sourceID: QualifiedSourceID,
         allowedOrigins: [String],
         resolver: any HostNameResolving) {
        webView = ExtensionBrowserStore.makeWebView(for: sourceID)
        self.allowedOrigins = allowedOrigins
        navigationGuard = HostBrowserNavigationGuard(allowedOrigins: allowedOrigins,
                                                      resolver: resolver)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    func extract(_ request: HostBrowserRequest,
                 sourceName: String,
                 context: HostInvocationContext) async throws -> HostBrowserResult {
        try await requireAllowed(request.url)
        try await load(request.url)
        if sawChallengeHeader {
            guard request.interaction == .allowForeground, context == .foreground else {
                throw HostCapabilityError(code: .interactionRequired,
                                          message: "browser verification requires foreground interaction")
            }
            try Task.checkCancellation()
            try await awaitChallenge(sourceName: sourceName)
        }
        let raw = try await runScript(request.script)
        let value = try HostJSONValueConverter.convert(raw)
        let finalURL = webView.url ?? request.url
        try await requireAllowed(finalURL)
        return HostBrowserResult(value: value, finalURL: finalURL, warnings: [])
    }

    func cancelChallenge() {
        resumeChallenge(.failure(HostCapabilityError(
            code: .interactionDeclined,
            message: "the reader declined browser verification"
        )))
    }

    private func requireAllowed(_ url: URL) async throws {
        switch await navigationGuard.decision(for: url) {
        case .allow: return
        case .cancel(let error): throw error
        }
    }

    private func load(_ url: URL) async throws {
        sawChallengeHeader = false
        let deadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(HostCapabilityLimits.browserNavigationTimeout))
            guard !Task.isCancelled, let self else { return }
            self.webView.stopLoading()
            self.resumeLoad(.failure(HostCapabilityError(
                code: .timeout,
                message: "browser navigation timed out"
            )))
        }
        defer { deadline.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                loadContinuation = continuation
                currentNavigation = webView.load(URLRequest(url: url))
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.webView.stopLoading()
                self?.resumeLoad(.failure(HostCapabilityError(
                    code: .cancelled,
                    message: "browser navigation was cancelled"
                )))
            }
        }
    }

    private func awaitChallenge(sourceName: String) async throws {
        let identity = UUID()
        challengeID = identity
        let origin = webView.url.flatMap(HostURLPolicy.canonicalOrigin) ?? "https://unknown.invalid"
        manager?.present(ExtensionBrowserChallenge(id: identity,
                                                   sourceName: sourceName,
                                                   origin: origin,
                                                   webView: webView))
        defer {
            manager?.dismiss(identity)
            challengeID = nil
        }

        let deadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(HostCapabilityLimits.browserInteractionTimeout))
            guard !Task.isCancelled, let self else { return }
            self.resumeChallenge(.failure(HostCapabilityError(
                code: .interactionTimedOut,
                message: "browser verification timed out"
            )))
        }
        defer { deadline.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                challengeContinuation = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resumeChallenge(.failure(HostCapabilityError(
                    code: .cancelled,
                    message: "browser verification was cancelled"
                )))
            }
        }
    }

    private func runScript(_ script: String) async throws -> Any {
        scriptGeneration += 1
        let generation = scriptGeneration
        let deadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(HostCapabilityLimits.browserScriptTimeout))
            guard !Task.isCancelled, let self else { return }
            self.resumeScript(.failure(HostCapabilityError(
                code: .timeout,
                message: "browser script execution timed out"
            )))
        }
        defer { deadline.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                scriptContinuation = continuation
                webView.evaluateJavaScript(script) { [weak self] value, error in
                    guard let self, generation == self.scriptGeneration else { return }
                    if error != nil {
                        self.resumeScript(.failure(HostCapabilityError(
                            code: .script,
                            message: "browser script execution failed"
                        )))
                    } else if let value {
                        self.resumeScript(.success(value))
                    } else {
                        self.resumeScript(.success(NSNull()))
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.scriptGeneration += 1
                self?.resumeScript(.failure(HostCapabilityError(
                    code: .cancelled,
                    message: "browser script execution was cancelled"
                )))
            }
        }
    }

    private func resumeLoad(_ result: Result<Void, Error>) {
        guard let continuation = loadContinuation else { return }
        loadContinuation = nil
        continuation.resume(with: result)
    }

    private func resumeScript(_ result: Result<Any, Error>) {
        guard let continuation = scriptContinuation else { return }
        scriptContinuation = nil
        continuation.resume(with: result)
    }

    private func resumeChallenge(_ result: Result<Void, Error>) {
        guard let continuation = challengeContinuation else { return }
        challengeContinuation = nil
        continuation.resume(with: result)
    }

    private func isCurrent(_ navigation: WKNavigation?) -> Bool {
        guard let navigation, let currentNavigation else { return true }
        return navigation === currentNavigation
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard navigationAction.targetFrame?.isMainFrame == true,
              let url = navigationAction.request.url else {
            return .cancel
        }
        switch await navigationGuard.decision(for: url) {
        case .allow:
            return .allow
        case .cancel(let error):
            resumeLoad(.failure(error))
            resumeChallenge(.failure(error))
            return .cancel
        }
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if navigationResponse.isForMainFrame,
           let response = navigationResponse.response as? HTTPURLResponse {
            sawChallengeHeader = response.value(forHTTPHeaderField: "cf-mitigated")?.lowercased()
                == "challenge"
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if loadContinuation != nil, let navigation { currentNavigation = navigation }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if loadContinuation != nil {
            guard isCurrent(navigation) else { return }
            resumeLoad(.success(()))
        } else if challengeContinuation != nil, !sawChallengeHeader {
            resumeChallenge(.success(()))
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationFailed(navigation, error: error)
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        navigationFailed(navigation, error: error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        let error = HostCapabilityError(code: .navigation,
                                        message: "the browser content process terminated")
        resumeLoad(.failure(error))
        resumeChallenge(.failure(error))
        resumeScript(.failure(error))
    }

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        nil
    }

    private func navigationFailed(_ navigation: WKNavigation?, error: Error) {
        let networkError = error as NSError
        if networkError.domain == NSURLErrorDomain,
           networkError.code == NSURLErrorCancelled { return }
        guard isCurrent(navigation) else { return }
        resumeLoad(.failure(HostCapabilityError(code: .navigation,
                                                message: "browser navigation failed")))
    }
}

@MainActor
final class ExtensionHostCapabilityFactory {
    let storageRepository: HostStorageRepository
    let diagnosticBuffer: HostDiagnosticBuffer
    let browserManager: ExtensionBrowserManager

    private let transport: any HostHTTPTransport
    private let resolver: any HostNameResolving
    private let rateLimiters: HostRateLimiterRegistry
    private var cookieJars: [QualifiedSourceID: HostHTTPCookieJar] = [:]

    convenience init(directory: URL,
                     rateLimiters: HostRateLimiterRegistry = HostRateLimiterRegistry()) throws {
        try self.init(directory: directory,
                      transport: URLSessionHostHTTPTransport(),
                      resolver: SystemHostResolver(),
                      browserManager: .shared,
                      diagnosticBuffer: HostDiagnosticBuffer(),
                      rateLimiters: rateLimiters)
    }

    init(directory: URL,
         transport: any HostHTTPTransport,
         resolver: any HostNameResolving,
         browserManager: ExtensionBrowserManager,
         diagnosticBuffer: HostDiagnosticBuffer,
         rateLimiters: HostRateLimiterRegistry = HostRateLimiterRegistry()) throws {
        storageRepository = try HostStorageRepository(directory: directory)
        self.transport = transport
        self.resolver = resolver
        self.browserManager = browserManager
        self.diagnosticBuffer = diagnosticBuffer
        self.rateLimiters = rateLimiters
    }

    func capabilities(for declaration: SourceDeclaration,
                      operation: SourceOperation,
                      invocationID: UUID,
                      context: HostInvocationContext) -> ExtensionHostCapabilities {
        let jar = cookieJars[declaration.qualifiedId] ?? HostHTTPCookieJar(
            sourceID: declaration.qualifiedId
        )
        cookieJars[declaration.qualifiedId] = jar
        return ExtensionHostCapabilities(
            http: HostHTTPClient(sourceID: declaration.qualifiedId,
                                 allowedOrigins: declaration.network.httpOrigins,
                                 transport: transport,
                                 resolver: resolver,
                                 cookies: jar,
                                 rateLimiters: rateLimiters),
            browser: HostBrowserCapability(sourceID: declaration.qualifiedId,
                                           sourceName: declaration.name,
                                           allowedOrigins: declaration.network.browserOrigins,
                                           context: context,
                                           manager: browserManager),
            storage: HostStorage(sourceID: declaration.qualifiedId,
                                 repository: storageRepository),
            log: HostLogger(sourceID: declaration.qualifiedId,
                            operation: operation,
                            invocationID: invocationID,
                            hostAPIVersion: declaration.selectedHostAPIVersion,
                            buffer: diagnosticBuffer)
        )
    }
}
