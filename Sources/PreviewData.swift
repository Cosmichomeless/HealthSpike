#if DEBUG
import SwiftUI

/// Datos de muestra deterministas para los `#Preview` (solo en Debug): sin red, sin disco y siempre iguales.
enum PreviewData {
    private static var cal: Calendar { Calendar.current }
    private static var today: Date { cal.startOfDay(for: Date()) }

    /// Ruido repetible en [0, 1) a partir de una semilla.
    private static func noise(_ seed: Int) -> Double {
        let x = sin(Double(seed) * 12.9898 + 78.233) * 43758.5453
        return x - x.rounded(.down)
    }

    private static func day(_ daysAgo: Int) -> Date { cal.date(byAdding: .day, value: -daysAgo, to: today)! }
    private static func reading(_ t: Date, _ v: Double) -> Reading { Reading(isAir: true, source: "Fitbit Air", time: t, value: v) }

    // MARK: - Sueño

    /// Noche que termina en la mañana de `daysAgo` (0 = esta mañana).
    static func night(daysAgo: Int = 0) -> SleepNight {
        let seed = daysAgo + 1
        let end = day(daysAgo).addingTimeInterval((6.6 + noise(seed) * 1.2) * 3600)
        let start = end.addingTimeInterval(-(6.8 + noise(seed + 50) * 1.6) * 3600)
        // Ciclos de ~90 min: profundo al principio, REM al final, con un pequeño despertar de vez en cuando.
        let pattern: [(String, Double)] = [("LIGHT", 14), ("DEEP", 34), ("LIGHT", 18), ("REM", 12), ("AWAKE", 4),
                                           ("LIGHT", 24), ("DEEP", 22), ("LIGHT", 20), ("REM", 20), ("LIGHT", 28),
                                           ("REM", 26), ("AWAKE", 6), ("LIGHT", 30), ("REM", 28), ("LIGHT", 20)]
        let total = pattern.map(\.1).reduce(0, +)
        let span = end.timeIntervalSince(start) / 60
        var t = start
        var segments: [SleepSegment] = []
        var minutes: [String: Double] = [:]
        for (stage, m) in pattern {
            let len = m / total * span
            let next = t.addingTimeInterval(len * 60)
            segments.append(SleepSegment(stage: stage, start: t, end: next))
            minutes[stage, default: 0] += len
            t = next
        }
        return SleepNight(start: start, end: end, minutes: minutes, segments: segments)
    }

    // MARK: - Hoy y ayer

    static func snapshot(daysAgo: Int = 0) -> Snapshot {
        let midnight = day(daysAgo)
        var s = Snapshot()
        // Pasos y distancia cada 15 min desde las 0:00 hasta las 21:00 (casi nada de noche, el grueso de día),
        // escalados para que el total del día sea el objetivo y la gráfica ocupe todo el eje.
        let target = daysAgo == 0 ? 8_966.0 : daysAgo == 1 ? 6_200.0 : 7_400.0
        let raw: [Double] = (0..<84).map { q in
            let h = Double(q) / 4
            if h < 6 { return 2 + noise(q * 3 + daysAgo) * 12 }
            if h < 7.5 { return (h - 5.5) / 2 * 150 * (0.5 + noise(q + daysAgo)) }
            let busy = noise(q + daysAgo * 100) > 0.45 ? 1.0 : 0.15
            return (30 + noise(q * 3 + daysAgo) * 420) * busy
        }
        let k = target / raw.reduce(0, +)
        var counts = raw.map { ($0 * k).rounded() }
        counts[counts.count - 1] += target - counts.reduce(0, +)
        for (q, steps) in counts.enumerated() {
            let t = midnight.addingTimeInterval(Double(q) * 900)
            s.steps.append(reading(t, steps))
            s.distanceKm.append(reading(t, steps * 0.00072))
        }
        // Pulso cada 5 min durante todo el día.
        for i in 0..<288 {
            let t = midnight.addingTimeInterval(Double(i) * 300)
            let h = Double(i) / 12
            let base = h < 7 ? 56 : 70 + 12 * sin(h / 24 * 2 * .pi * 2)
            let spike = noise(i + daysAgo * 7) > 0.93 ? 45 * noise(i) : 0
            s.heartRate.append(reading(t, (base + noise(i * 5) * 8 + spike).rounded()))
        }
        s.restingHR = reading(midnight.addingTimeInterval(6 * 3600), 58 + Double(daysAgo))
        s.sleep = night(daysAgo: daysAgo)
        s.caloriesKcal = 2_240 + Double(daysAgo) * 60
        s.floors = 9 - Double(daysAgo)
        s.fetchedAt = midnight.addingTimeInterval(21 * 3600)
        return s
    }

    // MARK: - Histórico

    static func history(days n: Int) -> History {
        var h = History()
        for i in stride(from: n - 1, through: 0, by: -1) {
            let d = day(i)
            let r = noise(i + 11)
            let steps = (4_500 + r * 9_500).rounded()
            h.days.append(DayStat(day: d, steps: steps, distanceKm: steps * 0.00072, floors: (r * 14).rounded(),
                                  calories: (2_050 + r * 700).rounded(),
                                  hrMin: 48 + (noise(i + 3) * 6).rounded(), hrAvg: 68 + (noise(i + 5) * 10).rounded(),
                                  hrMax: 120 + (noise(i + 9) * 45).rounded()))
            h.resting.append(reading(d.addingTimeInterval(6 * 3600), 56 + (noise(i + 21) * 6).rounded()))
            h.nights.append(night(daysAgo: i))
        }
        return h
    }

