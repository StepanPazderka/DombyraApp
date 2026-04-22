//
//  ToneDetector.swift
//  DombyraApp
//
//  Created by Stepan Pazderka on 16.04.2026.
//

import Foundation
import AVFoundation
import Combine

/// Live pitch detector for the tuner screen.
///
/// The class has three responsibilities:
/// - collect microphone samples from `AVAudioEngine`
/// - estimate raw pitch candidates with a YIN-style detector
/// - stabilize those candidates into a UI-friendly published frequency
///
/// The stabilization layer intentionally prefers continuity over raw accuracy.
/// Small changes should move immediately, while octave jumps and one-off outliers
/// must be confirmed before they are allowed to reach the UI.
final class ToneDetector: ObservableObject {
	@Published var frequency: Double = 0
	@Published var amplitude: Double = 0
	
	private let appStartTime = Date().timeIntervalSinceReferenceDate
	
	private struct PitchObservation {
		let time: TimeInterval
		let frequency: Double
		let confidence: Double
	}
	
	private enum TrackerState: String {
		case idle
		case acquiring
		case locked
	}
	
	private enum LogDecision: String {
		case pass
		case hold
		case reject
	}
	
	private struct PitchCluster {
		let representativeFrequency: Double
		let observations: [PitchObservation]
		
		var count: Int {
			observations.count
		}
		
		var averageConfidence: Double {
			observations.reduce(0) { $0 + $1.confidence } / Double(observations.count)
		}
		
		var timeSpan: TimeInterval {
			guard let first = observations.first, let last = observations.last else { return 0 }
			return last.time - first.time
		}
	}
	
	@Published private(set) var debugState: String = TrackerState.idle.rawValue
	
	// MARK: - Runtime State
	
	private var sampleBuffer: [Float] = []
	private var recentObservations: [PitchObservation] = []
	private var trackerState: TrackerState = .idle
	private var stableFrequency: Double?
	private var lastPublishedFrequency: Double?
	private var lastValidObservationTime: TimeInterval?
	private var lastLockedMatchTime: TimeInterval?
	private var noteOnsetTime: TimeInterval?
	private var lastRMSAboveThreshold = false
	
	// MARK: - Tuning Parameters
	
	private let tapBufferSize: AVAudioFrameCount = 512
	private let analysisFrameCount = 4096
	private let maxBufferedSamples = 8192
	
	private let observationWindow: TimeInterval = 1.2
	private let clusterWindow: TimeInterval = 0.85
	private let silenceHoldDuration: TimeInterval = 0.7
	private let onsetIgnoreDuration: TimeInterval = 0.05
	
	private let yinThreshold: Double = 0.12
	private let minimumRMS: Double = 0.0025
	private let minDetectableFrequency: Double = 60
	private let maxDetectableFrequency: Double = 400
	private let clusterToleranceRatio: Double = 0.028
	private let minimumObservationConfidence: Double = 0.16
	private let immediateRetuneRatio: Double = 0.02
	private let acquiringClusterCount = 2
	private let lockedClusterCount = 3
	private let lockedClusterTimeSpan: TimeInterval = 0.18
	private let relockDistanceRatio: Double = 0.075
	private let lockReplacementCount = 5
	private let lockReplacementTimeSpan: TimeInterval = 0.32
	private let fastSwitchClusterCount = 2
	private let fastSwitchTimeSpan: TimeInterval = 0.04
	private let fastSwitchConfidence: Double = 0.68
	private let fastSwitchAttackWindow: TimeInterval = 0.45
	private let logDetections = true
	
	// MARK: - Audio Engine
	
	private let engine = AVAudioEngine()
	private let session = AVAudioSession.sharedInstance()
	private var isRunning = false
	
	// MARK: - Lifecycle
	
