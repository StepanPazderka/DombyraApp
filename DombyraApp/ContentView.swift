//
//  ContentView.swift
//  DombyraApp
//
//  Created by Štěpán Pazderka on 01.02.2026.
//

import SwiftUI
import AVFoundation
import Observation

@Observable
class AudioListener {
    private let engine = AVAudioEngine()
    var detectedFrequency: Double = 0
    
    // Basic autocorrelation-based pitch detection for mono Float32 PCM
    private func estimatePitch(from buffer: AVAudioPCMBuffer, sampleRate: Double) -> Double {
        guard let channelData = buffer.floatChannelData?[0] else { return 0 }
        let frameLength = Int(buffer.frameLength)
        if frameLength == 0 { return 0 }

        // Copy to a local array for simplicity
        let samples = Array(UnsafeBufferPointer(start: channelData, count: frameLength))

        // Search lags corresponding roughly to 82 Hz ... 330 Hz
        let minFreq: Double = 82
        let maxFreq: Double = 330
        let minLag = Int(sampleRate / maxFreq)
        let maxLag = min(Int(sampleRate / minFreq), frameLength - 1)
        if maxLag <= minLag { return 0 }

        var bestLag = 0
        var bestScore: Float = 0

        // Mean normalize (remove DC)
        let mean = samples.reduce(0, +) / Float(frameLength)
        var normSamples = samples.map { $0 - mean }

        // Autocorrelation score over lag range
        for lag in minLag...maxLag {
            var sum: Float = 0
            let end = frameLength - lag
            var i = 0
            while i < end {
                sum += normSamples[i] * normSamples[i + lag]
                i += 1
            }
            if sum > bestScore {
                bestScore = sum
                bestLag = lag
            }
        }

        guard bestLag > 0 else { return 0 }
        let freq = sampleRate / Double(bestLag)
        return freq.isFinite ? freq : 0
    }
    
    deinit {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
    
    func start() {
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        
        inputNode.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { buffer, when in
            let sampleRate = Double(inputFormat.sampleRate)
            let rawFreq = self.estimatePitch(from: buffer, sampleRate: sampleRate)

            if rawFreq > 0 {
                Task { @MainActor in
                    self.detectedFrequency = rawFreq
                }
            } else {
                Task { @MainActor in
                    self.detectedFrequency = 0
                }
            }
        }
        
        engine.prepare()
        
        do {
            try engine.start()
        } catch {
            print("Audio Engine couldn't start: \(error.localizedDescription)")
        }
    }
}

struct ContentView: View {
    private var isRunningInPreview: Bool {
        ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }

    @State private var audioListener = AudioListener()
    
    @State private var isGLatched: Bool = false

    private let targetG: Double = 196
    private let innerTolerance: Double = 0.02  // 2% inside zone turns green
    private let outerTolerance: Double = 0.03  // 3% outside turns back to default

    private var freq: Double { audioListener.detectedFrequency }
    private var inInner: Bool {
        let f = freq
        return f > 0 && abs(f - targetG) <= targetG * innerTolerance
    }
    private var outOuter: Bool {
        let f = freq
        return f == 0 || abs(f - targetG) > targetG * outerTolerance
    }

    private var centsOffset: Double {
        let f = freq
        guard f > 0 else { return 0 }
        return 1200.0 * log2(f / targetG)
    }

    private var clampedCentsForMeter: Double {
        max(-50, min(50, centsOffset))
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Tune to G (\(Int(targetG)) Hz)")
                .font(.title2)
                .bold()
            
            // Large frequency readout
            Text("\(audioListener.detectedFrequency, format: .number.precision(.fractionLength(1))) Hz")
                .font(.system(size: 40, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .accessibilityLabel("Detected frequency")
            
            // Cents deviation and guidance
            let cents = centsOffset
            let absCents = abs(cents)
            let isInTune = absCents < 5
            let guidance: String = {
                if freq == 0 { return "Listening…" }
                if isInTune { return "In tune" }
                return cents < 0 ? "Tune up" : "Tune down"
            }()
            
            Text(String(format: "%+.1f cents", cents))
                .font(.headline)
                .foregroundStyle(isInTune ? .green : .primary)
                .accessibilityLabel("Deviation in cents")
            
            Text(guidance)
                .font(.subheadline)
                .foregroundStyle(isInTune ? .green : .secondary)
                .accessibilityHint("Negative means you are flat; positive means sharp.")
            
            // Simple horizontal meter from -50 to +50 cents
            GeometryReader { geo in
                let width = geo.size.width
                let midX = width / 2
                let meterHeight: CGFloat = 10
                let pointerX = midX + CGFloat(clampedCentsForMeter / 50.0) * (width / 2 - 12)
                
                ZStack(alignment: .topLeading) {
                    // Background track
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.gray.opacity(0.2))
                        .frame(height: meterHeight)
                    
                    // Center OK zone (~ +/- 5 cents)
                    let okWidth = width * 0.1 // 10% band ~ visual cue
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.green.opacity(0.25))
                        .frame(width: okWidth, height: meterHeight)
                        .position(x: midX, y: meterHeight/2)
                    
                    // Pointer
                    Circle()
                        .fill(isInTune ? Color.green : Color.accentColor)
                        .frame(width: 12, height: 12)
                        .position(x: max(6, min(width - 6, pointerX)), y: meterHeight/2)
                }
            }
            .frame(height: 24)
            
            // Legacy slider display (disabled)
            Slider(value: .constant(audioListener.detectedFrequency), in: 82...330) {
                Text("Note")
            }
            .disabled(true)
            
            // G label with latch coloring
            Text("G")
                .font(.largeTitle)
                .bold()
                .foregroundStyle(isGLatched ? .green : .primary)
        }
        .padding()
        .onAppear {
            guard !isRunningInPreview else { return }
            audioListener.start()
        }
        .onChange(of: inInner) { _, now in
            if now { isGLatched = true }
        }
        .onChange(of: outOuter) { _, now in
            if now { isGLatched = false }
        }
    }
}

#Preview {
    ContentView()
}

