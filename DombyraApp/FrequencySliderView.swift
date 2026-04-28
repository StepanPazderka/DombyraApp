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
		static let sliderAnimationDuration: Double = 0.05
		static let flashFadeInDuration: Double = 0.12
		static let flashFadeOutDuration: Double = 0.45
		static let flashPeakOpacity: Double = 0.9
		static let indicatorHorizontalInset: CGFloat = 9
		static let frequencyRange: ClosedRange<Double> = 0...400
		static let particleLifetime: TimeInterval = 1.1
		static let particleRiseDistance: CGFloat = 46
		static let particleSize: CGFloat = 6
		static let minimumParticleSize: CGFloat = 1
		static let loudParticleAmplitude: Double = 0.02
		static let maxParticleCount = 12
	}
	
	private struct FrequencyParticle: Identifiable {
		let id = UUID()
		let frequency: Double
		let tuningProgress: Double
		let color: Color
		let size: CGFloat
		let createdAt: Date
	}
	
	@Binding var frequency: Double
	@Binding var particleFrequency: Double
	@Binding var particleAmplitude: Double
	@Binding var lockedFrequency: Double?
	@Binding var activeLockedString: TuningView.LockedString?
	let stringID: TuningView.LockedString
	@State var displayedFrequency: Double
	var topPadding: CGFloat = 10
	var isHighlighted: Bool = false
	var directionIndicator: DirectionIndicator? = nil
	var directionProgress: Double = 0
	var particleTuningProgress: Double = -1
	var forceBlueParticles: Bool = false
	var isAwaitingInput: Bool = false
	var targetFrequency: Double? = nil
	var idleIndicatorSymbol: String = "lock.open"
	var successIndicatorSymbol: String = "checkmark.circle.fill"
	@State private var flashOpacity: Double = 0
	@State private var frequencyParticles: [FrequencyParticle] = []
	
	private var locked: Bool {
		activeLockedString == stringID
	}
	
	private var accentColor: Color? {
		switch true {
		case locked:
			return .blue
		case isAwaitingInput:
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
		if locked {
			return "lock"
		}
		
		if isHighlighted {
			return successIndicatorSymbol
		}
		
		return idleIndicatorSymbol
	}
	
	private func normalizedValue(for width: CGFloat, frequency: Double? = nil) -> (value: Double, xPosition: CGFloat) {
		let sourceFrequency = frequency ?? displayedFrequency
		let normalized = min(max(sourceFrequency / Layout.frequencyRange.upperBound, 0), 1)
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
	
	private func arrowOffset(at date: Date, direction: DirectionIndicator) -> CGFloat {
		let progress = date.timeIntervalSinceReferenceDate
			.truncatingRemainder(dividingBy: Layout.arrowAnimationDuration) / Layout.arrowAnimationDuration
		let offset = Layout.initialArrowOffset + ((Layout.finalArrowOffset - Layout.initialArrowOffset) * progress)
		
		switch direction {
		case .lower:
			return -offset
		case .raise:
			return offset
		}
	}
	
	@ViewBuilder
	private var indicatorIcon: some View {
		if let directionIndicator, !locked, !isHighlighted {
			TimelineView(.animation) { timeline in
				Image(systemName: directionIndicator.systemName)
					.font(.caption)
					.foregroundStyle(sliderAccentColor)
					.frame(width: Layout.iconWidth)
					.offset(x: arrowOffset(at: timeline.date, direction: directionIndicator))
			}
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

	@ViewBuilder
	private func targetIndicator(width: CGFloat) -> some View {
		if let targetFrequency, !locked {
			let targetPosition = normalizedValue(for: width, frequency: targetFrequency)
			let xOffset = indicatorXPosition(
				for: targetPosition.xPosition,
				width: width
			) + (Layout.iconWidth / 2) - 1

			VStack(spacing: 4) {
				ForEach(0..<6, id: \.self) { _ in
					Circle()
						.fill(Color.blue.opacity(0.9))
						.frame(width: 3, height: 3)
				}
			}
			.offset(x: xOffset, y: 2)
		}
	}
	
	private var shouldEmitFrequencyParticles: Bool {
		forceBlueParticles || (!locked && (activeLockedString == nil || particleTuningProgress >= 0))
	}
	
	private var currentParticleTuningProgress: Double {
		min(max(particleTuningProgress, 0), 1)
	}
	
	private func particleColor(for tuningProgress: Double) -> Color {
		Color(
			hue: 0.02 + (0.31 * min(max(tuningProgress, 0), 1)),
			saturation: 0.90,
			brightness: 0.95
		)
	}
	
	private func particleSize(for amplitude: Double) -> CGFloat {
		let normalizedAmplitude = min(max(amplitude / Layout.loudParticleAmplitude, 0), 1)
		return Layout.minimumParticleSize + ((Layout.particleSize - Layout.minimumParticleSize) * normalizedAmplitude)
	}
	
	private var currentParticleColor: Color {
		guard !forceBlueParticles else {
			return .blue
		}
		
		guard activeLockedString != nil else {
			return sliderAccentColor
		}
		
		return particleColor(for: currentParticleTuningProgress)
	}
	
	private func particleProgress(for particle: FrequencyParticle, at date: Date) -> Double {
		min(max(date.timeIntervalSince(particle.createdAt) / Layout.particleLifetime, 0), 1)
	}
	
	private func pruneExpiredParticles(now: Date = Date()) {
		frequencyParticles.removeAll {
			now.timeIntervalSince($0.createdAt) > Layout.particleLifetime
		}
	}
	
	private func appendFrequencyParticle(frequency: Double) {
		guard shouldEmitFrequencyParticles, frequency > 0 else { return }
		
		let now = Date()
		pruneExpiredParticles(now: now)
		frequencyParticles.append(
			FrequencyParticle(
				frequency: frequency,
				tuningProgress: currentParticleTuningProgress,
				color: currentParticleColor,
				size: particleSize(for: particleAmplitude),
				createdAt: now
			)
		)
		
		if frequencyParticles.count > Layout.maxParticleCount {
			frequencyParticles.removeFirst(frequencyParticles.count - Layout.maxParticleCount)
		}
	}
	
	private func frequencyParticleLayer(width: CGFloat) -> some View {
		TimelineView(.animation) { timeline in
			ZStack(alignment: .bottomLeading) {
				ForEach(frequencyParticles) { particle in
					let progress = particleProgress(for: particle, at: timeline.date)
					let xPosition = indicatorXPosition(
						for: normalizedValue(for: width, frequency: particle.frequency).xPosition,
						width: width
					) + (Layout.iconWidth / 2)
					
					Circle()
						.fill(particle.color.opacity(1 - progress))
						.frame(width: particle.size, height: particle.size)
						.offset(
							x: xPosition - (particle.size / 2),
							y: -(Layout.indicatorHeight + Layout.particleRiseDistance * progress)
						)
				}
			}
		}
		.allowsHitTesting(false)
	}
	
	var body: some View {
		GeometryReader { geometry in
			let sliderPosition = normalizedValue(for: geometry.size.width)
			
				ZStack(alignment: .leading) {
					Capsule()
						.frame(height: Layout.trackHeight)
					
					targetIndicator(width: geometry.size.width)

					frequencyParticleLayer(width: geometry.size.width)
				
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
			.onChange(of: particleFrequency) {
				appendFrequencyParticle(frequency: particleFrequency)
			}
			.onChange(of: activeLockedString) {
				if !locked {
					lockedFrequency = nil
				}
			}
			.onChange(of: isHighlighted) { _, newValue in
				if newValue {
					triggerFlash()
				}
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
}
