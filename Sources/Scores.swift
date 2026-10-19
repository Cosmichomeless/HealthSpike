import SwiftUI

// MARK: - Puntuaciones calculadas en local
//
// Google no publica las fórmulas ni su API devuelve las puntuaciones. Lo que sí enseña la app de Google Health es QUÉ factores
// mira cada una, y eso es lo que se reproduce aquí con los datos de la Air:
//  · Sueño (como Apple): duración 50 + hora de acostarte 30 (frente a tu media de 14 noches) + interrupciones 20. Los cuatro indicadores de
//    Google (tiempo hasta sueño profundo, sueño profundo, inquietud, interrupciones) se enseñan aparte, sin puntuar.
//  · Recuperación: VFC, sueño reciente y FC en reposo.
//  · Resiliencia: calma física, equilibrio de actividades y patrones de sueño.
// Los umbrales y los pesos son estimaciones: las cifras no tienen por qué coincidir con las de Google.

struct ScorePart: Identifiable {
    let id = UUID()
    let name: String
    let points: Double      // lo obtenido
    let maxPoints: Double   // lo máximo posible
    let detail: String
    var level = ""          // «Bueno», «Medio»…: la etiqueta que se enseña junto al factor
    var tone = 1            // 0 mal · 1 regular · 2 bien (color de la etiqueta)
}

/// Un indicador frente a su intervalo típico, como la pantalla «Calidad del sueño» de Google.
struct RangeMetric: Identifiable {
    enum Status { case low, inside, high }
    let id = UUID()
    let name: String
    let valueText: String
    let value: Double
    let lo: Double, hi: Double      // intervalo típico
    let axisMax: Double             // fondo de la barra
    let tolLow: Double, tolHigh: Double   // cuánto hay que salirse del intervalo para perder toda la puntuación

    var status: Status { value < lo ? .low : value > hi ? .high : .inside }
    /// 1 dentro del intervalo; baja de forma lineal hasta 0 al salirse `tol` por un lado.
    var fit: Double {
        switch status {
        case .inside: return 1
        case .low: return max(0, 1 - (lo - value) / max(tolLow, 0.1))
        case .high: return max(0, 1 - (value - hi) / max(tolHigh, 0.1))
        }
    }
}

struct Score {
    let value: Int
    let parts: [ScorePart]
    let label: String
    var metrics: [RangeMetric] = []
    var progress: Double { Double(value) / 100 }
}

private func clamp(_ x: Double, _ lo: Double = 0, _ hi: Double = 100) -> Double { min(max(x, lo), hi) }
private func pct(_ x: Double) -> String { "\(Int((x * 100).rounded())) %" }
/// 0…100 → nivel con tres nombres (de peor a mejor) y su tono.
private func tier(_ s: Double, good: Double, ok: Double, _ names: (String, String, String)) -> (String, Int) {
    s >= good ? (names.2, 2) : s >= ok ? (names.1, 1) : (names.0, 0)
}

enum Scoring {
    static let lastRecoveryKey = "lastRecoveryScore"
    static let lastResilienceKey = "lastResilienceScore"

    // MARK: Sueño (0–100): duración 50 + hora de acostarte 30 + interrupciones 20

    static func sleepLabel(_ v: Int) -> String { v >= 90 ? "Excelente" : v >= 80 ? "Buena" : v >= 60 ? "Regular" : "Baja" }

    /// Los cuatro indicadores de calidad de Google, con intervalos de un adulto típico:
    ///  · tiempo hasta el primer sueño profundo: hasta 60 min
    ///  · sueño profundo: 1–3 h
    ///  · inquietud: despiertos en tramos de menos de 5 min (movimiento), hasta 30 min
    ///  · interrupciones: despertares de 5 min o más, hasta 30 min en total
    static func sleepQuality(_ n: SleepNight) -> [RangeMetric] {
        let segs = n.segments.sorted { $0.start < $1.start }
        let toDeep = segs.first { $0.stage == "DEEP" }.map { $0.start.timeIntervalSince(n.start) / 60 }
        let wakes = segs.dropFirst().filter { $0.stage == "AWAKE" }.map { $0.end.timeIntervalSince($0.start) / 60 }
        let short = wakes.filter { $0 < 5 }.reduce(0, +)
        let long = wakes.filter { $0 >= 5 }
        let longMin = long.reduce(0, +)
        let deep = n.minutes["DEEP"] ?? 0
        return [
            RangeMetric(name: "Tiempo hasta sueño profundo", valueText: toDeep.map { hm($0) } ?? "sin sueño profundo", value: toDeep ?? 180,
                        lo: 0, hi: 60, axisMax: 180, tolLow: 1, tolHigh: 60),
            RangeMetric(name: "Sueño profundo", valueText: hm(deep), value: deep, lo: 60, hi: 180, axisMax: 240, tolLow: 60, tolHigh: 120),
            RangeMetric(name: "Inquietud", valueText: hm(short), value: short, lo: 0, hi: 30, axisMax: 90, tolLow: 1, tolHigh: 45),
            RangeMetric(name: "Interrupciones", valueText: "\(hm(longMin)), \(long.count) \(long.count == 1 ? "momento" : "momentos")",
                        value: longMin, lo: 0, hi: 30, axisMax: 90, tolLow: 1, tolHigh: 45),
        ]
    }

