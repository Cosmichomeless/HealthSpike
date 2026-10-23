import Combine
import Foundation

/// Un punto de datos ya reducido a lo que la app usa. `source` sale de `dataSource.platform` en Google:
/// Google mezcla en la misma lista la pulsera (FITBIT) y Apple Health (HEALTH_KIT).
struct Reading: Codable {
    let source: SourceID
    let time: Date
    let value: Double

    init(source: SourceID, time: Date, value: Double) {
        self.source = source; self.time = time; self.value = value
    }

    private enum CodingKeys: String, CodingKey { case source, time, value }
    private enum Legacy: String, CodingKey { case isAir }

    /// Las cachés anteriores guardaban `isAir` y el nombre de la fuente como texto: se siguen leyendo.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        time = try c.decode(Date.self, forKey: .time)
        value = try c.decode(Double.self, forKey: .value)
        if let id = try? c.decode(SourceID.self, forKey: .source) {
            source = id
        } else {
            let isAir = try decoder.container(keyedBy: Legacy.self).decodeIfPresent(Bool.self, forKey: .isAir) ?? true
            source = SourceID(legacyIsAir: isAir, name: try? c.decode(String.self, forKey: .source))
        }
    }
}

struct SleepSegment: Identifiable, Codable {
    var id = UUID()
    let stage: String               // DEEP, REM, LIGHT, AWAKE
    let start: Date, end: Date
}

struct SleepNight: Identifiable, Codable {
    let start: Date, end: Date
    let minutes: [String: Double]   // DEEP, REM, LIGHT, AWAKE
    let segments: [SleepSegment]
    var source = SourceID.google
    var id: Date { end }
    var asleep: Double { minutes.filter { $0.key != "AWAKE" }.values.reduce(0, +) }

    private enum CodingKeys: String, CodingKey { case start, end, minutes, segments, source }
    private enum Legacy: String, CodingKey { case isAir }

    /// Las cachés anteriores guardaban `isAir`: se siguen leyendo.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        start = try c.decode(Date.self, forKey: .start)
        end = try c.decode(Date.self, forKey: .end)
        minutes = try c.decode([String: Double].self, forKey: .minutes)
        segments = try c.decode([SleepSegment].self, forKey: .segments)
        if let id = try c.decodeIfPresent(SourceID.self, forKey: .source) {
            source = id
        } else {
            let isAir = try decoder.container(keyedBy: Legacy.self).decodeIfPresent(Bool.self, forKey: .isAir) ?? true
            source = SourceID(legacyIsAir: isAir, name: nil)
        }
    }

    init(start: Date, end: Date, minutes: [String: Double], segments: [SleepSegment], source: SourceID = .google) {
        self.start = start; self.end = end; self.minutes = minutes; self.segments = segments; self.source = source
    }
}

/// Un día del histórico (rollups diarios de Google: no traen fuente, salen de la Air).
struct DayStat: Identifiable, Codable {
    let day: Date
    var steps: Double?
    var distanceKm: Double?
    var floors: Double?
    var calories: Double?
    var hrMin: Double?, hrAvg: Double?, hrMax: Double?
    var id: Date { day }
}

struct History: Codable {
    var days: [DayStat] = []         // del más antiguo a hoy
    var resting: [Reading] = []      // FC en reposo diaria (`source` distingue Fitbit de Apple Health)
    var nights: [SleepNight] = []    // una por día (la más larga), del más antiguo al más reciente
    /// `false` si alguna petición falló: el hueco no debe darse por bueno ni guardarse en la caché.
    var complete = true
}

/// Lo que se guarda en disco: el histórico ya descargado y qué tramo de fechas cubre.
struct HistoryCache: Codable {
    var history: History
    var coveredFrom: Date            // primer día descargado
    var syncedUntil: Date            // final (exclusivo) de la última descarga: de ahí hacia atrás se vuelve a pedir un margen
    /// Versión del contenido: las cachés anteriores (sin este campo) tenían las calorías incompletas y se bajan de nuevo.
    var version: Int?
    static let currentVersion = 2
}

/// Cobertura y frescura de un dataType: cuántos puntos hay, de qué fuentes, primero/último y respuesta HTTP.
struct CoverageRow: Identifiable {
    let type: String, label: String, kind: String
    var n = 0                        // puntos de Google (la pulsera)
    var other = 0                    // puntos de otras fuentes (Apple Health…)
    var first: Date?, last: Date?
    var dayOnly = false              // daily y rollup: solo fecha, sin hora ni antigüedad
    var http = 200
    var note: String?
    var capped = false               // la lista llegó al máximo de páginas: puede haber más puntos de los contados
    var id: String { type }

    /// Mismo orden y nombres que la tabla del dashboard.
    static let catalog: [(type: String, label: String, kind: String)] = [
        ("steps", "Pasos", "interval"), ("distance", "Distancia", "interval"),
        ("total-calories", "Calorías totales (rollup)", "rollup"),
        ("active-minutes", "Minutos activos", "interval"), ("active-zone-minutes", "Minutos en zona activa", "interval"),
        ("sedentary-period", "Periodos sedentarios", "interval"), ("swim-lengths-data", "Natación (brazadas)", "interval"),
        ("heart-rate", "Frecuencia cardíaca", "sample"), ("heart-rate-variability", "HRV (muestras)", "sample"),
        ("oxygen-saturation", "SpO₂ (muestras)", "sample"), ("respiratory-rate-sleep-summary", "Resp. en sueño (resumen)", "sample"),
        ("run-vo2-max", "VO₂ máx. (carrera)", "sample"), ("vo2-max", "VO₂ máx. (muestras)", "sample"),
        ("daily-resting-heart-rate", "FC en reposo (diaria)", "daily"), ("daily-heart-rate-variability", "HRV (diaria)", "daily"),
        ("daily-oxygen-saturation", "SpO₂ (diaria)", "daily"), ("daily-respiratory-rate", "Frec. respiratoria (diaria)", "daily"),
        ("daily-sleep-temperature-derivations", "Temperatura nocturna", "daily"), ("daily-vo2-max", "VO₂ máx. (diario)", "daily"),
        ("exercise", "Ejercicios", "exercise"), ("sleep", "Sueño", "sleep"),
    ]
}

struct Snapshot: Codable {
    var steps: [Reading] = []
    var distanceKm: [Reading] = []
    var heartRate: [Reading] = []
    var restingHR: Reading?
    var sleep: SleepNight?           // la noche: la sesión más larga del último día con sueño
    var naps: [SleepNight]?          // el resto de sesiones de ese día (siestas); opcional para leer cachés antiguas
    var caloriesKcal: Double?        // calorías totales del día (rollup); opcional para leer cachés antiguas
    var floors: Double?              // pisos subidos del día (rollup; `floors` no admite `list`)
    var fetchedAt = Date()
}

struct HealthAPI {
    let auth: GoogleAuth
    private let base = "https://health.googleapis.com/v4/users/me/dataTypes"

