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
	
    private enum Layout {
        static let trackHeight: CGFloat = 4
		static let spacing: CGFloat = 6
		static let iconWidth: CGFloat = 18
		static let indicatorWidth: CGFloat = 2
		static let indicatorHeight: CGFloat = 32
		static let flashSize: CGFloat = 34
		static let flashBlurRadius: CGFloat = 8
		static let initialArrowOffset: CGFloat = -12
		static let finalArrowOffset: CGFloat = 12
        static let arrowAnimationDuration: Double = 0.85
        static let sliderAnimationDuration: Double = 0.10
        static let flashFadeInDuration: Double = 0.12
		static let flashFadeOutDuration: Double = 0.45
		static let flashPeakOpacity: Double = 0.9
		static let indicatorHorizontalInset: CGFloat = 9
		static let frequencyRange: ClosedRange<Double> = 0...400
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
	@State private var arrowLoopOffset: CGFloat = Layout.initialArrowOffset
	
	private var locked: Bool {
		activeLockedString == stringID
	}
	
	private var accentColor: Color? {
		switch true {
		case locked:
			return .blue
		case isHighlighted:
			return .green
		case directionIndicator != nil:
			return Color(
				hue: 0.10 + (0.23 * clampedDirectionProgress),
				saturation: 0.90,
				brightness: 0.95
			)
		default:
			return nil
		}
	}
	
	private var clampedDirectionProgress: Double {
		min(max(directionProgress, 0), 1)
	}
	
	private var sliderAccentColor: Color {
		accentColor ?? .primary
	}
	
	private var lockIconName: String {
		locked ? "lock" : "lock.open"
	}
	
	private var indicatorOffset: CGFloat {
		guard !locked, !isHighlighted else { return 0 }
		
		switch directionIndicator {
		case .lower:
			return -arrowLoopOffset
		case .raise:
			return arrowLoopOffset
		case nil:
			return 0
		}
	}
	
	private func normalizedValue(for width: CGFloat) -> (value: Double, xPosition: CGFloat) {
		let normalized = min(max(displayedFrequency / Layout.frequencyRange.upperBound, 0), 1)
		return (normalized, normalized * width)
	}
	
	private func indicatorXPosition(for xPosition: CGFloat, width: CGFloat) -> CGFloat {
		max(
			0,
			min(
				xPosition - Layout.indicatorHorizontalInset,
				width - Layout.iconWidth
			)
		)
	}
	
	@ViewBuilder
	private var indicatorIcon: some View {
		if let directionIndicator, !locked, !isHighlighted {
			Image(systemName: directionIndicator.systemName)
				.font(.caption)
				.foregroundStyle(sliderAccentColor)
				.frame(width: Layout.iconWidth)
				.offset(x: indicatorOffset)
		} else {
			Image(systemName: lockIconName)
				.font(.caption)
				.foregroundStyle(sliderAccentColor)
				.frame(width: Layout.iconWidth)
		}
	}
	
	private var flashOverlay: some View {
		Circle()
			.fill(sliderAccentColor.opacity(flashOpacity))
			.frame(width: Layout.flashSize, height: Layout.flashSize)
			.blur(radius: Layout.flashBlurRadius)
	}
	
	var body: some View {
		GeometryReader { geometry in
			let sliderPosition = normalizedValue(for: geometry.size.width)
			
			ZStack(alignment: .leading) {
				Capsule()
					.frame(height: Layout.trackHeight)
				
				VStack(spacing: Layout.spacing) {
					indicatorIcon
					
					Rectangle()
						.fill(sliderAccentColor)
						.frame(width: Layout.indicatorWidth, height: Layout.indicatorHeight)
				}
				.overlay {
					flashOverlay
				}
				.offset(
					x: indicatorXPosition(
						for: sliderPosition.xPosition,
						width: geometry.size.width
					)
				)
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
			}
                .onChange(of: frequency) {
                    if locked {
                        lockedFrequency = displayedFrequency
                    } else {
                        withAnimation(.linear(duration: Layout.sliderAnimationDuration)) {
                            displayedFrequency = frequency
                        }
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
		
		withAnimation(.easeOut(duration: Layout.flashFadeInDuration)) {
			flashOpacity = Layout.flashPeakOpacity
		}
		
		withAnimation(
			.easeOut(duration: Layout.flashFadeOutDuration)
			.delay(Layout.flashFadeInDuration)
		) {
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
			arrowLoopOffset = Layout.initialArrowOffset
		}
		
		withAnimation(
			.linear(duration: Layout.arrowAnimationDuration)
			.repeatForever(autoreverses: false)
		) {
			arrowLoopOffset = Layout.finalArrowOffset
		}
	}
}