	func start() async throws {
		guard !isRunning else { return }
		
		let granted = await AVAudioApplication.requestRecordPermission()
		guard granted else {
			throw NSError(domain: "ToneDetector", code: 1, userInfo: [
				NSLocalizedDescriptionKey: "Microphone permission denied"
			])
		}
		
		try session.setCategory(.playAndRecord, mode: .measurement, options: [])
		try session.setPreferredIOBufferDuration(Double(tapBufferSize) / 44_100.0)
		try session.setActive(true)
		
		let input = engine.inputNode
		let format = input.inputFormat(forBus: 0)
		
		input.removeTap(onBus: 0)
		input.installTap(onBus: 0, bufferSize: tapBufferSize, format: format) { [weak self] buffer, _ in
			guard let self else { return }
			self.process(buffer: buffer)
		}
		
		engine.prepare()
		try engine.start()
		isRunning = true
	}
	
	func stop() {
		guard isRunning else { return }
		engine.inputNode.removeTap(onBus: 0)
		engine.stop()
		isRunning = false
		
		sampleBuffer.removeAll()
			recentObservations.removeAll()
			trackerState = .idle
			stableFrequency = nil
		lastPublishedFrequency = nil
		lastValidObservationTime = nil
		lastLockedMatchTime = nil
		noteOnsetTime = nil
		lastRMSAboveThreshold = false
		
		Task { @MainActor in
			self.frequency = 0
			self.amplitude = 0
			self.debugState = TrackerState.idle.rawValue
		}
	}
	
	// MARK: - Audio Processing
	
	private func process(buffer: AVAudioPCMBuffer) {
		guard let channelData = buffer.floatChannelData?[0] else { return }
		
		let frameCount = Int(buffer.frameLength)
		guard frameCount > 0 else { return }
		
		let rawSamples = Array(UnsafeBufferPointer(start: channelData, count: frameCount))
		let rms = calculateRMS(rawSamples)
		let now = Date().timeIntervalSinceReferenceDate
		
		updateNoteOnsetTracking(rms: rms, now: now)
		
		if rms <= minimumRMS {
			handleSilence(now: now, rms: rms)
			return
		}
		
		sampleBuffer.append(contentsOf: rawSamples)
		if sampleBuffer.count > maxBufferedSamples {
			sampleBuffer.removeFirst(sampleBuffer.count - maxBufferedSamples)
		}
		
		guard sampleBuffer.count >= analysisFrameCount else {
				publish(frequency: currentPublishedFrequency(fallback: stableFrequency), amplitude: rms, state: trackerState)
			return
		}
		
		let sampleRate = buffer.format.sampleRate
		let analysisSamples = Array(sampleBuffer.suffix(analysisFrameCount))
		let preparedSamples = prepareSamplesForPitchDetection(analysisSamples)
		let rawDetection = detectFrequencyYIN(
			samples: preparedSamples,
			sampleRate: sampleRate,
			minFrequency: minDetectableFrequency,
			maxFrequency: maxDetectableFrequency
		)
			let normalizedPitchDetection = normalizedDetection(
				rawDetection,
				referenceFrequency: stableFrequency ?? lastPublishedFrequency
			)
		
		// The initial transient after a pluck is the noisiest part of the signal.
		// We keep publishing the previous stable value during that short window.
			if let noteOnsetTime, now - noteOnsetTime < onsetIgnoreDuration {
				log(
					rms: rms,
					detection: normalizedPitchDetection,
					published: currentPublishedFrequency(fallback: stableFrequency),
					status: "attack_ignore",
					decision: .reject
				)
				publish(frequency: currentPublishedFrequency(fallback: stableFrequency), amplitude: rms, state: trackerState)
				return
			}
			
			let observationAccepted = normalizedPitchDetection?.confidence ?? 0 >= minimumObservationConfidence
			if let normalizedPitchDetection, normalizedPitchDetection.confidence >= minimumObservationConfidence {
				let observation = PitchObservation(time: now, frequency: normalizedPitchDetection.frequency, confidence: normalizedPitchDetection.confidence)
				recentObservations.append(observation)
				lastValidObservationTime = now
			}
			
			recentObservations.removeAll { now - $0.time > observationWindow }
			
			let trackedFrequency = updateTracker(now: now)
			let publishedFrequency = currentPublishedFrequency(fallback: trackedFrequency)
			let decision = logDecision(
				detection: normalizedPitchDetection,
				observationAccepted: observationAccepted,
				publishedFrequency: publishedFrequency
			)
		
			log(
				rms: rms,
				detection: normalizedPitchDetection,
				published: publishedFrequency,
				status: trackerState.rawValue,
				decision: decision
		)
		publish(frequency: publishedFrequency, amplitude: rms, state: trackerState)
	}
	
