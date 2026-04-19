import SwiftUI

@main
struct DombyraApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var toneDetector = ToneDetector()

    var body: some Scene {
        WindowGroup {
            TabView {
                TuningView(tuningMode: .fourth)
                    .tabItem {
                        Image(systemName: "circle.fill")
                            .opacity(0)
                        Text("Fourth")
                    }

                TuningView(tuningMode: .fifth)
                    .tabItem {
                        Image(systemName: "circle.fill")
                            .opacity(0)
                        Text("Fifth")
                    }
            }
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
