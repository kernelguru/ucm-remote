import LocalAuthentication
import SwiftUI

/// Sperrt die App mit Face ID / Touch ID (Rückfall: Gerätecode), wenn sie im Hintergrund war.
@MainActor
final class AppLock: ObservableObject {
    static let enabledKey = "lock.enabled"

    @Published private(set) var isLocked: Bool
    @Published private(set) var authenticating = false
    @Published var errorText: String?
    /// Automatisch nachfragen, sobald die App aktiv wird (nur nach Start oder Hintergrund,
    /// damit „Abbrechen“ keine Endlosschleife auslöst).
    private var promptWhenActive: Bool

    var enabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    init() {
        let on = UserDefaults.standard.bool(forKey: Self.enabledKey)
        isLocked = on
        promptWhenActive = on
    }

    /// Name des Verfahrens für die Oberfläche.
    static var biometryName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        default: return "Gerätecode"
        }
    }

    func lockIfEnabled() {
        if enabled {
            isLocked = true
            promptWhenActive = true
        }
    }

    func becameActive() async {
        guard promptWhenActive else { return }
        promptWhenActive = false
        await unlock()
    }

    func unlock() async {
        guard isLocked, !authenticating else { return }
        if !enabled {
            isLocked = false
            return
        }
        authenticating = true
        defer { authenticating = false }
        if await Self.authenticate(reason: "UCM Remote entsperren") {
            isLocked = false
            errorText = nil
        }
    }

    /// Ein-/Ausschalten nur nach erfolgreicher Prüfung.
    func setEnabled(_ on: Bool) async -> Bool {
        guard await Self.authenticate(reason: on ? "Sperre aktivieren" : "Sperre deaktivieren") else { return false }
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        objectWillChange.send()
        return true
    }

    private static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = "Abbrechen"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }
}

/// Vollflächige Sperre über dem Inhalt, auch als Sichtschutz im App-Umschalter.
struct LockScreen: View {
    @EnvironmentObject private var lock: AppLock

    var body: some View {
        ZStack {
            AppBackground()
            VStack(spacing: 20) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 56))
                    .foregroundStyle(Theme.mint)
                    .padding(24)
                    .glassCircle()
                Text("UCM Remote ist gesperrt").font(.title3.bold())
                Button {
                    Task { await lock.unlock() }
                } label: {
                    Label("Mit \(AppLock.biometryName) entsperren", systemImage: "faceid")
                        .padding(.horizontal, 8)
                }
                .glassProminentButton()
                .disabled(lock.authenticating)
            }
        }
    }
}

/// Deckt den Inhalt ab, solange die App inaktiv ist (App-Umschalter).
struct PrivacyCover: View {
    var body: some View {
        ZStack {
            AppBackground()
            Image(systemName: "key.horizontal").font(.system(size: 48)).foregroundStyle(Theme.mint.opacity(0.7))
        }
    }
}
