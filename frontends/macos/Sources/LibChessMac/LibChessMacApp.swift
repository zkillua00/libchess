import LibChessKit
import SwiftUI

@main
struct LibChessMacApp: App {
    @StateObject private var store = LibChessStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 820, minHeight: 560)
        }
        .defaultSize(width: 980, height: 680)
        .windowResizability(.contentMinSize)
    }
}

