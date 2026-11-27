| id | description | result | killed by |
|---|---|---|---|
| LM1 | Cancel must stop before confirmation | KILLED | `LocalMatchingCoordinatorTests/testCancelledCombineDoesNotWrite()` |
| LM2 | Preserve the irreversible warning wording | KILLED | `LocalMatchingCoordinatorTests/testCancelledCombineDoesNotWrite()` |
| LM3 | Unavailable Source must fail before identity writes | KILLED | `LocalMatchingCoordinatorTests/testFailedMatchDoesNotPersistPartialIdentity()` |
| LM4 | Explicit identity merge keeps incumbent Work id | KILLED | `LocalMatchingCoordinatorTests/testUnmatchAfterMergeDoesNotSplitWorks()` |
| LM5 | Deferred Work aliases are followed during promotion | KILLED | `LocalMatchingCoordinatorTests/testConfirmPromotesDeferredProgressThroughMergedAlias()` |
| LM6 | Unmatch removes only rows owned by the Work | KILLED | `MALProgressOutboxTests/testRemoveUndeliveredKeepsDeliveredHistoryAndOtherWorkRows()` |
| LM7 | Unmatch removes deferred rows for the Work | KILLED | `MALProgressOutboxTests/testRemoveUndeliveredKeepsDeliveredHistoryAndOtherWorkRows()` |
| LM8 | Confirmed match records stay confirmed | KILLED | `LocalMatchingCoordinatorTests/testConfirmPostsMetadataChangeForCanonicalSurvivor()` |
| LM9 | Confirmation announces canonical metadata changes | KILLED | `LocalMatchingCoordinatorTests/testConfirmPostsMetadataChangeForCanonicalSurvivor()` |
| LM10 | Confirmation promotes deferred MAL progress | KILLED | `LocalMatchingCoordinatorTests/testConfirmPromotesDeferredProgressThroughMergedAlias()` |
| LM11 | Unmatch clears active external ids | KILLED | `LocalMatchingCoordinatorTests/testUnmatchAfterMergeDoesNotSplitWorks()` |
| LM12 | Explicit link operation must attach the Listing | KILLED | `WorkStoreTests/testExplicitLinkListingPreservesBothListingsWithoutRecordingIDs()` |

12 killed, 0 survived, 0 equivalent, 0 error (of 12).
