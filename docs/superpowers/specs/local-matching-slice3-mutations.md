| id | description | result | killed by |
|---|---|---|---|
| E1 | unmatched tombstones with provider ids stay ineligible | KILLED | `MetadataUpgradeQueueTests/testUnmatchedLocalWorkRemainsIneligible()` |
| E2 | MAL ids admit confirmed local Works | KILLED | `MetadataUpgradeQueueTests/testMatchedLocalWorkCanRequestProviderMetadata()` |
| E3 | AniList ids admit confirmed local Works | KILLED | `MetadataUpgradeQueueTests/testAniListOnlyConfirmedIDCanFetchMetadata()` |
| E4 | participating remote Listings admit confirmed local Works | KILLED | `MetadataUpgradeQueueTests/testConfirmedLocalWorkCanUseParticipatingRemoteListingWithoutProviderID()` |
| E5 | disabled remote Listing does not admit a confirmed local Work | KILLED | `MetadataUpgradeQueueTests/testConfirmedLocalWorkCanUseParticipatingRemoteListingWithoutProviderID()` |
| E6 | ordinary remote Works retain their existing eligibility | KILLED | `MetadataUpgradeQueueTests/testOrdinaryRemoteWorkUsesProductionEligibilityPredicate()` |
| E7 | request cancels an idle sleep as a wake, not as stop | KILLED | `MetadataUpgradeQueueTests/testRequestWakesIdleLoopAndUpgradesRequestedWork()` |
| E8 | confirmation requests the metadata queue after saving the match | KILLED | `LocalMatchingCoordinatorTests/testConfirmPostsMetadataChangeForCanonicalSurvivor()` |
| E9 | Local remains excluded from content refresh | KILLED | `LibraryRefreshCoordinatorTests/mixedRemoteAndLocalRefreshOnlyFetchesParticipatingRemote()` +1 more |
| E10 | rejected match records with provider ids stay ineligible | KILLED | `MetadataUpgradeQueueTests/testRejectedLocalMatchWithProviderIDIsIneligible()` |

10 killed, 0 survived, 0 equivalent, 0 error (of 10).
