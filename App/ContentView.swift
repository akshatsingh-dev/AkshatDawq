import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            HomeView()
                .tabItem {
                    Label("Home", systemImage: "house")
                }

            AskView()
                .tabItem {
                    Label("Ask", systemImage: "bubble.left.and.bubble.right")
                }

            DataView()
                .tabItem {
                    Label("Data", systemImage: "externaldrive")
                }

            ProfileView()
                .tabItem {
                    Label("You", systemImage: "person.circle")
                }
        }
        .tint(.primary)
    }
}