	private func handleSilence(now: TimeInterval, rms: Double) {
		recentObservations.removeAll { now - $0.time > observationWindow }
		
		let publishedFrequency: Double
		if let lastValidObservationTime, now - lastValidObservationTime <= silenceHoldDuration {
			let heldFrequency = currentPublishedFrequency(
				fallback: stableFrequency ?? strongestCluster(from: recentObservations)?.representativeFrequency
			)
			publishedFrequency = heldFrequency
			publish(frequency: heldFrequency, amplitude: rms, state: trackerState)
		} else {
			trackerState = .idle
			stableFrequency = nil
			publishedFrequency = currentPublishedFrequency()
			publish(frequency: publishedFrequency, amplitude: rms, state: trackerState)
		}
		
		log(
			rms: rms,
			detection: nil,
			published: publishedFrequency,
			status: "silence_\(trackerState.rawValue)",
			decision: publishedFrequency > 0 ? .hold : .reject
		)
	}
	
	private func updateNoteOnsetTracking(rms: Double, now: TimeInterval) {
		let isAboveThreshold = rms > minimumRMS
		if isAboveThreshold && !lastRMSAboveThreshold {
			noteOnsetTime = now
		} else if !isAboveThreshold {
			noteOnsetTime = nil
		}
		lastRMSAboveThreshold = isAboveThreshold
	}
	
	// MARK: - Pitch Tracking
	
	private func updateTracker(now: TimeInterval) -> Double? {
		let recentCandidates = recentObservations.filter { now - $0.time <= clusterWindow }
		guard !recentCandidates.isEmpty else {
			trackerState = .idle
			stableFrequency = nil
			return nil
		}
		
		// When we already have a stable tone, first try to keep following nearby
		// samples. Only if that fails do we look at the strongest cluster overall.
		let selectedCluster: PitchCluster?
		if let stableFrequency {
			selectedCluster = bestCluster(near: stableFrequency, from: recentCandidates) ?? strongestCluster(from: recentCandidates)
		} else {
			selectedCluster = strongestCluster(from: recentCandidates)
		}
		
		guard let selectedCluster else {
			trackerState = .idle
			stableFrequency = nil
			return nil
		}
		
		switch trackerState {
		case .idle:
			if selectedCluster.count >= acquiringClusterCount {
				trackerState = .acquiring
				stableFrequency = selectedCluster.representativeFrequency
				lastLockedMatchTime = now
				return selectedCluster.representativeFrequency
			}
			return nil
			
		case .acquiring:
			// For small retuning moves we do not want to wait for a full re-lock.
			// If the newest observations stay near the current cluster, publish them.
			if let latestResponsiveFrequency = latestResponsiveFrequency(near: selectedCluster.representativeFrequency, within: recentCandidates) {
				stableFrequency = latestResponsiveFrequency
				lastLockedMatchTime = now
				return latestResponsiveFrequency
			}
			
			if shouldFastSwitch(to: selectedCluster, now: now) {
				trackerState = .locked
				stableFrequency = selectedCluster.representativeFrequency
				lastLockedMatchTime = now
				return selectedCluster.representativeFrequency
			}
			
			if selectedCluster.count >= lockedClusterCount && selectedCluster.timeSpan >= lockedClusterTimeSpan {
				trackerState = .locked
				stableFrequency = selectedCluster.representativeFrequency
				lastLockedMatchTime = now
				return selectedCluster.representativeFrequency
			}
			
			if selectedCluster.count >= acquiringClusterCount {
				stableFrequency = selectedCluster.representativeFrequency
				lastLockedMatchTime = now
				return selectedCluster.representativeFrequency
			}
			return stableFrequency
			
		case .locked:
			guard let stableFrequency else {
				trackerState = .idle
				return nil
			}
			
			let deviationRatio = abs(selectedCluster.representativeFrequency - stableFrequency) / max(stableFrequency, 1)
			if deviationRatio <= relockDistanceRatio {
				let responsiveFrequency = latestResponsiveFrequency(
					near: selectedCluster.representativeFrequency,
					within: recentCandidates
				) ?? selectedCluster.representativeFrequency
				self.stableFrequency = responsiveFrequency
				lastLockedMatchTime = now
				return responsiveFrequency
			}
			
			// A fresh pluck can legitimately move to a different stable tone fast.
			// Allow that jump only when the new cluster is short, strong and coherent.
			if shouldFastSwitch(to: selectedCluster, now: now) {
				trackerState = .locked
				self.stableFrequency = selectedCluster.representativeFrequency
				lastLockedMatchTime = now
				return selectedCluster.representativeFrequency
			}
			
			if selectedCluster.count >= lockReplacementCount && selectedCluster.timeSpan >= lockReplacementTimeSpan {
				self.stableFrequency = selectedCluster.representativeFrequency
				lastLockedMatchTime = now
				return selectedCluster.representativeFrequency
			}
			
			if let lastLockedMatchTime, now - lastLockedMatchTime > 0.35, selectedCluster.count >= acquiringClusterCount {
				trackerState = .acquiring
				self.stableFrequency = selectedCluster.representativeFrequency
				return selectedCluster.representativeFrequency
			}
			
			return stableFrequency
		}
	}
	
