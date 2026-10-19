import Foundation

/// Lo que la app le deja al widget: un JSON pequeño en el App Group. El widget no habla con Google ni con la pulsera,
/// solo enseña lo último que guardó la app (iOS decide cuándo repinta). Este fichero se compila en la app y en la extensión.
struct WidgetData: Codable, Equatable {
    var updatedAt: Date
    /// Inicio del día al que pertenecen los pasos y las calorías: pasada la medianoche ya no son de «hoy».
    var day: Date
    var steps: Int
    var stepsGoal: Int
    var sleepScore: Int?
    var sleepHours: Double?
    /// «Excelente», «Buena»… tal como la enseña la app junto a la puntuación.
    var sleepLabel: String?
    var calories: Int?
    var caloriesGoal: Int
    var heartBPM: Int?
    var heartTime: Date?
    var resting: Int?
    /// FC máxima estimada (220 − edad): da la escala al arco del pulso.
    var heartMax: Int?
    var battery: Int?
}

enum WidgetStore {
    static let groupID = "group.dev.cosmichomeless.healthspike"
    static let kind = (summary: "HealthSpikeSummary", trio: "HealthSpikeTrio",
                       lockSteps: "HealthSpikeLockSteps", lockSleep: "HealthSpikeLockSleep", lockCalories: "HealthSpikeLockCalories")

    /// `nil` si el App Group no está disponible (por ejemplo, firmado sin ese permiso): entonces no se guarda nada.
    private static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)?.appendingPathComponent("widget.json")
    }

    static func save(_ d: WidgetData) {
        guard let url, let data = try? JSONEncoder().encode(d) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func load() -> WidgetData? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetData.self, from: data)
    }

    static func clear() {
        if let url { try? FileManager.default.removeItem(at: url) }
    }
}
