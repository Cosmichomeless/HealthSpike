import SwiftUI
import Charts

/// Un entreno registrado (`exercise`): la Air los detecta sola (`PASSIVELY_MEASURED`) o se lanzan desde la pulsera.
struct Workout: Codable, Identifiable, Equatable {
    var id: String
    var type: String                 // HIKING, CARDIO_WORKOUT…
    var name: String                 // nombre que da Google (ya en español)
    var start: Date
    var end: Date
    var kcal: Double?
    var km: Double?
    var steps: Int?
    var avgHR: Int?
    var paceMinPerKm: Double?
    /// Minutos en cada zona de pulso: light, moderate, vigorous, peak.
    var zones: [String: Int] = [:]
    var source: SourceID = .google

    private enum CodingKeys: String, CodingKey { case id, type, name, start, end, kcal, km, steps, avgHR, paceMinPerKm, zones, source }
    fileprivate enum Legacy: String, CodingKey { case isAir }

    var minutes: Double { end.timeIntervalSince(start) / 60 }

    var icon: String {
        switch type {
        case "HIKING": "figure.hiking"
        case "WALKING": "figure.walk"
        case "RUNNING", "TREADMILL": "figure.run"
        case "BIKING", "CYCLING": "figure.outdoor.cycle"
        case "SWIMMING", "SWIMMING_POOL": "figure.pool.swim"
        case "WEIGHTS", "STRENGTH_TRAINING": "figure.strengthtraining.traditional"
        case "YOGA": "figure.yoga"
        default: "figure.mixed.cardio"
        }
    }
}

/// Lo que se guarda en disco: los entrenos y hasta cuándo se han pedido (sin entrenos recientes no hay otra forma de saberlo).
struct WorkoutCache: Codable {
    var syncedAt: Date
    var workouts: [Workout]
}

extension HealthAPI {
    /// `exercise` solo admite filtro por `interval.civil_start_time` y páginas de 25.
    func workouts(since start: Date) async throws -> [Workout] {
        let pts = try await points("exercise", filter: "exercise.interval.civil_start_time >= \"\(Self.day(start))\"", pageSize: 25, maxPages: 40)
        return pts.compactMap { p in
            guard let e = p["exercise"] as? [String: Any], let iv = e["interval"] as? [String: Any],
                  let s = (iv["startTime"] as? String).flatMap(Self.parse), let f = (iv["endTime"] as? String).flatMap(Self.parse), f > s else { return nil }
            let type = e["exerciseType"] as? String ?? ""
            let m = e["metricsSummary"] as? [String: Any] ?? [:]
            var zones: [String: Int] = [:]
            for (k, v) in m["heartRateZoneDurations"] as? [String: Any] ?? [:] {
                // "1380s" → minutos
                if let sec = Double(String(describing: v).trimmingCharacters(in: CharacterSet(charactersIn: "s"))) { zones[k.replacingOccurrences(of: "Time", with: "")] = Int((sec / 60).rounded()) }
            }
            let name = (e["displayName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? type.replacingOccurrences(of: "_", with: " ").capitalized
            return Workout(id: p["name"] as? String ?? Self.iso(s), type: type, name: name, start: s, end: f,
                           kcal: Self.num(m["caloriesKcal"]),
                           km: Self.num(m["distanceMillimeters"]).flatMap { $0 > 0 ? $0 / 1e6 : nil },
                           steps: Self.num(m["steps"]).flatMap { $0 > 0 ? Int($0) : nil },
                           avgHR: Self.num(m["averageHeartRateBeatsPerMinute"]).map { Int($0.rounded()) },
                           paceMinPerKm: Self.num(m["averagePaceSecondsPerMeter"]).map { $0 * 1000 / 60 },
                           zones: zones, source: Self.sourceInfo(p))
        }.sorted { $0.start < $1.start }
    }
}

extension HealthModel {
    #if DEBUG
    /// Entrenos inventados para las pruebas por línea de comandos (`-coachTest workout`): solo en memoria, no se guardan.
    static var fakeWorkouts: [Workout] = []
    private var allWorkouts: [Workout] { (workouts ?? []) + Self.fakeWorkouts }
    #else
    private var allWorkouts: [Workout] { workouts ?? [] }
    #endif

    /// Entrenos de un día natural, el más antiguo primero (respeta la fuente elegida en Ajustes).
    func workouts(on day: Date) -> [Workout] {
        let cal = Calendar.current
        return allWorkouts.filter { cal.isDate($0.start, inSameDayAs: day) && sourceScope.keeps($0.source) }
    }

    /// Entrenos que empiezan dentro de [from, to) (respeta la fuente elegida en Ajustes).
    func workouts(from: Date, to: Date) -> [Workout] {
        allWorkouts.filter { $0.start >= from && $0.start < to && sourceScope.keeps($0.source) }
    }
}

/// Las cachés anteriores guardaban `isAir` en vez de `source`; está en una extensión para conservar el `init` de miembros.
extension Workout {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = try c.decode(String.self, forKey: .type)
        name = try c.decode(String.self, forKey: .name)
        start = try c.decode(Date.self, forKey: .start)
        end = try c.decode(Date.self, forKey: .end)
        kcal = try c.decodeIfPresent(Double.self, forKey: .kcal)
        km = try c.decodeIfPresent(Double.self, forKey: .km)
        steps = try c.decodeIfPresent(Int.self, forKey: .steps)
        avgHR = try c.decodeIfPresent(Int.self, forKey: .avgHR)
        paceMinPerKm = try c.decodeIfPresent(Double.self, forKey: .paceMinPerKm)
        zones = try c.decodeIfPresent([String: Int].self, forKey: .zones) ?? [:]
        if let id = try c.decodeIfPresent(SourceID.self, forKey: .source) {
            source = id
        } else {
            let isAir = try decoder.container(keyedBy: Legacy.self).decodeIfPresent(Bool.self, forKey: .isAir) ?? true
            source = SourceID(legacyIsAir: isAir, name: nil)
        }
    }
}

// MARK: - Tarjetas

/// Zonas de pulso de Google en el orden en que se intensifican.
private let workoutZones: [(key: String, name: String, color: Color)] = [
    ("light", "Ligera", Theme.light), ("moderate", "Moderada", Theme.steps), ("vigorous", "Intensa", Theme.awake), ("peak", "Pico", Theme.heart),
]

/// Barra apilada con el tiempo en cada zona de pulso y, debajo, la leyenda con los minutos.
private struct ZoneBar: View {
    let zones: [String: Int]

