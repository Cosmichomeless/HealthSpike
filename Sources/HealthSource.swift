import Foundation

/// De dónde sale un dato: el proveedor que lo entrega a la app y el origen legible dentro de él
/// (dispositivo de Fitbit, «Apple Health» dentro de Google, nombre del reloj en Apple Salud…).
/// Sustituye al antiguo `isAir: Bool`, que solo sabía distinguir «la Air» de «lo demás».
struct SourceID: Codable, Hashable {
    enum Provider: String, Codable {
        case google         // Google Health API: Fitbit y lo que Google guarda como propio
        case appleHealth    // HealthKit, leído directamente en el iPhone
        case other          // cualquier otra plataforma que Google mezcle en las listas
    }

    var provider: Provider
    var origin: String

    init(_ provider: Provider, _ origin: String) {
        self.provider = provider
        self.origin = origin
    }

    /// Origen de un dato de Google sin nombre de dispositivo (histórico antiguo, rollups diarios).
    static let google = SourceID(.google, "Google Health")

    /// Las cachés en disco anteriores solo guardaban `isAir` (+ nombre en los puntos): se traduce a un `SourceID`.
    init(legacyIsAir isAir: Bool, name: String?) {
        if isAir { self.init(.google, name ?? "Google Health") }
        else if name == nil || name == "Apple Health" { self.init(.other, "Apple Health") }
        else { self.init(.other, name!) }
    }
}

/// Qué fuentes cuentan en las pantallas (Ajustes → «Fuente de los datos»).
/// En la fase 3 pasará a elegir el proveedor («Google Health» | «Apple Salud»); hoy solo hay Google.
enum SourceScope: String {
    case googleOnly     // solo lo que Google entrega como propio (la pulsera): por defecto, evita duplicados
    case all            // todo lo que venga en las listas, incluido Apple Health mezclado por Google

    func keeps(_ s: SourceID) -> Bool { self == .all || s.provider == .google }

    static let key = "sourceScope"
    /// Clave anterior (`Bool`, «solo Air»): se lee una vez para no perder la elección del usuario.
    private static let legacyKey = "airOnly"

    static func stored() -> SourceScope {
        let d = UserDefaults.standard
        if let raw = d.string(forKey: key), let s = SourceScope(rawValue: raw) { return s }
        if let old = d.object(forKey: legacyKey) as? Bool { return old ? .googleOnly : .all }
        return .googleOnly
    }

    func save() { UserDefaults.standard.set(rawValue, forKey: Self.key) }
}

/// Lo que `HealthModel` necesita de una fuente de datos, sea Google Health o (fase 2) HealthKit.
/// Cada fuente devuelve los mismos tipos, con `SourceID` en cada dato, y el modelo no sabe de dónde vienen.
protocol HealthSource {
    var provider: SourceID.Provider { get }
    /// Pasos, distancia, FC en reposo y sueño de hoy (sin el pulso, que va aparte).
    func snapshot() async throws -> Snapshot
    /// Lo mismo para un día natural cerrado, con su pulso.
    func day(starting midnight: Date) async throws -> Snapshot
    /// Muestras de pulso entre dos instantes.
    func heartRate(from: Date, to: Date) async throws -> [Reading]
    /// Resumen diario, reposo y sueño de un rango de fechas. `complete == false` si algo falló.
    func history(from start: Date, to end: Date) async -> History
    /// Entrenos que empiezan desde `start`.
    func workouts(since start: Date) async throws -> [Workout]
}

/// Google Health API v4 (Fitbit Air y compañía): el código de siempre, ahora detrás del protocolo.
typealias GoogleHealthSource = HealthAPI

extension HealthAPI: HealthSource {
    var provider: SourceID.Provider { .google }
}
