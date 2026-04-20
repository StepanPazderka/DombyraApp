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

    private var sampleBuffer: [Float] = []
    private var observations: [PitchObservation] = []
    private var trackerState: TrackerState = .idle
    private var lockedFrequency: Double?
    private var lastValidObservationTime: TimeInterval?
    private var lastLockedMatchTime: TimeInterval?
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
            publish(frequency: lockedFrequency ?? 0, amplitude: rms, state: trackerState)
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
            log(
                rms: rms,
                detection: detection,
                published: lockedFrequency ?? 0,
                status: "attack_ignore",
                decision: .reject
            )
            publish(frequency: lockedFrequency ?? 0, amplitude: rms, state: trackerState)
            return
        }

        let observationAccepted = detection?.confidence ?? 0 >= minimumObservationConfidence
        if let detection, detection.confidence >= minimumObservationConfidence {
            let observation = PitchObservation(time: now, frequency: detection.frequency, confidence: detection.confidence)
            observations.append(observation)
            lastValidObservationTime = now
        }

        observations.removeAll { now - $0.time > observationWindow }

        let trackedFrequency = updateTracker(now: now)
        let publishedFrequency = trackedFrequency ?? 0
        let decision = logDecision(
            detection: detection,
            observationAccepted: observationAccepted,
            publishedFrequency: publishedFrequency
        )

        log(
            rms: rms,
            detection: detection,
            published: publishedFrequency,
            status: trackerState.rawValue,
            decision: decision
        )
        publish(frequency: publishedFrequency, amplitude: rms, state: trackerState)
    }

    private func handleSilence(now: TimeInterval, rms: Double) {
        observations.removeAll { now - $0.time > observationWindow }

        let publishedFrequency: Double
        if let lastValidObservationTime, now - lastValidObservationTime <= silenceHoldDuration {
            let heldFrequency = lockedFrequency ?? strongestCluster(from: observations)?.representativeFrequency ?? 0
            publishedFrequency = heldFrequency
            publish(frequency: heldFrequency, amplitude: rms, state: trackerState)
        } else {
            trackerState = .idle
            lockedFrequency = nil
            publishedFrequency = 0
            publish(frequency: 0, amplitude: rms, state: trackerState)
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
                lockedFrequency = cluster.representativeFrequency
                lastLockedMatchTime = now
                return cluster.representativeFrequency
            }
            return nil

        case .acquiring:
            if cluster.count >= lockedClusterCount && cluster.timeSpan >= lockedClusterTimeSpan {
                trackerState = .locked
                lockedFrequency = cluster.representativeFrequency
                lastLockedMatchTime = now
                return cluster.representativeFrequency
            }

            if cluster.count >= acquiringClusterCount {
                lockedFrequency = cluster.representativeFrequency
                lastLockedMatchTime = now
                return cluster.representativeFrequency
            }
            return lockedFrequency

        case .locked:
            guard let lockedFrequency else {
                trackerState = .idle
                return nil
            }

            let deviationRatio = abs(cluster.representativeFrequency - lockedFrequency) / max(lockedFrequency, 1)
            if deviationRatio <= relockDistanceRatio {
                self.lockedFrequency = cluster.representativeFrequency
                lastLockedMatchTime = now
                return cluster.representativeFrequency
            }

            if cluster.count >= lockReplacementCount && cluster.timeSpan >= lockReplacementTimeSpan {
                self.lockedFrequency = cluster.representativeFrequency
                lastLockedMatchTime = now
                return cluster.representativeFrequency
            }

            if let lastLockedMatchTime, now - lastLockedMatchTime > 0.35, cluster.count >= acquiringClusterCount {
                trackerState = .acquiring
                self.lockedFrequency = cluster.representativeFrequency
                return cluster.representativeFrequency
            }

            return lockedFrequency
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

    private func representativeFrequency(for observations: [PitchObservation]) -> Double {
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
                observations.count,
                status
            )
        )
    }
}