    /// Pasos, distancia, FC en reposo y sueño de hoy: pocas llamadas pequeñas (~1 s). El pulso va aparte (`heartRate`).
    func snapshot() async throws -> Snapshot {
        let cal = Calendar.current
        let midnight = cal.startOfDay(for: Date())
        let from = Self.iso(midnight)
        var s = Snapshot()
        async let steps = points("steps", filter: "steps.interval.start_time >= \"\(from)\"", pageSize: 5000, maxPages: 6)
        async let dist = points("distance", filter: "distance.interval.start_time >= \"\(from)\"", pageSize: 5000, maxPages: 6)
        async let rhr = points("daily-resting-heart-rate", filter: "daily_resting_heart_rate.date >= \"\(Self.day(cal.date(byAdding: .day, value: -1, to: midnight)!))\"", pageSize: 10, maxPages: 1)
        async let sleep = points("sleep", filter: "sleep.interval.end_time >= \"\(Self.iso(Date().addingTimeInterval(-36 * 3600)))\"", pageSize: 25, maxPages: 1)
        async let kcal = calories(on: midnight)
        async let flr = floors(on: midnight)

        s.steps = try await steps.compactMap { Self.reading($0, "steps", key: "count", scale: 1, timePath: ["interval", "startTime"]) }
        s.distanceKm = try await dist.compactMap { Self.reading($0, "distance", key: "millimeters", scale: 1_000_000, timePath: ["interval", "startTime"]) }
        s.restingHR = try await rhr.compactMap { Self.restingReading($0) }.first(where: { $0.source.provider == .google })
        // Google junta todas las sesiones del día (noche + siestas): la noche es la más larga y el resto son siestas.
        // Quedarse con la última en terminar enseñaba solo la siesta cuando había una por la tarde.
        let sessions = Self.nights(try await sleep).filter { $0.source.provider == .google }
        if let latest = sessions.max(by: { $0.end < $1.end }) {
            let day = cal.startOfDay(for: latest.end)
            let ofDay = sessions.filter { cal.startOfDay(for: $0.end) == day }
            let main = ofDay.max(by: { $0.asleep < $1.asleep })
            s.sleep = main
            s.naps = ofDay.filter { $0.end != main?.end }.sorted { $0.start < $1.start }
        }
        s.caloriesKcal = await kcal
        s.floors = await flr
        return s
    }

    /// Pisos subidos de un día civil vía `dailyRollUp` (`floors.countSum`). nil si la API no devuelve nada.
    func floors(on midnight: Date) async -> Double? {
        let end = Calendar.current.date(byAdding: .day, value: 1, to: midnight)!
        guard let pts = try? await rollup("floors", from: midnight, to: end, chunk: 14) else { return nil }
        return pts.lazy.compactMap { Self.num(($0.1["floors"] as? [String: Any])?["countSum"]) }.first
    }

    /// Calorías totales de un día civil vía `dailyRollUp` (`totalCalories.kcalSum`). nil si la API no devuelve nada.
    func calories(on midnight: Date) async -> Double? {
        let end = Calendar.current.date(byAdding: .day, value: 1, to: midnight)!
        guard let pts = try? await rollup("total-calories", from: midnight, to: end, chunk: 14) else { return nil }
        for (_, p) in pts {
            if let v = (p["totalCalories"] as? [String: Any])?["kcalSum"] as? Double { return v }
            if let v = (p["totalCalories"] as? [String: Any])?["kcalSum"] as? Int { return Double(v) }
        }
        return nil
    }

    /// Pasos, distancia y pulso de un día cerrado (el de ayer). Sin FC en reposo ni sueño: esos salen de otras pantallas.
    func day(starting midnight: Date) async throws -> Snapshot {
        let end = Calendar.current.date(byAdding: .day, value: 1, to: midnight)!
        let range = { (f: String) in "\(f).interval.start_time >= \"\(Self.iso(midnight))\" AND \(f).interval.start_time < \"\(Self.iso(end))\"" }
        async let steps = points("steps", filter: range("steps"), pageSize: 5000, maxPages: 6)
        async let dist = points("distance", filter: range("distance"), pageSize: 5000, maxPages: 6)
        async let hr = heartRate(from: midnight, to: end)
        async let kcal = calories(on: midnight)
        async let flr = floors(on: midnight)
        var s = Snapshot()
        s.steps = try await steps.compactMap { Self.reading($0, "steps", key: "count", scale: 1, timePath: ["interval", "startTime"]) }
        s.distanceKm = try await dist.compactMap { Self.reading($0, "distance", key: "millimeters", scale: 1_000_000, timePath: ["interval", "startTime"]) }
        s.heartRate = try await hr
        s.caloriesKcal = await kcal
        s.floors = await flr
        s.fetchedAt = end.addingTimeInterval(-1)
        return s
    }

    /// Muestras de FC entre `from` y `to`. Un día son ~24.000 puntos (15 MB) en páginas de ~5.000 encadenadas,
    /// así que se parte en ventanas de 2 h que se piden a la vez (cada una cabe en una página).
    /// Con `from` reciente (refresco incremental) es una sola petición pequeña.
    func heartRate(from: Date, to: Date) async throws -> [Reading] {
        var windows: [(Date, Date)] = []
        var a = from
        while a < to { let b = min(a.addingTimeInterval(2 * 3600), to); windows.append((a, b)); a = b }
        return try await withThrowingTaskGroup(of: [Reading].self) { group in
            for (a, b) in windows {
                group.addTask {
                    let f = "heart_rate.sample_time.physical_time >= \"\(Self.iso(a))\" AND heart_rate.sample_time.physical_time < \"\(Self.iso(b))\""
                    return try await self.points("heart-rate", filter: f, pageSize: 10000, maxPages: 4)
                        .compactMap { Self.reading($0, "heartRate", key: "beatsPerMinute", scale: 1, timePath: ["sampleTime", "physicalTime"]) }
                }
            }
            var all: [Reading] = []
            for try await part in group { all += part }
            return all.sorted { $0.time < $1.time }
        }
    }

    /// Histórico entre `start` y `end` (días enteros): rollups diarios (FC máx. 14 días por llamada), FC en reposo y sueño
    /// por `list`. Cada pieza falla por separado: un hueco no tumba el resto, pero deja `complete = false`.
    func history(from start: Date, to end: Date) async -> History {
        let cal = Calendar.current
        var complete = true
        // Tramo largo (3 meses, año): el pulso es lo caro (14 días por llamada), así que solo se pide desde el
        // primer día con pasos o distancia, que se averigua antes con esas dos llamadas baratas.
        let long = end.timeIntervalSince(start) > 32 * 86400
        async let hrEarly: [(Date, [String: Any])]? = long ? nil : try? await rollup("heart-rate", from: start, to: end, chunk: 14)
        async let st = rollup("steps", from: start, to: end, chunk: 30)
        async let di = rollup("distance", from: start, to: end, chunk: 30)
        async let fl = try? await rollup("floors", from: start, to: end, chunk: 30)
        // `total-calories` admite como máximo 14 días por llamada; con 30 fallaba en silencio y solo quedaban las calorías de los últimos días.
        async let kc = try? await rollup("total-calories", from: start, to: end, chunk: 14)
        async let rhr = points("daily-resting-heart-rate", filter: "daily_resting_heart_rate.date >= \"\(Self.day(start))\"", pageSize: 100, maxPages: long ? 5 : 2)
        async let sl = points("sleep", filter: "sleep.interval.end_time >= \"\(Self.iso(start))\"", pageSize: long ? 100 : 40, maxPages: long ? 5 : 4)

        let stRes = try? await st, diRes = try? await di
        let stR = stRes ?? [], diR = diRes ?? []
        var hr = await hrEarly
        if long {
            let first = (stR + diR).map(\.0).min() ?? cal.date(byAdding: .day, value: -30, to: end)!
            hr = try? await rollup("heart-rate", from: max(first, start), to: end, chunk: 14)
        }
        if stRes == nil || diRes == nil || hr == nil { complete = false }

        var byDay: [Date: DayStat] = [:]
        var d = start
        while d < end { byDay[d] = DayStat(day: d); d = cal.date(byAdding: .day, value: 1, to: d)! }
        for (day, p) in hr ?? [] {
            guard let b = p["heartRate"] as? [String: Any] else { continue }
            byDay[day]?.hrMin = Self.num(b["beatsPerMinuteMin"]); byDay[day]?.hrMax = Self.num(b["beatsPerMinuteMax"])
            byDay[day]?.hrAvg = Self.num(b["beatsPerMinuteAvg"])
        }
        for (day, p) in stR { byDay[day]?.steps = Self.num((p["steps"] as? [String: Any])?["countSum"]) }
        for (day, p) in await kc ?? [] { byDay[day]?.calories = Self.num((p["totalCalories"] as? [String: Any])?["kcalSum"]) }
        for (day, p) in await fl ?? [] { byDay[day]?.floors = Self.num((p["floors"] as? [String: Any])?["countSum"]) }
        for (day, p) in diR {
            byDay[day]?.distanceKm = Self.num((p["distance"] as? [String: Any])?["millimetersSum"]).map { $0 / 1_000_000 }
        }

        var h = History()
        h.days = byDay.values.sorted { $0.day < $1.day }
        let rhrRes = try? await rhr, slRes = try? await sl
        if rhrRes == nil || slRes == nil { complete = false }
        h.complete = complete
        h.resting = (rhrRes ?? []).compactMap(Self.restingReading).sorted { $0.time < $1.time }
        // Una noche por día de despertar: gana la más larga (las siestas quedan fuera).
        let nights = Self.nights(slRes ?? [])
        let perDay = Dictionary(grouping: nights.filter { $0.source.provider == .google }) { cal.startOfDay(for: $0.end) }
        h.nights = perDay.values.compactMap { $0.max(by: { $0.asleep < $1.asleep }) }.sorted { $0.end < $1.end }
        let other = Dictionary(grouping: nights.filter { $0.source.provider != .google }) { cal.startOfDay(for: $0.end) }
        h.nights += other.filter { perDay[$0.key] == nil }.values.compactMap { $0.max(by: { $0.asleep < $1.asleep }) }
        h.nights.sort { $0.end < $1.end }
        return h
    }

