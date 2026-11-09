import SwiftUI

@main
struct UCMRemoteApp: App {
    @StateObject private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .preferredColorScheme(.dark)
        }
    }
}

/// Server-Adresse, API-Schlüssel (Schlüsselbund) und gepinntes TLS-Zertifikat.
final class AppSettings: ObservableObject {
    @AppStorage("server") var server: String = ""
    @AppStorage("pinnedFingerprint") var pinnedFingerprint: String = ""
    @Published var apiKey: String = Keychain.loadAPIKey()

    var isConfigured: Bool { !server.trimmed.isEmpty && !apiKey.isEmpty }

    func saveAPIKey(_ key: String) {
        apiKey = key.trimmed
        Keychain.saveAPIKey(apiKey)
    }

    func client() throws -> UCMClient {
        try UCMClient(server: server, apiKey: apiKey, pinnedFingerprint: pinnedFingerprint)
    }
}

struct ContentView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { SignView() }
                .tabItem { Label("Ausstellen", systemImage: "signature") }
                .tag(0)
            NavigationStack { CertListView() }
                .tabItem { Label("Zertifikate", systemImage: "key.horizontal") }
                .tag(1)
            NavigationStack { CAListView() }
                .tabItem { Label("CAs", systemImage: "building.columns") }
                .tag(2)
            NavigationStack { SettingsView() }
                .tabItem { Label("Einstellungen", systemImage: "gearshape") }
                .tag(3)
        }
        .tint(Theme.mint)
        .minimizingTabBar()
        .onAppear { if !settings.isConfigured { tab = 3 } }
    }
}
