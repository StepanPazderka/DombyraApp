import Foundation
import Testing
@testable import DombyraApp

struct TuningRulesTests {
    @Test func sameReferenceWarningRequiresColoredTuningLine() {
        let lockedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let now = lockedAt.addingTimeInterval(1.2)

        #expect(TuningRules.shouldShowSameReferenceWarning(
            referenceFrequency: 100,
            referenceLockedAt: lockedAt,
            isTuningLineColored: false,
            displayedFrequency: 100.5,
            amplitude: 0.01,
            now: now
        ) == false)

        #expect(TuningRules.shouldShowSameReferenceWarning(
            referenceFrequency: 100,
            referenceLockedAt: lockedAt,
            isTuningLineColored: true,
            displayedFrequency: 100.5,
            amplitude: 0.01,
            now: now
        ))
    }

    @Test func sameReferenceWarningWaitsAfterReferenceLock() {
        let lockedAt = Date(timeIntervalSinceReferenceDate: 1_000)

        #expect(TuningRules.shouldShowSameReferenceWarning(
            referenceFrequency: 100,
            referenceLockedAt: lockedAt,
            isTuningLineColored: true,
            displayedFrequency: 100.5,
            amplitude: 0.01,
            now: lockedAt.addingTimeInterval(0.8)
        ) == false)
    }

    @Test func sameReferenceWarningRequiresSimilarFrequencies() {
        let lockedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let now = lockedAt.addingTimeInterval(1.2)

        #expect(TuningRules.shouldShowSameReferenceWarning(
            referenceFrequency: 100,
            referenceLockedAt: lockedAt,
            isTuningLineColored: true,
            displayedFrequency: 103,
            amplitude: 0.01,
            now: now
        ) == false)
    }
}
