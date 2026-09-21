import Foundation

@MainActor
final class RepositorySettingsViewModel: ObservableObject {
    @Published var errorMessage: String?
    /// The sheet the installer is waiting on. It always appears for a `mixed` or
    /// `adultOnly` Source — a reader who has already confirmed their age still sees which
    /// Source is adult-classed and who says so (format design §7.1) — but only asks the
    /// age question when the device has no confirmation yet.
    struct PendingAcknowledgement: Identifiable, Equatable {
        let acknowledgement: AdultInstallAcknowledgement
        let asksForAge: Bool
        var id: String { acknowledgement.repositoryName + "/" + acknowledgement.sourceName }
    }

    @Published var pendingAcknowledgement: PendingAcknowledgement?
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
            let asksForAge = !self.defaults.bool(forKey: Self.declaredAgeKey)
            return await withCheckedContinuation { continuation in
                self.pendingAcknowledgement = PendingAcknowledgement(acknowledgement: acknowledgement,
                                                                     asksForAge: asksForAge)
                self.ageAnswer = continuation
            }
        }
    }

    static let declaredAgeKey = "settings.declaredAgeOver18"
    static let showAdultSourcesKey = "settings.showAdultSources"
    /// Names the maintainer as the one classifying, and never the developer: the class is
    /// what the repository attests by serving the declaration (format design §7.2), and
    /// ADR-0022 Amendment 2's copy rule is that nothing here reads as moderated by us.
    static let declarationCopy = "{repository} declares {source} as {classification}."
    static let ageQuestionCopy = "Confirm that you are 18 or over to install it."
    static let alreadyConfirmedCopy = "You have already confirmed your age on this device."

    static func shouldShowAdultSourcesToggle(isConfirmed: Bool, hasRegisteredAdultSource: Bool) -> Bool {
        isConfirmed && hasRegisteredAdultSource
    }

    static func setAdultSourcesVisible(_ visible: Bool, defaults: UserDefaults) {
        defaults.set(visible, forKey: showAdultSourcesKey)
        if !visible { defaults.removeObject(forKey: declaredAgeKey) }
    }

    static func ageConfirmationCopy(for acknowledgement: AdultInstallAcknowledgement,
                                    asksForAge: Bool = true) -> String {
        let classification: String
        switch acknowledgement.classification {
        case .adultOnly: classification = "adult-only"
        case .mixed: classification = "mixed adult and general content"
        case .none: classification = "general content"
        }
        let declaration = declarationCopy
            .replacingOccurrences(of: "{source}", with: acknowledgement.sourceName)
            .replacingOccurrences(of: "{repository}", with: acknowledgement.repositoryName)
            .replacingOccurrences(of: "{classification}", with: classification)
        return declaration + " " + (asksForAge ? ageQuestionCopy : alreadyConfirmedCopy)
    }

    func refreshStoreStatus() {
        do { try composition.repositories.loadIfNeeded(); storeUnreadable = false }
        catch { storeUnreadable = true; errorMessage = "Installed Sources could not be read. Nothing was removed." }
    }

    func answerAgeGate(_ confirmed: Bool) {
        if confirmed, pendingAcknowledgement?.asksForAge == true {
            defaults.set(true, forKey: Self.declaredAgeKey)
        }
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

    func sentence(for error: Error) -> String {
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