    /// Como el desglose de Apple: duración (50), hora de acostarte (30) e interrupciones (20). `history` son noches anteriores:
    /// con menos de 3 no se puede medir la regularidad, se omite ese factor y el total se reescala sobre los otros dos.
    static func sleep(_ n: SleepNight, goalHours: Double, history: [SleepNight] = []) -> Score {
        // Duración (50): tiempo dormido (sin contar despierto) frente a tu objetivo.
        let goal = max(goalHours * 60, 1)
        let ratio = n.asleep / goal
        // Curva algo convexa: quedarse corto resta más que proporcionalmente (6 h 35 de 8 h son 39, no 41).
        let duration = 50 * pow(min(ratio, 1), 1.25)
        let dLevel = tier(ratio * 100, good: 90, ok: 75, ("Corta", "Aceptable", "Buena"))
        var parts = [ScorePart(name: "Duración del sueño", points: duration, maxPoints: 50,
                               detail: "\(hm(n.asleep)) de \(hm(goal)) (\(pct(ratio)))", level: dLevel.0, tone: dLevel.1)]
        var earned = duration, maxPts = 50.0

        // Hora de acostarte (30): plena a ±30 min de tu media de las últimas 14 noches y a 0 a 2 h y media.
        let prior = priorNights(n, history)
        if prior.count >= 3 {
            let mean = prior.map(bedMinutes).reduce(0, +) / Double(prior.count)
            let dev = bedMinutes(n) - mean
            let pts = 30 * clamp(1 - (abs(dev) - 30) / 120, 0, 1)
            let m = Int(mean.rounded()) % 1440
            let level = tier(pts / 30 * 100, good: 85, ok: 50, ("Irregular", "Variable", "Regular"))
            parts.append(ScorePart(name: "Hora de acostarte", points: pts, maxPoints: 30,
                                   detail: "\(n.start.hhmm) frente a tu media de \(String(format: "%d:%02d", m / 60, m % 60)) en \(prior.count) noches",
                                   level: level.0, tone: level.1))
            earned += pts; maxPts += 30
        }

        // Interrupciones (20): todo el tiempo despierto tras dormirte, también los despertares cortos; 0 min = 20 y 80 min = 0.
        let long = n.segments.sorted { $0.start < $1.start }.dropFirst()
            .filter { $0.stage == "AWAKE" }.map { $0.end.timeIntervalSince($0.start) / 60 }
        let longMin = long.reduce(0, +)
        let ipts = 20 * clamp(1 - longMin / 80, 0, 1)
        let iLevel = tier(ipts / 20 * 100, good: 85, ok: 50, ("Muchas", "Algunas", "Pocas"))
        parts.append(ScorePart(name: "Interrupciones", points: ipts, maxPoints: 20,
                               detail: long.isEmpty ? "Sin despertares" : "\(hm(longMin)) en \(long.count) \(long.count == 1 ? "momento" : "momentos")",
                               level: iLevel.0, tone: iLevel.1))
        earned += ipts; maxPts += 20

        let total = Int((earned / maxPts * 100).rounded())
        return Score(value: total, parts: parts, label: sleepLabel(total), metrics: sleepQuality(n))
    }

    /// Las 14 noches anteriores a `n`, una por día.
    static func priorNights(_ n: SleepNight, _ history: [SleepNight]) -> [SleepNight] {
        Array(lastPerDay(history.filter { $0.end <= n.start }).suffix(14))
    }

    /// Frase corta que resume la noche con reglas: la duración frente al objetivo y, si destaca algo más, un segundo matiz
    /// (lo malo primero; si no hay nada malo, lo bueno). Sin historial no se comparan sueño profundo ni hora de acostarte.
    static func sleepHeadline(_ n: SleepNight, goalHours: Double, history: [SleepNight]) -> String {
        let goal = max(goalHours * 60, 1)
        let main: (text: String, good: Bool)
        if n.asleep >= goal { main = ("Objetivo de sueño cumplido", true) }
        else if n.asleep >= goal * 0.9 { main = ("Casi tu objetivo de sueño", true) }
        else { main = ("Noche corta: \(hm(goal - n.asleep)) menos que tu objetivo", false) }

        var notes: [(text: String, good: Bool)] = []
        let segs = n.segments.sorted { $0.start < $1.start }.dropFirst()
        let awake = segs.filter { $0.stage == "AWAKE" }.map { $0.end.timeIntervalSince($0.start) / 60 }.reduce(0, +)
        if awake <= 10 { notes.append(("sin apenas despertares", true)) }
        else if awake >= 30 { notes.append(("\(hm(awake)) despierto durante la noche", false)) }

        let prior = priorNights(n, history)
        if prior.count >= 3 {
            let dev = bedMinutes(n) - prior.map(bedMinutes).reduce(0, +) / Double(prior.count)
            if abs(dev) <= 30 { notes.append(("te acostaste a tu hora", true)) }
            else if dev > 0 { notes.append(("te acostaste \(hm(dev)) más tarde de lo habitual", false)) }
            else { notes.append(("te acostaste \(hm(-dev)) antes de lo habitual", true)) }

            let deepAvg = prior.map { $0.minutes["DEEP"] ?? 0 }.reduce(0, +) / Double(prior.count)
            let deep = n.minutes["DEEP"] ?? 0
            if deepAvg > 0 {
                if deep >= deepAvg * 1.15 { notes.append(("con más sueño profundo de lo habitual", true)) }
                else if deep <= deepAvg * 0.75 { notes.append(("con poco sueño profundo", false)) }
            }
        }

        guard let extra = notes.first(where: { !$0.good }) ?? notes.first else { return main.text }
        return "\(main.text)\(main.good == extra.good ? " y " : ", pero ")\(extra.text)"
    }

    // MARK: Recuperación (0–100)
    //
    // Google mira tres cosas: VFC, sueño reciente y FC en reposo. Cada una se compara con TU línea base:
    //  · VFC (ln RMSSD) y FC en reposo: la última noche frente a tus 60 días anteriores, medida en desviaciones típicas (z),
    //    con la «diferencia mínima relevante» de 0,5 SD (Plews/Buchheit): dentro de ese margen cuenta como normal.
    //  · Sueño reciente: última noche y balance de 14 días.
    //  Ajuste con 19 días de Google (24 sep–13 oct): la nota de Google sigue la VFC de esa misma noche (no una media de tres)
    //  y arranca con 5 días de base. Con eso y la curva `recoveryPoints` el error medio es de 3 puntos (correlación 0,97).
    //  Pesos: VFC 50 · sueño 30 · FC en reposo 20 (la VFC es la señal que más pesa en Whoop y Oura).