	private func strongestCluster(from observations: [PitchObservation]) -> PitchCluster? {
		var clusters: [PitchCluster] = []
		
		for observation in observations {
			let tolerance = max(1.5, observation.frequency * clusterToleranceRatio)
			
			if let index = clusters.firstIndex(where: { abs($0.representativeFrequency - observation.frequency) <= tolerance }) {
				var updatedObservations = clusters[index].observations
				updatedObservations.append(observation)
				let representativeFrequency = representativeFrequency(for: updatedObservations)
				clusters[index] = PitchCluster(representativeFrequency: representativeFrequency, observations: updatedObservations)
			} else {
				clusters.append(PitchCluster(representativeFrequency: observation.frequency, observations: [observation]))
			}
		}
		
		return clusters
			.sorted { lhs, rhs in
				if lhs.count == rhs.count {
					return lhs.averageConfidence > rhs.averageConfidence
				}
				return lhs.count > rhs.count
			}
			.first
	}
	
	private func bestCluster(near reference: Double, from observations: [PitchObservation]) -> PitchCluster? {
		let nearby = observations.filter {
			abs($0.frequency - reference) / max(reference, 1) <= relockDistanceRatio
		}
		
		guard !nearby.isEmpty else { return nil }
		return strongestCluster(from: nearby)
	}
	
	private func shouldFastSwitch(to cluster: PitchCluster, now: TimeInterval) -> Bool {
		guard cluster.count >= fastSwitchClusterCount else { return false }
		guard cluster.timeSpan >= fastSwitchTimeSpan else { return false }
		guard cluster.averageConfidence >= fastSwitchConfidence else { return false }
		
		if let noteOnsetTime {
			return now - noteOnsetTime <= fastSwitchAttackWindow
		}
		
		if let lastLockedMatchTime {
			return now - lastLockedMatchTime <= fastSwitchAttackWindow
		}
		
		return false
	}
	
	private func latestResponsiveFrequency(
		near referenceFrequency: Double,
		within observations: [PitchObservation]
	) -> Double? {
		// Use the newest nearby sample instead of a slower cluster center when the
		// player is making small manual tuning adjustments.
		let tolerance = max(1.0, referenceFrequency * immediateRetuneRatio)
		return observations
			.reversed()
			.first(where: { abs($0.frequency - referenceFrequency) <= tolerance })?
			.frequency
	}
	
	private func publish(frequency: Double, amplitude: Double, state: TrackerState) {
		if frequency > 0 {
			lastPublishedFrequency = frequency
		}
		
		Task { @MainActor in
			self.frequency = frequency
			self.amplitude = amplitude
			self.debugState = state.rawValue
		}
	}
	
	private func currentPublishedFrequency(fallback: Double? = nil) -> Double {
		if let fallback, fallback > 0 {
			return fallback
		}
		
		if let lastPublishedFrequency, lastPublishedFrequency > 0 {
			return lastPublishedFrequency
		}
		
		return 0
	}
	