    /// `dataPoints:dailyRollUp` (POST): un punto por día civil; devuelve (inicio del día, punto).
    func rollup(_ type: String, from: Date, to: Date, chunk: Int, limit: Int = 6) async throws -> [(Date, [String: Any])] {
        let cal = Calendar.current
        var ranges: [(Date, Date)] = []
        var s = from
        while s < to { let e = min(cal.date(byAdding: .day, value: chunk, to: s)!, to); ranges.append((s, e)); s = e }
        // Los trozos (p. ej. 14 días de FC, ~3 s cada uno) se piden a la vez, como mucho `limit` simultáneos.
        return try await withThrowingTaskGroup(of: [(Date, [String: Any])].self) { group in
            var pending = ranges.makeIterator()
            for _ in 0..<limit { if let (s, e) = pending.next() { group.addTask { try await self.rollupChunk(type, from: s, to: e) } } }
            var out: [(Date, [String: Any])] = []
            while let part = try await group.next() {
                out += part
                if let (s, e) = pending.next() { group.addTask { try await self.rollupChunk(type, from: s, to: e) } }
            }
            return out
        }
    }

    private func rollupChunk(_ type: String, from s: Date, to e: Date) async throws -> [(Date, [String: Any])] {
        let cal = Calendar.current
        var req = URLRequest(url: URL(string: "\(base)/\(type)/dataPoints:dailyRollUp")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(try await auth.validAccessToken())", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["range": ["start": Self.civil(s), "end": Self.civil(e)], "windowSizeDays": 1] as [String: Any])
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AuthError.http(status, "\(type) rollup: " + (String(data: data, encoding: .utf8) ?? ""))
        }
        var out: [(Date, [String: Any])] = []
        for p in json["rollupDataPoints"] as? [[String: Any]] ?? [] {
            guard let c = (p["civilStartTime"] as? [String: Any])?["date"] as? [String: Int],
                  let day = cal.date(from: DateComponents(year: c["year"], month: c["month"], day: c["day"])) else { continue }
            out.append((day, p))
        }
        return out
    }

    // MARK: - Cobertura de todos los dataTypes

    /// Una fila por dataType de la Air (misma lista y filtros que `spikes/oauth_read/dashboard.py`), últimos `days` días.
    /// `heart-rate` se omite (14 días son ~300.000 muestras, ~200 MB): la fila la monta el modelo con el pulso de hoy.
    /// Cada tipo falla por separado y deja su código HTTP.
    func coverage(days: Int = 14) async -> [String: CoverageRow] {
        await withTaskGroup(of: CoverageRow.self) { group in
            for t in CoverageRow.catalog where t.type != "heart-rate" {
                group.addTask { await self.coverageRow(t.type, t.label, t.kind, days: days) }
            }
            var out: [String: CoverageRow] = [:]
            for await r in group { out[r.type] = r }
            return out
        }
    }

    private func coverageRow(_ type: String, _ label: String, _ kind: String, days: Int) async -> CoverageRow {
        var row = CoverageRow(type: type, label: label, kind: kind)
        let cal = Calendar.current
        let now = Date(), start = now.addingTimeInterval(-Double(days) * 86400)
        let f = type.replacingOccurrences(of: "-", with: "_")
        let filter: String
        switch kind {
        case "interval": filter = "\(f).interval.start_time >= \"\(Self.iso(start))\""
        case "exercise": filter = "\(f).interval.civil_start_time >= \"\(Self.day(start))\""
        case "sample": filter = "\(f).sample_time.physical_time >= \"\(Self.iso(start))\""
        case "daily": filter = "\(f).date >= \"\(Self.day(start))\""
        case "sleep": filter = "sleep.interval.end_time >= \"\(Self.iso(start))\""
        default: filter = ""
        }
        do {
            if kind == "rollup" {
                let end = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!
                let r = try await rollup(type, from: cal.date(byAdding: .day, value: -min(days, 14), to: end)!, to: end, chunk: 14)
                row.n = r.count; row.dayOnly = true
                row.first = r.map(\.0).min(); row.last = r.map(\.0).max()
            } else {
                let small = kind == "exercise" || kind == "sleep"
                let pts = try await points(type, filter: filter, pageSize: small ? 25 : 10000, maxPages: small ? 4 : 8)
                let mine = pts.filter { Self.sourceInfo($0).provider == .google }
                row.n = mine.count; row.other = pts.count - mine.count
                row.capped = pts.count >= (small ? 25 * 4 : 10000 * 8)
                let times = mine.compactMap { Self.pointTime($0, type) }
                row.dayOnly = times.first?.1 ?? false
                row.first = times.map(\.0).min(); row.last = times.map(\.0).max()
            }
        } catch AuthError.http(let code, let body) {
            row.http = code; row.note = String(body.prefix(120))
        } catch {
            row.http = 0; row.note = error.localizedDescription
        }
        return row
    }

    /// Instante (o día, `true`) de un punto según el tipo de registro.
    private static func pointTime(_ p: [String: Any], _ type: String) -> (Date, Bool)? {
        let parts = type.split(separator: "-").map(String.init)
        let key = parts[0] + parts.dropFirst().map { $0.capitalized }.joined()
        let body = p[key] as? [String: Any]
        if let s = (body?["interval"] as? [String: Any])?["startTime"] as? String, let d = parse(s) { return (d, false) }
        if let s = (body?["sampleTime"] as? [String: Any])?["physicalTime"] as? String, let d = parse(s) { return (d, false) }
        let civil = (body?["date"] as? [String: Int]) ?? (((p["civilStartTime"] as? [String: Any])?["date"]) as? [String: Int])
        if let c = civil, let d = Calendar.current.date(from: DateComponents(year: c["year"], month: c["month"], day: c["day"])) { return (d, true) }
        return nil
    }

    // MARK: - Red