    /// Google llama «moderado» a un 65: las bandas son terciles, no las de Fitbit de antes.
    static func recoveryLabel(_ v: Int) -> String { v >= 66 ? "Alta" : v >= 35 ? "Moderada" : "Baja" }

    static func recoveryMessage(_ v: Int) -> String {
        v >= 66 ? "Tu cuerpo está bien recuperado y listo para entrenar fuerte."
            : v >= 35 ? "Tu cuerpo se ha recuperado y está listo para entrenar."
            : "Tu cuerpo aún se está recuperando: mejor un día tranquilo."
    }

    /// z → 0…100: meseta de 85 dentro de ±0,5 SD y caída de 15 puntos por SD por debajo; un poco más por encima.
    private static func zPoints(_ z: Double) -> Double { clamp(85 + 30 * min(z + 0.5, 0) + 10 * min(max(z, 0), 1)) }

    /// Recuperación: z → 0…100. Normal (±0,5 SD) = 50 y 50 puntos por SD hacia cada lado; las bandas de Google dejan lo normal en «Moderada».
    private static func recoveryPoints(_ z: Double) -> Double { clamp(50 + 50 * min(z + 0.5, 0) + 50 * min(max(z - 0.5, 0), 1.5)) }

    private struct Base { let z: Double; let recent: Double; let mean: Double }

    /// z del valor reciente frente a la línea base. `higherIsBetter` invierte el signo. `asOf` calcula como si fuera ese momento
    /// (para el histórico de puntuaciones): ignora lo posterior.
    private static func base(_ pts: [VitalPoint], log: Bool = false, minSD: Double, recentN: Int = 3, minPrev: Int = 14,
                             higherIsBetter: Bool = true, asOf: Date = Date()) -> Base? {
        let s = pts.filter { $0.day <= asOf }.sorted { $0.day < $1.day }
        guard let last = s.last, Calendar.current.dateComponents([.day], from: last.day, to: asOf).day ?? 9 <= 2 else { return nil }
        let f: (Double) -> Double = { log ? Foundation.log(max($0, 0.1)) : $0 }
        let recentPts = s.suffix(recentN)
        let w = (0..<recentPts.count).map { Double($0 + 1) }            // la más reciente pesa más
        let recent = zip(recentPts, w).reduce(0) { $0 + f($1.0.value) * $1.1 } / w.reduce(0, +)
        let prev = s.dropLast(recentN).suffix(60).map { f($0.value) }
        guard prev.count >= minPrev else { return nil }
        let m = prev.reduce(0, +) / Double(prev.count)
        let sd = max((prev.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(prev.count)).squareRoot(), minSD)
        var z = (recent - m) / sd
        if !higherIsBetter { z = -z }
        let back: (Double) -> Double = { log ? exp($0) : $0 }
        return Base(z: z, recent: back(recent), mean: back(m))
    }

    static func recovery(vitals: Vitals?, nights: [SleepNight], goalHours: Double, asOf: Date = Date()) -> Score? {
        var raw: [(name: String, weight: Double, score: Double, detail: String)] = []

        if let v = vitals {
            if let b = base(v.hrv, log: true, minSD: 0.05, recentN: 1, minPrev: 5, asOf: asOf) {
                raw.append(("Variabilidad de la FC (VFC)", 50, recoveryPoints(b.z), "\(Int(b.recent.rounded())) ms · tu base \(Int(b.mean.rounded())) ms"))
            }
            if let b = base(v.rhr, minSD: 1, recentN: 1, minPrev: 5, higherIsBetter: false, asOf: asOf) {
                raw.append(("FC en reposo (FCR)", 20, recoveryPoints(b.z), "\(Int(b.recent.rounded())) lpm · tu base \(Int(b.mean.rounded())) lpm"))
            }
        }
        let days = lastPerDay(nights.filter { $0.end <= asOf })
        if let last = days.last, days.count >= 3, Calendar.current.dateComponents([.day], from: last.end, to: asOf).day ?? 9 <= 2 {
            let lastScore = Double(sleep(last, goalHours: goalHours).value)
            let two = days.filter { $0.end >= asOf.addingTimeInterval(-14 * 86400) }
            let balance = clamp(two.map(\.asleep).reduce(0, +) / Double(two.count) / (goalHours * 60), 0, 1) * 100
            raw.append(("Sueño reciente", 30, 0.6 * lastScore + 0.4 * balance,
                        "Anoche \(Int(lastScore)) · balance de \(two.count) noches \(Int(balance.rounded())) %"))
        }
        guard raw.count >= 2, raw.contains(where: { $0.name.hasPrefix("Variab") || $0.name.hasPrefix("FC") }) else { return nil }
        let wsum = raw.map(\.weight).reduce(0, +)              // reescala sobre lo que haya
        let parts = raw.map { r -> ScorePart in
            let t = tier(r.score, good: 80, ok: 50, ("Bajo", "Aceptable", "Bueno"))
            return ScorePart(name: r.name, points: r.score * r.weight / wsum, maxPoints: r.weight / wsum * 100, detail: r.detail, level: t.0, tone: t.1)
        }
        let total = Int(parts.map(\.points).reduce(0, +).rounded())
        return Score(value: total, parts: parts, label: recoveryLabel(total))
    }

