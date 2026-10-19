import Foundation

struct HRBucket: Identifiable {
    let time: Date
    let min: Double, max: Double, avg: Double
    var id: Date { time }
}

struct HourSteps: Identifiable {
    let hour: Date
    let steps: Double
    var id: Date { hour }
}

struct HourValue: Identifiable {
    let hour: Date
    let value: Double
    var id: Date { hour }
}

struct CumPoint: Identifiable {
    let time: Date
    let value: Double
    var id: Date { time }
}

/// Todo lo que las pantallas de «Hoy» necesitan, ya filtrado por fuente.
struct TodayMetrics {
    let midnight: Date
    let fetchedAt: Date
    let steps: Double
    let distanceKm: Double
    let otherSourceSteps: Double          // pasos de Apple Health que Google mezcla en la lista
    let hr: [Reading]
    let lastHR: Reading?
    let hrMin: Double?, hrMax: Double?
    let resting: Reading?
    let sleep: SleepNight?
    let naps: [SleepNight]                // siestas del mismo día que `sleep`
    var sleepTotal: Double { (sleep?.asleep ?? 0) + naps.reduce(0) { $0 + $1.asleep } }   // noche + siestas, como Google
    let calories: Double?
    let floors: Double?
    let hourlySteps: [HourSteps]
    let hourlyDistance: [HourValue]       // km por hora
    let heartBuckets: [HRBucket]          // FC en tramos de 10 min, calculado una vez

    init(_ s: Snapshot, airOnly: Bool) {
        let cal = Calendar.current
        let keep: (Reading) -> Bool = { airOnly ? $0.isAir : true }
        midnight = cal.startOfDay(for: s.fetchedAt)
        fetchedAt = s.fetchedAt
        let st = s.steps.filter(keep)
        steps = st.reduce(0) { $0 + $1.value }
        distanceKm = s.distanceKm.filter(keep).reduce(0) { $0 + $1.value }
        otherSourceSteps = s.steps.filter { !$0.isAir }.reduce(0) { $0 + $1.value }
        hr = s.heartRate.filter(keep)
        lastHR = hr.max(by: { $0.time < $1.time })
        hrMin = hr.map(\.value).min()
        hrMax = hr.map(\.value).max()
        heartBuckets = Self.makeBuckets(hr, midnight: midnight)
        resting = s.restingHR
        sleep = s.sleep
        naps = s.naps ?? []
        calories = s.caloriesKcal
        floors = s.floors
        let perHour = Dictionary(grouping: st) { cal.dateInterval(of: .hour, for: $0.time)?.start ?? $0.time }
        hourlySteps = perHour.map { HourSteps(hour: $0.key, steps: $0.value.reduce(0) { $0 + $1.value }) }.sorted { $0.hour < $1.hour }
        let dist = Dictionary(grouping: s.distanceKm.filter(keep)) { cal.dateInterval(of: .hour, for: $0.time)?.start ?? $0.time }
        hourlyDistance = dist.map { HourValue(hour: $0.key, value: $0.value.reduce(0) { $0 + $1.value }) }.sorted { $0.hour < $1.hour }
    }

    /// Muestras de FC agrupadas en tramos de 10 min (mín/máx/media), en una sola pasada.
    private static func makeBuckets(_ hr: [Reading], midnight: Date, minutes: Int = 10) -> [HRBucket] {
        let width = TimeInterval(minutes * 60)
        let slots = 26 * 60 / minutes
        var n = [Int](repeating: 0, count: slots), sum = [Double](repeating: 0, count: slots)
        var lo = [Double](repeating: .infinity, count: slots), hi = [Double](repeating: -.infinity, count: slots)
        for r in hr {
            let k = Int(r.time.timeIntervalSince(midnight) / width)
            guard k >= 0, k < slots else { continue }
            n[k] += 1; sum[k] += r.value; lo[k] = Swift.min(lo[k], r.value); hi[k] = Swift.max(hi[k], r.value)
        }
        return (0..<slots).compactMap { k in
            n[k] == 0 ? nil : HRBucket(time: midnight.addingTimeInterval(Double(k) * width + width / 2), min: lo[k], max: hi[k], avg: sum[k] / Double(n[k]))
        }
    }

    /// Pasos acumulados a lo largo del día, un punto por hora.
    var cumulative: [CumPoint] {
        var run = 0.0
        var pts = [CumPoint(time: midnight, value: 0)]
        let byHour = Dictionary(uniqueKeysWithValues: hourlySteps.map { ($0.hour, $0.steps) })
        let cal = Calendar.current
        var h = midnight
        while h <= fetchedAt {
            run += byHour[h] ?? 0
            let next = cal.date(byAdding: .hour, value: 1, to: h)!
            pts.append(CumPoint(time: min(next, fetchedAt), value: run))
            h = next
        }
        return pts
    }

    /// Eje X del gráfico del día: de medianoche a ahora (mínimo 6 h para que no quede aplastado).
    var dayDomain: ClosedRange<Date> {
        midnight...max(fetchedAt.addingTimeInterval(600), midnight.addingTimeInterval(6 * 3600))
    }
}

// MARK: - Formato

func hm(_ minutes: Double) -> String {
    let t = Int(minutes.rounded())
    return "\(t / 60) h \(t % 60) min"
}

func hmColon(_ minutes: Double) -> String {
    let t = Int(minutes.rounded())
    return String(format: "%d:%02d", t / 60, t % 60)
}