    var body: some View {
        let parts = workoutZones.filter { (zones[$0.key] ?? 0) > 0 }
        if !parts.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        ForEach(parts, id: \.key) { z in
                            RoundedRectangle(cornerRadius: 3).fill(z.color)
                                .frame(width: max(4, (geo.size.width - 2 * CGFloat(parts.count - 1)) * CGFloat(zones[z.key]!) / CGFloat(parts.map { zones[$0.key]! }.reduce(0, +))))
                        }
                    }
                }.frame(height: 8)
                HStack(spacing: 12) {
                    ForEach(parts, id: \.key) { z in
                        Label("\(z.name) \(zones[z.key]!) min", systemImage: "circle.fill").labelStyle(ZoneLegendStyle(color: z.color))
                    }
                }.font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct ZoneLegendStyle: LabelStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.icon.font(.system(size: 7)).foregroundStyle(color); configuration.title }
    }
}

private func paceText(_ p: Double) -> String {
    let m = Int(p), s = Int(((p - Double(m)) * 60).rounded())
    return s == 60 ? "\(m + 1):00 min/km" : String(format: "%d:%02d min/km", m, s)
}

private let clock = Date.FormatStyle().hour(.twoDigits(amPM: .omitted)).minute().locale(esES)

/// «Entrenos» del día elegido en Actividad: uno por fila con tipo, horario, duración, kcal, pulso medio y minutos por zona.
struct WorkoutsDayCard: View {
    @EnvironmentObject var model: HealthModel
    let day: DayChoice