    // MARK: Resiliencia (0–100)
    //
    // Google la explica con tres pilares y la info de su app dice qué señales mira cada uno. Aquí se reproducen así:
    //  · Calma física (40): «momentos de mayor actividad física en tu cuerpo», por estrés o por excitación: VFC, FC alta al
    //    despertar (FC en reposo) y FC alta durante el sueño (FC mínima del día, que se da durmiendo), en z-scores sobre tu línea base.
    //    Misma lógica que Recuperación (la noche de ese día, base de 5 noches mínimo, curva `recoveryPoints`). Con las capturas de
    //    Google (13 oct) es el pilar que decide: «Equilibrada» el 6, 7 y 13 oct (calma Alta, la app da 77–86) y «Baja» el resto
    //    del mes (calma Baja o Media, la app da 72 como máximo). Con la curva de meseta anterior todo salía entre 84 y 94.
    //  · Equilibrio de actividades (35): «muy poco ejercicio» y «demasiado sin descansar» restan. Mira pasos diarios, minutos en
    //    zona activa semanales (objetivo fijo de 150) y actividad frente a fatiga (carga de 7 días frente a la habitual de 28);
    //    pasos y carga, frente a lo habitual de la persona. Puntúa el peor de los tres: basta con que uno esté desequilibrado.
    //    Ajuste con 5 días de Google (8–13 oct, actividad «Baja» siempre) y pesos 40/35/25: con la actividad en 0 salen
    //    Baja, Baja, Baja y Equilibrada en 4 de los 5 días (el 8 oct sale Equilibrada y Google dio Baja); con 50/15/35 no.
    //  · Patrones de sueño (25): duración frente a tu objetivo (40 %) y los indicadores que cita Google (60 %): tiempo hasta
    //    sueño profundo, sueño atrasado (hora de acostarte frente a la habitual), REM + profundo y despertares completos.

    // Google describe el total con tres estados (su ayuda): Óptima, Equilibrada y Baja. Vistas en capturas (21 sep–13 oct): "Baja" y
    // "Equilibrada". Los cortes 65 y 83 son una estimación: con la calma ajustada, 65 separa las Equilibradas de Google (6, 7 y 13 oct)
    // de casi todas las Baja desde el 3 oct (falla el 5 oct); el 83 sale de la geometría de su gráfica y no se ha visto ninguna Óptima.
    static func resilienceLabel(_ v: Int) -> String { v >= 83 ? "Óptima" : v >= 65 ? "Equilibrada" : "Baja" }

    static func resilienceMessage(_ v: Int) -> String {
        v >= 83 ? "Te has recargado por completo y tienes los recursos necesarios para afrontar un reto."
            : v >= 65 ? "Tu cuerpo está en un estado estable y puedes seguir tu rutina normal."
            : "Tu cuerpo está bajo presión o agotado. Es un buen día para centrarte en la recuperación."
    }

    /// Minutos desde las 12:00 a la hora de acostarse: las noches que empiezan tras medianoche cuentan como +24 h.
    static func bedMinutes(_ n: SleepNight) -> Double {
        let c = Calendar.current.dateComponents([.hour, .minute], from: n.start)
        let m = Double((c.hour ?? 0) * 60 + (c.minute ?? 0))
        return m < 12 * 60 ? m + 1440 : m
    }

    /// 0…100 para una carga (o pasos) relativa a su objetivo: plena entre `lo` y `hi`, a 0 en `lo − 0,5` y en `hi + 0,5`.
    private static func balance(_ ratio: Double, lo: Double = 0.6, hi: Double = CardioLoad.overtrain) -> Double {
        ratio < lo ? clamp((ratio - (lo - 0.5)) / 0.5 * 100) : ratio > hi ? clamp((hi + 0.5 - ratio) / 0.5 * 100) : 100
    }