    func points(_ type: String, filter: String, pageSize: Int, maxPages: Int) async throws -> [[String: Any]] {
        var all: [[String: Any]] = []
        var token: String?
        for _ in 0..<maxPages {
            var c = URLComponents(string: "\(base)/\(type)/dataPoints")!
            var items = [URLQueryItem(name: "filter", value: filter), URLQueryItem(name: "pageSize", value: String(pageSize))]
            if let token { items.append(URLQueryItem(name: "pageToken", value: token)) }
            c.queryItems = items
            var req = URLRequest(url: c.url!)
            req.setValue("Bearer \(try await auth.validAccessToken())", forHTTPHeaderField: "Authorization")
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AuthError.http(status, "\(type): " + (String(data: data, encoding: .utf8) ?? ""))
            }
            all += json["dataPoints"] as? [[String: Any]] ?? []
            token = json["nextPageToken"] as? String
            if token == nil || token?.isEmpty == true { break }
        }
        return all
    }

    // MARK: - Decodificación

    static func num(_ raw: Any?) -> Double? {
        if let n = raw as? NSNumber { return n.doubleValue }
        return (raw as? String).flatMap(Double.init)
    }

    static func civil(_ d: Date) -> [String: Any] {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return ["date": ["year": c.year!, "month": c.month!, "day": c.day!], "time": [String: Int]()]
    }

    /// Quién entregó el punto. Fitbit y los puntos sin `dataSource` (rollups) son de Google; HEALTH_KIT es Apple Health
    /// mezclado por Google (no es lo mismo que leer HealthKit directamente) y cualquier otra plataforma va aparte.
    static func sourceInfo(_ p: [String: Any]) -> SourceID {
        let ds = p["dataSource"] as? [String: Any]
        switch ds?["platform"] as? String {
        case "FITBIT": return SourceID(.google, ((ds?["device"] as? [String: Any])?["displayName"] as? String) ?? "Fitbit")
        case "HEALTH_KIT": return SourceID(.other, "Apple Health")
        default: return ds == nil ? .google : SourceID(.other, (ds?["platform"] as? String) ?? "(sin fuente)")
        }
    }

    private static func reading(_ p: [String: Any], _ field: String, key: String, scale: Double, timePath: [String]) -> Reading? {
        guard let body = p[field] as? [String: Any], let raw = body[key] else { return nil }
        let v = (raw as? String).flatMap(Double.init) ?? (raw as? Double) ?? 0
        var node: Any? = body
        for k in timePath { node = (node as? [String: Any])?[k] }
        guard let t = (node as? String).flatMap(parse) else { return nil }
        return Reading(source: sourceInfo(p), time: t, value: v / scale)
    }

    private static func restingReading(_ p: [String: Any]) -> Reading? {
        guard let body = p["dailyRestingHeartRate"] as? [String: Any],
              let v = (body["beatsPerMinute"] as? String).flatMap(Double.init),
              let d = body["date"] as? [String: Int],
              let date = Calendar.current.date(from: DateComponents(year: d["year"], month: d["month"], day: d["day"])) else { return nil }
        return Reading(source: sourceInfo(p), time: date, value: v)
    }

    /// Todas las noches del listado, con su fuente según `dataSource.platform`.
    private static func nights(_ pts: [[String: Any]]) -> [SleepNight] {
        pts.compactMap { p in
            guard let s = p["sleep"] as? [String: Any], let iv = s["interval"] as? [String: Any],
                  let a = (iv["startTime"] as? String).flatMap(parse), let b = (iv["endTime"] as? String).flatMap(parse),
                  let stages = s["stages"] as? [[String: Any]], !stages.isEmpty else { return nil }
            var mins: [String: Double] = [:]
            var segs: [SleepSegment] = []
            for st in stages {
                guard let t = st["type"] as? String, let x = (st["startTime"] as? String).flatMap(parse),
                      let y = (st["endTime"] as? String).flatMap(parse) else { continue }
                mins[t, default: 0] += y.timeIntervalSince(x) / 60
                segs.append(SleepSegment(stage: t, start: x, end: y))
            }
            return SleepNight(start: a, end: b, minutes: mins, segments: segs, source: sourceInfo(p))
        }
    }

    // MARK: - Fechas

    private static let isoPlain: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f }()
    private static let isoFrac: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
    static func parse(_ s: String) -> Date? { isoPlain.date(from: s) ?? isoFrac.date(from: s) }
    static func iso(_ d: Date) -> String { isoPlain.string(from: d) }
    static func day(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
}

// MARK: - Dispositivos emparejados (batería)

/// Un dispositivo de `users/me/pairedDevices`. La batería se actualiza cuando la pulsera sincroniza con la app de Fitbit.
struct PairedDevice: Codable, Equatable {
    var name: String
    var isTracker: Bool
    var version: String?
    var batteryLevel: Int?
    var batteryStatus: String?       // High / Medium / Low / Empty
    var lastSync: Date?
}

extension HealthAPI {
    /// Necesita el scope `googlehealth.settings.readonly`: sin él Google responde 403.
    func pairedDevices() async throws -> [PairedDevice] {
        var c = URLComponents(string: "https://health.googleapis.com/v4/users/me/pairedDevices")!
        c.queryItems = [URLQueryItem(name: "pageSize", value: "20")]
        var req = URLRequest(url: c.url!)
        req.setValue("Bearer \(try await auth.validAccessToken())", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AuthError.http(status, "pairedDevices: " + (String(data: data, encoding: .utf8) ?? ""))
        }
        return (json["pairedDevices"] as? [[String: Any]] ?? []).map { d in
            // Los enteros de 64 bits pueden llegar como texto.
            let level = (d["batteryLevel"] as? Int) ?? (d["batteryLevel"] as? String).flatMap(Int.init)
            return PairedDevice(
                name: d["name"] as? String ?? "",
                isTracker: (d["deviceType"] as? String) == "TRACKER",
                version: d["deviceVersion"] as? String,
                batteryLevel: level,
                batteryStatus: d["batteryStatus"] as? String,
                lastSync: (d["lastSyncTime"] as? String).flatMap(Self.parse))
        }
    }
}

