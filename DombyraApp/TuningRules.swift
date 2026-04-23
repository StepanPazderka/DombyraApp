//
//  ToneDetector.swift
//  DombyraApp
//
//  Created by Stepan Pazderka on 16.04.2026.
//

import Foundation

struct TuningRules {
    static func shouldShowSameReferenceWarning(
        referenceFrequency: Double?,
        referenceLockedAt: Date?,
        isTuningLineColored: Bool,
        displayedFrequency: Double,
        amplitude: Double,
        now: Date = Date(),
        minimumAmplitude: Double = 0.003,
        delay: TimeInterval = 1.0,
        tolerance: Double = 2.0
    ) -> Bool {
        guard let referenceFrequency,
              let referenceLockedAt,
              isTuningLineColored,
              displayedFrequency > 0,
              amplitude > minimumAmplitude else { return false }

        guard now.timeIntervalSince(referenceLockedAt) >= delay else {
            return false
        }

        return abs(displayedFrequency - referenceFrequency) <= tolerance
    }
}