    static func resilience(vitals: Vitals?, nights: [SleepNight], goalHours: Double, days: [DayStat], loads: [LoadDay]?,
                           weeklyLoadGoal: Double, stepsGoal: Int, zones: [ZoneDay] = [], asOf: Date = Date()) -> Score? {
        var raw: [(name: String, weight: Double, score: Double, detail: String, names: (String, String, String))] = []

        // Calma física
        var calm: [Double] = [], calmText: [String] = []
        if let b = vitals.flatMap({ base($0.hrv, log: true, minSD: 0.05, recentN: 1, minPrev: 5, asOf: asOf) }) {
            calm.append(recoveryPoints(b.z)); calmText.append("VFC \(Int(b.recent.rounded())) ms (base \(Int(b.mean.rounded())))")
        }
        if let b = vitals.flatMap({ base($0.rhr, minSD: 1, recentN: 1, minPrev: 5, higherIsBetter: false, asOf: asOf) }) {
            calm.append(recoveryPoints(b.z)); calmText.append("FC reposo \(Int(b.recent.rounded())) lpm (base \(Int(b.mean.rounded())))")
        }
        let minHR = days.compactMap { d in d.hrMin.map { VitalPoint(day: d.day, value: $0) } }
        if let b = base(minHR, minSD: 1, recentN: 1, minPrev: 7, higherIsBetter: false, asOf: asOf) {
            calm.append(recoveryPoints(b.z)); calmText.append("FC mínima \(Int(b.recent.rounded())) lpm (base \(Int(b.mean.rounded())))")
        }
        if !calm.isEmpty {
            raw.append(("Calma física", 40, calm.reduce(0, +) / Double(calm.count), calmText.joined(separator: " · "), ("Baja", "Medio", "Alta")))
        }

        // Equilibrio de actividades: pasos diarios, minutos en zona activa semanales y actividad frente a fatiga. Cada uno se
        // compara con LO HABITUAL de la persona (últimos 28 días), no con un objetivo fijo; sin 14 días de base, con el objetivo.
        var act: [Double] = [], actText: [String] = []
        // El día de `asOf` (hoy) no cuenta: va a medias (a primera hora tiene 0 pasos y 0 de carga) y haría saltar «muy poco ejercicio» cada mañana.
        let cal = Calendar.current
        let done = days.filter { $0.day <= asOf && !cal.isDate($0.day, inSameDayAs: asOf) }
        let steps = done.suffix(7).compactMap(\.steps)
        if steps.count >= 4 {
            let avg = steps.reduce(0, +) / Double(steps.count)
            let usual = done.suffix(28).compactMap(\.steps)
            if usual.count >= 14 {
                let base = usual.reduce(0, +) / Double(usual.count)
                act.append(balance(avg / max(base, 1), lo: 0.7, hi: 1.3))
                actText.append("\(Int(avg).formatted()) pasos al día frente a \(Int(base).formatted()) habituales")
            } else {
                act.append(balance(avg / Double(stepsGoal), hi: 2)); actText.append("\(Int(avg).formatted()) pasos al día de media")
            }
        }
        let weekStart = cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: asOf)) ?? asOf
        let azm = zones.filter { $0.day >= weekStart && $0.day <= asOf }
        if azm.count >= 4 {
            let total = azm.map(\.total).reduce(0, +)
            // El objetivo semanal de minutos en zona activa es fijo (150, el estándar de Google/OMS): por debajo cuenta en proporción.
            let ratio = total / 150
            act.append(ratio < 1 ? ratio * 100 : balance(ratio, hi: 3))
            actText.append("\(Int(total.rounded())) min en zona activa esta semana (objetivo 150)")
        }
        if let z = loads?.filter({ $0.day <= asOf && !cal.isDate($0.day, inSameDayAs: asOf) }), z.count >= 14 {
            let acute = CardioLoad.sum(z, days: 7), chronic = CardioLoad.sum(z, days: 28) / Double(min(z.count, 28)) * 7
            if chronic > 0 {
                act.append(balance(acute / chronic, lo: 0.7, hi: 1.3)); actText.append("carga de 7 días \(Int(acute.rounded())) frente a \(Int(chronic.rounded())) habitual")
            }
        }
        if !act.isEmpty {
            raw.append(("Equilibrio de actividades", 35, act.min() ?? 0, actText.joined(separator: " · "), ("Baja", "Media", "Alta")))
        }

        // Patrones de sueño: duración y los indicadores que cita Google, de las últimas 7 noches.
        let ns = lastPerDay(nights.filter { $0.end <= asOf })
        let week = ns.filter { $0.end >= asOf.addingTimeInterval(-7 * 86400) }
        if week.count >= 3 {
            let avg = week.map(\.asleep).reduce(0, +) / Double(week.count)
            let dur = clamp(avg / (goalHours * 60), 0, 1) * 100
            let usual = ns.suffix(10).map(bedMinutes).sorted()
            let median = usual[usual.count / 2]
            let fits = week.map { n -> Double in
                let q = sleepQuality(n)
                let remDeep = RangeMetric(name: "REM y profundo", valueText: "", value: (n.minutes["DEEP"] ?? 0) + (n.minutes["REM"] ?? 0),
                                          lo: 120, hi: .infinity, axisMax: 0, tolLow: 60, tolHigh: 1)
                let late = clamp(100 - max(0, bedMinutes(n) - median) / 120 * 100) / 100
                return (q[0].fit + q[3].fit + remDeep.fit + late) / 4
            }
            let quality = fits.reduce(0, +) / Double(fits.count) * 100
            raw.append(("Patrones de sueño", 25, 0.4 * dur + 0.6 * quality,
                        "Media de \(hm(avg)) en \(week.count) noches · calidad \(Int(quality.rounded())) % (profundo, REM, despertares, hora de acostarte)",
                        ("Irregular", "Variable", "Habitual")))
        }

        guard raw.count >= 2 else { return nil }
        let wsum = raw.map(\.weight).reduce(0, +)
        let parts = raw.map { r -> ScorePart in
            let t = tier(r.score, good: 70, ok: 40, r.names)
            return ScorePart(name: r.name, points: r.score * r.weight / wsum, maxPoints: r.weight / wsum * 100, detail: r.detail, level: t.0, tone: t.1)
        }
        let total = Int(parts.map(\.points).reduce(0, +).rounded())
        return Score(value: total, parts: parts, label: resilienceLabel(total))
    }

    /// Una noche por día (la más larga), de la más antigua a la más reciente.
    static func lastPerDay(_ nights: [SleepNight]) -> [SleepNight] {
        let cal = Calendar.current
        return Dictionary(grouping: nights) { cal.startOfDay(for: $0.end) }
            .values.compactMap { $0.max { $0.asleep < $1.asleep } }.sorted { $0.end < $1.end }
    }
}

// MARK: - Vistas

struct ScoreRing: View {
    let score: Score
    let color: Color
    var size: CGFloat = 96

    var body: some View {
        ZStack(alignment: .bottom) {
            ArcMeter(progress: score.progress, color: color, lineWidth: size * 0.11)
            VStack(spacing: 0) {
                Text("\(score.value)").font(.system(size: size * 0.34, weight: .bold)).monospacedDigit()
                Text(score.label).font(.caption2).foregroundStyle(.secondary)
            }
        }.frame(width: size, height: ArcMeter.height(width: size, lineWidth: size * 0.11, below: size * 0.34 * 0.6 + 4))
    }
}

/// Un factor con su etiqueta de color («Bueno», «Medio»…) y el dato que lo explica.
struct FactorRow: View {
    let part: ScorePart

    private var tint: Color { part.tone == 2 ? .green : part.tone == 1 ? .blue : .orange }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(part.name).font(.subheadline.weight(.medium))
                Spacer(minLength: 8)
                Text(part.level).font(.caption.weight(.bold)).foregroundStyle(tint)
                    .padding(.horizontal, 9).padding(.vertical, 3).background(tint.opacity(0.15), in: Capsule())
            }
            Text(part.detail).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Un indicador sobre su barra, con el intervalo típico sombreado y un punto en tu valor.
