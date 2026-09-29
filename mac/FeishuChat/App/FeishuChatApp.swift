import SwiftUI
import FeishuChatCore

@main
struct FeishuChatApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    var body: some View {
        Text(Greeting().message(for: "FeishuChat"))
            .padding(40)
    }
}
