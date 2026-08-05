import SwiftUI

@main
struct WeChatMoverApp: App {
    @StateObject private var viewModel = AppViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .frame(minWidth: 560, minHeight: 520)
                .onAppear { viewModel.refresh() }
        }
        .windowResizability(.contentSize)
    }
}
