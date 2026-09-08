import SwiftUI

@main
struct AirPopApp: App {
    var body: some Scene {
        Window("AirPop", id: "main") {
            ContentView()
                .frame(minWidth: 760, minHeight: 520)
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}