@MainActor
final class HealthModel: ObservableObject {
    let auth = GoogleAuth()
    /// De dónde salen los datos centrales (hoy, día, pulso, histórico, entrenos). Lo propio de Google
    /// (constantes, zonas, dispositivos, cobertura) se sigue pidiendo a `HealthAPI` directamente.
    private var source: any HealthSource { GoogleHealthSource(auth: auth) }
    @Published var snapshot: Snapshot? { didSet { rebuildToday() } }
    /// Se calcula una vez por cambio de datos o de fuente (agrupar ~24.000 muestras en cada `body` frenaba la interfaz).
    @Published private(set) var today: TodayMetrics?
    private var lastHistory: Date?
    /// Últimos 30 días del histórico (Semana y Mes).
    @Published var history: History?
    /// Hasta un año de histórico para “3 meses” y “Año”: se pide al abrir esos periodos, no en cada refresco.
    @Published private(set) var longHistory: History?
    @Published private(set) var longLoading = false
    private var longRequested = false
    /// Todo lo descargado, también en disco: los días cerrados no cambian, así que solo se vuelve a pedir lo reciente.
    private var store = History()
    private var coveredFrom: Date?
    private var syncedUntil: Date?
    private static let cacheURL = URL.applicationSupportDirectory.appending(path: "history-cache.json")
    private static let snapshotURL = URL.applicationSupportDirectory.appending(path: "today-cache.json")
    /// Días recientes que se vuelven a pedir siempre (la pulsera puede sincronizar con retraso).
    private static let tailDays = 3
    /// Ayer, ya cerrado: se descarga al pedirlo y se guarda en disco (no vuelve a cambiar).
    @Published private(set) var vitals: Vitals?
    @Published private(set) var zones: [ZoneDay]?
    /// Pulso por minutos de los últimos 30 días (hasta un año si se ha pedido), ya resumido por día: de aquí sale la carga cardiovascular.
    @Published private(set) var hrDays: [HRDay]?
    /// Pulseras y básculas emparejadas; `nil` mientras no se hayan leído (o si falta el permiso).
    @Published private(set) var devices: [PairedDevice]?
    /// La pulsera: el primer dispositivo de tipo TRACKER.
    var tracker: PairedDevice? { devices?.first(where: \.isTracker) }
    @Published private(set) var hrLoading = false
    private var hrWanted = 30            // días que alguna pantalla ha pedido; solo crece
    private static let hrDaysURL = URL.applicationSupportDirectory.appending(path: "hrdays-cache.json")
    private static let zonesURL = URL.applicationSupportDirectory.appending(path: "zones-cache.json")
    private static let vitalsURL = URL.applicationSupportDirectory.appending(path: "vitals-cache.json")
    /// Entrenos (`exercise`) de hasta un año; `nil` mientras no haya cache ni descarga. `workoutsFailed`: la última descarga falló.
    @Published private(set) var workouts: [Workout]?
    @Published private(set) var workoutsFailed = false
    private var workoutsSyncedAt: Date?
    private var workoutsLoading = false
    private static let workoutsURL = URL.applicationSupportDirectory.appending(path: "workouts-cache.json")
    @Published private(set) var yesterday: TodayMetrics?
    @Published private(set) var yesterdayLoading = false
    private var yesterdaySnapshot: Snapshot? { didSet { rebuildToday() } }
    private static let yesterdayURL = URL.applicationSupportDirectory.appending(path: "yesterday-cache.json")
    @Published var loading = false
    /// Modelo de muestra para `#Preview`: las cargas no tocan red ni disco.
    private(set) var isPreview = false
    @Published var error: String?
    @Published var lastRefresh: Date?
    @Published var sourceScope: SourceScope { didSet { sourceScope.save(); rebuildToday() } }
    private var bag = Set<AnyCancellable>()
    @Published private(set) var coverageByType: [String: CoverageRow]?
    @Published private(set) var coverageLoading = false
    @Published private(set) var coverageAt: Date?

    /// Tabla de cobertura en el orden del catálogo. `heart-rate` sale del pulso de hoy que ya está en memoria.
    var coverage: [CoverageRow]? {
        guard let by = coverageByType else { return nil }
        return CoverageRow.catalog.compactMap { t in
            if t.type != "heart-rate" { return by[t.type] }
            var r = CoverageRow(type: t.type, label: t.label, kind: t.kind)
            let hr = snapshot?.heartRate ?? []
            r.n = hr.filter { $0.source.provider == .google }.count; r.other = hr.count - r.n
            r.first = hr.map(\.time).min(); r.last = hr.map(\.time).max()
            return r
        }
    }

    func loadCoverage() async {
        guard !isPreview else { return }
        guard !coverageLoading else { return }
        coverageLoading = true
        defer { coverageLoading = false }
        // Tarea suelta: si SwiftUI cancela la de la vista, las peticiones no se abortan a medias.
        coverageByType = await Task { await HealthAPI(auth: auth).coverage() }.value
        coverageAt = Date()
    }

