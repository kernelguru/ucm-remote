import SwiftUI

@main
struct UCMRemoteApp: App {
    @StateObject private var settings = AppSettings()
    @StateObject private var lock = AppLock()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        FileExport.cleanTemporary()
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
                if lock.isLocked {
                    LockScreen().transition(.opacity)
                } else if scenePhase != .active && lock.enabled {
                    PrivacyCover()
                }
            }
            .environmentObject(settings)
            .environmentObject(lock)
            .preferredColorScheme(.dark)
            .task { await lock.becameActive() }
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .background:
                lock.lockIfEnabled()
            case .active:
                Task { await lock.becameActive() }
            default:
                break
            }
        }
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
