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
		
		var title: String {
			switch self {
			case .fourth:
				return "Fourth tuning"
			case .fifth:
				return "Fifth tuning"
			}
		}
		
		var shortTitle: String {
			switch self {
			case .fourth:
				return "4:3"
			case .fifth:
				return "3:2"
			}
		}
	}
	
	enum LockedString {
		case top
		case bottom
	}
	
    @Binding var tuningMode: TuningMode
    
    @EnvironmentObject private var detector: ToneDetector
    @State private var displayedFrequency: Double = 0
    @State private var displayedFrequencyTextValue: Double = 0
    @State private var lockedTopFrequency: Double? = nil
    @State private var lockedBottomFrequency: Double? = nil
    @State private var activeLockedString: LockedString? = nil
    @State private var textAnimationTask: Task<Void, Never>?
	
	@State var topStringFrequency: Double = 0
	@State var bottomStringFrequency: Double = 0
	
    private let pairingTolerance: Double = 2.0
    private let highlightTolerance: Double = 0.6
    private let animatedTextThreshold: Double = 50.0
	
	private var shouldHighlightTopString: Bool {
		guard lockedTopFrequency == nil,
			  let lockedBottomFrequency,
			  displayedFrequency > 0 else { return false }
		
		let expectedTopFrequency = pairedFrequency(for: lockedBottomFrequency, isTopString: false)
		return abs(displayedFrequency - expectedTopFrequency) <= highlightTolerance
	}
	
	private var shouldHighlightBottomString: Bool {
		guard lockedBottomFrequency == nil,
			  let lockedTopFrequency,
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
			  displayedFrequency > 0 else { return nil }
		
		let expectedTopFrequency = pairedFrequency(for: lockedBottomFrequency, isTopString: false)
		let difference = displayedFrequency - expectedTopFrequency
		
		guard abs(difference) > highlightTolerance else { return nil }
		return difference < 0 ? .raise : .lower
	}
	
	private var topStringDirectionProgress: Double {
		guard lockedTopFrequency == nil,
			  let lockedBottomFrequency,
			  displayedFrequency > 0 else { return 0 }
		
		let expectedTopFrequency = pairedFrequency(for: lockedBottomFrequency, isTopString: false)
		return directionProgress(for: displayedFrequency - expectedTopFrequency)
	}
	
	private var bottomStringDirectionIndicator: FrequencySliderView.DirectionIndicator? {
		guard lockedBottomFrequency == nil,
			  let lockedTopFrequency,
			  displayedFrequency > 0 else { return nil }
		
		let expectedBottomFrequency = pairedFrequency(for: lockedTopFrequency, isTopString: true)
		let difference = displayedFrequency - expectedBottomFrequency
		
		guard abs(difference) > highlightTolerance else { return nil }
		return difference < 0 ? .raise : .lower
	}
	
	private var bottomStringDirectionProgress: Double {
		guard lockedBottomFrequency == nil,
			  let lockedTopFrequency,
			  displayedFrequency > 0 else { return 0 }
		
		let expectedBottomFrequency = pairedFrequency(for: lockedTopFrequency, isTopString: true)
		return directionProgress(for: displayedFrequency - expectedBottomFrequency)
	}
	
	private func directionProgress(for difference: Double) -> Double {
		let falloffRange = pairingTolerance * 6
		let normalizedDistance = min(abs(difference) / falloffRange, 1)
		return 1 - normalizedDistance
	}
	
	var body: some View {
		ZStack {
			GeometryReader { geometry in
				Image("Dombyra")
					.resizable()
					.scaledToFill()
					.frame(width: geometry.size.width, height: geometry.size.height)
					.frame(maxWidth: .infinity, maxHeight: .infinity)
					.opacity(0.5)
					.clipped()
			}
			.ignoresSafeArea()
			
			VStack(spacing: 16) {
                Text(displayedFrequency > 0
                     ? "\(displayedFrequencyTextValue, specifier: "%.2f") Hz"
                     : "Listening...")
                    .font(.largeTitle)
				
				FrequencySliderView(
					frequency: $displayedFrequency,
					lockedFrequency: $lockedTopFrequency,
					activeLockedString: $activeLockedString,
					stringID: .top,
					displayedFrequency: displayedFrequency,
					isHighlighted: shouldHighlightTopString,
					directionIndicator: topStringDirectionIndicator,
					directionProgress: topStringDirectionProgress
				)
				
				FrequencySliderView(
					frequency: $displayedFrequency,
					lockedFrequency: $lockedBottomFrequency,
					activeLockedString: $activeLockedString,
					stringID: .bottom,
					displayedFrequency: displayedFrequency,
					isHighlighted: shouldHighlightBottomString,
					directionIndicator: bottomStringDirectionIndicator,
					directionProgress: bottomStringDirectionProgress
				)
				
				if let lockedTopFrequency {
					Text("Top locked: \(lockedTopFrequency, specifier: "%.2f") Hz")
						.font(.subheadline)
				}
				
				if let lockedBottomFrequency {
					Text("Bottom locked: \(lockedBottomFrequency, specifier: "%.2f") Hz")
						.font(.subheadline)
				}
				
				Color.clear
					.frame(height: 1)
			}
			.padding()
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

            withAnimation(.linear(duration: 0.10)) {
                displayedFrequency = newFrequency
            }

            animateFrequencyText(to: newFrequency)
        }
        .onChange(of: activeLockedString) {
            if activeLockedString != .top {
                lockedTopFrequency = nil
            }
			
            if activeLockedString != .bottom {
                lockedBottomFrequency = nil
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

        let stepCount = max(1, min(30, Int(abs(delta) * 3)))

        textAnimationTask = Task {
            for step in 1...stepCount {
                guard !Task.isCancelled else { return }

                let progress = Double(step) / Double(stepCount)
                let nextValue = startFrequency + (delta * progress)

                await MainActor.run {
                    displayedFrequencyTextValue = nextValue
                }

                try? await Task.sleep(for: .milliseconds(10))
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
