//
//  ToneDetector.swift
//  DombyraApp
//
//  Created by Štěpán Pazderka on 16.04.2026.
//

import Foundation
import AVFoundation
import Combine

final class ToneDetector: ObservableObject {
	@Published var frequency: Double = 0
	@Published var amplitude: Double = 0
	
	private var recentFrequencies: [(time: TimeInterval, value: Double)] = []
	private let stabilityWindow: TimeInterval = 0.18
	private let tapBufferSize: AVAudioFrameCount = 2048
	private let smoothingFactor: Double = 0.22
	private var smoothedFrequency: Double = 0
	
	private let yinThreshold: Double = 0.12
	private let minimumRMS: Double = 0.003
	private let minDetectableFrequency: Double = 60
	private let maxDetectableFrequency: Double = 400
	
	private let engine = AVAudioEngine()
	private let session = AVAudioSession.sharedInstance()
	private var isRunning = false
	
	func start() async throws {
		guard !isRunning else { return }
		
		let granted = await AVAudioApplication.requestRecordPermission()
		guard granted else {
			throw NSError(domain: "ToneDetector", code: 1, userInfo: [
				NSLocalizedDescriptionKey: "Microphone permission denied"
			])
		}
		
		try session.setCategory(.playAndRecord, mode: .measurement, options: [])
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
		recentFrequencies.removeAll()
		smoothedFrequency = 0
		
		Task { @MainActor in
			self.frequency = 0
			self.amplitude = 0
		}
	}
	
	private func process(buffer: AVAudioPCMBuffer) {
		guard let channelData = buffer.floatChannelData?[0] else { return }
		
		let frameCount = Int(buffer.frameLength)
		guard frameCount > 0 else { return }
		
		let rawSamples = Array(UnsafeBufferPointer(start: channelData, count: frameCount))
		let rms = calculateRMS(rawSamples)
		
		guard rms > minimumRMS else {
			recentFrequencies.removeAll()
			smoothedFrequency = 0
			Task { @MainActor in
				self.amplitude = rms
				self.frequency = 0
			}
			return
		}
		
		let sampleRate = buffer.format.sampleRate
		let preparedSamples = prepareSamplesForPitchDetection(rawSamples)
		let detectedFrequency = detectFrequencyYIN(
			samples: preparedSamples,
			sampleRate: sampleRate,
			minFrequency: minDetectableFrequency,
			maxFrequency: maxDetectableFrequency
		)
		
		if let detectedFrequency {
			let now = Date().timeIntervalSinceReferenceDate
			recentFrequencies.append((time: now, value: detectedFrequency))
			recentFrequencies.removeAll { now - $0.time > stabilityWindow }
		}
		
		let stabilizedFrequency = medianRecentFrequency() ?? detectedFrequency ?? 0
		if stabilizedFrequency > 0 {
			if smoothedFrequency == 0 {
				smoothedFrequency = stabilizedFrequency
			} else {
				smoothedFrequency = (smoothingFactor * stabilizedFrequency) + ((1 - smoothingFactor) * smoothedFrequency)
			}
		}
		
		Task { @MainActor in
			self.amplitude = rms
			self.frequency = smoothedFrequency
		}
	}
	
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
	
	private func medianRecentFrequency() -> Double? {
		let values = recentFrequencies.map(\.value).filter { $0 > 0 }
		guard !values.isEmpty else { return nil }
		
		let sorted = values.sorted()
		let middleIndex = sorted.count / 2
		
		if sorted.count.isMultiple(of: 2) {
			return (sorted[middleIndex - 1] + sorted[middleIndex]) / 2
		} else {
			return sorted[middleIndex]
		}
	}
	
	private func detectFrequencyYIN(
		samples: [Double],
		sampleRate: Double,
		minFrequency: Double,
		maxFrequency: Double
	) -> Double? {
		guard samples.count > 32 else { return nil }
		
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
		for lag in minLag...maxLag {
			if cmndf[lag] < yinThreshold {
				var refinedLag = lag
				while refinedLag + 1 <= maxLag, cmndf[refinedLag + 1] < cmndf[refinedLag] {
					refinedLag += 1
				}
				candidateLag = refinedLag
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
			
			guard bestValue < 0.25 else { return nil }
			candidateLag = bestLag
		}
		
		guard let lag = candidateLag else { return nil }
		let betterLag = parabolicLagEstimate(values: cmndf, index: lag)
		guard betterLag > 0 else { return nil }
		
		let detectedFrequency = sampleRate / betterLag
		guard detectedFrequency.isFinite else { return nil }
		guard detectedFrequency >= minFrequency, detectedFrequency <= maxFrequency else { return nil }
		return detectedFrequency
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
}