struct RangeRow: View {
    let metric: RangeMetric

    private var status: (String, Color) {
        switch metric.status {
        case .inside: return ("Dentro del intervalo", .green)
        case .low: return ("Inferior al intervalo", .orange)
        case .high: return ("Superior al intervalo", .orange)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                (Text(metric.name).font(.subheadline.weight(.medium)) + Text(" · \(metric.valueText)").font(.subheadline).foregroundColor(.secondary))
                    .lineLimit(2)
                Spacer(minLength: 8)
                Text(status.0).font(.caption2.weight(.bold)).foregroundStyle(status.1)
                    .padding(.horizontal, 8).padding(.vertical, 3).background(status.1.opacity(0.15), in: Capsule())
            }
            GeometryReader { g in
                let w = g.size.width
                let x = { (v: Double) in w * CGFloat(min(max(v / metric.axisMax, 0), 1)) }
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule().fill(status.1.opacity(0.22)).frame(width: max(x(metric.hi) - x(metric.lo), 6)).offset(x: x(metric.lo))
                        .overlay(Capsule().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3])).foregroundStyle(.secondary)
                            .frame(width: max(x(metric.hi) - x(metric.lo), 6)).offset(x: x(metric.lo)), alignment: .leading)
                    Circle().fill(Color.primary).frame(width: 12, height: 12).offset(x: min(max(x(metric.value) - 6, 0), w - 12))
                }
            }.frame(height: 12)
        }
    }
}

/// Un componente de la puntuación con sus puntos, una barra y el dato que lo explica.
struct ScoreBarRow: View {
    let part: ScorePart

    private var tint: Color { part.tone == 2 ? .green : part.tone == 1 ? .blue : .orange }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(part.name).font(.subheadline.weight(.medium))
                Spacer(minLength: 6)
                Text("\(Int(part.points.rounded()))").font(.subheadline.weight(.bold).monospacedDigit())
                    + Text("/\(Int(part.maxPoints))").font(.caption.monospacedDigit()).foregroundColor(.secondary)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(tint.opacity(0.18))
                    Capsule().fill(tint).frame(width: g.size.width * CGFloat(min(max(part.points / part.maxPoints, 0.02), 1)))
                }
            }.frame(height: 7)
            Text(part.detail).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Puntuación de la última noche con su desglose.
struct SleepScoreCard: View {
    /// Frase sobre un fondo del color de la noche: verde (80+), naranja (60–79) o rojo.
    private func headline(_ score: Int, _ text: String) -> some View {
        let tint: Color = score >= 80 ? .green : score >= 60 ? .orange : .red
        return Text(text).font(.subheadline.weight(.semibold)).foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 10)
            .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @EnvironmentObject var model: HealthModel
    let night: SleepNight
    let goalHours: Double
    @State private var showQuality = false

    var body: some View {
        let s = model.sleepScore(night, goalHours: goalHours)
        VStack(alignment: .leading, spacing: 14) {
            CardHeader(icon: "sparkles", title: "Puntuación de sueño", color: Theme.sleep, trailing: "estimada", chevron: false)
            headline(s.value, model.sleepHeadline(night, goalHours: goalHours))
            HStack(alignment: .center, spacing: 18) {
                ScoreRing(score: s, color: Theme.sleep)
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(s.parts) { ScoreBarRow(part: $0) }
                }
            }
            Divider()
            DisclosureGroup(isExpanded: $showQuality) {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(s.metrics) { RangeRow(metric: $0) }
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 3).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3])).frame(width: 18, height: 10)
                        Text("Intervalo típico de un adulto").font(.caption)
                    }.foregroundStyle(.secondary)
                    Text(s.parts.count < 3
                         ? "Aún no hay noches suficientes para puntuar la hora de acostarte: el total se calcula con la duración y las interrupciones."
                         : "Duración (50) según lo que duermes frente a tu objetivo, hora de acostarte (30) frente a tu media de 14 noches e interrupciones (20) por el tiempo despierto durante la noche.")
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding(.top, 10)
            } label: {
                Text("Calidad del sueño").font(.headline)
            }.tint(.secondary)
        }.card()
    }
}

/// Puntuación de un día pasado, para las gráficas de periodo.
struct ScoreDay: Identifiable {
    let day: Date
    let value: Int
    var id: Date { day }
}

/// Ajustes y cálculo compartidos por las tarjetas de Hoy y las vistas de detalle de Recuperación y Resiliencia.
@MainActor struct ScoreSettings: DynamicProperty {
    @AppStorage("sleepGoalHours") private var sleepGoal = 8.0
    @AppStorage(CardioLoad.goalKey) private var loadGoal = 0
    @AppStorage(CardioLoad.ageKey) private var age = CardioLoad.defaultAge
    @AppStorage("stepsGoal") private var stepsGoal = 10_000

    func recovery(_ model: HealthModel) -> Score? {
        Scoring.recovery(vitals: model.vitals, nights: model.nights, goalHours: sleepGoal)
    }

    func resilience(_ model: HealthModel) -> Score? {
        let loads = model.loadDays(age: age)
        return Scoring.resilience(vitals: model.vitals, nights: model.nights, goalHours: sleepGoal, days: model.history?.days ?? [],
                                  loads: loads, weeklyLoadGoal: CardioLoad.weeklyGoal(setting: loadGoal, loads: loads ?? []),
                                  stepsGoal: stepsGoal, zones: model.zones ?? [])
    }