    init(preview: Bool = false) {
        isPreview = preview
        sourceScope = preview ? .googleOnly : SourceScope.stored()
        if !preview {
            loadCache()
            loadSnapshotCache()
            loadYesterdayCache()
            loadVitalsCache()
        }
        // `signedIn` vive en GoogleAuth: reenviamos sus cambios para que las vistas que observan el modelo se refresquen.
        auth.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)
    }

    private var nightHRCache: [Date: [Reading]] = [:]
    private var workoutHRCache: [String: [Reading]] = [:]
    /// Pulso de un entreno (una petición pequeña, guardada en memoria mientras la app siga abierta). Vacío si falla.
    func workoutHeart(_ w: Workout) async -> [Reading] {
        if let c = workoutHRCache[w.id] { return c }
        if isPreview { return (snapshot?.heartRate ?? []).filter { $0.time >= w.start && $0.time <= w.end } }
        let result = await Task { try? await source.heartRate(from: w.start, to: w.end) }.value
        guard let r = result, !r.isEmpty else { return [] }
        workoutHRCache[w.id] = r.filter { sourceScope.keeps($0.source) }
        return workoutHRCache[w.id]!
    }
    /// Pulso entre acostarse y despertar. El de hoy empieza a medianoche, así que la noche se pide aparte, al abrir el desplegable.
    func nightHeart(_ n: SleepNight) async -> [Reading] {
        if let c = nightHRCache[n.end] { return c }
        if isPreview { return (snapshot?.heartRate ?? []).filter { $0.time >= n.start && $0.time <= n.end } }
        guard let r = try? await source.heartRate(from: n.start, to: n.end), !r.isEmpty else { return [] }
        nightHRCache[n.end] = r
        return r
    }

    func sleepScore(_ n: SleepNight, goalHours: Double) -> Score { Scoring.sleep(n, goalHours: goalHours, history: nights) }
    func sleepHeadline(_ n: SleepNight, goalHours: Double) -> String { Scoring.sleepHeadline(n, goalHours: goalHours, history: nights) }

    private func rebuildToday() {
        today = snapshot.map { TodayMetrics($0, scope: sourceScope) }
        yesterday = yesterdaySnapshot.map { TodayMetrics($0, scope: sourceScope) }
    }

    func loadYesterday() async {
        guard !isPreview else { return }
        let cal = Calendar.current
        let midnight = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: Date()))!
        if let y = yesterdaySnapshot, cal.startOfDay(for: y.fetchedAt) == midnight { return }
        guard !yesterdayLoading else { return }
        yesterdayLoading = true
        defer { yesterdayLoading = false }
        // Tarea suelta: cambiar de Hoy a Ayer cancela la de la vista, pero la descarga no se aborta.
        let result = await Task { try? await source.day(starting: midnight) }.value
        guard let s = result else { error = "No se pudo descargar ayer. Vuelve a probar."; return }
        yesterdaySnapshot = s
        let url = Self.yesterdayURL
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(s) { try? data.write(to: url, options: .atomic) }
        }
    }

    func loadVitals() async {
        guard !isPreview else { return }
        let previous = vitals
        let result = await Task { await HealthAPI(auth: auth).vitals(previous: previous) }.value
        guard let v = result else { return }
        vitals = v
        let url = Self.vitalsURL
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(v) { try? data.write(to: url, options: .atomic) }
        }
    }

    /// Sin el permiso de ajustes (sesión anterior al scope nuevo) Google da 403: no es un error de la app, solo no hay batería.
    func loadDevices() async {
        guard !isPreview else { return }
        let result = await Task { try? await HealthAPI(auth: auth).pairedDevices() }.value
        if let r = result { devices = r }
    }

    func loadZones() async {
        guard !isPreview else { return }
        let result = await Task { try? await HealthAPI(auth: auth).activeZone(days: 30) }.value
        guard let z = result else { return }
        zones = z
        let url = Self.zonesURL
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(z) { try? data.write(to: url, options: .atomic) }
        }
    }

    /// Entrenos del último año: la primera vez baja todo; después solo desde unos días antes de la última descarga (cambia poco y sincroniza con retraso).
    /// Si falla, se conservan los que había y `workoutsFailed` avisa a la pantalla.
    func loadWorkouts() async {
        guard !isPreview, !workoutsLoading else { return }
        workoutsLoading = true
        defer { workoutsLoading = false }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let yearAgo = cal.date(byAdding: .day, value: -364, to: today)!
        let from = workoutsSyncedAt.map { max(yearAgo, cal.date(byAdding: .day, value: -Self.tailDays - 1, to: cal.startOfDay(for: $0))!) } ?? yearAgo
        // Tarea suelta: si SwiftUI cancela la de la vista, la descarga no se aborta a medias.
        let result = await Task { try? await source.workouts(since: from) }.value
        guard let got = result else { workoutsFailed = true; return }
        workoutsFailed = false
        let all = ((workouts ?? []).filter { $0.start < from && $0.start >= yearAgo } + got).sorted { $0.start < $1.start }
        workouts = all
        workoutsSyncedAt = Date()
        let url = Self.workoutsURL, cache = WorkoutCache(syncedAt: Date(), workouts: all)
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(cache) { try? data.write(to: url, options: .atomic) }
        }
    }

    /// Deja `hrDays` con los últimos `days` días (hasta 365) pidiendo solo los que faltan y los recientes (la Air puede sincronizar con retraso).
    /// Baja de 30 en 30 días, del más reciente al más antiguo, y guarda cada tanda: si se cierra la app a medias no se pierde lo bajado.
    func loadHRDays(days: Int = 30) async {
        guard !isPreview else { return }
        hrWanted = max(hrWanted, min(days, 365))
        guard !hrLoading else { return }     // otra llamada ya está bajando; repetirá al acabar si se ha pedido más
        hrLoading = true
        defer { hrLoading = false }
        let cal = Calendar.current
        var done: Int
        repeat {
            done = hrWanted
            let today = cal.startOfDay(for: Date())
            let start = cal.date(byAdding: .day, value: -(done - 1), to: today)!
            let keepFrom = cal.date(byAdding: .day, value: -364, to: today)!
            let recent = cal.date(byAdding: .day, value: -Self.tailDays, to: today)!
            var have = Dictionary((hrDays ?? []).map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
            let need = (0..<done).map { cal.date(byAdding: .day, value: -$0, to: today)! }.filter { $0 >= start && (have[$0] == nil || $0 >= recent) }
            for from in stride(from: 0, to: need.count, by: 30) {
                let part = Array(need[from..<min(from + 30, need.count)])
                // Tarea suelta: si SwiftUI cancela la de la vista, las peticiones no se abortan a medias.
                let got = await Task { await HealthAPI(auth: auth).heartMinutes(days: part) }.value
                guard !got.isEmpty else { break }
                for d in got { have[d.day] = d }
                let all = have.values.filter { $0.day >= keepFrom }.sorted { $0.day < $1.day }
                hrDays = all
                let url = Self.hrDaysURL
                Task.detached(priority: .utility) {
                    try? FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
                    if let data = try? JSONEncoder().encode(all) { try? data.write(to: url, options: .atomic) }
                }
            }
        } while hrWanted > done
    }

    /// Mediana de la FC en reposo reciente: la referencia para la reserva cardíaca.
    var restingBaseline: Double {
        let v = resting(for: .month).values.sorted()
        return v.isEmpty ? 60 : v[v.count / 2]
    }

    /// Carga cardiovascular por día (los que haya en `hrDays`), recalculada con la edad que haya en Ajustes.
    func loadDays(age: Int) -> [LoadDay]? {
        guard let days = hrDays else { return nil }
        let rest = restingBaseline, mx = CardioLoad.maxHR(age: age)
        return days.map { LoadDay(day: $0.day, value: CardioLoad.load($0, rest: rest, maxHR: mx)) }
    }

    private func loadVitalsCache() {
        if let data = try? Data(contentsOf: Self.hrDaysURL), let h = try? JSONDecoder().decode([HRDay].self, from: data) { hrDays = h }
        if let data = try? Data(contentsOf: Self.zonesURL), let z = try? JSONDecoder().decode([ZoneDay].self, from: data) { zones = z }
        if let data = try? Data(contentsOf: Self.vitalsURL), let v = try? JSONDecoder().decode(Vitals.self, from: data) { vitals = v }
        if let data = try? Data(contentsOf: Self.workoutsURL), let c = try? JSONDecoder().decode(WorkoutCache.self, from: data) { workouts = c.workouts; workoutsSyncedAt = c.syncedAt }
    }

    private func loadYesterdayCache() {
        let cal = Calendar.current
        guard let data = try? Data(contentsOf: Self.yesterdayURL), let s = try? JSONDecoder().decode(Snapshot.self, from: data),
              cal.isDateInYesterday(s.fetchedAt) else { return }
        yesterdaySnapshot = s; rebuildToday()
    }

    /// Histórico que corresponde al periodo elegido (30 días o el largo de un año).
    func history(for r: HistRange) -> History? { r.needsLong ? longHistory : history }

    /// FC en reposo por día, respetando el filtro de fuente.
    func resting(for r: HistRange) -> [Date: Double] {
        var m: [Date: Double] = [:]
        for x in history(for: r)?.resting ?? [] where sourceScope.keeps(x.source) { m[Calendar.current.startOfDay(for: x.time)] = x.value }
        if let x = snapshot?.restingHR { m[Calendar.current.startOfDay(for: x.time)] = x.value }
        return m
    }

    func nights(for r: HistRange) -> [SleepNight] { (history(for: r)?.nights ?? []).filter { sourceScope.keeps($0.source) } }

    var resting: [Date: Double] { resting(for: .month) }
    var nights: [SleepNight] { nights(for: .month) }

    func loadLong() async {
        guard !isPreview else { return }
        guard !longLoading else { return }
        longRequested = true
        longLoading = true
        defer { longLoading = false }
        // Tarea suelta: cambiar de periodo cancela la de la vista, pero la descarga no se aborta.
        _ = await Task { await ensureHistory(days: 365) }.value
    }

    // MARK: - Caché del histórico

    private func loadCache() {
        guard let data = try? Data(contentsOf: Self.cacheURL), let c = try? JSONDecoder().decode(HistoryCache.self, from: data) else { return }
        // Caché con las calorías incompletas (o anterior a ellas): se descarta para que el histórico se vuelva a bajar.
        guard c.version == HistoryCache.currentVersion else { return }
        store = c.history; coveredFrom = c.coveredFrom; syncedUntil = c.syncedUntil
        publishStore()
    }

    private func saveCache() {
        guard let from = coveredFrom, let until = syncedUntil else { return }
        try? FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(HistoryCache(history: store, coveredFrom: from, syncedUntil: until, version: HistoryCache.currentVersion)) {
            try? data.write(to: Self.cacheURL, options: .atomic)
        }
    }

    /// Lo último que se leyó de hoy, para pintar la pantalla al abrir la app sin esperar a Google.
    /// Solo vale si es de hoy: pasos y pulso de ayer no pueden salir como si fueran de hoy.
    private func loadSnapshotCache() {
        guard let data = try? Data(contentsOf: Self.snapshotURL), let s = try? JSONDecoder().decode(Snapshot.self, from: data),
              Calendar.current.isDateInToday(s.fetchedAt) else { return }
        snapshot = s; rebuildToday()      // en `init` el `didSet` no se ejecuta
        lastRefresh = s.fetchedAt
    }

    /// Se codifica fuera del hilo principal: el pulso de un día son decenas de miles de muestras.
    private func saveSnapshotCache(_ s: Snapshot) {
        let url = Self.snapshotURL
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(s) { try? data.write(to: url, options: .atomic) }
        }
    }

    /// Borra el histórico guardado en el móvil; se vuelve a descargar entero en el siguiente refresco.
    func clearCache() {
        store = History(); coveredFrom = nil; syncedUntil = nil
        try? FileManager.default.removeItem(at: Self.cacheURL)
        history = nil; longHistory = nil
    }

    private func clearSnapshotCache() { try? FileManager.default.removeItem(at: Self.snapshotURL) }

    /// `history` = últimos 30 días; `longHistory` = todo lo que haya, si ya cubre lo que piden 3 meses y Año.
    private func publishStore() {
        let cal = Calendar.current
        let from30 = cal.date(byAdding: .day, value: -30, to: cal.startOfDay(for: Date()))!
        history = History(days: store.days.filter { $0.day >= from30 }, resting: store.resting.filter { $0.time >= from30 },
                          nights: store.nights.filter { $0.end >= from30 })
        if longRequested || (coveredFrom.map { $0 <= cal.date(byAdding: .day, value: -360, to: Date())! } ?? false) { longHistory = store }
    }

    /// Sustituye en la caché el tramo [from, to) por lo recién descargado.
    private func merge(_ h: History, from: Date, to: Date) {
        store.days = (store.days.filter { $0.day < from || $0.day >= to } + h.days.filter { $0.day >= from && $0.day < to }).sorted { $0.day < $1.day }
        store.resting = (store.resting.filter { $0.time < from || $0.time >= to } + h.resting.filter { $0.time >= from && $0.time < to }).sorted { $0.time < $1.time }
        store.nights = (store.nights.filter { $0.end < from || $0.end >= to } + h.nights.filter { $0.end >= from && $0.end < to }).sorted { $0.end < $1.end }
    }

    /// Deja la caché cubriendo los últimos `days` días pidiendo solo lo que falta: los días recientes (siempre)
    /// y, si la caché no llega tan atrás, el tramo antiguo que le falta. Devuelve `false` si algo falló.
    @discardableResult
    func ensureHistory(days: Int) async -> Bool {
        let cal = Calendar.current
        let end = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date()))!
        let need = cal.date(byAdding: .day, value: -days, to: end)!
        let api = source
        // Tramo reciente: desde unos días antes de la última descarga (o todo, si no hay caché).
        let tailFrom = syncedUntil.map { max(need, cal.date(byAdding: .day, value: -Self.tailDays, to: $0)!) } ?? need
        // Tramo antiguo que la caché aún no tiene.
        let headTo: Date? = coveredFrom.flatMap { $0 > need ? $0 : nil }
        async let tail = api.history(from: min(tailFrom, end), to: end)
        async let head: History? = headTo != nil ? await api.history(from: need, to: headTo!) : nil
        let t = await tail, h = await head

        let hadCache = coveredFrom != nil
        var ok = true
        if t.complete || !hadCache { merge(t, from: tailFrom, to: end) }
        if !t.complete { ok = false }
        if t.complete { syncedUntil = end }
        if let h, let headTo {
            if h.complete { merge(h, from: need, to: headTo); coveredFrom = need } else { ok = false }
        } else if !hadCache, t.complete { coveredFrom = need }
        if ok { saveCache() }
        publishStore()
        return ok
    }

    func signIn() async {
        error = nil
        do { try await auth.signIn(); await refresh() } catch { self.error = error.localizedDescription }
    }

    func signOut() { auth.signOut(); WidgetStore.clear(); clearSnapshotCache(); try? FileManager.default.removeItem(at: Self.yesterdayURL); try? FileManager.default.removeItem(at: Self.vitalsURL); try? FileManager.default.removeItem(at: Self.zonesURL); try? FileManager.default.removeItem(at: Self.hrDaysURL); try? FileManager.default.removeItem(at: Self.workoutsURL); workouts = nil; workoutsSyncedAt = nil; workoutsFailed = false; vitals = nil; zones = nil; hrDays = nil; hrWanted = 30; devices = nil; UserDefaults.standard.removeObject(forKey: Scoring.lastRecoveryKey); UserDefaults.standard.removeObject(forKey: Scoring.lastResilienceKey); yesterdaySnapshot = nil; snapshot = nil; history = nil; lastRefresh = nil; lastHistory = nil; coverageByType = nil; coverageAt = nil; longRequested = false; clearCache() }

    /// `force`: gesto de arrastrar o botón → también relee el histórico. Si no (al volver a la app), el histórico
    /// solo se pide si tiene más de 30 min. El pulso de hoy es incremental: solo se piden las muestras nuevas.
    /// `widgetOnly`: la ejecución en segundo plano (poco tiempo y batería) solo trae pasos, sueño y pulso de hoy y avisa a los widgets.
    func refresh(force: Bool = true, widgetOnly: Bool = false) async {
        guard !isPreview else { return }
        guard !loading else { return }
        loading = true; error = nil
        defer { loading = false }
        let api = source
        do {
            let cal = Calendar.current
            let cachedHR = snapshot.map { cal.isDateInToday($0.fetchedAt) ? $0.heartRate : [] } ?? []
            let hrFrom = cachedHR.last.map { $0.time.addingTimeInterval(-120) } ?? cal.startOfDay(for: Date())
            let needHistory = !widgetOnly && (force || history == nil || Date().timeIntervalSince(lastHistory ?? .distantPast) > 1800)

            async let light = api.snapshot()
            async let hr = api.heartRate(from: hrFrom, to: Date().addingTimeInterval(3600))
            async let histOK = needHistory ? await ensureHistory(days: longRequested ? 365 : 30) : false
            // Recuperación y resiliencia salen de estos datos: se actualizan con todo lo demás.
            async let vit: Void = widgetOnly ? () : loadVitals()
            async let zon: Void = widgetOnly ? () : loadZones()
            async let hrd: Void = widgetOnly ? () : loadHRDays()
            async let dev: Void = widgetOnly ? () : loadDevices()
            async let wko: Void = widgetOnly ? () : loadWorkouts()

            var s = try await light
            s.heartRate = cachedHR
            if !cachedHR.isEmpty, auth.signedIn { snapshot = s }          // pasos y sueño ya, mientras llega el pulso
            s.heartRate = cachedHR.filter { $0.time < hrFrom } + (try await hr)
            s.fetchedAt = Date()
            guard auth.signedIn else { return }            // se cerró sesión durante la lectura: no reponer datos
            snapshot = s
            saveSnapshotCache(s)
            if await histOK { lastHistory = Date() }
            await vit; await zon; await hrd; await dev; await wko
            lastRefresh = Date()
            publishWidget()
        } catch AuthError.http(let code, let body) where (code == 400 || code == 401) && body.contains("invalid_grant") {
            // El refresh_token caduca a los 7 días mientras el proyecto de Google esté en modo Testing.
            signOut()
            error = "Tu sesión de Google ha caducado (en modo pruebas dura 7 días). Vuelve a iniciar sesión."
        } catch is CancellationError {
        } catch let e as URLError where e.code == .cancelled {
        } catch { self.error = error.localizedDescription }
    }
}

