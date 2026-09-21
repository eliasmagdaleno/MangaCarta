import XCTest
@testable import MangaCarta

@MainActor
final class RepositorySettingsViewModelTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepositorySettingsViewModelTests-\(UUID().uuidString)", isDirectory: true)
        let suite = "RepositorySettingsViewModelTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeModel() throws -> RepositorySettingsViewModel {
        let composition = AppComposition(defaults: defaults, directory: directory,
                                         repositoryTransport: AppComposition.RepositorySettingsUITestTransport())
        return RepositorySettingsViewModel(composition: try XCTUnwrap(composition.extensions), defaults: defaults)
    }

    func testBadURLIsAReaderFacingSentence() throws {
        let model = try makeModel()
        model.addRepository("http://example.test/index.json")
        XCTAssertEqual(model.errorMessage, "Enter a valid HTTPS repository URL.")
    }

    func testIndexRejectionIsAReaderFacingSentence() throws {
        let model = try makeModel()
        let message = model.sentence(for: RepositoryIndexError.unsupportedFormat(path: "format", value: 2))
        XCTAssertTrue(message.hasSuffix("."))
        XCTAssertTrue(message.contains("not supported"))
    }

    func testDigestMismatchIsAReaderFacingSentence() throws {
        let model = try makeModel()
        let error = ExtensionInstallError.scriptDigestMismatch(expected: "expected", actual: "actual")
        XCTAssertTrue(model.sentence(for: error).contains("does not match what the repository promised"))
    }

    func testAdultDeclineIsAReaderFacingSentence() throws {
        let model = try makeModel()
        let message = model.sentence(for: ExtensionInstallError.adultAcknowledgementDeclined(localId: "adult"))
        XCTAssertEqual(message, "The install was cancelled. Nothing was added.")
    }

    func testUnreadableStoreIsNamedAndKept() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let storeFile = directory.appendingPathComponent("repositories.json")
        try Data("not json".utf8).write(to: storeFile)
        let model = try makeModel()
        model.refreshStoreStatus()
        XCTAssertTrue(model.storeUnreadable)
        XCTAssertEqual(model.errorMessage, "Installed Sources could not be read. Nothing was removed.")
    }

    func testDecliningAgeGateReturnsFalseWithoutPersistingConfirmation() async throws {
        let model = try makeModel()
        let url = URL(string: "https://fixture.invalid/index.json")!
        let repository = try await model.composition.installer.addRepository(at: url)
        let sourceID = ExtensionInstaller.qualifiedID(repositoryID: repository.id, localId: "fixture")
        let install = Task { try await model.composition.installer.install(localId: "fixture", from: repository.id) }
        for _ in 0..<100 where model.pendingAcknowledgement == nil { await Task.yield() }
        XCTAssertEqual(model.pendingAcknowledgement?.classification, .mixed)
        model.answerAgeGate(false)
        do {
            _ = try await install.value
            XCTFail("declining the age gate must stop installation")
        } catch {
            XCTAssertEqual(error as? ExtensionInstallError, .adultAcknowledgementDeclined(localId: "fixture"))
        }
        XCTAssertNil(model.composition.repositories.source(sourceID))
        XCTAssertFalse(defaults.bool(forKey: RepositorySettingsViewModel.declaredAgeKey))
    }

    func testConfirmingAgeOncePersistsForLaterAcknowledgements() async throws {
        let model = try makeModel()
        let acknowledgement = AdultInstallAcknowledgement(sourceName: "Adult Source", repositoryName: "Fixture Repo", classification: .mixed)
        let first = Task { await model.composition.adultAcknowledgement.acknowledge(acknowledgement) }
        await Task.yield()
        model.answerAgeGate(true)
        let firstAccepted = await first.value
        XCTAssertTrue(firstAccepted)
        XCTAssertTrue(defaults.bool(forKey: RepositorySettingsViewModel.declaredAgeKey))
        if defaults.bool(forKey: RepositorySettingsViewModel.declaredAgeKey) {
            let secondAccepted = await model.composition.adultAcknowledgement.acknowledge(acknowledgement)
            XCTAssertTrue(secondAccepted)
            XCTAssertNil(model.pendingAcknowledgement)
        }
    }

    func testAdultToggleRequiresBothAgeConfirmationAndRegisteredAdultSource() {
        let visible = RepositorySettingsViewModel.shouldShowAdultSourcesToggle(isConfirmed: true, hasRegisteredAdultSource: true)
        XCTAssertTrue(visible)
        XCTAssertFalse(RepositorySettingsViewModel.shouldShowAdultSourcesToggle(isConfirmed: false, hasRegisteredAdultSource: true))
        XCTAssertFalse(RepositorySettingsViewModel.shouldShowAdultSourcesToggle(isConfirmed: true, hasRegisteredAdultSource: false))
        XCTAssertFalse(RepositorySettingsViewModel.shouldShowAdultSourcesToggle(isConfirmed: false, hasRegisteredAdultSource: false))
    }

    func testTurningOffAdultSourcesPreferenceClearsAgeConfirmation() {
        defaults.set(true, forKey: RepositorySettingsViewModel.declaredAgeKey)
        RepositorySettingsViewModel.setAdultSourcesVisible(false, defaults: defaults)
        XCTAssertFalse(defaults.bool(forKey: RepositorySettingsViewModel.declaredAgeKey))
        XCTAssertFalse(defaults.bool(forKey: RepositorySettingsViewModel.showAdultSourcesKey))
    }

    func testGateCopyNamesTheDeclarationWithoutImplyingModeration() {
        let acknowledgement = AdultInstallAcknowledgement(sourceName: "Reader's Choice", repositoryName: "Community Index", classification: .adultOnly)
        let copy = RepositorySettingsViewModel.ageConfirmationCopy(for: acknowledgement)
        XCTAssertTrue(copy.contains("Reader's Choice"))
        XCTAssertTrue(copy.contains("Community Index"))
        XCTAssertTrue(copy.contains("adultOnly"))
        XCTAssertTrue(copy.contains("18 or over"))
        XCTAssertFalse(copy.localizedCaseInsensitiveContains("moderated"))
        XCTAssertFalse(copy.localizedCaseInsensitiveContains("approved"))
    }
}
