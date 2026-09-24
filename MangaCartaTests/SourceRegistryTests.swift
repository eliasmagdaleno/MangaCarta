import Testing
@testable import MangaCarta

@MainActor @Suite("SourceRegistryTests")
struct SourceRegistryTests {
    @Test func visibleSourcesNeverIncludesLocal() {
        let registry = SourceRegistry(sources: [LocalSource(), MangaDexSource()])
        #expect(registry.visibleSources(includeAdult: true).map(\.id) == [MangaDexSource.sourceID])
        #expect(!registry.browsableSourceNames.contains("Local"))
    }

    @Test func localIsResolvableById() {
        let registry = SourceRegistry(sources: [LocalSource(), MangaDexSource()])
        #expect(registry.source(id: "local")?.id == "local")
    }
}
