import Foundation

@MainActor
final class RepositorySettingsViewModel: ObservableObject {
    @Published var errorMessage: String?
    @Published var pendingAcknowledgement: AdultInstallAcknowledgement?
    @Published var storeUnreadable = false
    @Published var availableSources: [UUID: [RepositoryListing.Entry]] = [:]

    let composition: AppComposition.ExtensionComposition
    private let defaults: UserDefaults
    private var ageAnswer: CheckedContinuation<Bool, Never>?

    init(composition: AppComposition.ExtensionComposition,
         defaults: UserDefaults = .standard) {
        self.composition = composition
        self.defaults = defaults
        composition.adultAcknowledgement.present = { [weak self] acknowledgement in
            guard let self else { return false }
            if self.defaults.bool(forKey: Self.declaredAgeKey) { return true }
            return await withCheckedContinuation { continuation in
                self.pendingAcknowledgement = acknowledgement
                self.ageAnswer = continuation
            }
        }
    }

    static let declaredAgeKey = "settings.declaredAgeOver18"

    func refreshStoreStatus() {
        do { try composition.repositories.loadIfNeeded(); storeUnreadable = false }
        catch { storeUnreadable = true; errorMessage = "Installed Sources could not be read. Nothing was removed." }
    }

    func answerAgeGate(_ confirmed: Bool) {
        if confirmed { defaults.set(true, forKey: Self.declaredAgeKey) }
        pendingAcknowledgement = nil
        ageAnswer?.resume(returning: confirmed)
        ageAnswer = nil
    }

    func run(_ operation: @escaping () async throws -> Void) {
        Task {
            do { try await operation(); errorMessage = nil }
            catch { errorMessage = sentence(for: error) }
        }
    }

    private func sentence(for error: Error) -> String {
        if let error = error as? ExtensionInstallError { return error.message }
        if let error = error as? RepositoryIndexError { return error.message }
        if let error = error as? LocalizedError, let description = error.errorDescription { return description }
        return "The repository operation failed. Please check the URL and try again."
    }

    func addRepository(_ rawURL: String) {
        guard let url = URL(string: rawURL), url.scheme?.lowercased() == "https", url.host != nil else {
            errorMessage = "Enter a valid HTTPS repository URL."
            return
        }
        Task {
            do {
                let repository = try await composition.installer.addRepository(at: url)
                availableSources[repository.id] = composition.installer.listings[repository.id]?.entries ?? []
                errorMessage = nil
            } catch { errorMessage = sentence(for: error) }
        }
    }

    func refreshRepository(_ id: UUID) {
        Task {
            do {
                if case .refreshed(let listing) = try await composition.installer.refresh(id) {
                    availableSources[id] = listing.entries
                }
                errorMessage = nil
            } catch { errorMessage = sentence(for: error) }
        }
    }
}
