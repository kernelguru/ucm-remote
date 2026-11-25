import Foundation
import UserNotifications

/// Lokale Erinnerungen, bevor SSH-Zertifikate ablaufen.
enum ExpiryNotifier {
    static let enabledKey = "notify.enabled"
    static let leadKey = "notify.leadHours"
    static let leadOptions: [(hours: Int, label: String)] = [(1, "1 Stunde vorher"), (24, "1 Tag vorher"), (168, "1 Woche vorher")]

    static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    static var leadSeconds: TimeInterval {
        let h = UserDefaults.standard.integer(forKey: leadKey)
        return TimeInterval((h == 0 ? 24 : h) * 3600)
    }

    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    private static func prefix(_ profileID: UUID) -> String { "expiry-\(profileID.uuidString)-" }
    private static func identifier(_ certID: Int, _ profileID: UUID) -> String { prefix(profileID) + String(certID) }

    /// Zeitpunkt der Erinnerung: `leadSeconds` vor Ablauf, bei kurzen Laufzeiten höchstens nach
    /// drei Vierteln der Laufzeit. Nil, wenn keine Erinnerung mehr sinnvoll ist.
    static func fireDate(for cert: SSHCertificate, lead: TimeInterval, now: Date = Date()) -> Date? {
        guard !cert.isRevoked, let to = cert.validToDate, to > now else { return nil }
        var effectiveLead = lead
        if let from = cert.validFromDate, to > from {
            effectiveLead = min(lead, to.timeIntervalSince(from) / 4)
        }
        let fire = to.addingTimeInterval(-effectiveLead)
        return fire > now.addingTimeInterval(60) ? fire : nil
    }

    /// Ersetzt alle Erinnerungen eines Profils durch die für `certs`.
    static func reschedule(_ certs: [SSHCertificate], profile: ServerProfile) async {
        let center = UNUserNotificationCenter.current()
        let p = prefix(profile.id)
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(p) })
        guard enabled else { return }
        let lead = leadSeconds
        let upcoming = certs
            .compactMap { c in fireDate(for: c, lead: lead).map { (c, $0) } }
            .sorted { $0.1 < $1.1 }
            .prefix(50)
        for (cert, date) in upcoming { await add(cert, at: date, profile: profile) }
    }

    static func schedule(_ cert: SSHCertificate, profile: ServerProfile) async {
        guard enabled, let date = fireDate(for: cert, lead: leadSeconds) else { return }
        await add(cert, at: date, profile: profile)
    }

    static func remove(certID: Int, profileID: UUID?) {
        guard let profileID else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier(certID, profileID)])
    }

    static func removeAll(profileID: UUID) {
        let center = UNUserNotificationCenter.current()
        let p = prefix(profileID)
        center.getPendingNotificationRequests { requests in
            center.removePendingNotificationRequests(withIdentifiers: requests.map(\.identifier).filter { $0.hasPrefix(p) })
        }
    }

    static func removeEverything() {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            center.removePendingNotificationRequests(withIdentifiers: requests.map(\.identifier).filter { $0.hasPrefix("expiry-") })
        }
    }

    private static func add(_ cert: SSHCertificate, at date: Date, profile: ServerProfile) async {
        let content = UNMutableNotificationContent()
        content.title = "SSH-Zertifikat läuft ab"
        let end = cert.validToDate?.formatted(date: .abbreviated, time: .shortened) ?? "bald"
        content.body = "\(cert.displayName) (\(profile.displayName)) ist nur noch bis \(end) gültig."
        content.sound = .default
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let request = UNNotificationRequest(identifier: identifier(cert.id, profile.id), content: content, trigger: trigger)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
