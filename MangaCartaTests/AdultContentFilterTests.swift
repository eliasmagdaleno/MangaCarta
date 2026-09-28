import Testing
@testable import MangaCarta

@Suite("AdultContentFilter")
struct AdultContentFilterTests {
    @Test(arguments: ["erotica", "pornographic"])
    func adultRatingsAreHiddenWhenTheSwitchIsOff(rating: String) {
        #expect(!AdultContentFilter.admits(rating: rating, sourceDeclaresAdultTitles: false, showAdultContent: false))
        #expect(!AdultContentFilter.admits(rating: rating, sourceDeclaresAdultTitles: true, showAdultContent: false))
    }

    @Test(arguments: ["safe", "suggestive"])
    func generalRatingsAlwaysPass(rating: String) {
        #expect(AdultContentFilter.admits(rating: rating, sourceDeclaresAdultTitles: true, showAdultContent: false))
    }

    @Test func unratedTitleFollowsTheSourcesDeclaration() {
        #expect(!AdultContentFilter.admits(rating: nil, sourceDeclaresAdultTitles: true, showAdultContent: false))
        #expect(AdultContentFilter.admits(rating: nil, sourceDeclaresAdultTitles: false, showAdultContent: false))
    }

    @Test func switchOnAdmitsEverything() {
        #expect(AdultContentFilter.admits(rating: "pornographic", sourceDeclaresAdultTitles: true, showAdultContent: true))
        #expect(AdultContentFilter.admits(rating: nil, sourceDeclaresAdultTitles: true, showAdultContent: true))
    }

    @Test func settingKeyIsThePersistedOne() {
        #expect(AdultContentSetting.key == "settings.showAdultSources")
        #expect(AdultContentSetting.key == RepositorySettingsViewModel.showAdultSourcesKey)
    }
}