	// MARK: - Signal Preparation
	
	private func calculateRMS(_ samples: [Float]) -> Double {
		guard !samples.isEmpty else { return 0 }
		let sum = samples.reduce(0.0) { partial, sample in
			partial + Double(sample * sample)
		}
		return sqrt(sum / Double(samples.count))
	}
	
	private func prepareSamplesForPitchDetection(_ samples: [Float]) -> [Double] {
		guard !samples.isEmpty else { return [] }
		
		let mean = samples.reduce(0.0) { $0 + Double($1) } / Double(samples.count)
		let count = samples.count
		guard count > 1 else { return samples.map { Double($0) - mean } }
		
		return samples.enumerated().map { index, sample in
			let normalizedIndex = Double(index) / Double(count - 1)
			let window = 0.5 * (1.0 - cos(2.0 * .pi * normalizedIndex))
			return (Double(sample) - mean) * window
		}
	}
	
	private func representativeFrequency(for observations: [PitchObservation]) -> Double {
		// Cluster centers are intentionally robust rather than perfectly smooth.
		// We prefer the newest value near the median so the UI stays responsive
		// without letting one distant outlier drag the result away.
		let sortedByTime = observations.sorted { $0.time < $1.time }
		let sortedValues = sortedByTime.map(\.frequency).sorted()
		let middleIndex = sortedValues.count / 2
		let medianFrequency: Double
		
		if sortedValues.count.isMultiple(of: 2) {
			medianFrequency = (sortedValues[middleIndex - 1] + sortedValues[middleIndex]) / 2
		} else {
			medianFrequency = sortedValues[middleIndex]
		}
		
		let tolerance = max(1.2, medianFrequency * 0.015)
		if let newestNearMedian = sortedByTime.last(where: { abs($0.frequency - medianFrequency) <= tolerance }) {
			return newestNearMedian.frequency
		}
		
		return sortedByTime.last?.frequency ?? medianFrequency
	}
	
	private func normalizedDetection(
		_ detection: (frequency: Double, confidence: Double)?,
		referenceFrequency: Double?
	) -> (frequency: Double, confidence: Double)? {
		// If YIN briefly reports an octave above or below the current stable tone,
		// snap it back to the nearest octave-equivalent candidate.
		guard let detection else { return nil }
		guard let referenceFrequency, referenceFrequency > 0 else { return detection }
		guard trackerState != .idle else { return detection }
		
		let candidate = detection.frequency
		var bestFrequency = candidate
		var bestDistance = abs(candidate - referenceFrequency)
		
		for multiplier in [0.5, 1.0, 2.0] {
			let adjustedFrequency = candidate * multiplier
			guard adjustedFrequency >= minDetectableFrequency,
				  adjustedFrequency <= maxDetectableFrequency else {
				continue
			}
			
			let distance = abs(adjustedFrequency - referenceFrequency)
			if distance < bestDistance {
				bestDistance = distance
				bestFrequency = adjustedFrequency
			}
		}
		
		let referenceTolerance = max(3.5, referenceFrequency * 0.18)
		guard bestFrequency != candidate, bestDistance <= referenceTolerance else {
			return detection
		}
		
		return (bestFrequency, detection.confidence)
	}
	
