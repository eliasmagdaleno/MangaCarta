//
//  LiveUITestRepositoryInstallTests.swift
//  MangaCartaTests
//
//  `-uitest-install-repository` runs on the seeded simulator, whose reconnected Listings
//  name one repository UUID. A second add would mint another and orphan them, so the
//  property worth a unit test is that relaunching installs nothing new.
//

import XCTest
@testable import MangaCarta

@MainActor
final class LiveUITestRepositoryInstallTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private let url = URL(string: "https://fixture.invalid/index.json")!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveUITestRepositoryInstallTests-\(UUID().uuidString)", isDirectory: true)
        suite = "LiveUITestRepositoryInstallTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func launch() async throws -> (AppComposition.ExtensionComposition, SourceRegistry) {
        let registry = SourceRegistry(sources: [])
        let composition = AppComposition(defaults: defaults, directory: directory, registry: registry,
                                         repositoryTransport: AppComposition.RepositorySettingsUITestTransport())
        let extensions = try XCTUnwrap(composition.extensions)
        await LiveUITestRepositoryInstall.run(url: url, extensions: extensions, registry: registry,
                                              defaults: defaults)
        return (extensions, registry)
    }

    func testInstallsTheListedAdultSourceAndMakesItBrowsable() async throws {
        let (extensions, registry) = try await launch()

        let repository = try XCTUnwrap(extensions.repositories.repository(at: url))
        let id = ExtensionInstaller.qualifiedID(repositoryID: repository.id, localId: "fixture")
        XCTAssertEqual(extensions.repositories.source(id)?.state, .registered)
        XCTAssertNotNil(registry.source(id: id.rawValue))
        XCTAssertTrue(defaults.bool(forKey: RepositorySettingsViewModel.showAdultSourcesKey))
        XCTAssertNil(extensions.adultAcknowledgement.present, "the forced yes must not outlive the run")
    }

    func testRelaunchingKeepsTheOneRepositoryAndItsSource() async throws {
        let (first, _) = try await launch()
        let repository = try XCTUnwrap(first.repositories.repository(at: url))
        let id = ExtensionInstaller.qualifiedID(repositoryID: repository.id, localId: "fixture")
        let installedAt = try XCTUnwrap(first.repositories.source(id)?.installedAt)

        let (second, registry) = try await launch()

        XCTAssertEqual(second.repositories.repositories.map(\.id), [repository.id])
        XCTAssertEqual(second.repositories.source(id)?.installedAt, installedAt, "nothing was reinstalled")
        XCTAssertNotNil(registry.source(id: id.rawValue))
    }
}
