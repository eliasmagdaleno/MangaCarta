| id | description | result | killed by |
|---|---|---|---|
| LM1 | Cancel must stop before confirmation | KILLED | `LocalMatchingCoordinatorTests/testCancelledCombineDoesNotWrite()` |
| LM2 | Preserve the irreversible warning wording | KILLED | `LocalMatchingCoordinatorTests/testCancelledCombineDoesNotWrite()` |
| LM3 | Unavailable Source must fail before identity writes | KILLED | `LocalMatchingCoordinatorTests/testFailedMatchDoesNotPersistPartialIdentity()` |
| LM4 | Explicit identity merge keeps incumbent Work id | KILLED | `LocalMatchingCoordinatorTests/testUnmatchAfterMergeDoesNotSplitWorks()` |
| LM5 | Deferred Work aliases are followed during promotion | KILLED | `LocalMatchingCoordinatorTests/testConfirmPromotesDeferredProgressThroughMergedAlias()` |
| LM6 | Unmatch keeps rows with another recorded Work id | KILLED | `MALProgressOutboxTests/testRemoveUndeliveredKeepsDeliveredHistoryAndOtherWorkRows()` |
| LM7 | Unmatch removes only deferred rows with the original Work id | KILLED | `MALProgressOutboxTests/testRemoveUndeliveredKeepsDeliveredHistoryAndOtherWorkRows()` |
| LM8 | Confirmed match records stay confirmed | KILLED | `LocalMatchingCoordinatorTests/testConfirmPostsMetadataChangeForCanonicalSurvivor()` |
| LM9 | Confirmation announces canonical metadata changes | KILLED | `LocalMatchingCoordinatorTests/testConfirmPostsMetadataChangeForCanonicalSurvivor()` |
| LM10 | Confirmation promotes deferred MAL progress | KILLED | `LocalMatchingCoordinatorTests/testConfirmPromotesDeferredProgressThroughMergedAlias()` |
| LM11 | Unmatch clears active external ids | KILLED | `LocalMatchingCoordinatorTests/testUnmatchAfterMergeDoesNotSplitWorks()` |
| LM12 | Explicit link operation must attach the Listing | KILLED | `WorkStoreTests/testExplicitLinkListingPreservesBothListingsWithoutRecordingIDs()` |
| LM15 | Validate listing merge feasibility before changing Work identity | KILLED | `LocalMatchingCoordinatorTests/testFailedListingLinkDoesNotPersistPartialMerge()` |
| LM16 | Only record a remote Listing newly attached by this match | KILLED | `LocalMatchingCoordinatorTests/testUnmatchKeepsIncumbentListingAlreadyPresentBeforeConfirmation()` |
| LM17 | Only clear the external id value that was confirmed | KILLED | `LocalMatchingCoordinatorTests/testUnmatchClearsOnlyTheRecordedExternalIDValue()` |
| LM18 | Do not remove an external id the incumbent already owned | KILLED | `LocalMatchingCoordinatorTests/testUnmatchPreservesIncumbentExternalIDAndProgress()` |
| LM19 | Remove an external id newly introduced by this confirmation | KILLED | `LocalMatchingCoordinatorTests/testUnmatchRemovesExternalIDIntroducedByNonCombineMatch()` |
| LM20 | Remove alias progress under the original local Work id | KILLED | `LocalMatchingCoordinatorTests/testUnmatchAfterMergeRemovesPromotedAliasProgressOnly()` |
| LM21 | Decode slice 1 records with the original id fallback | KILLED | `LocalMatchStoreTests/testSliceOneLocalMatchesFileDecodesWithoutReviewFields()` |
| LM22 | Do not remove an external id already held by the local Work before combine | KILLED | `LocalMatchingCoordinatorTests/testUnmatchPreservesLocalExternalIDMergedIntoIncumbent()` |

20 killed, 0 survived, 0 equivalent, 0 error (of 20).