    var body: some View {
        let date = Calendar.current.date(byAdding: .day, value: day == .today ? 0 : -1, to: Date())!
        let items = model.workouts(on: date)
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(icon: "figure.run", title: "Entrenos", color: Theme.steps,
                       trailing: items.isEmpty ? nil : "\(items.count) · \(Int(items.map(\.minutes).reduce(0, +).rounded())) min", chevron: false)
            if model.workouts == nil {
                if model.workoutsFailed { Label("No se pudieron descargar los entrenos. Tira hacia abajo para reintentar.", systemImage: "exclamationmark.triangle").font(.subheadline).foregroundStyle(.secondary) }
                else { ProgressView().frame(maxWidth: .infinity, minHeight: 60) }
            } else if items.isEmpty {
                Text("Sin entrenos \(day == .today ? "hoy" : "ayer")").font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 50)
            } else {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, w in
                    if i > 0 { Divider() }
                    NavigationLink { WorkoutDetailView(workout: w) } label: { row(w) }.buttonStyle(.plain)
                }
                if model.workoutsFailed { Label("No se pudo actualizar la lista de entrenos.", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary) }
            }
        }.card()
    }

    private func row(_ w: Workout) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: w.icon).font(.title3).foregroundStyle(Theme.steps).frame(width: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(w.name).font(.headline)
                    Text("\(w.start.formatted(clock))–\(w.end.formatted(clock))").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(Int(w.minutes.rounded())) min").font(.headline.monospacedDigit())
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            HStack {
                if let k = w.kcal { StatCell(title: "Calorías", value: "\(Int(k.rounded())) kcal") }
                if let h = w.avgHR { StatCell(title: "Pulso medio", value: "\(h) lpm") }
                if let km = w.km { StatCell(title: "Distancia", value: String(format: "%.2f km", km)) }
                if let s = w.steps, w.km == nil { StatCell(title: "Pasos", value: s.formatted()) }
            }
            if let p = w.paceMinPerKm, w.km != nil {
                Text("Ritmo medio \(paceText(p))").font(.caption).foregroundStyle(.secondary)
            }
            ZoneBar(zones: w.zones)
        }
    }
}

/// «Entrenos» de Semana/Mes/3 meses/Año: número, minutos y calorías del periodo y minutos por semana o mes.
struct WorkoutsRangeCard: View {
    @EnvironmentObject var model: HealthModel
    let range: HistRange

    var body: some View {
        let cal = Calendar.current
        let end = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date()))!
        let from = cal.date(byAdding: .day, value: -range.days, to: end)!
        let items = model.workouts(from: from, to: end)
        let total = items.map(\.minutes).reduce(0, +)
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(icon: "figure.run", title: "Entrenos", color: Theme.steps, chevron: false)
            if model.workouts == nil {
                if model.workoutsFailed { Label("No se pudieron descargar los entrenos. Tira hacia abajo para reintentar.", systemImage: "exclamationmark.triangle").font(.subheadline).foregroundStyle(.secondary) }
                else { ProgressView().frame(maxWidth: .infinity, minHeight: 60) }
            } else if items.isEmpty {
                Text("Sin entrenos en este periodo").font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 50)
            } else {
                HStack {
                    StatCell(title: "Entrenos", value: items.count.formatted())
                    StatCell(title: "Tiempo", value: "\(Int(total.rounded()).formatted()) min")
                    StatCell(title: "Calorías", value: "\(Int(items.compactMap(\.kcal).reduce(0, +).rounded()).formatted()) kcal")
                }
                let buckets = Dictionary(grouping: items) { range.bucketStart($0.start) }.map { ($0.key, $0.value.map(\.minutes).reduce(0, +)) }.sorted { $0.0 < $1.0 }
                WorkoutBars(range: range, buckets: buckets, from: from, to: end).frame(height: 130)
                NavigationLink { WorkoutsLogView(range: range, workouts: items) } label: {
                    HStack {
                        Text("Ver los \(items.count) \(items.count == 1 ? "entreno" : "entrenos")").font(.subheadline.weight(.semibold))
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                }.buttonStyle(.plain)
                if range.unit != .day { Text("Minutos de entreno por \(range.unit == .month ? "mes" : "semana").").font(.caption).foregroundStyle(.secondary) }
                if model.workoutsFailed { Label("No se pudo actualizar la lista de entrenos.", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary) }
            }
        }.card()
    }
}

private struct WorkoutBars: View {
    let range: HistRange
    let buckets: [(Date, Double)]
    let from: Date, to: Date
    @State private var selected: Date?

    var body: some View {
        let sel = selected.flatMap { s in buckets.first { esCalendar.isDate($0.0, equalTo: s, toGranularity: range.unit) } }
        Chart {
            ForEach(buckets, id: \.0) { b in
                BarMark(x: .value("Periodo", b.0, unit: range.unit), y: .value("Min", b.1))
                    .foregroundStyle(Theme.steps).opacity(sel == nil || sel?.0 == b.0 ? 1 : 0.35)
            }
            if let sel {
                RuleMark(x: .value("Selección", sel.0, unit: range.unit)).foregroundStyle(Color.clear)
                    .annotation(position: .top, spacing: 4, overflowResolution: AnnotationOverflowResolution(x: .fit(to: .chart), y: .disabled)) {
                        ScrubBubble(title: range.bucketLabel(sel.0), value: "\(Int(sel.1.rounded())) min", color: Theme.steps)
                    }
            }
        }
        .chartXSelection(value: $selected)
        .chartXScale(domain: from...to)
        .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) }
    }
}

