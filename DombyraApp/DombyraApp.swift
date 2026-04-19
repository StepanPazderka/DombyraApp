import SwiftUI

@main
struct DombyraApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var toneDetector = ToneDetector()
    @State private var tuningMode: TuningView.TuningMode = .fourth

    var body: some Scene {
        WindowGroup {
            TuningView(tuningMode: $tuningMode)
            .environmentObject(toneDetector)
            .task {
                await startToneDetectorIfNeeded()
            }
            .onChange(of: scenePhase) { _, newPhase in
                handleScenePhaseChange(newPhase)
            }
        }
    }

    private func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .active:
            Task {
                await startToneDetectorIfNeeded()
            }
        case .inactive, .background:
            toneDetector.stop()
        @unknown default:
            break
        }
    }

    private func startToneDetectorIfNeeded() async {
        do {
            try await toneDetector.start()
        } catch {
            print(error)
        }
    }
}