// MARK: - Constantes vitales (dailies de la noche)

struct VitalPoint: Codable { let day: Date; let value: Double }

/// Los últimos días de los resúmenes nocturnos que Google calcula al despertar.
struct Vitals: Codable {
    var resp: [VitalPoint] = []      // respiraciones por minuto
    var spo2: [VitalPoint] = []      // % medio
    var rhr: [VitalPoint] = []       // lpm
    var hrv: [VitalPoint] = []       // ms
    var temp: [VitalPoint] = []      // °C respecto a tu base
    var fetchedAt = Date()
}

extension HealthAPI {
    /// Cada tipo falla por separado; `nil` solo si fallan los cinco.
    /// Una serie que falla conserva la de `previous`, para que un fallo suelto no borre de la caché datos buenos.
    func vitals(days: Int = 90, previous: Vitals? = nil) async -> Vitals? {
        let from = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let filter = { @Sendable (t: String) in "\(t.replacingOccurrences(of: "-", with: "_")).date >= \"\(Self.day(from))\"" }
        @Sendable func series(_ type: String, _ value: @escaping @Sendable ([String: Any]) -> Double?) async -> [VitalPoint]? {
            guard let pts = try? await points(type, filter: filter(type), pageSize: 100, maxPages: 2) else { return nil }
            let key = type.split(separator: "-").enumerated().map { $0.offset == 0 ? String($0.element) : $0.element.capitalized }.joined()
            return pts.compactMap { p -> VitalPoint? in
                guard Self.sourceInfo(p).provider == .google, let b = p[key] as? [String: Any], let d = b["date"] as? [String: Int],
                      let day = Calendar.current.date(from: DateComponents(year: d["year"], month: d["month"], day: d["day"])),
                      let v = value(b), v.isFinite else { return nil }  // un NaN rompe la codificación JSON y la caché no se guardaba
                return VitalPoint(day: day, value: v)
            }.sorted { $0.day < $1.day }
        }
        async let resp = series("daily-respiratory-rate") { Self.num($0["breathsPerMinute"]) }
        async let spo2 = series("daily-oxygen-saturation") { Self.num($0["averagePercentage"]) }
        async let rhr = series("daily-resting-heart-rate") { Self.num($0["beatsPerMinute"]) }
        async let hrv = series("daily-heart-rate-variability") { Self.num($0["averageHeartRateVariabilityMilliseconds"]) }
        async let temp = series("daily-sleep-temperature-derivations") { b in
            guard let n = Self.num(b["nightlyTemperatureCelsius"]), let base = Self.num(b["baselineTemperatureCelsius"]) else { return nil }
            return n - base
        }
        let r = (await resp, await spo2, await rhr, await hrv, await temp)
        if r.0 == nil && r.1 == nil && r.2 == nil && r.3 == nil && r.4 == nil { return nil }
        var v = Vitals(resp: r.0 ?? previous?.resp ?? [], spo2: r.1 ?? previous?.spo2 ?? [], rhr: r.2 ?? previous?.rhr ?? [],
                       hrv: r.3 ?? previous?.hrv ?? [], temp: r.4 ?? previous?.temp ?? [])
        // Si alguna serie viene de la caché, la fecha de descarga sigue siendo la anterior: no se debe aparentar frescura.
        if let p = previous, r.0 == nil || r.1 == nil || r.2 == nil || r.3 == nil || r.4 == nil { v.fetchedAt = p.fetchedAt }
        return v
    }
}

