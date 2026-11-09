import SwiftUI

/// Gemeinsame Bausteine für das Liquid-Glass-Design.
/// Ab iOS 26 echtes Liquid Glass, davor Milchglas (Material) als Rückfall.

enum Theme {
    static let deep = Color(red: 0.03, green: 0.12, blue: 0.14)
    static let teal = Color(red: 0.05, green: 0.45, blue: 0.42)
    static let mint = Color(red: 0.45, green: 0.95, blue: 0.80)
}

/// Hintergrund im Stil des App-Icons, mit weichen Lichtflecken,
/// damit das Glas darüber etwas zum Brechen hat.
struct AppBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.deep, Theme.teal], startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle()
                .fill(Theme.mint.opacity(0.35))
                .frame(width: 360, height: 360)
                .blur(radius: 90)
                .offset(x: -120, y: -260)
            Circle()
                .fill(Color.indigo.opacity(0.45))
                .frame(width: 420, height: 420)
                .blur(radius: 110)
                .offset(x: 150, y: 320)
        }
        .ignoresSafeArea()
    }
}

extension View {
    /// Glas-Fläche in Form eines abgerundeten Rechtecks.
    @ViewBuilder
    func glassCard(cornerRadius: CGFloat = 24) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }

    /// Glas-Fläche in Kreisform (z. B. für Symbole).
    @ViewBuilder
    func glassCircle() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.tint(Theme.mint.opacity(0.25)), in: .circle)
        } else {
            self.background(.ultraThinMaterial, in: Circle())
        }
    }

    @ViewBuilder
    func glassProminentButton() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    func glassButton() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }

    /// Tab-Leiste beim Scrollen verkleinern (iOS 26).
    @ViewBuilder
    func minimizingTabBar() -> some View {
        if #available(iOS 26.0, *) {
            self.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
    }

    /// Formulare/Listen transparent über dem App-Hintergrund.
    func appBackground() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(AppBackground())
    }
}

/// Karte mit Titelzeile und Glas-Hintergrund.
struct GlassCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }
}