    /// Puntuación de cada uno de los últimos `range.days` días, calculada con lo que se sabía al acabar ese día (hoy, hasta ahora).
    /// Los días sin datos suficientes no salen. Carga y minutos en zona solo se guardan 30 días: antes, falta ese factor.
    func recoverySeries(_ model: HealthModel, range: HistRange) -> [ScoreDay] {
        let nights = model.nights(for: range)
        return series(range) { Scoring.recovery(vitals: model.vitals, nights: nights, goalHours: sleepGoal, asOf: $0) }
    }

    func resilienceSeries(_ model: HealthModel, range: HistRange) -> [ScoreDay] {
        let nights = model.nights(for: range), days = model.history(for: range)?.days ?? []
        let loads = model.loadDays(age: age)
        let goal = CardioLoad.weeklyGoal(setting: loadGoal, loads: loads ?? [])
        return series(range) {
            Scoring.resilience(vitals: model.vitals, nights: nights, goalHours: sleepGoal, days: days, loads: loads, weeklyLoadGoal: goal,
                               stepsGoal: stepsGoal, zones: model.zones ?? [], asOf: $0)
        }
    }

    private func series(_ range: HistRange, _ score: (Date) -> Score?) -> [ScoreDay] {
        let cal = Calendar.current, today = cal.startOfDay(for: Date())
        return (0..<range.days).reversed().compactMap { back in
            guard let day = cal.date(byAdding: .day, value: -back, to: today) else { return nil }
            let asOf = back == 0 ? Date() : (cal.date(byAdding: .day, value: 1, to: day) ?? day).addingTimeInterval(-1)
            return score(asOf).map { ScoreDay(day: day, value: $0.value) }
        }
    }
}

/// Tarjeta pequeña de Hoy con un aro de puntuación. `last` (-1 = ninguna) es la última puntuación calculada:
/// se enseña mientras llegan los datos para que la card no salga vacía.
private struct ScoreMiniCard: View {
    let route: Route
    let icon: String, title: String
    let color: Color
    let score: Score?
    @Binding var last: Int
    let label: (Int) -> String

    var body: some View {
        let shown = score ?? (last < 0 ? nil : Score(value: last, parts: [], label: label(last)))
        NavigationLink(value: route) {
            VStack(alignment: .leading, spacing: 10) {
                MiniHeader(icon: icon, title: title, color: color)
                Group {
                    if let shown { ScoreRing(score: shown, color: color, size: 84) }
                    else { Text("—").font(.title2.weight(.bold)).foregroundStyle(.secondary).frame(width: 84, height: 84) }
                }.frame(maxWidth: .infinity)
            }.miniCard()
        }
        .buttonStyle(.plain)
        .onChange(of: score?.value, initial: true) { if let v = score?.value { last = v } }
    }
}

/// Tarjeta de Hoy con la recuperación.
struct RecoveryCard: View {
    @EnvironmentObject var model: HealthModel
    private let settings = ScoreSettings()
    @AppStorage(Scoring.lastRecoveryKey) private var lastRec = -1

    var body: some View {
        ScoreMiniCard(route: .recovery, icon: "bolt.heart.fill", title: "Recuperación", color: Theme.steps,
                      score: settings.recovery(model), last: $lastRec, label: Scoring.recoveryLabel)
    }
}

/// Tarjeta de Hoy con la resiliencia.
struct ResilienceCard: View {
    @EnvironmentObject var model: HealthModel
    private let settings = ScoreSettings()
    @AppStorage(Scoring.lastResilienceKey) private var lastRes = -1

    var body: some View {
        ScoreMiniCard(route: .resilience, icon: "shield.lefthalf.filled", title: "Resiliencia", color: Theme.rem,
                      score: settings.resilience(model), last: $lastRes, label: Scoring.resilienceLabel)
    }
}

/// Bloque de detalle de una puntuación: aro, mensaje y factores.
private struct ScoreDetailBlock: View {
    @EnvironmentObject var model: HealthModel
    let title: String, icon: String
    let color: Color
    let score: Score?
    let message: String?
    let heading: String, empty: String, text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardHeader(icon: icon, title: title, color: color, chevron: false)
            if let s = score {
                HStack(spacing: 18) {
                    ScoreRing(score: s, color: color)
                    if let message { Text(message).font(.subheadline) }
                }
                Text(heading).font(.headline)
                ForEach(s.parts) { FactorRow(part: $0) }
                Text(text).font(.footnote).foregroundStyle(.secondary)
            } else {
                EmptyNote(text: model.vitals == nil ? "Descargando…" : empty)
                Text(text).font(.footnote).foregroundStyle(.secondary)
            }
        }.card()
    }
}

