//
//  ToneDetector.swift
//  DombyraApp
//
//  Created by Stepan Pazderka on 16.04.2026.
//

import SwiftUI

struct TuningView: View {
	enum TuningMode: String, CaseIterable, Identifiable {
		case fourth
		case fifth
		
		var id: String {
			rawValue
		}
		
		var upwardRatio: Double {
			switch self {
			case .fourth:
				return 4.0 / 3.0
			case .fifth:
				return 3.0 / 2.0
			}
		}
		
		var shortTitle: String {
			switch self {
			case .fourth:
				return "оң бұрау"
			case .fifth:
				return "теріс бұрау"
			}
		}
	}
	
	enum LockedString {
		case top
		case bottom
	}
	
    @Binding var tuningMode: TuningMode
	@Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var detector: ToneDetector
    @State private var displayedFrequency: Double = 0
    @State private var displayedFrequencyTextValue: Double = 0
    @State private var rawDetectedFrequency: Double = 0
    @State private var rawDetectedAmplitude: Double = 0
    @State private var lockedTopFrequency: Double? = nil
    @State private var lockedBottomFrequency: Double? = nil
    @State private var activeLockedString: LockedString? = nil
    @State private var referenceLockedAt: Date? = nil
    @State private var textAnimationTask: Task<Void, Never>?
    @State private var hasStartedTopStringSearch = false
    @State private var hasStartedBottomStringSearch = false
	
	@State var topStringFrequency: Double = 0
	@State var bottomStringFrequency: Double = 0
	
    private let pairingTolerance: Double = 2.0
    private let highlightTolerance: Double = 0.6
    private let animatedTextThreshold: Double = 50.0
    private let searchActivationTolerance: Double = 16.0
    private let sameReferenceDelay: TimeInterval = 1.0
    private let sameReferenceTolerance: Double = 2.0
	
    private var shouldHighlightTopString: Bool {
        guard lockedTopFrequency == nil,
              let lockedBottomFrequency,
              hasStartedTopStringSearch,
              displayedFrequency > 0 else { return false }
		
		let expectedTopFrequency = pairedFrequency(for: lockedBottomFrequency, isTopString: false)
		return abs(displayedFrequency - expectedTopFrequency) <= highlightTolerance
	}
	
    private var shouldHighlightBottomString: Bool {
        guard lockedBottomFrequency == nil,
              let lockedTopFrequency,
              hasStartedBottomStringSearch,
              displayedFrequency > 0 else { return false }
		
		let expectedBottomFrequency = pairedFrequency(for: lockedTopFrequency, isTopString: true)
		return abs(displayedFrequency - expectedBottomFrequency) <= highlightTolerance
	}
	
	private func pairedFrequency(for frequency: Double, isTopString: Bool) -> Double {
		let upwardRatio = tuningMode.upwardRatio
		if isTopString {
			return frequency * upwardRatio
		} else {
			return frequency / upwardRatio
		}
	}
	
    private var topStringDirectionIndicator: FrequencySliderView.DirectionIndicator? {
        guard lockedTopFrequency == nil,
              let lockedBottomFrequency,
              hasStartedTopStringSearch,
              displayedFrequency > 0 else { return nil }
		
		let expectedTopFrequency = pairedFrequency(for: lockedBottomFrequency, isTopString: false)
		let difference = displayedFrequency - expectedTopFrequency
		
		guard abs(difference) > highlightTolerance else { return nil }
		return difference < 0 ? .raise : .lower
	}
	
    private var topStringDirectionProgress: Double {
        guard lockedTopFrequency == nil,
              let lockedBottomFrequency,
              hasStartedTopStringSearch,
              displayedFrequency > 0 else { return 0 }
		
		let expectedTopFrequency = pairedFrequency(for: lockedBottomFrequency, isTopString: false)
		return directionProgress(for: displayedFrequency - expectedTopFrequency)
	}
	
    private var bottomStringDirectionIndicator: FrequencySliderView.DirectionIndicator? {
        guard lockedBottomFrequency == nil,
              let lockedTopFrequency,
              hasStartedBottomStringSearch,
              displayedFrequency > 0 else { return nil }
		
		let expectedBottomFrequency = pairedFrequency(for: lockedTopFrequency, isTopString: true)
		let difference = displayedFrequency - expectedBottomFrequency
		
		guard abs(difference) > highlightTolerance else { return nil }
		return difference < 0 ? .raise : .lower
	}
	
    private var bottomStringDirectionProgress: Double {
        guard lockedBottomFrequency == nil,
              let lockedTopFrequency,
              hasStartedBottomStringSearch,
              displayedFrequency > 0 else { return 0 }
		
		let expectedBottomFrequency = pairedFrequency(for: lockedTopFrequency, isTopString: true)
			return directionProgress(for: displayedFrequency - expectedBottomFrequency)
		}

