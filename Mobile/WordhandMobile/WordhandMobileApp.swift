import SwiftUI

@main
struct WordhandMobileApp: App {
    @StateObject private var model = RecorderViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .task {
                    await model.prepare()
                }
                .onOpenURL { url in
                    guard url.scheme == MobileConfiguration.callbackScheme else { return }
                    Task { await model.startRecording() }
                }
        }
    }
}
