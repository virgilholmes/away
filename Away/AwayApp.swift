import SwiftUI

@main
struct AwayApp: App {
    @StateObject private var client = OscarClient()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(client)
        }
    }
}
