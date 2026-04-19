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
    var directionProgress: Double = 0
    @State private var flashOpacity: Double = 0
    @State private var arrowLoopOffset: CGFloat = -12

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
            return Color(
                hue: 0.10 + (0.23 * clampedDirectionProgress),
                saturation: 0.90,
                brightness: 0.95
            )
        }

        return nil
    }

    private var clampedDirectionProgress: Double {
        min(max(directionProgress, 0), 1)
    }

    private var indicatorOffset: CGFloat {
        guard !locked, !isHighlighted, directionIndicator != nil else { return 0 }

        switch directionIndicator {
        case .lower:
            return -arrowLoopOffset
        case .raise:
            return arrowLoopOffset
        case nil:
            return 0
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let normalizedValue = min(max(displayedFrequency / 400, 0), 1)
            let xPosition = normalizedValue * geometry.size.width

            ZStack(alignment: .leading) {
                Capsule()
                    .frame(height: 4)

                VStack(spacing: 6) {
                    if let directionIndicator, !locked, !isHighlighted {
                        Image(systemName: directionIndicator.systemName)
                            .font(.caption)
                            .foregroundStyle(accentColor ?? .primary)
                            .frame(width: 18)
                            .offset(x: indicatorOffset)
                    } else {
                        Image(systemName: locked ? "lock" : "lock.open")
                            .font(.caption)
                            .foregroundStyle(accentColor ?? .primary)
                            .frame(width: 18)
                    }

                    Rectangle()
                        .fill(accentColor ?? .primary)
                        .frame(width: 2, height: 32)
                }
                .overlay {
                    Circle()
                        .fill((accentColor ?? .clear).opacity(flashOpacity))
                        .frame(width: 34, height: 34)
                        .blur(radius: 8)
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
            .onChange(of: isHighlighted) { _, newValue in
                guard newValue else { return }
                triggerFlash()
            }
            .onAppear {
                startArrowLoopIfNeeded()
            }
            .onChange(of: directionIndicator) {
                startArrowLoopIfNeeded()
            }
            .onChange(of: isHighlighted) {
                startArrowLoopIfNeeded()
            }
        }
        .frame(height: 32)
        .padding([.top, .bottom], topPadding)
    }

    private func triggerFlash() {
        flashOpacity = 0

        withAnimation(.easeOut(duration: 0.12)) {
            flashOpacity = 0.9
        }

        withAnimation(.easeOut(duration: 0.45).delay(0.12)) {
            flashOpacity = 0
        }
    }

    private func startArrowLoopIfNeeded() {
        guard !locked, !isHighlighted, directionIndicator != nil else {
            withAnimation(.none) {
                arrowLoopOffset = 0
            }
            return
        }

        withAnimation(.none) {
            arrowLoopOffset = -12
        }
        withAnimation(.linear(duration: 0.85).repeatForever(autoreverses: false)) {
            arrowLoopOffset = 12
        }
    }
}