    private var topStringParticleTuningProgress: Double {
        guard lockedTopFrequency == nil,
              let lockedBottomFrequency,
              hasStartedTopStringSearch,
              rawDetectedFrequency > 0 else { return -1 }

        let expectedTopFrequency = pairedFrequency(for: lockedBottomFrequency, isTopString: false)
        return directionProgress(for: rawDetectedFrequency - expectedTopFrequency)
    }

    private var bottomStringParticleTuningProgress: Double {
        guard lockedBottomFrequency == nil,
              let lockedTopFrequency,
              hasStartedBottomStringSearch,
              rawDetectedFrequency > 0 else { return -1 }

        let expectedBottomFrequency = pairedFrequency(for: lockedTopFrequency, isTopString: true)
        return directionProgress(for: rawDetectedFrequency - expectedBottomFrequency)
    }
	
    private func directionProgress(for difference: Double) -> Double {
        let falloffRange = pairingTolerance * 6
        let normalizedDistance = min(abs(difference) / falloffRange, 1)
        return 1 - normalizedDistance
    }

    private var topStringIdleIndicatorSymbol: String {
        shouldAwaitTopStringInput ? "play.circle" : "lock.open"
    }

    private var bottomStringIdleIndicatorSymbol: String {
        shouldAwaitBottomStringInput ? "play.circle" : "lock.open"
    }

    private var shouldAwaitTopStringInput: Bool {
        lockedTopFrequency == nil && lockedBottomFrequency != nil && !hasStartedTopStringSearch
    }

    private var shouldAwaitBottomStringInput: Bool {
        lockedBottomFrequency == nil && lockedTopFrequency != nil && !hasStartedBottomStringSearch
    }

    private var referenceFrequency: Double? {
        switch activeLockedString {
        case .top:
            return lockedTopFrequency
        case .bottom:
            return lockedBottomFrequency
        case nil:
            return nil
        }
    }

    private var isTuningLineColored: Bool {
        if lockedTopFrequency == nil, lockedBottomFrequency != nil {
            return shouldHighlightTopString || topStringDirectionIndicator != nil
        }

        if lockedBottomFrequency == nil, lockedTopFrequency != nil {
            return shouldHighlightBottomString || bottomStringDirectionIndicator != nil
        }

        return false
    }

    private var isTuningSameAsReference: Bool {
        TuningRules.shouldShowSameReferenceWarning(
            referenceFrequency: referenceFrequency,
            referenceLockedAt: referenceLockedAt,
            isTuningLineColored: isTuningLineColored,
            displayedFrequency: displayedFrequency,
            amplitude: rawDetectedAmplitude,
            delay: sameReferenceDelay,
            tolerance: sameReferenceTolerance
        )
    }

    private func updateStringSearchState(for liveFrequency: Double, amplitude: Double) {
        guard amplitude > 0.003 else { return }

        if let lockedBottomFrequency, lockedTopFrequency == nil, !hasStartedTopStringSearch {
            let expectedTopFrequency = pairedFrequency(for: lockedBottomFrequency, isTopString: false)
            if abs(liveFrequency - expectedTopFrequency) <= searchActivationTolerance {
                hasStartedTopStringSearch = true
            }
        }

        if let lockedTopFrequency, lockedBottomFrequency == nil, !hasStartedBottomStringSearch {
            let expectedBottomFrequency = pairedFrequency(for: lockedTopFrequency, isTopString: true)
            if abs(liveFrequency - expectedBottomFrequency) <= searchActivationTolerance {
                hasStartedBottomStringSearch = true
            }
        }
    }
	