// MARK: - Detalle

/// Un entreno entero: datos grandes, zonas de pulso y la curva del pulso de principio a fin con mín., media y máx.
struct WorkoutDetailView: View {
    @EnvironmentObject var model: HealthModel
    let workout: Workout
    @State private var readings: [Reading]?

    /// Una barra cada ~1/80 de la duración (entre 15 s y 2 min) para que la curva no sea ruido.
    private var buckets: [HRBucket] {
        let width = min(max(workout.end.timeIntervalSince(workout.start) / 80, 15), 120)
        let by = Dictionary(grouping: readings ?? []) { Int($0.time.timeIntervalSince(workout.start) / width) }
        return by.keys.sorted().map { k in
            let v = by[k]!.map(\.value)
            return HRBucket(time: workout.start.addingTimeInterval((Double(k) + 0.5) * width), min: v.min()!, max: v.max()!, avg: v.reduce(0, +) / Double(v.count))
        }
    }

    var body: some View {
        let w = workout
        ScrollView {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Image(systemName: w.icon).font(.title2).foregroundStyle(Theme.steps)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(w.name).font(.title3.weight(.semibold))
                            Text("\(w.start.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(esES))) · \(w.start.formatted(clock))–\(w.end.formatted(clock))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    BigValue(value: "\(Int(w.minutes.rounded()))", unit: "min")
                    HStack {
                        if let k = w.kcal { StatCell(title: "Calorías", value: "\(Int(k.rounded())) kcal") }
                        if let km = w.km { StatCell(title: "Distancia", value: String(format: "%.2f km", km)) }
                        if let s = w.steps { StatCell(title: "Pasos", value: s.formatted()) }
                        if let p = w.paceMinPerKm, w.km != nil { StatCell(title: "Ritmo", value: paceText(p)) }
                    }
                }.card()

                VStack(alignment: .leading, spacing: 10) {
                    CardHeader(icon: "heart.fill", title: "Pulso", color: Theme.heart, trailing: w.avgHR.map { "media \($0) lpm" }, chevron: false)
                    if let readings {
                        let b = buckets
                        if b.isEmpty {
                            Text("Sin muestras de pulso en este entreno").font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 80)
                        } else {
                            HStack {
                                StatCell(title: "Mínimo", value: "\(Int(readings.map(\.value).min()!.rounded())) lpm")
                                StatCell(title: "Media", value: "\(w.avgHR ?? Int((readings.map(\.value).reduce(0, +) / Double(readings.count)).rounded())) lpm")
                                StatCell(title: "Máximo", value: "\(Int(readings.map(\.value).max()!.rounded())) lpm")
                            }
                            HeartDayChart(buckets: b, domain: w.start...w.end).frame(height: 180)
                        }
                    } else {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                    }
                }.card()

                if !w.zones.values.allSatisfy({ $0 == 0 }) {
                    VStack(alignment: .leading, spacing: 10) {
                        CardHeader(icon: "bolt.heart.fill", title: "Zonas de pulso", color: Theme.awake, chevron: false)
                        ZoneBar(zones: w.zones)
                    }.card()
                }
                if w.source.provider != .google {
                    Label("Este entreno no viene de Google Health.", systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 16).padding(.bottom, 24)
        }
        .healthChrome("Entreno")
        .task { readings = await model.workoutHeart(workout) }
    }
}

/// Todos los entrenos de un periodo, el más reciente primero; cada uno abre su detalle.
struct WorkoutsLogView: View {
    let range: HistRange
    let workouts: [Workout]

    var body: some View {
        List {
            ForEach(Array(workouts.reversed())) { w in
                NavigationLink { WorkoutDetailView(workout: w) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: w.icon).foregroundStyle(Theme.steps).frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(w.name).font(.subheadline.weight(.semibold))
                            Text("\(w.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(esES))) · \(w.start.formatted(clock))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(Int(w.minutes.rounded())) min").font(.subheadline.monospacedDigit().weight(.semibold))
                            Text([w.kcal.map { "\(Int($0.rounded())) kcal" }, w.avgHR.map { "\($0) lpm" }].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden).background(Theme.background)
        .navigationTitle("Entrenos").navigationBarTitleDisplayMode(.inline)
    }
}
