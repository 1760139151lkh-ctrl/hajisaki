import SwiftUI

@main
struct HajiSakiApp: App {
    @StateObject private var model = TheaterModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            TheaterRootView(model: model)
                .task {
                    await model.setApplicationActive(scenePhase == .active)
                    await model.start()
                }
                .onChange(of: scenePhase) { _, phase in
                    Task {
                        await model.setApplicationActive(phase == .active)
                        if phase != .active { await model.flushDraft() }
                    }
                }
        }
    }
}