// MARK: - Minutos en zona activa

struct ZoneDay: Codable, Identifiable {
    let day: Date
    var fat = 0.0, cardio = 0.0, peak = 0.0
    var id: Date { day }
    var total: Double { fat + cardio + peak }
}

extension HealthAPI {
    /// Minutos en zona activa por día y zona (`active-zone-minutes`), de los últimos `days` días.
    func activeZone(days: Int = 30) async throws -> [ZoneDay] {
        let cal = Calendar.current
        let start = cal.date(byAdding: .day, value: -(days - 1), to: cal.startOfDay(for: Date()))!
        let pts = try await points("active-zone-minutes", filter: "active_zone_minutes.interval.start_time >= \"\(Self.iso(start))\"", pageSize: 1000, maxPages: 15)
        var byDay: [Date: ZoneDay] = [:]
        for p in pts where Self.sourceInfo(p).provider == .google {
            guard let b = p["activeZoneMinutes"] as? [String: Any], let iv = b["interval"] as? [String: Any],
                  let c = (iv["civilStartTime"] as? [String: Any])?["date"] as? [String: Int],
                  let day = cal.date(from: DateComponents(year: c["year"], month: c["month"], day: c["day"])),
                  let m = Self.num(b["activeZoneMinutes"]) else { continue }
            let zone = (b["heartRateZone"] as? String ?? "").uppercased()
            var z = byDay[day] ?? ZoneDay(day: day)
            if zone.contains("PEAK") { z.peak += m } else if zone.contains("CARDIO") { z.cardio += m } else { z.fat += m }
            byDay[day] = z
        }
        return (0..<days).map { i in
            let d = cal.date(byAdding: .day, value: i, to: start)!
            return byDay[d] ?? ZoneDay(day: d)
        }
    }
}

/// Minutos que un día pasó a cada pulso (media por minuto, redondeada a lpm). Con esto la carga cardiovascular se puede
/// recalcular con cualquier FC máxima o de reposo sin volver a pedir nada, y un mes entero cabe en pocos KB.
struct HRDay: Codable, Identifiable {
    let day: Date
    var minutes: [Int: Double] = [:]
    var id: Date { day }
}

extension HealthAPI {
    /// `dataPoints:rollUp` (POST) con ventanas de 60 s: media de FC por minuto de un día civil (hasta ahora si es hoy).
    func heartMinutes(day: Date) async throws -> HRDay {
        let end = min(Calendar.current.date(byAdding: .day, value: 1, to: day)!, Date())
        var out = HRDay(day: day)
        guard end > day else { return out }
        var req = URLRequest(url: URL(string: "\(base)/heart-rate/dataPoints:rollUp")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(try await auth.validAccessToken())", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["range": ["startTime": Self.iso(day), "endTime": Self.iso(end)], "windowSize": "60s"] as [String: Any])
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AuthError.http(status, "heart-rate rollUp: " + (String(data: data, encoding: .utf8) ?? ""))
        }
        let parse = ISO8601DateFormatter()
        for p in json["rollupDataPoints"] as? [[String: Any]] ?? [] {
            guard let hr = (p["heartRate"] as? [String: Any]).flatMap({ Self.num($0["beatsPerMinuteAvg"]) }),
                  let a = (p["startTime"] as? String).flatMap(parse.date(from:)), let b = (p["endTime"] as? String).flatMap(parse.date(from:)) else { continue }
            let from = max(a, day), to = min(b, end)
            if to > from { out.minutes[Int(hr.rounded()), default: 0] += to.timeIntervalSince(from) / 60 }
        }
        return out
    }

    /// Varios días a la vez (como mucho `limit` simultáneos). Los que fallen no salen en el resultado.
    func heartMinutes(days: [Date], limit: Int = 6) async -> [HRDay] {
        await withTaskGroup(of: HRDay?.self) { group in
            var it = days.makeIterator()
            for _ in 0..<limit { if let d = it.next() { group.addTask { try? await self.heartMinutes(day: d) } } }
            var out: [HRDay] = []
            while let r = await group.next() {
                if let r { out.append(r) }
                if let d = it.next() { group.addTask { try? await self.heartMinutes(day: d) } }
            }
            return out
        }
    }
}

#if DEBUG
extension HealthModel {
    /// Modelo con datos de muestra para los `#Preview`: no lee ni escribe disco y las cargas no hacen nada.
    static var preview: HealthModel {
        let m = HealthModel(preview: true)
        m.snapshot = PreviewData.snapshot()
        m.yesterdaySnapshot = PreviewData.snapshot(daysAgo: 1)
        m.history = PreviewData.history(days: 30)
        m.longHistory = PreviewData.history(days: 365)
        m.vitals = PreviewData.vitals()
        m.zones = PreviewData.zones()
        m.hrDays = PreviewData.hrDays(days: 365)
        m.devices = [PairedDevice(name: "Fitbit Air", isTracker: true, version: nil, batteryLevel: 69, batteryStatus: "Normal",
                                  lastSync: Date().addingTimeInterval(-600))]
        m.coverageByType = PreviewData.coverage()
        m.lastRefresh = Date()
        return m
    }

    /// Sin ningún dato: para ver los estados vacíos.
    static var previewEmpty: HealthModel { HealthModel(preview: true) }
}
#endif
