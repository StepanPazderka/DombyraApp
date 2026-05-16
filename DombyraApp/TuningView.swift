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
	@State private var immediateFrequency: Double = 0
	@State private var rawDetectedAmplitude: Double = 0
	@State private var lockedTopFrequency: Double? = nil
	@State private var lockedBottomFrequency: Double? = nil
	@State private var activeLockedString: LockedString? = nil
	@State private var referenceLockedAt: Date? = nil
	@State private var textAnimationTask: Task<Void, Never>?
	@State private var hasStartedTopStringSearch = false
	@State private var hasStartedBottomStringSearch = false
	@State private var stringRevealTask: Task<Void, Never>? = nil
	@State private var stringRevealString: LockedString? = nil
	@State private var stringRevealCenter: CGPoint = .zero
	@State private var stringRevealRadius: CGFloat = 0
	@State private var ornamentAnimationTask: Task<Void, Never>? = nil
	@State private var ornamentOpacity: Double = 0
	@State private var ornamentGlow: Double = 0
	@State private var ornamentScale: CGFloat = 1
	@State private var isOrnamentSignalActive = false
	
	@State var topStringFrequency: Double = 0
	@State var bottomStringFrequency: Double = 0
	
	init(tuningMode: Binding<TuningMode>) {
		self._tuningMode = tuningMode
	}
	
	private let pairingTolerance: Double = 2.0
	private let highlightTolerance: Double = 0.6
	private let animatedTextThreshold: Double = 50.0
	private let searchActivationTolerance: Double = 16.0
	private let sameReferenceTolerance: Double = 2.0
	private let contentHorizontalPadding: CGFloat = 16
	private let maximumControlsWidth: CGFloat = 760
	private let tuningModePickerBottomPadding: CGFloat = 36
	private let portraitSliderSpacing: CGFloat = 16
	private let landscapeSliderSpacing: CGFloat = 6
	private let stringRevealDuration: Double = 0.25
	private let dombyraSVGSize = CGSize(width: 1080, height: 1080)
	private let dombyraTopCropMargin: CGFloat = 80
	private let dombyraHeadBottomY: CGFloat = 420
	private let stringTapHorizontalPadding: CGFloat = 140
	private let topStringSVGX: CGFloat = 527
	private let bottomStringSVGX: CGFloat = 551
	private let ornamentVisibleDuration: UInt64 = 1_000_000_000
	private let ornamentFadeDuration: Double = 0.35
	private let ornamentGlowColor = Color(red: 0, green: 1, blue: 0.929)
	private let ornamentTriggerAmplitudeThreshold: Double = 0.003
	
	private var dombyraImageName: String {
		colorScheme == .dark ? "dombyra_dark" : "dombyra_light"
	}
	
	private var appBackground: some View {
		GeometryReader { geometry in
			let shadowRadius = max(geometry.size.width, geometry.size.height) * 0.58
			
			if colorScheme == .light {
				Color(white: 1.00)
					.overlay(alignment: .bottom) {
						RadialGradient(
							stops: [
								.init(color: Color(white: 0.62), location: 0),
								.init(color: Color(white: 0.62), location: 0.34),
								.init(color: Color(white: 0.78), location: 0.52),
								.init(color: Color(white: 0.88).opacity(0), location: 0.76)
							],
							center: .bottom,
							startRadius: 0,
							endRadius: shadowRadius
						)
						.scaleEffect(x: 1.35, y: 0.90, anchor: .bottom)
						.blur(radius: 28)
					}
					.overlay(alignment: .bottom) {
						RadialGradient(
							stops: [
								.init(color: Color.black.opacity(0.99), location: 0),
								.init(color: Color.black.opacity(0.52), location: 0.30),
								.init(color: Color.black.opacity(0), location: 0.78)
							],
							center: .bottom,
							startRadius: 0,
							endRadius: shadowRadius * 0.42
						)
						.scaleEffect(x: 2.2, y: 0.30, anchor: .bottom)
					}
					.overlay {
						ornamentBottomGlow(
							size: geometry.size,
							bottomSafeAreaInset: geometry.safeAreaInsets.bottom
						)
					}
				} else {
					Color(white: 0.18)
						.overlay(alignment: .bottom) {
							RadialGradient(
								stops: [
								.init(color: Color(white: 0.10), location: 0),
								.init(color: Color(white: 0.12), location: 0.34),
								.init(color: Color(white: 0.15), location: 0.42),
								.init(color: Color(white: 0.10).opacity(0), location: 0.66)
							],
							center: .bottom,
							startRadius: 0,
							endRadius: shadowRadius
						)
						.scaleEffect(x: 1.35, y: 0.90, anchor: .bottom)
						.blur(radius: 28)
					}
					.overlay(alignment: .bottom) {
						RadialGradient(
							stops: [
								.init(color: .black, location: 0),
								.init(color: Color.black.opacity(0.82), location: 0.30),
								.init(color: Color.black.opacity(0), location: 0.78)
							],
							center: .bottom,
							startRadius: 0,
							endRadius: shadowRadius * 0.42
						)
						.scaleEffect(x: 2.2, y: 0.30, anchor: .bottom)
					}
					.overlay {
						ornamentBottomGlow(
							size: geometry.size,
							bottomSafeAreaInset: geometry.safeAreaInsets.bottom
						)
					}
				}
			}
			.ignoresSafeArea()
		}
	
	private var shouldLiftTuningModePicker: Bool {
		let idiom = UIDevice.current.userInterfaceIdiom
		return idiom == .pad || idiom == .mac
	}
	
	private func sliderSpacing(for size: CGSize) -> CGFloat {
		size.width > size.height ? landscapeSliderSpacing : portraitSliderSpacing
	}
	
	private func topCropMargin(for size: CGSize) -> CGFloat {
		let isPhoneLandscape = UIDevice.current.userInterfaceIdiom == .phone && size.width > size.height
		return isPhoneLandscape ? 98 : dombyraTopCropMargin
	}
	
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
	
	private func controlsWidth(for size: CGSize) -> CGFloat {
		min(size.width - (contentHorizontalPadding * 2), maximumControlsWidth)
	}
	
	private func stringAnchorPosition(svgX: CGFloat, in size: CGSize, controlsWidth: CGFloat) -> CGFloat {
		let stringScreenX = screenPoint(for: CGPoint(x: svgX, y: 0), in: size).x
		let sliderWidth = max(controlsWidth, 1)
		let sliderOriginX = (size.width - controlsWidth) / 2
		let sliderLocalX = stringScreenX - sliderOriginX
		
		return min(max(sliderLocalX / sliderWidth, 0), 1)
	}
	
	private func imageScale(for size: CGSize) -> CGFloat {
		let topCropMargin = topCropMargin(for: size)
		let widthScale = size.width / dombyraSVGSize.width
		let headScale = (size.height * 0.5) / (dombyraHeadBottomY - topCropMargin)
		return max(widthScale, headScale)
	}
	
	private func displayedImageSize(for size: CGSize) -> CGSize {
		let scale = imageScale(for: size)
		return CGSize(
			width: dombyraSVGSize.width * scale,
			height: dombyraSVGSize.height * scale
		)
	}
	
	private func screenPoint(for svgPoint: CGPoint, in size: CGSize) -> CGPoint {
		let scale = imageScale(for: size)
		let topCropMargin = topCropMargin(for: size)
		let displayedImageSize = displayedImageSize(for: size)
		let imageOrigin = CGPoint(
			x: (size.width - displayedImageSize.width) / 2,
			y: -(topCropMargin * scale)
		)
		
		return CGPoint(
			x: imageOrigin.x + (svgPoint.x * scale),
			y: imageOrigin.y + (svgPoint.y * scale)
		)
	}
	
	private var topStringOverlayColor: Color? {
		if activeLockedString == .top {
			return .blue
		}
		
		return shouldHighlightTopString ? .green : nil
	}
	
	private var bottomStringOverlayColor: Color? {
		if activeLockedString == .bottom {
			return .blue
		}
		
		return shouldHighlightBottomString ? .green : nil
	}
	
	private var topStringFrequencyTextValue: Double? {
		if activeLockedString == .top {
			return lockedTopFrequency
		}
		
		if lockedTopFrequency == nil, lockedBottomFrequency != nil, displayedFrequency > 0 {
			return displayedFrequencyTextValue
		}
		
		return nil
	}
	
	private var bottomStringFrequencyTextValue: Double? {
		if activeLockedString == .bottom {
			return lockedBottomFrequency
		}
		
		if lockedBottomFrequency == nil, lockedTopFrequency != nil, displayedFrequency > 0 {
			return displayedFrequencyTextValue
		}
		
		return nil
	}
	
	private var topStringFrequencyTextColor: Color? {
		if activeLockedString == .top {
			return .blue
		}
		
		if shouldHighlightTopString {
			return .green
		}
		
		if topStringDirectionIndicator != nil {
			return tuningIndicatorColor(progress: topStringDirectionProgress)
		}
		
		return nil
	}
	
	private var bottomStringFrequencyTextColor: Color? {
		if activeLockedString == .bottom {
			return .blue
		}
		
		if shouldHighlightBottomString {
			return .green
		}
		
		if bottomStringDirectionIndicator != nil {
			return tuningIndicatorColor(progress: bottomStringDirectionProgress)
		}
		
		return nil
	}
	
	private func tuningIndicatorColor(progress: Double) -> Color {
		let clampedProgress = min(max(progress, 0), 1)
		return Color(hue: 0.10 + (0.23 * clampedProgress), saturation: 0.90, brightness: 0.95)
	}
	
	private var stringFrequencyLabels: some View {
		HStack(alignment: .firstTextBaseline, spacing: 12) {
			stringFrequencyLabel(
				value: topStringFrequencyTextValue,
				color: topStringFrequencyTextColor,
				alignment: .leading
			)
			
			stringFrequencyLabel(
				value: bottomStringFrequencyTextValue,
				color: bottomStringFrequencyTextColor,
				alignment: .trailing
			)
		}
		.frame(maxWidth: .infinity)
	}
	
	private func stringFrequencyLabel(value: Double?, color: Color?, alignment: Alignment) -> some View {
		let isVisible = value != nil && color != nil
		
		return Group {
			if let value {
				Text("\(value, specifier: "%.2f") Hz")
			} else {
				Text("00.00 Hz")
		}
		}
		.monospacedDigit()
		.foregroundStyle(color ?? .secondary)
		.opacity(isVisible ? 1 : 0)
		.animation(.easeInOut(duration: 0.5), value: isVisible)
		.frame(maxWidth: .infinity, alignment: alignment)
	}
	
	@ViewBuilder
	private func coloredStringOverlay(size: CGSize) -> some View {
		ZStack {
				if let topStringOverlayColor {
					coloredStringImage(
						name: "left_string",
						string: .top,
						color: topStringOverlayColor,
						size: size
					)
			}
			
				if let bottomStringOverlayColor {
					coloredStringImage(
						name: "right_string",
						string: .bottom,
						color: bottomStringOverlayColor,
						size: size
					)
			}
		}
			.allowsHitTesting(false)
	}
	
	private func coloredStringImage(
		name: String,
		string: LockedString,
		color: Color,
		size: CGSize
	) -> some View {
		let displayedImageSize = displayedImageSize(for: size)
		let topCropMargin = topCropMargin(for: size)
		
		return Image(name)
			.renderingMode(.template)
			.resizable()
			.frame(width: displayedImageSize.width, height: displayedImageSize.height)
			.offset(y: -topCropMargin * imageScale(for: size))
			.frame(width: size.width, height: size.height, alignment: .top)
			.frame(maxWidth: .infinity, maxHeight: .infinity)
			.foregroundStyle(color)
			.opacity(0.95)
			.mask {
				stringRevealMask(for: string, size: size)
			}
			.clipped(antialiased: true)
			.ignoresSafeArea()
	}
	
	private func ornamentOverlay(size: CGSize) -> some View {
		let displayedImageSize = displayedImageSize(for: size)
		let topCropMargin = topCropMargin(for: size)
		
		return Image("dombyra_ornament")
			.resizable()
			.frame(width: displayedImageSize.width, height: displayedImageSize.height)
			.scaleEffect(ornamentScale)
			.offset(y: -topCropMargin * imageScale(for: size))
			.frame(width: size.width, height: size.height, alignment: .top)
			.frame(maxWidth: .infinity, maxHeight: .infinity)
			.opacity(ornamentOpacity)
			.shadow(color: ornamentGlowColor.opacity(ornamentGlow), radius: 18)
			.shadow(color: ornamentGlowColor.opacity(ornamentGlow * 0.7), radius: 8)
			.clipped(antialiased: true)
			.ignoresSafeArea()
			.allowsHitTesting(false)
	}
	
	private func ornamentBottomGlow(size: CGSize, bottomSafeAreaInset: CGFloat) -> some View {
		let glowHeight = size.height + bottomSafeAreaInset
		
		return LinearGradient(
			stops: [
				.init(color: ornamentGlowColor.opacity(ornamentGlow * 0.42), location: 0),
				.init(color: ornamentGlowColor.opacity(ornamentGlow * 0.56), location: 0.10),
				.init(color: ornamentGlowColor.opacity(ornamentGlow * 0.24), location: 0.48),
				.init(color: ornamentGlowColor.opacity(0), location: 1)
			],
			startPoint: .bottom,
			endPoint: .top
		)
		.frame(width: size.width, height: glowHeight)
		.offset(y: bottomSafeAreaInset)
		.frame(width: size.width, height: size.height, alignment: .bottom)
		.ignoresSafeArea()
		.allowsHitTesting(false)
	}
	
	@ViewBuilder
	private func stringRevealMask(for string: LockedString, size: CGSize) -> some View {
		if stringRevealString == string {
			ZStack(alignment: .topLeading) {
				Circle()
					.fill(.white)
				.frame(width: max(stringRevealRadius * 2, 1), height: max(stringRevealRadius * 2, 1))
					.blur(radius: 18)
				.position(stringRevealCenter)
			}
			.frame(width: size.width, height: size.height)
		} else {
			Rectangle()
				.fill(.white)
		}
	}
	
	private func stringTapOverlay(size: CGSize) -> some View {
		let topStringX = screenPoint(for: CGPoint(x: topStringSVGX, y: 0), in: size).x
		let bottomStringX = screenPoint(for: CGPoint(x: bottomStringSVGX, y: 0), in: size).x
		let stringSplitX = (topStringX + bottomStringX) / 2
		let leftString: LockedString = topStringX < bottomStringX ? .top : .bottom
		let rightString: LockedString = topStringX < bottomStringX ? .bottom : .top
		let tapMinX = max(0, min(topStringX, bottomStringX) - stringTapHorizontalPadding)
		let tapMaxX = min(size.width, max(topStringX, bottomStringX) + stringTapHorizontalPadding)
		
		return Color.clear
			.contentShape(Rectangle())
			.frame(width: size.width, height: size.height)
			.gesture(
					DragGesture(minimumDistance: 0)
						.onEnded { value in
							guard value.location.x >= tapMinX, value.location.x <= tapMaxX else { return }
							let tappedString = value.location.x < stringSplitX ? leftString : rightString
							let shouldReveal = activeLockedString != tappedString
							
							toggleLockedString(tappedString)
							
							if activeLockedString != tappedString {
								return
							}
							
							if shouldReveal {
								triggerStringReveal(for: tappedString, at: value.location, in: size)
							}
						}
				)
	}
	
	private func triggerStringReveal(for string: LockedString, at location: CGPoint, in size: CGSize) {
		let maxRadius = [
			hypot(location.x, location.y),
			hypot(size.width - location.x, location.y),
			hypot(location.x, size.height - location.y),
			hypot(size.width - location.x, size.height - location.y)
		].max() ?? max(size.width, size.height)
		
		stringRevealString = string
		stringRevealCenter = location
		stringRevealRadius = 0
		
		stringRevealTask?.cancel()
		stringRevealTask = Task { @MainActor in
			try? await Task.sleep(for: .milliseconds(16))
			
			guard !Task.isCancelled else { return }
			withAnimation(.easeOut(duration: stringRevealDuration)) {
				stringRevealRadius = maxRadius + 80
			}
		}
	}
	
	private func triggerOrnamentGlow() {
		ornamentAnimationTask?.cancel()
		ornamentOpacity = 0
		ornamentGlow = 0
		ornamentScale = 0.985
		
		withAnimation(.easeOut(duration: 0.18)) {
			ornamentOpacity = 1
			ornamentGlow = 0.9
			ornamentScale = 1.015
		}
		
		withAnimation(.easeOut(duration: 0.30).delay(0.18)) {
			ornamentGlow = 0.25
			ornamentScale = 1
		}
		
		ornamentAnimationTask = Task { @MainActor in
			try? await Task.sleep(nanoseconds: ornamentVisibleDuration)
			
			guard !Task.isCancelled else { return }
			withAnimation(.easeIn(duration: ornamentFadeDuration)) {
				ornamentOpacity = 0
				ornamentGlow = 0
			}
		}
	}
	
	private func updateOrnamentTriggerState(amplitude: Double) {
		let isCorrectlyTuned = shouldHighlightTopString || shouldHighlightBottomString
		let hasStrongSignal = amplitude > ornamentTriggerAmplitudeThreshold
		let shouldActivate = isCorrectlyTuned && hasStrongSignal
		
		if shouldActivate && !isOrnamentSignalActive {
			triggerOrnamentGlow()
		}
		
		isOrnamentSignalActive = shouldActivate
	}
	
	private func toggleLockedString(_ string: LockedString) {
		if activeLockedString == string {
			activeLockedString = nil
			lockedTopFrequency = nil
			lockedBottomFrequency = nil
			return
		}
		
		activeLockedString = string
		switch string {
		case .top:
			lockedTopFrequency = displayedFrequency
			lockedBottomFrequency = nil
		case .bottom:
			lockedBottomFrequency = displayedFrequency
			lockedTopFrequency = nil
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
			  immediateFrequency > 0 else { return -1 }
		
		let expectedTopFrequency = pairedFrequency(for: lockedBottomFrequency, isTopString: false)
		return directionProgress(for: immediateFrequency - expectedTopFrequency)
	}
	
	private var bottomStringParticleTuningProgress: Double {
		guard lockedBottomFrequency == nil,
			  let lockedTopFrequency,
			  hasStartedBottomStringSearch,
			  immediateFrequency > 0 else { return -1 }
		
		let expectedBottomFrequency = pairedFrequency(for: lockedTopFrequency, isTopString: true)
		return directionProgress(for: immediateFrequency - expectedBottomFrequency)
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
	
	private var targetTopFrequency: Double? {
		guard lockedTopFrequency == nil, let lockedBottomFrequency else { return nil }
		return pairedFrequency(for: lockedBottomFrequency, isTopString: false)
	}
	
	private var targetBottomFrequency: Double? {
		guard lockedBottomFrequency == nil, let lockedTopFrequency else { return nil }
		return pairedFrequency(for: lockedTopFrequency, isTopString: true)
	}
	
	var body: some View {
		GeometryReader { geometry in
			let controlsWidth = controlsWidth(for: geometry.size)
			let topStringAnchorPosition = stringAnchorPosition(
				svgX: topStringSVGX,
				in: geometry.size,
				controlsWidth: controlsWidth
			)
			let bottomStringAnchorPosition = stringAnchorPosition(
				svgX: bottomStringSVGX,
				in: geometry.size,
				controlsWidth: controlsWidth
			)
			let displayedImageSize = displayedImageSize(for: geometry.size)
			let lowerHalfHeight = geometry.size.height * 0.5
			let sliderSpacing = sliderSpacing(for: geometry.size)
			let topCropMargin = topCropMargin(for: geometry.size)
			
				ZStack(alignment: .bottom) {
					appBackground
					
						Image(dombyraImageName)
						.resizable()
						.frame(width: displayedImageSize.width, height: displayedImageSize.height)
						.offset(y: -topCropMargin * imageScale(for: geometry.size))
					.frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
					.frame(maxWidth: .infinity, maxHeight: .infinity)
					.clipped(antialiased: true)
					.ignoresSafeArea()
					
					coloredStringOverlay(size: geometry.size)
					
					ornamentOverlay(size: geometry.size)
					
					stringTapOverlay(size: geometry.size)
				
				VStack(spacing: sliderSpacing) {
					stringFrequencyLabels
				
					FrequencySliderView(
						frequency: $displayedFrequency,
					particleFrequency: $immediateFrequency,
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
						isAwaitingInput: shouldAwaitTopStringInput,
						targetFrequency: targetTopFrequency,
						targetAnchorPosition: topStringAnchorPosition,
						idleIndicatorSymbol: topStringIdleIndicatorSymbol
					)
				
				FrequencySliderView(
					frequency: $displayedFrequency,
					particleFrequency: $immediateFrequency,
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
						isAwaitingInput: shouldAwaitBottomStringInput,
						targetFrequency: targetBottomFrequency,
						targetAnchorPosition: bottomStringAnchorPosition,
						idleIndicatorSymbol: bottomStringIdleIndicatorSymbol
					)
				
				}
				.padding(contentHorizontalPadding)
				.frame(width: controlsWidth, height: lowerHalfHeight, alignment: .center)
			}
		}
				.safeAreaInset(edge: .bottom, spacing: 0) {
					Group {
						if #available(iOS 26.0, *) {
							tuningModePicker
								.glassEffect()
						} else {
							tuningModePicker
						}
			}
			.padding(.horizontal)
			.padding(.bottom, shouldLiftTuningModePicker ? tuningModePickerBottomPadding : 0)
		}
			.onReceive(detector.$stabilizedFrequency) { newFrequency in
				guard newFrequency > 0 else { return }
				
				displayedFrequency = newFrequency
				animateFrequencyText(to: newFrequency)
			}
		.onReceive(detector.$immediateFrequency) { newFrequency in
			immediateFrequency = newFrequency
		}
			.onReceive(detector.$amplitude) { amplitude in
				rawDetectedAmplitude = amplitude
				updateStringSearchState(for: detector.stabilizedFrequency, amplitude: amplitude)
				updateOrnamentTriggerState(amplitude: amplitude)
			}
			.onChange(of: shouldHighlightTopString) { _, isHighlighted in
				if isHighlighted {
					updateOrnamentTriggerState(amplitude: rawDetectedAmplitude)
				} else {
					isOrnamentSignalActive = false
				}
			}
			.onChange(of: shouldHighlightBottomString) { _, isHighlighted in
				if isHighlighted {
					updateOrnamentTriggerState(amplitude: rawDetectedAmplitude)
				} else {
					isOrnamentSignalActive = false
				}
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
					stringRevealTask?.cancel()
					ornamentAnimationTask?.cancel()
				}
	}

	private var tuningModePicker: some View {
		Picker("Tuning mode", selection: $tuningMode) {
				ForEach(TuningMode.allCases) { mode in
					Text(mode.shortTitle)
						.monospacedDigit()
						.tag(mode)
				}
		}
		.pickerStyle(.segmented)
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