    // MARK: - Constantes, zonas y pulso por minutos

    static func vitals(days n: Int = 30) -> Vitals {
        func series(_ base: Double, _ spread: Double, _ salt: Int) -> [VitalPoint] {
            (0..<n).reversed().map { i in VitalPoint(day: day(i), value: base + (noise(i + salt) - 0.5) * spread) }
        }
        return Vitals(resp: series(14.5, 2, 1), spo2: series(96.5, 2.5, 2), rhr: series(58, 7, 3),
                      hrv: series(46, 22, 4), temp: series(0, 1.2, 5), fetchedAt: Date())
    }

    static func zones(days n: Int = 30) -> [ZoneDay] {
        (0..<n).reversed().map { i in
            let active = noise(i + 31) > 0.35
            return ZoneDay(day: day(i), fat: active ? (10 + noise(i) * 40).rounded() : 0,
                           cardio: active ? (noise(i + 2) * 25).rounded() : 0, peak: active ? (noise(i + 4) * 8).rounded() : 0)
        }
    }

    static func hrDays(days n: Int = 30) -> [HRDay] {
        (0..<n).reversed().map { i in
            var d = HRDay(day: day(i))
            // ~1.440 min repartidos en una campana alrededor de 65 lpm, con una cola de esfuerzo.
            for bpm in 48...170 {
                let x = Double(bpm - 65) / 14
                let rest = 900 * exp(-x * x / 2)
                let effort = bpm > 110 ? 30 * noise(i + bpm) * exp(-Double(bpm - 110) / 25) : 0
                let m = rest + effort
                if m >= 1 { d.minutes[bpm] = m.rounded() }
            }
            return d
        }
    }

    // MARK: - Cobertura

    static func coverage() -> [String: CoverageRow] {
        var out: [String: CoverageRow] = [:]
        for (i, t) in CoverageRow.catalog.enumerated() {
            var r = CoverageRow(type: t.type, label: t.label, kind: t.kind)
            r.n = 40 + i * 37
            r.other = i % 4 == 0 ? 12 : 0
            r.first = day(30 - i); r.last = Date().addingTimeInterval(-Double(i) * 3600)
            r.dayOnly = t.kind == "daily" || t.kind == "rollup"
            if i == 6 { r.n = 0; r.first = nil; r.last = nil; r.note = "Sin datos" }
            out[t.type] = r
        }
        return out
    }
}

// MARK: - Registros manuales

extension LogStore {
    @MainActor static var preview: LogStore {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let weights = (0..<60).reversed().map { i in
            WeightEntry(date: cal.date(byAdding: .day, value: -i, to: today)!.addingTimeInterval(8 * 3600),
                        kg: 74.2 - Double(60 - i) * 0.03 + (sin(Double(i)) * 0.35))
        }
        let moods = (0..<30).reversed().map { i in
            MoodEntry(date: cal.date(byAdding: .day, value: -i, to: today)!.addingTimeInterval(21 * 3600),
                      level: 2 + (i * 7 % 4), tags: i % 3 == 0 ? ["Calma", "Energía"] : i % 3 == 1 ? ["Estrés"] : [],
                      note: i % 5 == 0 ? "Día tranquilo" : "")
        }
        return LogStore(weights: weights, moods: moods)
    }
}

// MARK: - Entorno común de los previews

extension View {
    /// Modelo y registros de muestra, en español, como en la app. `empty` enseña los estados sin datos.
    @MainActor func previewEnvironment(empty: Bool = false) -> some View {
        environmentObject(empty ? HealthModel.previewEmpty : HealthModel.preview)
            .environmentObject(empty ? LogStore(weights: [], moods: []) : LogStore.preview)
            .environmentObject(empty ? CoachStore(preview: []) : CoachStore.preview)
            .environment(\.locale, esES)
            .environment(\.calendar, esCalendar)
    }

    /// Igual, dentro de una `NavigationStack` (pantallas con título, ajustes o enlaces).
    @MainActor func previewScreen(empty: Bool = false) -> some View {
        NavigationStack { self }.previewEnvironment(empty: empty)
    }

    /// Tarjeta suelta sobre el fondo agrupado de la app, con margen.
    func previewCard() -> some View {
        padding(16).frame(maxWidth: .infinity, alignment: .topLeading).background(Color(.systemGroupedBackground))
    }
}
#endif

// MARK: - Modo demo

enum Demo {
    /// Solo en DEBUG y con el argumento `-demo`; en Release siempre es falso.
    #if DEBUG
    static let on = CommandLine.arguments.contains("-demo")
    /// `-tab N` (0 Hoy … 4 Coach) elige la pestaña inicial.
    static let tab: Int = {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "-tab"), i + 1 < a.count, let n = Int(a[i + 1]), (0...4).contains(n) else { return 0 }
        return n
    }()
    #else
    static let on = false
    static let tab = 0
    #endif
}