func hoursText(_ h: Double) -> String {
    h == h.rounded() ? "\(Int(h)) h" : String(format: "%.1f h", h)
}

extension Date {
    var hhmm: String { formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(esES)) }
    var dayMonth: String { formatted(.dateTime.day().month(.abbreviated).locale(esES)) }
}

func rangeText(_ from: Date, _ to: Date) -> String {
    let sameMonth = Calendar.current.isDate(from, equalTo: to, toGranularity: .month)
    let a = from.formatted(sameMonth ? .dateTime.day().locale(esES) : .dateTime.day().month(.abbreviated).locale(esES))
    let b = to.formatted(.dateTime.day().month(.abbreviated).locale(esES))
    return "\(a)–\(b)".uppercased()
}

/// Las fechas con formatted() ignoran el locale del entorno; se pasa explícito.
let esES = Locale(identifier: "es_ES")
/// Calendario con semanas de lunes a domingo: lo usan la agrupación por semanas y los ejes de las gráficas.
let esCalendar: Calendar = { var c = Calendar(identifier: .gregorian); c.locale = esES; c.firstWeekday = 2; c.minimumDaysInFirstWeek = 4; return c }()

// MARK: - Agrupación por periodo (3 meses → semanas, año → meses)

enum HistRange: String, CaseIterable, Identifiable {
    case day, week, month, quarter, year
    var id: String { rawValue }
    /// Días de histórico que cubre (Día usa los datos de hoy).
    var days: Int {
        switch self {
        case .day, .week: return 7
        case .month: return 30
        case .quarter: return 90
        case .year: return 365
        }
    }
    func label(day: String) -> String {
        switch self {
        case .day: return day
        case .week: return "Semana"
        case .month: return "Mes"
        case .quarter: return "3 meses"
        case .year: return "Año"
        }
    }
    var needsLong: Bool { self == .quarter || self == .year }
    /// Duración en texto corto, para títulos de tarjeta.
    var span: String {
        switch self {
        case .day: return "hoy"
        case .week: return "7 días"
        case .month: return "30 días"
        case .quarter: return "3 meses"
        case .year: return "1 año"
        }
    }
    /// Cada barra de las gráficas: día (hasta 30 días), semana (3 meses) o mes (año).
    var unit: Calendar.Component {
        switch self {
        case .day, .week, .month: return .day
        case .quarter: return .weekOfYear
        case .year: return .month
        }
    }
}

extension HistRange {
    /// Primer instante de la barra a la que pertenece `d`.
    func bucketStart(_ d: Date) -> Date {
        esCalendar.dateInterval(of: unit, for: d)?.start ?? esCalendar.startOfDay(for: d)
    }

    func isCurrent(_ d: Date) -> Bool { bucketStart(d) == bucketStart(Date()) }

    /// Etiqueta de una barra en las listas: “lun 5 oct”, “Semana del 5 oct”, “octubre”.
    func bucketLabel(_ d: Date) -> String {
        switch unit {
        case .weekOfYear: return "Semana del " + d.formatted(.dateTime.day().month(.abbreviated).locale(esES))
        case .month: return d.formatted(.dateTime.month(.wide).year().locale(esES)).capitalized
        default: return d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(esES))
        }
    }

    /// Quita los días iniciales sin ningún dato (antes de tener la pulsera) en los periodos largos.
    func trimmed(_ days: [DayStat]) -> [DayStat] {
        guard needsLong else { return days }
        return Array(days.drop { $0.steps == nil && $0.distanceKm == nil && $0.hrMin == nil })
    }

    /// Pasos y distancia: media diaria del periodo. Pulso: mín de mínimos, media de medias, máx de máximos.
    func grouped(_ days: [DayStat]) -> [DayStat] {
        guard unit != .day else { return days }
        func avg(_ v: [Double?]) -> Double? { let x = v.compactMap { $0 }; return x.isEmpty ? nil : x.reduce(0, +) / Double(x.count) }
        return Dictionary(grouping: days) { bucketStart($0.day) }.map { start, ds in
            DayStat(day: start, steps: avg(ds.map(\.steps)), distanceKm: avg(ds.map(\.distanceKm)), floors: avg(ds.map(\.floors)), calories: avg(ds.map(\.calories)),
                    hrMin: ds.compactMap(\.hrMin).min(), hrAvg: avg(ds.map(\.hrAvg)), hrMax: ds.compactMap(\.hrMax).max())
        }.sorted { $0.day < $1.day }
    }

    func grouped(resting: [Date: Double]) -> [Date: Double] {
        guard unit != .day else { return resting }
        let by = Dictionary(grouping: resting) { bucketStart($0.key) }
        return by.mapValues { $0.map(\.value).reduce(0, +) / Double($0.count) }
    }

    /// Una “noche” por barra con la media de minutos por fase.
    func grouped(_ nights: [SleepNight]) -> [SleepNight] {
        guard unit != .day else { return nights }
        return Dictionary(grouping: nights) { bucketStart($0.end) }.map { start, ns in
            var mins: [String: Double] = [:]
            for st in ["DEEP", "LIGHT", "REM", "AWAKE"] { mins[st] = ns.map { $0.minutes[st] ?? 0 }.reduce(0, +) / Double(ns.count) }
            return SleepNight(start: start, end: start, minutes: mins, segments: [])
        }.sorted { $0.end < $1.end }
    }
}
