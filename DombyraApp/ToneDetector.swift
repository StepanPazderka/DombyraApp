//
//  ToneDetector.swift
//  DombyraApp
//
//  Created by Stepan Pazderka on 16.04.2026.
//

import Foundation
import AVFoundation
import Combine

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

    private struct PitchCluster {
        let center: Double
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

    private var sampleBuffer: [Float] = []
    private var observations: [PitchObservation] = []
    private var trackerState: TrackerState = .idle
    private var lockedFrequency: Double?
    private var smoothedFrequency: Double = 0
    private var lastValidObservationTime: TimeInterval?
    private var noteOnsetTime: TimeInterval?
    private var lastRMSAboveThreshold = false

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
    private let acquiringClusterCount = 2
    private let lockedClusterCount = 3
    private let lockedClusterTimeSpan: TimeInterval = 0.18
    private let relockDistanceRatio: Double = 0.075
    private let lockReplacementCount = 5
    private let lockReplacementTimeSpan: TimeInterval = 0.32
    private let logDetections = true

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
        observations.removeAll()
        trackerState = .idle
        lockedFrequency = nil
        smoothedFrequency = 0
        lastValidObservationTime = nil
        noteOnsetTime = nil
        lastRMSAboveThreshold = false

        Task { @MainActor in
            self.frequency = 0
            self.amplitude = 0
            self.debugState = TrackerState.idle.rawValue
        }
    }

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
            publish(frequency: smoothedFrequency, amplitude: rms, state: trackerState)
            return
        }

        let sampleRate = buffer.format.sampleRate
        let analysisSamples = Array(sampleBuffer.suffix(analysisFrameCount))
        let preparedSamples = prepareSamplesForPitchDetection(analysisSamples)
        let detection = detectFrequencyYIN(
            samples: preparedSamples,
            sampleRate: sampleRate,
            minFrequency: minDetectableFrequency,
            maxFrequency: maxDetectableFrequency
        )

        if let noteOnsetTime, now - noteOnsetTime < onsetIgnoreDuration {
            log(rms: rms, detection: detection, published: smoothedFrequency, status: "attack_ignore")
            publish(frequency: smoothedFrequency, amplitude: rms, state: trackerState)
            return
        }

        if let detection, detection.confidence >= minimumObservationConfidence {
            let observation = PitchObservation(time: now, frequency: detection.frequency, confidence: detection.confidence)
            observations.append(observation)
            lastValidObservationTime = now
        }

        observations.removeAll { now - $0.time > observationWindow }

        let trackedFrequency = updateTracker(now: now)
        if let trackedFrequency {
            if smoothedFrequency == 0 {
                smoothedFrequency = trackedFrequency
            } else {
                let alpha = smoothingFactor(for: trackedFrequency)
                smoothedFrequency = (alpha * trackedFrequency) + ((1 - alpha) * smoothedFrequency)
            }
        } else {
            smoothedFrequency = 0
        }

        log(rms: rms, detection: detection, published: smoothedFrequency, status: trackerState.rawValue)
        publish(frequency: smoothedFrequency, amplitude: rms, state: trackerState)
    }

    private func handleSilence(now: TimeInterval, rms: Double) {
        observations.removeAll { now - $0.time > observationWindow }

        if let lastValidObservationTime, now - lastValidObservationTime <= silenceHoldDuration {
            let heldFrequency = lockedFrequency ?? strongestCluster(from: observations)?.center ?? smoothedFrequency
            smoothedFrequency = (0.03 * heldFrequency) + (0.97 * smoothedFrequency)
        } else {
            trackerState = .idle
            lockedFrequency = nil
            smoothedFrequency = 0
        }

        log(rms: rms, detection: nil, published: smoothedFrequency, status: "silence_\(trackerState.rawValue)")
        publish(frequency: smoothedFrequency, amplitude: rms, state: trackerState)
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

    private func updateTracker(now: TimeInterval) -> Double? {
        let candidates = observations.filter { now - $0.time <= clusterWindow }
        guard !candidates.isEmpty else {
            trackerState = .idle
            lockedFrequency = nil
            return nil
        }

        let cluster: PitchCluster?
        if let lockedFrequency {
            cluster = bestCluster(near: lockedFrequency, from: candidates) ?? strongestCluster(from: candidates)
        } else {
            cluster = strongestCluster(from: candidates)
        }

        guard let cluster else {
            trackerState = .idle
            lockedFrequency = nil
            return nil
        }

        switch trackerState {
        case .idle:
            if cluster.count >= acquiringClusterCount {
                trackerState = .acquiring
                lockedFrequency = cluster.center
                return cluster.center
            }
            return nil

        case .acquiring:
            if cluster.count >= lockedClusterCount && cluster.timeSpan >= lockedClusterTimeSpan {
                trackerState = .locked
                lockedFrequency = cluster.center
                return cluster.center
            }

            if cluster.count >= acquiringClusterCount {
                lockedFrequency = cluster.center
                return cluster.center
            }
            return lockedFrequency

        case .locked:
            guard let lockedFrequency else {
                trackerState = .idle
                return nil
            }

            let deviationRatio = abs(cluster.center - lockedFrequency) / max(lockedFrequency, 1)
            if deviationRatio <= relockDistanceRatio {
                self.lockedFrequency = cluster.center
                return cluster.center
            }

            if cluster.count >= lockReplacementCount && cluster.timeSpan >= lockReplacementTimeSpan {
                self.lockedFrequency = cluster.center
                return cluster.center
            }

            return lockedFrequency
        }
    }

    private func strongestCluster(from observations: [PitchObservation]) -> PitchCluster? {
        var clusters: [PitchCluster] = []

        for observation in observations {
            let tolerance = max(1.5, observation.frequency * clusterToleranceRatio)

            if let index = clusters.firstIndex(where: { abs($0.center - observation.frequency) <= tolerance }) {
                var updatedObservations = clusters[index].observations
                updatedObservations.append(observation)
                let newCenter = weightedCenter(for: updatedObservations)
                clusters[index] = PitchCluster(center: newCenter, observations: updatedObservations)
            } else {
                clusters.append(PitchCluster(center: observation.frequency, observations: [observation]))
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

    private func weightedCenter(for observations: [PitchObservation]) -> Double {
        let totalWeight = observations.reduce(0.0) { $0 + $1.confidence }
        guard totalWeight > .ulpOfOne else {
            return observations.reduce(0.0) { $0 + $1.frequency } / Double(observations.count)
        }

        let weightedSum = observations.reduce(0.0) { $0 + ($1.frequency * $1.confidence) }
        return weightedSum / totalWeight
    }

    private func publish(frequency: Double, amplitude: Double, state: TrackerState) {
        Task { @MainActor in
            self.frequency = frequency
            self.amplitude = amplitude
            self.debugState = state.rawValue
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

    private func smoothingFactor(for frequency: Double) -> Double {
        switch frequency {
        case ..<110:
            return 0.14
        case ..<180:
            return 0.18
        case ..<260:
            return 0.22
        default:
            return 0.26
        }
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

    private func log(rms: Double, detection: (frequency: Double, confidence: Double)?, published: Double, status: String) {
        guard logDetections else { return }

        let elapsedMilliseconds = Int(((Date().timeIntervalSinceReferenceDate - appStartTime) * 1000).rounded())
        let detectedText = detection.map { String(format: "%.2f", $0.frequency) } ?? "nil"
        let confidenceText = detection.map { String(format: "%.2f", $0.confidence) } ?? "nil"
        print(
            String(
                format: "[ToneDetector] t=%dms detected=%@ published=%.2f rms=%.5f confidence=%@ observations=%d state=%@",
                elapsedMilliseconds,
                detectedText,
                published,
                rms,
                confidenceText,
                observations.count,
                status
            )
        )
    }
}
