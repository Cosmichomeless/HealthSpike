import SwiftUI
import UserNotifications

// Mensajes del Coach automáticos (#46). El del sueño y los de siestas y entrenos salen cuando llega un dato nuevo; el del día, a una hora fija.
// iOS no deja ejecutar el modelo a una hora fija con la app cerrada, así que se combinan tres cosas: una notificación local a la hora
// del día, la generación al abrir la app (o al tocar el aviso) y un intento en el refresco en segundo plano, que iOS reparte cuando quiere.
@MainActor enum CoachAuto {
    static let enabledKey = "coachAuto", dayKey = "coachDayMinutes"
    /// Ids de los entrenos que ya tienen su mensaje (o que ya estaban cuando se activó): solo uno nuevo dispara otro.
    static let seenKey = "coachSeenWorkouts"
    /// Inicios de las noches y siestas que ya tienen su mensaje (o que ya estaban cuando se activó).
    static let seenSleepKey = "coachSeenSleeps"
    static let defaultDay = 23 * 60 + 30

    private static var defaults: UserDefaults { .standard }
    static var enabled: Bool { defaults.object(forKey: enabledKey) as? Bool ?? true }
    static var dayMinutes: Int { defaults.object(forKey: dayKey) as? Int ?? defaultDay }

    /// Ya pasó esa hora del día de hoy.
    static func passed(_ minutes: Int, now: Date = Date()) -> Bool {
        let cal = Calendar.current
        return now >= cal.startOfDay(for: now).addingTimeInterval(TimeInterval(minutes * 60))
    }

    private static let dayID = "coach.day"

    /// Deja programado el aviso diario del resumen del día (o ninguno si está desactivado o el modelo no está disponible). Pide permiso la primera vez.
    /// También retira el aviso fijo del sueño de versiones anteriores: ahora sale al llegar el sueño.
    static func scheduleNotifications() async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [dayID, "coach.sleep"])
        guard enabled, SystemLM.status.ok else { return }
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
        let content = UNMutableNotificationContent()
        content.title = "Resumen del día"; content.body = "Abre el Coach para ver cómo fue tu día."; content.sound = .default
        var parts = DateComponents(); parts.hour = dayMinutes / 60; parts.minute = dayMinutes % 60
        let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: true)
        try? await center.add(UNNotificationRequest(identifier: dayID, content: content, trigger: trigger))
    }

    private static let fallbackKey = "coachFallbackSent"

    /// Plan B: el modelo no pudo generar el mensaje con la app en segundo plano (iOS lo cortó o no lo dejó trabajar), pero el dato nuevo existe:
    /// se avisa igualmente y el resumen se genera al abrir la app. Solo una vez por dato; devuelve si lo envió.
    static func notifyWithoutSummary(id: String, title: String) async -> Bool {
        let sent = defaults.stringArray(forKey: fallbackKey) ?? []
        guard !sent.contains(id) else { return false }
        defaults.set(Array((sent + [id]).suffix(40)), forKey: fallbackKey)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = "Abre el Coach para ver el resumen."
        content.sound = .default
        do {
            try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "coach.fallback.\(id)", content: content, trigger: nil))
            return true
        } catch {
            return false
        }
    }

    /// Si el resumen sí llegó después, el aviso sin resumen sobra: se retira de la pantalla de avisos.
    static func removeWithoutSummary(id: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["coach.fallback.\(id)"])
    }

    /// Aviso inmediato cuando un mensaje se genera con la app fuera de primer plano.
    static func notify(_ m: CoachMessage, after delay: TimeInterval? = nil) async {
        let content = UNMutableNotificationContent()
        content.title = m.title
        content.body = m.summary.replacingOccurrences(of: "**", with: "")
        content.sound = .default
        let trigger = delay.map { UNTimeIntervalNotificationTrigger(timeInterval: $0, repeats: false) }
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "coach.\(m.id)", content: content, trigger: trigger))
    }
}