	private func detectFrequencyYIN(
		samples: [Double],
		sampleRate: Double,
		minFrequency: Double,
		maxFrequency: Double
	) -> (frequency: Double, confidence: Double)? {
		guard samples.count > 64 else { return nil }
		
		let minLag = max(2, Int(sampleRate / maxFrequency))
		let maxLag = min(Int(sampleRate / minFrequency), (samples.count / 2) - 1)
		guard minLag < maxLag, maxLag > 2 else { return nil }
		
		var difference = Array(repeating: 0.0, count: maxLag + 1)
		var cmndf = Array(repeating: 1.0, count: maxLag + 1)
		
		for lag in 1...maxLag {
			var sum = 0.0
			let limit = samples.count - lag
			if limit <= 0 { continue }
			
			for index in 0..<limit {
				let delta = samples[index] - samples[index + lag]
				sum += delta * delta
			}
			
			difference[lag] = sum
		}
		
		var runningSum = 0.0
		for lag in 1...maxLag {
			runningSum += difference[lag]
			cmndf[lag] = runningSum == 0 ? 1.0 : difference[lag] * Double(lag) / runningSum
		}
		
		var candidateLag: Int?
		var candidateValue = 1.0
		
		for lag in minLag...maxLag {
			if cmndf[lag] < yinThreshold {
				var refinedLag = lag
				while refinedLag + 1 <= maxLag, cmndf[refinedLag + 1] < cmndf[refinedLag] {
					refinedLag += 1
				}
				candidateLag = refinedLag
				candidateValue = cmndf[refinedLag]
				break
			}
		}
		
		if candidateLag == nil {
			var bestLag = minLag
			var bestValue = cmndf[minLag]
			for lag in (minLag + 1)...maxLag where cmndf[lag] < bestValue {
				bestValue = cmndf[lag]
				bestLag = lag
			}
			
			guard bestValue < 0.22 else { return nil }
			candidateLag = bestLag
			candidateValue = bestValue
		}
		
		guard let lag = candidateLag else { return nil }
		let octaveCorrectedLag = correctedLag(from: lag, candidateValue: candidateValue, values: cmndf, maxLag: maxLag)
		let refinedLag = parabolicLagEstimate(values: cmndf, index: octaveCorrectedLag)
		guard refinedLag > 0 else { return nil }
		
		let detectedFrequency = sampleRate / refinedLag
		guard detectedFrequency.isFinite else { return nil }
		guard detectedFrequency >= minFrequency, detectedFrequency <= maxFrequency else { return nil }
		
		let confidence = max(0, min(1, 1 - (candidateValue / 0.25)))
		return (detectedFrequency, confidence)
	}
	
	private func correctedLag(from lag: Int, candidateValue: Double, values: [Double], maxLag: Int) -> Int {
		let octaveLag = lag * 2
		guard octaveLag <= maxLag else { return lag }
		
		let octaveValue = values[octaveLag]
		let acceptableOctaveValue = min(0.22, candidateValue * 1.45)
		guard octaveValue <= acceptableOctaveValue else { return lag }
		
		return octaveLag
	}
	
	private func parabolicLagEstimate(values: [Double], index: Int) -> Double {
		guard index > 0, index < values.count - 1 else { return Double(index) }
		
		let left = values[index - 1]
		let center = values[index]
		let right = values[index + 1]
		let denominator = left - (2 * center) + right
		
		guard abs(denominator) > .ulpOfOne else { return Double(index) }
		let offset = 0.5 * (left - right) / denominator
		return Double(index) + offset
	}
	
	// MARK: - Debug Logging
	
	private func logDecision(
		detection: (frequency: Double, confidence: Double)?,
		observationAccepted: Bool,
		publishedFrequency: Double
	) -> LogDecision {
		guard let detection else {
			return publishedFrequency > 0 ? .hold : .reject
		}
		
		guard observationAccepted else {
			return .reject
		}
		
		guard publishedFrequency > 0 else {
			return .hold
		}
		
		let tolerance = max(1.5, detection.frequency * clusterToleranceRatio)
		return abs(publishedFrequency - detection.frequency) <= tolerance ? .pass : .hold
	}
	
	private func log(
		rms: Double,
		detection: (frequency: Double, confidence: Double)?,
		published: Double,
		status: String,
		decision: LogDecision
	) {
		guard logDetections else { return }
		
		let elapsedSeconds = Date().timeIntervalSinceReferenceDate - appStartTime
		let detectedText = detection.map { String(format: "%.4f", $0.frequency) } ?? "nil"
		let publishedText = published > 0 ? String(format: "%.4f", published) : "0.0000"
		let confidenceText = detection.map { String(format: "%.2f", $0.confidence) } ?? "nil"
		print(
			String(
				format: "[ToneDetector] t=%.2fs detected=%@ published=%@ ui=%@ rms=%.5f confidence=%@ observations=%d state=%@",
				elapsedSeconds,
				detectedText,
				publishedText,
				decision.rawValue,
				rms,
				confidenceText,
				recentObservations.count,
				status
			)
		)
	}
}