	var body: some View {
		ZStack {
			GeometryReader { geometry in
				Image("Dombyra")
					.resizable()
					.scaledToFill()
					.frame(width: geometry.size.width, height: geometry.size.height)
					.frame(maxWidth: .infinity, maxHeight: .infinity)
					.opacity(colorScheme == .dark ? 0.8 : 0.5 )
					.clipped()
			}
			.ignoresSafeArea()
			
			VStack(spacing: 16) {
                    VStack(spacing: 4) {
                        Text(displayedFrequency > 0
                             ? "\(displayedFrequencyTextValue, specifier: "%.2f") Hz"
                             : "00.00 Hz")
                            .font(.largeTitle)
                            .opacity(displayedFrequency > 0 ? 1 : 0)

                        Text(referenceFrequency.map { "\($0, specifier: "%.2f") Hz" } ?? "00.00 Hz")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.blue)
                            .opacity(referenceFrequency == nil ? 0 : 1)
                    }
				
                    FrequencySliderView(
                        frequency: $displayedFrequency,
                        particleFrequency: $rawDetectedFrequency,
                        particleAmplitude: $rawDetectedAmplitude,
                        lockedFrequency: $lockedTopFrequency,
                        activeLockedString: $activeLockedString,
                        stringID: .top,
                        displayedFrequency: displayedFrequency,
                        isHighlighted: shouldHighlightTopString,
                        directionIndicator: topStringDirectionIndicator,
                        directionProgress: topStringDirectionProgress,
                        particleTuningProgress: topStringParticleTuningProgress,
                        forceBlueParticles: isTuningSameAsReference,
                        idleIndicatorSymbol: topStringIdleIndicatorSymbol
                    )
				
                    FrequencySliderView(
                        frequency: $displayedFrequency,
                        particleFrequency: $rawDetectedFrequency,
                        particleAmplitude: $rawDetectedAmplitude,
                        lockedFrequency: $lockedBottomFrequency,
                        activeLockedString: $activeLockedString,
                        stringID: .bottom,
                        displayedFrequency: displayedFrequency,
                        isHighlighted: shouldHighlightBottomString,
                        directionIndicator: bottomStringDirectionIndicator,
                        directionProgress: bottomStringDirectionProgress,
                        particleTuningProgress: bottomStringParticleTuningProgress,
                        forceBlueParticles: isTuningSameAsReference,
                        idleIndicatorSymbol: bottomStringIdleIndicatorSymbol
                    )

							Color.clear
							.frame(height: 1)
				}
				.padding()

                Text("Ойпырмай!")
                    .font(.system(size: 72, weight: .black, design: .rounded))
                    .minimumScaleFactor(0.45)
                    .lineLimit(1)
                    .foregroundStyle(.blue)
                    .shadow(color: .white.opacity(0.75), radius: 10)
                    .padding(.horizontal, 18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(isTuningSameAsReference ? 1 : 0)
                    .allowsHitTesting(false)
			}
		.safeAreaInset(edge: .bottom, spacing: 0) {
			Picker("Tuning mode", selection: $tuningMode) {
				ForEach(TuningMode.allCases) { mode in
					Text(mode.shortTitle)
						.font(.system(size: 34, weight: .semibold, design: .rounded))
						.monospacedDigit()
						.tag(mode)
				}
			}
			.pickerStyle(.segmented)
			.padding(.horizontal)
		}
        .onReceive(detector.$frequency) { newFrequency in
            guard newFrequency > 0 else { return }

            displayedFrequency = newFrequency
            animateFrequencyText(to: newFrequency)
        }
        .onReceive(detector.$rawFrequency) { newFrequency in
            rawDetectedFrequency = newFrequency
        }
        .onReceive(detector.$amplitude) { amplitude in
            rawDetectedAmplitude = amplitude
            updateStringSearchState(for: detector.frequency, amplitude: amplitude)
        }
        .onChange(of: activeLockedString) {
            if activeLockedString == nil {
                referenceLockedAt = nil
            } else {
                referenceLockedAt = Date()
            }

            if activeLockedString != .top {
                lockedTopFrequency = nil
            }
				
            if activeLockedString != .bottom {
                lockedBottomFrequency = nil
            }

            if activeLockedString == .top {
                hasStartedBottomStringSearch = false
            } else if activeLockedString == .bottom {
                hasStartedTopStringSearch = false
            } else {
                hasStartedTopStringSearch = false
                hasStartedBottomStringSearch = false
            }
        }
        .onDisappear {
            textAnimationTask?.cancel()
        }
    }

    private func animateFrequencyText(to targetFrequency: Double) {
        textAnimationTask?.cancel()

        let startFrequency = displayedFrequencyTextValue
        let delta = targetFrequency - startFrequency

        guard abs(delta) < animatedTextThreshold else {
            displayedFrequencyTextValue = targetFrequency
            return
        }

        let stepCount = max(1, min(18, Int(abs(delta) * 1.5)))

        textAnimationTask = Task {
            for step in 1...stepCount {
                guard !Task.isCancelled else { return }

                let progress = Double(step) / Double(stepCount)
                let nextValue = startFrequency + (delta * progress)

                await MainActor.run {
                    displayedFrequencyTextValue = nextValue
                }

                try? await Task.sleep(for: .milliseconds(4))
            }

            await MainActor.run {
                displayedFrequencyTextValue = targetFrequency
            }
        }
    }
}

#Preview {
	TuningView(tuningMode: .constant(.fourth))
		.environmentObject(ToneDetector())
}
