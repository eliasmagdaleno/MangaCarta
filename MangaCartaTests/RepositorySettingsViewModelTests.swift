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
        XCTAssertEqual(model.pendingAcknowledgement?.acknowledgement.classification, .mixed)
        XCTAssertEqual(model.pendingAcknowledgement?.asksForAge, true)
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
        let acknowledgement = AdultInstallAcknowledgement(sourceName: "Adult Source",
                                                          repositoryName: "Fixture Repo", classification: .mixed)
        let first = Task { await model.composition.adultAcknowledgement.acknowledge(acknowledgement) }
        await Task.yield()
        model.answerAgeGate(true)
        let firstAccepted = await first.value
        XCTAssertTrue(firstAccepted)
        XCTAssertTrue(defaults.bool(forKey: RepositorySettingsViewModel.declaredAgeKey))

        // Format design §7.1: a confirmed reader still sees the sheet name the Source and
        // its class, but is not asked again.
        let second = Task { await model.composition.adultAcknowledgement.acknowledge(acknowledgement) }
        for _ in 0..<100 where model.pendingAcknowledgement == nil { await Task.yield() }
        let pending = try XCTUnwrap(model.pendingAcknowledgement)
        XCTAssertEqual(pending.acknowledgement, acknowledgement)
        XCTAssertFalse(pending.asksForAge, "confirmed once per device; the sheet names, it does not ask")
        let copy = RepositorySettingsViewModel.ageConfirmationCopy(for: acknowledgement, asksForAge: false)
        XCTAssertTrue(copy.contains("Adult Source"))
        XCTAssertFalse(copy.contains("18 or over"))
        model.answerAgeGate(true)
        let secondAccepted = await second.value
        XCTAssertTrue(secondAccepted)
        XCTAssertNil(model.pendingAcknowledgement)
    }

    func testOverlappingAgeGateRequestsBothComplete() async throws {
        let model = try makeModel()
        let firstAcknowledgement = AdultInstallAcknowledgement(sourceName: "First Source",
                                                                repositoryName: "Fixture Repo",
                                                                classification: .mixed)
        let secondAcknowledgement = AdultInstallAcknowledgement(sourceName: "Second Source",
                                                                 repositoryName: "Fixture Repo",
                                                                 classification: .adultOnly)

        let first = Task { await model.composition.adultAcknowledgement.acknowledge(firstAcknowledgement) }
        for _ in 0..<100 where model.pendingAcknowledgement == nil { await Task.yield() }
        XCTAssertEqual(model.pendingAcknowledgement?.acknowledgement, firstAcknowledgement)

        let firstFinished = XCTestExpectation(description: "the replaced acknowledgement completes")
        let firstResult = Task {
            let result = await first.value
            firstFinished.fulfill()
            return result
        }
        let second = Task { await model.composition.adultAcknowledgement.acknowledge(secondAcknowledgement) }
        for _ in 0..<100 where model.pendingAcknowledgement?.acknowledgement != secondAcknowledgement {
            await Task.yield()
        }
        await fulfillment(of: [firstFinished], timeout: 1)
        let firstAccepted = await firstResult.value
        XCTAssertFalse(firstAccepted)

        model.answerAgeGate(true)
        let secondAccepted = await second.value
        XCTAssertTrue(secondAccepted)
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
        let acknowledgement = AdultInstallAcknowledgement(sourceName: "Reader's Choice",
                                                          repositoryName: "Community Index", classification: .adultOnly)
        let copy = RepositorySettingsViewModel.ageConfirmationCopy(for: acknowledgement)
        XCTAssertTrue(copy.contains("Reader's Choice"))
        XCTAssertTrue(copy.contains("Community Index"))
        XCTAssertTrue(copy.contains("adult-only"), "the class is a word, not an enum case")
        XCTAssertTrue(copy.contains("18 or over"))
        XCTAssertTrue(copy.hasPrefix("Community Index declares"),
                      "the repository is named as the one classifying, not the developer")
        XCTAssertFalse(copy.localizedCaseInsensitiveContains("moderated"))
        XCTAssertFalse(copy.localizedCaseInsensitiveContains("approved"))
        XCTAssertFalse(copy.localizedCaseInsensitiveContains("is classified"),
                       "passive voice leaves the classifier unnamed")
    }
}
