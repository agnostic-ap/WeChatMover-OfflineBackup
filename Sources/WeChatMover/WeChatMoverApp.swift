import SwiftUI

@main
struct WeChatMoverApp: App {
    @StateObject private var viewModel = AppViewModel()

    var body: some Scene {
        WindowGroup("WeChatMover") {
            ContentView()
                .environmentObject(viewModel)
                .frame(minWidth: 760, minHeight: 580)
                .onAppear { viewModel.refresh() }
        }
        .defaultSize(width: 920, height: 680)
        .windowResizability(.contentSize)
    }
}
