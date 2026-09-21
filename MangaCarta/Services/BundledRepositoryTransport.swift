import Foundation

/// The repository shipped with the app. Its bytes are resources so installation uses the
/// same transport and installer path as a user-added repository.
struct BundledRepositoryTransport: RepositoryTransport, @unchecked Sendable {
    enum Error: LocalizedError, Equatable {
        case missingResource(String)
        case adultSource(String)
        case invalidScript
        case scriptTooLarge(actualBytes: Int, maximumBytes: Int)

        var errorDescription: String? {
            switch self {
            case .missingResource(let name): return "The bundled repository resource '\(name)' is missing."
            case .adultSource(let localID): return "The bundled repository cannot include adult Source '\(localID)'."
            case .invalidScript: return "The bundled repository engine is not valid UTF-8."
            case .scriptTooLarge(let actual, let maximum):
                return "Bundle script is \(actual) bytes; the maximum is \(maximum) bytes."
            }
        }
    }

    let bundle: Bundle
    let repositoryID: UUID

    init(bundle: Bundle = .main, repositoryID: UUID = BundledRepositories.weebCentralRepositoryID) {
        self.bundle = bundle
        self.repositoryID = repositoryID
    }

    func fetchIndex(at url: URL) async throws -> RepositoryIndexFetchOutcome {
        guard let resourceURL = bundle.url(forResource: "index", withExtension: "json",
                                           subdirectory: "BundledRepositories/weebcentral") else {
            throw Error.missingResource("index.json")
        }
        let data = try Data(contentsOf: resourceURL)
        let index: RepositoryIndex
        switch RepositoryIndexValidator.validate(json: data, indexURL: resourceURL) {
        case .success(let value): index = value
        case .failure(let error): throw error
        }
        for bundleRecord in index.bundles {
            for source in bundleRecord.sources {
                guard let localID = source.localID else { continue }
                let qualified = ExtensionInstaller.qualifiedID(repositoryID: repositoryID, localId: localID)
                switch source.validate(qualifiedId: qualified) {
                case .success(let declaration):
                    if declaration.adult != .none { throw Error.adultSource(localID) }
                case .failure:
                    continue
                }
            }
        }
        return .index(index)
    }

    func fetchScript(at url: URL) async throws -> Data {
        guard let resourceURL = bundle.url(forResource: "engine", withExtension: "js",
                                           subdirectory: "BundledRepositories/weebcentral") else {
            throw Error.missingResource("engine.js")
        }
        let data = try Data(contentsOf: resourceURL)
        guard data.count <= RepositoryFormatLimits.maximumScriptBytes else {
            throw Error.scriptTooLarge(actualBytes: data.count,
                                       maximumBytes: RepositoryFormatLimits.maximumScriptBytes)
        }
        guard String(data: data, encoding: .utf8) != nil else { throw Error.invalidScript }
        return data
    }
}

enum BundledRepositories {
    static let weebCentralRepositoryID = UUID(uuidString: "9C6A1C65-2AB0-4B53-8F91-55BDFDEB8E55")!
    static let weebCentralURL = URL(string: "bundled://weebcentral/index.json")!
}

struct AppRepositoryTransport: RepositoryTransport, @unchecked Sendable {
    private let bundled: BundledRepositoryTransport
    private let network: URLSessionRepositoryTransport

    init(bundle: Bundle = .main) {
        bundled = BundledRepositoryTransport(bundle: bundle)
        network = URLSessionRepositoryTransport()
    }

    func fetchIndex(at url: URL) async throws -> RepositoryIndexFetchOutcome {
        if url.scheme == "bundled" { return try await bundled.fetchIndex(at: url) }
        return try await network.fetchIndex(at: url)
    }

    func fetchScript(at url: URL) async throws -> Data {
        if url.scheme == "bundled" { return try await bundled.fetchScript(at: url) }
        return try await network.fetchScript(at: url)
    }
}
