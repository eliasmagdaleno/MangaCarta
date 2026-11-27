| id | description | result | killed by |
|---|---|---|---|
| E1 | unmatched tombstones with provider ids stay ineligible | KILLED | `MetadataUpgradeQueueTests/testUnmatchedLocalWorkRemainsIneligible()` |
| E2 | MAL ids admit confirmed local Works | KILLED | `MetadataUpgradeQueueTests/testMatchedLocalWorkCanRequestProviderMetadata()` |
| E3 | AniList ids admit confirmed local Works | KILLED | `MetadataUpgradeQueueTests/testAniListOnlyConfirmedIDCanFetchMetadata()` |
| E6 | ordinary remote Works retain their existing eligibility | KILLED | `MetadataUpgradeQueueTests/testOrdinaryRemoteWorkUsesProductionEligibilityPredicate()` |
| E7 | request cancels an idle sleep as a wake, not as stop | KILLED | `MetadataUpgradeQueueTests/testRequestWakesIdleLoopAndUpgradesRequestedWork()` |
| E8 | confirmation requests the metadata queue after saving the match | KILLED | `LocalMatchingCoordinatorTests/testConfirmPostsMetadataChangeForCanonicalSurvivor()` |
| E9 | Local remains excluded from content refresh | KILLED | `LibraryRefreshCoordinatorTests/matchedLocalWorkIsNeverContentRefreshed()` +1 more |
| E10 | rejected match records with provider ids stay ineligible | KILLED | `MetadataUpgradeQueueTests/testRejectedLocalMatchWithProviderIDIsIneligible()` |
| E11 | Local plus unregistered remote Listing remains eligible without a match record | KILLED | `MetadataUpgradeQueueTests/testLocalAndUnregisteredRemoteWorkWithoutMatchRecordRemainsEligible()` |
| E12 | local-only Work without a match record stays ineligible | KILLED | `MetadataUpgradeQueueTests/testLocalOnlyWorkWithoutMatchRecordIsIneligible()` |
| E14 | ordinary unknown Sources retain legacy participation fallback | KILLED | `AppCompositionTests/testProgressDeferredForAnUnresolvedWorkIsPromotedWhenTheQueueLearnsItsMALID()` |

11 killed, 0 survived, 0 equivalent, 0 error (of 11).
