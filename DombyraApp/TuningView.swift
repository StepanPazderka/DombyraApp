import SwiftUI

struct TuningView: View {
    enum TuningMode {
        case fourth
        case fifth

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
    }

    enum LockedString {
        case top
        case bottom
    }

    private let tuningMode: TuningMode

    init(tuningMode: TuningMode = .fourth) {
        self.tuningMode = tuningMode
    }

    @EnvironmentObject private var detector: ToneDetector
    @State private var displayedFrequency: Double = 0
    @State private var lockedTopFrequency: Double? = nil
    @State private var lockedBottomFrequency: Double? = nil
    @State private var activeLockedString: LockedString? = nil

    @State var topStringFrequency: Double = 0
    @State var bottomStringFrequency: Double = 0

    private let pairingTolerance: Double = 2.0

    private var shouldHighlightTopString: Bool {
        guard lockedTopFrequency == nil,
              let lockedBottomFrequency,
              displayedFrequency > 0 else { return false }

        let expectedTopFrequency = pairedFrequency(for: lockedBottomFrequency, isTopString: false)
        return abs(displayedFrequency - expectedTopFrequency) <= pairingTolerance
    }

    private var shouldHighlightBottomString: Bool {
        guard lockedBottomFrequency == nil,
              let lockedTopFrequency,
              displayedFrequency > 0 else { return false }

        let expectedBottomFrequency = pairedFrequency(for: lockedTopFrequency, isTopString: true)
        return abs(displayedFrequency - expectedBottomFrequency) <= pairingTolerance
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

        guard abs(difference) > pairingTolerance else { return nil }
        return difference < 0 ? .raise : .lower
    }

    private var bottomStringDirectionIndicator: FrequencySliderView.DirectionIndicator? {
        guard lockedBottomFrequency == nil,
              let lockedTopFrequency,
              displayedFrequency > 0 else { return nil }

        let expectedBottomFrequency = pairedFrequency(for: lockedTopFrequency, isTopString: true)
        let difference = displayedFrequency - expectedBottomFrequency

        guard abs(difference) > pairingTolerance else { return nil }
        return difference < 0 ? .raise : .lower
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(tuningMode.title)
                .font(.headline)

            Text(displayedFrequency > 0
                 ? "\(displayedFrequency, specifier: "%.1f") Hz"
                 : "Listening...")
                .font(.largeTitle)

            FrequencySliderView(
                frequency: $displayedFrequency,
                lockedFrequency: $lockedTopFrequency,
                activeLockedString: $activeLockedString,
                stringID: .top,
                displayedFrequency: displayedFrequency,
                isHighlighted: shouldHighlightTopString,
                directionIndicator: topStringDirectionIndicator
            )

            FrequencySliderView(
                frequency: $displayedFrequency,
                lockedFrequency: $lockedBottomFrequency,
                activeLockedString: $activeLockedString,
                stringID: .bottom,
                displayedFrequency: displayedFrequency,
                isHighlighted: shouldHighlightBottomString,
                directionIndicator: bottomStringDirectionIndicator
            )

            if let lockedTopFrequency {
                Text("Top locked: \(lockedTopFrequency, specifier: "%.1f") Hz")
                    .font(.subheadline)
            }

            if let lockedBottomFrequency {
                Text("Bottom locked: \(lockedBottomFrequency, specifier: "%.1f") Hz")
                    .font(.subheadline)
            }

            Color.clear
                .frame(height: 1)
        }
        .padding()
        .onReceive(detector.$frequency) { newFrequency in
            guard newFrequency > 0 else { return }

            withAnimation(.easeOut(duration: 0.18)) {
                displayedFrequency = newFrequency
            }
        }
        .onChange(of: activeLockedString) {
            if activeLockedString != .top {
                lockedTopFrequency = nil
            }

            if activeLockedString != .bottom {
                lockedBottomFrequency = nil
            }
        }
    }
}

#Preview {
	TuningView(tuningMode: .fourth)
		.environmentObject(ToneDetector())
}
