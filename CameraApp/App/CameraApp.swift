import SwiftUI

@main
@MainActor
struct CameraApp: App {
    @State private var controller = CameraController()

    var body: some Scene {
        WindowGroup {
            CameraScreen()
                .environment(controller)
                .preferredColorScheme(.dark)
                .statusBarHidden()
                .task {
                    await controller.start()
                }
        }
    }
}