/// Resumen de una puntuación en un periodo: media, mínima y máxima, gráfica (por semanas en 3 meses) y días por estado.
private struct ScoreHistoryBlock: View {
    let title: String, icon: String
    let color: Color
    let range: HistRange
    let series: [ScoreDay]
    let labels: [String]                 // estados de mejor a peor
    let label: (Int) -> String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardHeader(icon: icon, title: title, color: color, trailing: range.span, chevron: false)
            if series.count < 2 {
                EmptyNote(text: "Aún no hay días suficientes con datos para este periodo.")
            } else {
                stats
                TrendChart(points: points, color: color, range: range, zeroBased: false, yStep: 10, format: formatScore)
                    .frame(height: 200)
                Text("Días por estado").font(.headline)
                ForEach(labels, id: \.self) { l in distributionRow(l) }
            }
            Text(text).font(.footnote).foregroundStyle(.secondary)
        }.card()
    }

    private func formatScore(_ v: Double) -> String { "\(Int(v.rounded()))" }

    private var stats: some View {
        let values = series.map(\.value)
        let mean = Double(values.reduce(0, +)) / Double(values.count)
        return HStack {
            StatCell(title: "Media", value: "\(Int(mean.rounded()))")
            StatCell(title: "Mínima", value: "\(values.min() ?? 0)")
            StatCell(title: "Máxima", value: "\(values.max() ?? 0)")
            StatCell(title: "Días", value: "\(values.count)")
        }
    }

    private func distributionRow(_ l: String) -> some View {
        let n = series.filter { label($0.value) == l }.count
        return HStack {
            Text(l).font(.subheadline)
            Spacer()
            Text("\(n) días").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    /// En 3 meses, la media de cada semana; en el resto, un punto por día.
    private var points: [TrendPoint] {
        guard range.unit != .day else { return series.map { TrendPoint(date: $0.day, value: Double($0.value)) } }
        let groups: [Date: [ScoreDay]] = Dictionary(grouping: series) { range.bucketStart($0.day) }
        var out: [TrendPoint] = []
        for (start, ds) in groups {
            let total = ds.reduce(0) { $0 + $1.value }
            out.append(TrendPoint(date: start, value: Double(total) / Double(ds.count)))
        }
        return out.sorted { $0.date < $1.date }
    }
}

private let scoreRanges: [HistRange] = [.day, .week, .month, .quarter]

struct RecoveryView: View {
    @EnvironmentObject var model: HealthModel
    private let settings = ScoreSettings()
    @State private var range = HistRange.day

    private static let explanation = "Google mira tres indicadores: VFC (50 %), sueño reciente (30 %) y FC en reposo (20 %), comparando tu última noche con tu normalidad de los 60 días anteriores. Un cambio de menos de media desviación típica respecto a lo tuyo no cuenta como cambio. Alta desde 66, moderada de 35 a 65, baja por debajo."

    var body: some View {
        let rec = settings.recovery(model)
        ScrollView {
            VStack(spacing: 16) {
                Picker("Periodo", selection: $range) {
                    ForEach(scoreRanges) { Text($0.label(day: "Día")).tag($0) }
                }.pickerStyle(.segmented)

                if range == .day {
                    dayBlock(rec)
                } else {
                    ScoreHistoryBlock(title: "Recuperación", icon: "bolt.heart.fill", color: Theme.steps, range: range,
                                      series: settings.recoverySeries(model, range: range), labels: ["Alta", "Moderada", "Baja"],
                                      label: Scoring.recoveryLabel, text: Self.explanation)
                }
            }.padding(.horizontal, 16).padding(.bottom, 24)
        }
        .healthChrome("Recuperación")
        .task { await model.loadVitals() }
        .task { await model.loadLong() }
    }

    private func dayBlock(_ rec: Score?) -> some View {
        ScoreDetailBlock(title: "Recuperación diaria", icon: "bolt.heart.fill", color: Theme.steps, score: rec,
                         message: rec.map { Scoring.recoveryMessage($0.value) },
                         heading: "Qué ha afectado a tu recuperación",
                         empty: "Hacen falta unas 3 semanas de VFC o FC en reposo para fijar tu línea base, y que anoche haya datos.",
                         text: Self.explanation)
    }
}

struct ResilienceView: View {
    @EnvironmentObject var model: HealthModel
    private let settings = ScoreSettings()
    @State private var range = HistRange.day

    private static let explanation = "Los tres pilares de Google: calma física (VFC, FC al despertar y FC durante el sueño frente a tu normalidad), equilibrio de actividades (pasos, minutos en zona activa de la semana y carga frente a fatiga: ni sedentarismo ni exceso; cuenta el que peor esté) y patrones de sueño (duración, tiempo hasta sueño profundo, REM y profundo, despertares y hora de acostarte). Óptima desde 83, equilibrada de 65 a 82 y baja por debajo (cortes estimados con las capturas de Google). La carga y los minutos en zona activa solo se guardan 30 días: antes de eso, el equilibrio se puntúa solo con los pasos."

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Picker("Periodo", selection: $range) {
                    ForEach(scoreRanges) { Text($0.label(day: "Día")).tag($0) }
                }.pickerStyle(.segmented)

                if range == .day {
                    let res = settings.resilience(model)
                    ScoreDetailBlock(title: "Resiliencia", icon: "shield.lefthalf.filled", color: Theme.rem, score: res,
                                     message: res.map { Scoring.resilienceMessage($0.value) },
                                     heading: "Cómo calculamos tu resiliencia",
                                     empty: "Hacen falta unos días de VFC, sueño y actividad para calcularla.",
                                     text: Self.explanation)
                } else {
                    ScoreHistoryBlock(title: "Resiliencia", icon: "shield.lefthalf.filled", color: Theme.rem, range: range,
                                      series: settings.resilienceSeries(model, range: range), labels: ["Óptima", "Equilibrada", "Baja"],
                                      label: Scoring.resilienceLabel, text: Self.explanation)
                }
            }.padding(.horizontal, 16).padding(.bottom, 24)
        }
        .healthChrome("Resiliencia")
        .task { await model.loadVitals() }
        .task { await model.loadLong() }
        .task { await model.loadHRDays() }
    }
}

#if DEBUG
#Preview("Anillos y factores") {
    let m = HealthModel.preview
    let score = m.sleepScore(PreviewData.night(), goalHours: 8)
    return ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            ScoreRing(score: score, color: Theme.sleep)
            ForEach(score.parts) { FactorRow(part: $0) }
            ForEach(score.parts) { ScoreBarRow(part: $0) }
            ForEach(score.metrics) { RangeRow(metric: $0) }
        }.padding(16)
    }.previewEnvironment()
}
#Preview("Tarjeta de sueño") {
    SleepScoreCard(night: PreviewData.night(), goalHours: 8).previewCard().previewEnvironment()
}
#Preview("Recuperación (tarjeta)") { RecoveryCard().previewCard().previewEnvironment() }
#Preview("Resiliencia (tarjeta)") { ResilienceCard().previewCard().previewEnvironment() }
#Preview("Recuperación") { RecoveryView().previewScreen() }
#Preview("Resiliencia") { ResilienceView().previewScreen() }
#endif
