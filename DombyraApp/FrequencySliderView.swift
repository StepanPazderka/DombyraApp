//
//  FrequencySliderView.swift
//  DombyraApp
//
//  Created by Štěpán Pazderka on 18.04.2026.
//

import SwiftUI

struct FrequencySliderView: View {
    enum DirectionIndicator {
        case lower
        case raise

        var systemName: String {
            switch self {
            case .lower:
                return "arrow.left"
            case .raise:
                return "arrow.right"
            }
        }
    }

    @Binding var frequency: Double
    @Binding var lockedFrequency: Double?
    @Binding var activeLockedString: TuningView.LockedString?
    let stringID: TuningView.LockedString
    @State var displayedFrequency: Double
    var topPadding: CGFloat = 10
    var isHighlighted: Bool = false
    var directionIndicator: DirectionIndicator? = nil

    private var locked: Bool {
        activeLockedString == stringID
    }

    private var accentColor: Color? {
        if locked {
            return .blue
        }

        if isHighlighted {
            return .green
        }

        if directionIndicator != nil {
            return .orange
        }

        return nil
    }

    private var indicatorSystemName: String {
        if locked {
            return "lock"
        }

        return directionIndicator?.systemName ?? "lock.open"
    }

    var body: some View {
        GeometryReader { geometry in
            let normalizedValue = min(max(displayedFrequency / 400, 0), 1)
            let xPosition = normalizedValue * geometry.size.width

            ZStack(alignment: .leading) {
                Capsule()
                    .frame(height: 4)

                VStack(spacing: 6) {
                    Image(systemName: indicatorSystemName)
                        .font(.caption)
                        .foregroundStyle(accentColor ?? .primary)

                    Rectangle()
                        .fill(accentColor ?? .primary)
                        .frame(width: 2, height: 32)
                }
                .offset(x: max(0, min(xPosition - 9, geometry.size.width - 18)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .onTapGesture {
                if locked {
                    activeLockedString = nil
                    lockedFrequency = nil
                } else {
                    activeLockedString = stringID
                    lockedFrequency = displayedFrequency
                }
                print("Slider tapped at frequency: \(displayedFrequency)")
            }
            .onChange(of: frequency) {
                if locked {
                    lockedFrequency = displayedFrequency
                } else {
                    displayedFrequency = frequency
                }
            }
            .onChange(of: activeLockedString) {
                if !locked {
                    lockedFrequency = nil
                }
            }
        }
        .frame(height: 32)
        .padding([.top, .bottom], topPadding)
    }
}
