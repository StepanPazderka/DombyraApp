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
			static let trackEdgeHeight: CGFloat = 0.8
			static let trackCenterHeight: CGFloat = 2.6
			static let indicatorWidth: CGFloat = 2
			static let indicatorHeight: CGFloat = 32
			static let flashSize: CGFloat = 34
			static let flashBlurRadius: CGFloat = 8
			static let sliderAnimationDuration: Double = 0.05
			static let flashFadeInDuration: Double = 0.12
			static let flashFadeOutDuration: Double = 0.45
			static let flashPeakOpacity: Double = 0.9
			static let indicatorRevealDuration: Double = 1.0
			static let frequencyRange: ClosedRange<Double> = 0...400
			static let anchoredFrequencyWindow: Double = 80
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
	
	private struct TaperedTrackShape: Shape {
		func path(in rect: CGRect) -> Path {
			let steps = 48
			let centerY = rect.midY
			let minimumHeight = Layout.trackEdgeHeight
			let maximumHeight = Layout.trackCenterHeight
			
			func height(at progress: CGFloat) -> CGFloat {
				let wave = pow(sin(progress * .pi), 3.0)
				return minimumHeight + ((maximumHeight - minimumHeight) * wave)
			}
			
			var path = Path()
			
			for step in 0...steps {
				let progress = CGFloat(step) / CGFloat(steps)
				let x = rect.minX + (rect.width * progress)
				let y = centerY - (height(at: progress) / 2)
				
				if step == 0 {
					path.move(to: CGPoint(x: x, y: y))
				} else {
					path.addLine(to: CGPoint(x: x, y: y))
				}
			}
			
			for step in stride(from: steps, through: 0, by: -1) {
				let progress = CGFloat(step) / CGFloat(steps)
				let x = rect.minX + (rect.width * progress)
				let y = centerY + (height(at: progress) / 2)
				path.addLine(to: CGPoint(x: x, y: y))
			}
			
			path.closeSubpath()
			return path
		}
	}
	
	@Binding var frequency: Double
	@Binding var particleFrequency: Double
	@Binding var particleAmplitude: Double
	@Binding var lockedFrequency: Double?
	@Binding var activeLockedString: TuningView.LockedString?
	@Environment(\.colorScheme) private var colorScheme
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
	var targetAnchorPosition: CGFloat? = nil
	var idleIndicatorSymbol: String = "lock.open"
	var successIndicatorSymbol: String = "checkmark.circle.fill"
	@State private var flashOpacity: Double = 0
	@State private var indicatorRevealProgress: CGFloat = 0
	@State private var frequencyParticles: [FrequencyParticle] = []
	
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
		accentColor ?? (colorScheme == .light ? Color(white: 0.32) : .primary)
	}
	
	private var shouldShowIndicator: Bool {
		displayedFrequency > 0 && !locked && !isHighlighted
	}
	
	private func normalizedValue(for width: CGFloat, frequency: Double? = nil) -> (value: Double, xPosition: CGFloat) {
		let sourceFrequency = frequency ?? displayedFrequency
		let normalized: Double
		if let targetAnchorPosition, let referenceFrequency = targetFrequency ?? lockedFrequency {
			let anchor = Double(min(max(targetAnchorPosition, 0), 1))
			normalized = min(max(anchor + ((sourceFrequency - referenceFrequency) / Layout.anchoredFrequencyWindow), 0), 1)
		} else {
			normalized = min(max(sourceFrequency / Layout.frequencyRange.upperBound, 0), 1)
		}
		return (normalized, normalized * width)
	}
	
		private func indicatorXPosition(for xPosition: CGFloat, width: CGFloat) -> CGFloat {
			max(
				0,
				min(
					xPosition - (Layout.indicatorWidth / 2),
					width - Layout.indicatorWidth
				)
			)
		}
	
	private var flashOverlay: some View {
		Circle()
			.fill(sliderAccentColor.opacity(flashOpacity))
			.frame(width: Layout.flashSize, height: Layout.flashSize)
			.blur(radius: Layout.flashBlurRadius)
	}
	
	private var trackGradient: some ShapeStyle {
		LinearGradient(
			stops: [
				.init(color: sliderAccentColor.opacity(0), location: 0),
				.init(color: sliderAccentColor.opacity(0.85), location: 0.18),
				.init(color: sliderAccentColor.opacity(0.85), location: 0.82),
				.init(color: sliderAccentColor.opacity(0), location: 1)
			],
			startPoint: .leading,
			endPoint: .trailing
		)
	}
	
	private var trackBody: some View {
		TaperedTrackShape()
			.fill(trackGradient)
			.frame(height: Layout.trackCenterHeight)
	}
	
	private var indicatorMark: some View {
		ZStack {
			ForEach(0..<9, id: \.self) { index in
				let fraction = CGFloat(index) / 8
				let delay = fraction * 0.35
				let dotProgress = min(max((indicatorRevealProgress - delay) / max(1 - delay, 0.01), 0), 1)
				let targetY = (-Layout.indicatorHeight / 2) + (Layout.indicatorHeight * fraction)
				let startY = Layout.indicatorHeight * 0.85
				let startX = (index.isMultiple(of: 2) ? -1.0 : 1.0) * CGFloat(5 + (index % 3) * 3)
				let dotFadeOut = min(max((indicatorRevealProgress - 0.74) / 0.26, 0), 1)
				
				Circle()
					.fill(sliderAccentColor)
					.frame(width: Layout.indicatorWidth + 2, height: Layout.indicatorWidth + 2)
					.opacity((1 - dotFadeOut) * min(dotProgress * 1.4, 1))
					.offset(
						x: startX * (1 - dotProgress),
						y: startY + ((targetY - startY) * dotProgress)
					)
			}
			
			Rectangle()
				.fill(sliderAccentColor)
				.frame(width: Layout.indicatorWidth, height: Layout.indicatorHeight)
				.opacity(min(max((indicatorRevealProgress - 0.70) / 0.30, 0), 1))
		}
		.frame(width: Layout.indicatorWidth + 1, height: Layout.indicatorHeight)
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
					let particleStartY = -Layout.indicatorHeight * indicatorRevealProgress
					let xPosition = indicatorXPosition(
						for: normalizedValue(for: width, frequency: particle.frequency).xPosition,
						width: width
					) + (Layout.indicatorWidth / 2)
					
					Circle()
						.fill(particle.color.opacity(1 - progress))
						.frame(width: particle.size, height: particle.size)
						.offset(
							x: xPosition - (particle.size / 2),
							y: particleStartY - (Layout.particleRiseDistance * progress)
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
					trackBody

					frequencyParticleLayer(width: geometry.size.width)
				
						if shouldShowIndicator {
							indicatorMark
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
				.onChange(of: shouldShowIndicator) { _, newValue in
					animateIndicatorAppearance(isVisible: newValue)
				}
				.onChange(of: particleFrequency) {
					appendFrequencyParticle(frequency: particleFrequency)
				}
				.onChange(of: activeLockedString) {
					if !locked {
						lockedFrequency = nil
						displayedFrequency = 0
						indicatorRevealProgress = 0
					}
				}
				.onChange(of: isHighlighted) { _, newValue in
					if newValue {
						triggerFlash()
					}
				}
				.onAppear {
					indicatorRevealProgress = shouldShowIndicator ? 1 : 0
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
	
	private func animateIndicatorAppearance(isVisible: Bool) {
		if isVisible {
			indicatorRevealProgress = 0
			withAnimation(.easeOut(duration: Layout.indicatorRevealDuration)) {
				indicatorRevealProgress = 1
			}
		} else {
			withAnimation(.easeOut(duration: 0.16)) {
				indicatorRevealProgress = 0
			}
		}
	}
}
