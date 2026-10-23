import SwiftUI
import Charts

struct ActivityView: View {
    @EnvironmentObject var model: HealthModel
    @AppStorage("stepsGoal") private var stepsGoal = 10_000
    @AppStorage("caloriesGoal") private var caloriesGoal = 2_500
    @State private var range = HistRange.day
    @State private var day = DayChoice.today
    // Selección con el dedo en las gráficas de esta pantalla (las de Charts.swift llevan la suya).
    @State private var selCalDay: Date?
    @State private var selHourAt: Date?
    @State private var selCum: Date?
    @State private var selWeekdayAt: Date?
    private static let bubbleOverflow = AnnotationOverflowResolution(x: .fit(to: .chart), y: .disabled)

    private func closest<T>(_ items: [T], to date: Date?, _ key: (T) -> Date) -> T? {
        guard let date else { return nil }
        return items.min { abs(key($0).timeIntervalSince(date)) < abs(key($1).timeIntervalSince(date)) }
    }
    /// Pasos por hora a partir de los cuales una hora cuenta como activa (el criterio clásico de Fitbit).
    private static let activeHourSteps = 250.0

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Picker("Periodo", selection: $range) {
                    ForEach(HistRange.allCases) { Text($0.label(day: "Día")).tag($0) }
                }.pickerStyle(.segmented)

                if let e = model.error { ErrorBanner(text: e) }
                recordCard
                if range == .day { DayChoicePicker(choice: $day); dayContent } else { rangeContent }
            }
            .padding(.horizontal, 16).padding(.bottom, 24)
        }
        .healthChrome("Actividad")
        .task(id: range) { await model.loadLong() }   // récords y comparación con el periodo anterior usan todo el histórico
        .task(id: day) { await model.loadYesterday() }
        .task { await model.loadZones() }
        .task { await model.loadWorkouts() }
        .task(id: range) { await model.loadHRDays(days: range == .day ? 30 : range.days) }   // el pulso de cada día solo se baja hasta donde llega el filtro
    }

    // MARK: - Día

    @ViewBuilder
    private var dayContent: some View {
        if let t = day == .today ? model.today : model.yesterday {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 18) {
                    ZStack(alignment: .bottom) {
                        ArcMeter(progress: t.steps / Double(stepsGoal), color: Theme.steps)
                        Text("\(Int((t.steps / Double(stepsGoal) * 100).rounded())) %").font(.system(size: 20, weight: .bold))
                    }.frame(width: 100, height: ArcMeter.height(width: 100, below: 4))
                    VStack(alignment: .leading, spacing: 4) {
                        BigValue(value: Int(t.steps).formatted(), unit: "pasos")
                        Text("de \(stepsGoal.formatted()) · \(String(format: "%.2f", t.distanceKm)) km").font(.subheadline).foregroundStyle(.secondary)
                        if let f = t.floors { Label("\(Int(f.rounded())) \(Int(f.rounded()) == 1 ? "piso" : "pisos")", systemImage: "figure.stairs").font(.subheadline).foregroundStyle(.secondary) }
                    }
                }
                Text("PASOS POR HORA").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                let sessions = model.workouts(on: t.midnight)
                DayTrendChart(points: t.hourlySteps.map { HourValue(hour: $0.hour, value: $0.steps) }, domain: t.dayDomain, color: Theme.steps,
                              bands: sessions.map { $0.start...$0.end },
                              format: { "\(Int($0.rounded()).formatted()) pasos" }).frame(height: 180)
                if !sessions.isEmpty {
                    Label("Franja naranja: \(sessions.count == 1 ? "entreno" : "entrenos")", systemImage: "square.fill").font(.caption).foregroundStyle(Theme.awake)
                }
            }.card()
            if t.calories != nil || !t.hourlyDistance.isEmpty {
                HStack(alignment: .top, spacing: 12) {
                    if !t.hourlyDistance.isEmpty { distanceCard(t) }
                    if let k = t.calories { caloriesCard(k) }
                }.fixedSize(horizontal: false, vertical: true)
            }
            if day == .today, let y = model.yesterday, y.steps > 0 {
                HStack(alignment: .top, spacing: 12) {
                    vsYesterdayCard(t, y)
                    activeHoursCard(t, half: true)
                }.fixedSize(horizontal: false, vertical: true)
            } else {
                activeHoursCard(t, half: false)
            }
            WorkoutsDayCard(day: day)
            ZoneMinutesCard(days: model.zones, day: day)
            CardioLoadChartCard(range: .day, day: day)
            if t.otherSourceSteps > 0 {
                Label(model.sourceScope == .googleOnly
                      ? "Google también tiene \(Int(t.otherSourceSteps).formatted()) pasos de Apple Health \(day == .today ? "hoy" : "ayer"); se ignoran porque la fuente es solo Google Health."
                      : "Incluye \(Int(t.otherSourceSteps).formatted()) pasos de Apple Health: pueden estar duplicados con los de Google Health.",
                      systemImage: "info.circle")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } else if model.loading || model.yesterdayLoading {
            ProgressView().frame(maxWidth: .infinity, minHeight: 240)
        } else {
            EmptyNote(text: day == .today ? "Sin datos de hoy" : "Sin datos de ayer")
        }
    }

    /// Media anchura: km de la hora y línea por horas.
    private func distanceCard(_ t: TodayMetrics) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            MiniHeader(icon: "location.fill", title: "Distancia", color: Theme.steps, chevron: false)
            BigValue(value: String(format: "%.2f", t.distanceKm), unit: "km", size: 30)
            DayTrendChart(points: t.hourlyDistance, domain: t.dayDomain, color: Theme.steps,
                          format: { String(format: "%.2f km", $0) }).frame(height: 110)
            Text("por hora").font(.caption).foregroundStyle(.secondary)
        }.miniCard()
    }

    /// Media anchura: calorías del día y barras de los últimos 7 días (el día elegido, resaltado).
    private func caloriesCard(_ k: Double) -> some View {
        let cal = Calendar.current
        let target = cal.date(byAdding: .day, value: day == .today ? 0 : -1, to: cal.startOfDay(for: Date()))!
        let from = cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: Date()))!
        let bars = (model.history?.days ?? []).filter { $0.day >= from && $0.calories != nil }
        let picked = selCalDay.flatMap { s in bars.first { cal.isDate($0.day, inSameDayAs: s) } }
        return VStack(alignment: .leading, spacing: 8) {
            MiniHeader(icon: "flame.fill", title: "Calorías", color: Theme.calories,
                       trailing: "\(Int((k / Double(max(caloriesGoal, 1)) * 100).rounded())) %", chevron: false)
            BigValue(value: Int(k.rounded()).formatted(), unit: "kcal", size: 30)
            Chart {
                ForEach(bars) { d in
                    BarMark(x: .value("Día", d.day, unit: .day), y: .value("kcal", d.calories ?? 0))
                        .foregroundStyle(Theme.calories.opacity(picked.map { cal.isDate($0.day, inSameDayAs: d.day) ? 1 : 0.35 } ?? (cal.isDate(d.day, inSameDayAs: target) ? 1 : 0.35))).cornerRadius(2)
                }
                RuleMark(y: .value("Objetivo", Double(caloriesGoal))).foregroundStyle(Color.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                if let p = picked {
                    RuleMark(x: .value("Día", p.day.addingTimeInterval(43200))).foregroundStyle(Color.clear)
                        .annotation(position: .top, spacing: 4, overflowResolution: Self.bubbleOverflow) {
                            ScrubBubble(title: p.day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(esES)),
                                        value: "\(Int((p.calories ?? 0).rounded()).formatted()) kcal", color: Theme.calories)
                        }
                }
            }
            .chartXSelection(value: $selCalDay)
            .chartXScale(domain: from...from.addingTimeInterval(7 * 86400))
            .chartYScale(domain: 0...max(Double(caloriesGoal), bars.compactMap(\.calories).max() ?? 0) * 1.1)
            .chartXAxis { AxisMarks(values: .stride(by: .day)) { v in
                AxisValueLabel { if let d = v.as(Date.self) { Text(String(esCalendar.shortWeekdaySymbols[esCalendar.component(.weekday, from: d) - 1].prefix(1)).uppercased()).font(.caption2) } }
            } }
            .chartYAxis(.hidden)
            .frame(height: 110)
            Text("objetivo \(caloriesGoal.formatted()) kcal").font(.caption).foregroundStyle(.secondary)
        }.miniCard()
    }

    /// Media anchura: pasos acumulados de hoy sobre los de ayer a la misma hora.
    private func vsYesterdayCard(_ t: TodayMetrics, _ y: TodayMetrics) -> some View {
        let cal = Calendar.current
        let ys = y.cumulative.map { CumPoint(time: cal.date(byAdding: .day, value: 1, to: $0.time)!, value: $0.value) }
        let ts = t.cumulative
        let now = ts.last?.time ?? Date()
        let diff = Int(((ts.last?.value ?? t.steps) - (ys.last { $0.time <= now }?.value ?? 0)).rounded())
        return VStack(alignment: .leading, spacing: 8) {
            MiniHeader(icon: "chart.line.uptrend.xyaxis", title: "Frente a ayer", color: Theme.steps, chevron: false)
            BigValue(value: diff == 0 ? "0" : "\(diff > 0 ? "+" : "−")\(abs(diff).formatted())", unit: "pasos", size: 30)
            Chart {
                ForEach(ys) { p in
                    LineMark(x: .value("Hora", p.time), y: .value("Pasos", p.value), series: .value("Día", "Ayer"))
                        .foregroundStyle(Color.secondary.opacity(0.7)).lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3])).interpolationMethod(.monotone)
                }
                ForEach(ts) { p in
                    AreaMark(x: .value("Hora", p.time), y: .value("Pasos", p.value), series: .value("Día", "Hoy"))
                        .foregroundStyle(Theme.steps.opacity(0.16)).interpolationMethod(.monotone)
                    LineMark(x: .value("Hora", p.time), y: .value("Pasos", p.value), series: .value("Día", "Hoy"))
                        .foregroundStyle(Theme.steps).lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round)).interpolationMethod(.monotone)
                }
                if let p = closest(ts, to: selCum, { $0.time }) {
                    RuleMark(x: .value("Hora", p.time)).foregroundStyle(Color.secondary.opacity(0.5))
                        .annotation(position: .top, spacing: 4, overflowResolution: Self.bubbleOverflow) {
                            ScrubBubble(title: p.time.formatted(.dateTime.hour().minute().locale(esES)),
                                        value: "\(Int(p.value.rounded()).formatted()) hoy",
                                        detail: "\(Int((closest(ys, to: p.time, { $0.time })?.value ?? 0).rounded()).formatted()) ayer", color: Theme.steps)
                        }
                }
            }
            .chartXSelection(value: $selCum)
            .chartXScale(domain: t.midnight...t.midnight.addingTimeInterval(24 * 3600))
            .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 12)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour().locale(esES)) } }
            .chartYAxis(.hidden)
            .frame(height: 110)
            HStack(spacing: 14) {
                Label("Hoy", systemImage: "circle.fill").foregroundStyle(Theme.steps)
                Label("Ayer", systemImage: "circle.fill").foregroundStyle(.secondary)
            }.font(.caption).labelStyle(LegendLabelStyle())
        }.miniCard()
    }

    /// Pasos de cada hora del día: en color las que llegan a `activeHourSteps` (horas activas), con el umbral punteado.
    /// `half` es la versión de media anchura, para ir junto a «Frente a ayer».
    private func activeHoursCard(_ t: TodayMetrics, half: Bool) -> some View {
        let cal = Calendar.current
        let byHour = Dictionary(t.hourlySteps.map { (cal.component(.hour, from: $0.hour), $0.steps) }, uniquingKeysWith: +)
        let active = Set((0..<24).filter { (byHour[$0] ?? 0) >= Self.activeHourSteps })
        let now = cal.component(.hour, from: Date())
        let isToday = day == .today
        let top = max(byHour.values.max() ?? 0, Self.activeHourSteps * 1.5)
        let count = "\(active.count) \(active.count == 1 ? "hora" : "horas")"
        // Eje de fechas (una barra por hora), como la gráfica de calorías: con enteros y `width: .ratio` no llegaban a pintarse barras.
        let hours = (0..<24).map { (h: $0, at: cal.date(byAdding: .hour, value: $0, to: t.midnight)!) }
        let chart = Chart {
            ForEach(hours, id: \.h) { x in
                BarMark(x: .value("Hora", x.at, unit: .hour), y: .value("Pasos", byHour[x.h] ?? 0))
                    .foregroundStyle(active.contains(x.h) ? Theme.steps : Color.secondary.opacity(isToday && x.h > now ? 0.12 : 0.35)).cornerRadius(2)
            }
            RuleMark(y: .value("Umbral", Self.activeHourSteps)).foregroundStyle(Color.secondary.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            if let sel = selHourAt {
                let h = min(max(cal.component(.hour, from: sel), 0), 23)
                RuleMark(x: .value("Hora", hours[h].at.addingTimeInterval(1800))).foregroundStyle(Color.secondary.opacity(0.5))
                    .annotation(position: .top, spacing: 4, overflowResolution: Self.bubbleOverflow) {
                        ScrubBubble(title: String(format: "%02d:00–%02d:00", h, (h + 1) % 24), value: "\(Int((byHour[h] ?? 0).rounded()).formatted()) pasos",
                                    detail: active.contains(h) ? "hora activa" : nil, color: Theme.steps)
                    }
            }
        }
        .chartXSelection(value: $selHourAt)
        .chartXScale(domain: t.midnight...t.midnight.addingTimeInterval(24 * 3600))
        .chartYScale(domain: 0...(top * 1.1))
        .chartYAxis(.hidden)
        .chartXAxis { AxisMarks(values: .stride(by: .hour, count: half ? 12 : 6)) { _ in
            AxisValueLabel(format: .dateTime.hour(.twoDigits(amPM: .omitted)).locale(esES))
        } }
        let note = Text("Una hora cuenta con \(Int(Self.activeHourSteps)) pasos o más.").font(.caption).foregroundStyle(.secondary)
        return Group {
            if half {
                VStack(alignment: .leading, spacing: 8) {
                    MiniHeader(icon: "clock.fill", title: "Horas activas", color: Theme.steps, chevron: false)
                    BigValue(value: "\(active.count)", unit: active.count == 1 ? "hora" : "horas", size: 30)
                    chart.frame(height: 110)
                    note
                }.miniCard()
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    CardHeader(icon: "clock.fill", title: "Horas activas", color: Theme.steps, trailing: count, chevron: false)
                    chart.frame(height: 90)
                    note
                }.card()
            }
        }
    }

    /// Días del periodo con el objetivo de pasos cumplido, y rachas (la actual se cuenta sobre todo el histórico que haya).
    private func goalCard(days: [DayStat]) -> some View {
        let cal = Calendar.current
        let goal = Double(stepsGoal)
        // Hoy solo cuenta si ya se ha cumplido: un día sin acabar no puede ser un fallo.
        let closed = days.filter { !cal.isDateInToday($0.day) || ($0.steps ?? 0) >= goal }
        let hit = closed.filter { ($0.steps ?? 0) >= goal }.count
        let all = (model.history(for: .year) ?? model.history(for: .month))?.days.filter { $0.steps != nil && (!cal.isDateInToday($0.day) || ($0.steps ?? 0) >= goal) } ?? closed
        var current = 0
        for d in all.reversed() { if (d.steps ?? 0) >= goal { current += 1 } else { break } }
        var best = 0, run = 0
        for d in closed { if (d.steps ?? 0) >= goal { run += 1; best = max(best, run) } else { run = 0 } }
        return VStack(alignment: .leading, spacing: 12) {
            CardHeader(icon: "target", title: "Objetivo de pasos", color: Theme.steps, trailing: "\(stepsGoal.formatted()) al día", chevron: false)
            HStack {
                StatCell(title: "Días cumplido", value: "\(hit) de \(closed.count)")
                StatCell(title: "Racha actual", value: "\(current) \(current == 1 ? "día" : "días")")
                StatCell(title: "Mejor racha", value: "\(best) \(best == 1 ? "día" : "días")")
            }
        }.card()
    }

    /// Media diaria de pasos frente a la de los mismos días justo antes del periodo. Hoy no cuenta (está a medias).
    private func comparison(days: [DayStat]) -> (pct: Double, prev: Double)? {
        let cal = Calendar.current
        guard let first = days.first?.day else { return nil }
        let cur = days.filter { !cal.isDateInToday($0.day) }.compactMap(\.steps)
        let from = cal.date(byAdding: .day, value: -range.days, to: first)!
        let prev = (model.longHistory ?? model.history)?.days.filter { $0.day >= from && $0.day < first }.compactMap(\.steps) ?? []
        // Con menos de la mitad del periodo anterior descargado la media no es comparable.
        guard !cur.isEmpty, prev.count >= max(range.days / 2, 3) else { return nil }
        let p = prev.reduce(0, +) / Double(prev.count)
        guard p > 0 else { return nil }
        return ((cur.reduce(0, +) / Double(cur.count) - p) / p, p)
    }

    /// Media de pasos de cada día de la semana en el periodo (lunes primero), con el más activo resaltado.
    @ViewBuilder
    private func weekdayCard(days: [DayStat]) -> some View {
        let closed = days.filter { !Calendar.current.isDateInToday($0.day) && $0.steps != nil }
        if closed.count >= 14 {
            let order = [2, 3, 4, 5, 6, 7, 1]
            let byDay = Dictionary(grouping: closed) { esCalendar.component(.weekday, from: $0.day) }
            let avg: [Double] = order.map { w in
                let v = (byDay[w] ?? []).compactMap(\.steps)
                return v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count)
            }
            let top = avg.indices.max { avg[$0] < avg[$1] }!
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(icon: "calendar", title: "Por día de la semana", color: Theme.steps,
                           trailing: "más activo: \(esCalendar.weekdaySymbols[order[top] - 1])", chevron: false)
                // Eje de fechas (lunes a domingo de una semana cualquiera), como las demás barras: con enteros y `width: .ratio` no llegaban a pintarse.
                let monday = esCalendar.dateInterval(of: .weekOfYear, for: Date())!.start
                let dates = avg.indices.map { esCalendar.date(byAdding: .day, value: $0, to: monday)! }
                Chart {
                    ForEach(avg.indices, id: \.self) { i in
                        BarMark(x: .value("Día", dates[i], unit: .day), y: .value("Pasos", avg[i]))
                            .foregroundStyle(Theme.steps.opacity(i == top ? 1 : 0.4)).cornerRadius(3)
                    }
                    RuleMark(y: .value("Objetivo", Double(stepsGoal))).foregroundStyle(Color.secondary.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    if let sel = selWeekdayAt {
                        let i = min(max(esCalendar.dateComponents([.day], from: monday, to: sel).day ?? 0, 0), 6)
                        RuleMark(x: .value("Día", dates[i].addingTimeInterval(43200))).foregroundStyle(Color.secondary.opacity(0.5))
                            .annotation(position: .top, spacing: 4, overflowResolution: Self.bubbleOverflow) {
                                ScrubBubble(title: esCalendar.weekdaySymbols[order[i] - 1].capitalized, value: "\(Int(avg[i].rounded()).formatted()) pasos",
                                            detail: "\((byDay[order[i]] ?? []).count) días", color: Theme.steps)
                            }
                    }
                }
                .chartXSelection(value: $selWeekdayAt)
                .chartXScale(domain: monday...esCalendar.date(byAdding: .day, value: 7, to: monday)!)
                .chartYScale(domain: 0...max(Double(stepsGoal), avg.max() ?? 0) * 1.1)
                .chartXAxis { AxisMarks(values: .stride(by: .day)) { v in
                    AxisValueLabel { if let d = v.as(Date.self) { Text(esCalendar.veryShortWeekdaySymbols[esCalendar.component(.weekday, from: d) - 1].uppercased()).font(.caption2) } }
                } }
                .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) }
                .frame(height: 140)
                Text("Media de cada día de la semana en el periodo; la línea es tu objetivo.").font(.caption).foregroundStyle(.secondary)
            }.card()
        }
    }

    /// Récord arriba del todo, según el filtro: día → mejor día, semana → mejor semana, mes y año → mejor mes, 3 meses → mejor trimestre.
    /// Se calcula sobre todo el histórico descargado, no solo sobre el periodo elegido.
    @ViewBuilder
    private var recordCard: some View {
        let all = (model.longHistory?.days ?? []).filter { $0.steps != nil }
        if let r = record(in: all) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: "trophy.fill").font(.caption).foregroundStyle(Theme.steps)
                    Text(r.title).font(.caption.weight(.semibold)).foregroundStyle(Theme.steps)
                    Text("\(r.value) \(r.unit)").font(.caption.weight(.bold)).monospacedDigit()
                    Spacer(minLength: 4)
                    Text(r.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
                }
                if let n = r.note { Text(n).font(.caption2).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.cardStroke, lineWidth: 1) }
        }
    }

    private struct RecordInfo { let title: String, value: String, unit: String, detail: String; var note: String? }

    private func record(in all: [DayStat]) -> RecordInfo? {
        guard !all.isEmpty else { return nil }
        func best(_ comp: Calendar.Component, minDays: Int, average: Bool) -> (key: Date, value: Double)? {
            Dictionary(grouping: all) { esCalendar.dateInterval(of: comp, for: $0.day)!.start }
                .filter { $0.value.count >= minDays }
                .mapValues { g in g.compactMap(\.steps).reduce(0, +) / (average ? Double(g.count) : 1) }
                .max { $0.value < $1.value }
                .map { (key: $0.key, value: $0.value) }
        }
        func monthRecord() -> RecordInfo? {
            best(.month, minDays: 14, average: true).map {
                RecordInfo(title: "Mejor mes", value: Int($0.value.rounded()).formatted(), unit: "pasos al día",
                           detail: $0.key.formatted(.dateTime.month(.wide).year().locale(esES)).capitalized)
            }
        }
        switch range {
        case .day:
            let b = all.max { ($0.steps ?? 0) < ($1.steps ?? 0) }!
            let mine = (day == .today ? model.today : model.yesterday)?.steps ?? 0
            let top = max(b.steps ?? 0, mine)
            let isMine = mine >= (b.steps ?? 0) && mine > 0
            let when = day == .today ? "Hoy" : "Ayer"
            return RecordInfo(title: "Mejor día", value: Int(top).formatted(), unit: "pasos",
                              detail: isMine ? when : b.day.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(esES)),
                              note: mine <= 0 ? nil : isMine ? "¡\(when) es tu récord!" : "\(when) llevas el \(Int((mine / top * 100).rounded())) % de tu récord.")
        case .week:
            return best(.weekOfYear, minDays: 7, average: false).map {
                RecordInfo(title: "Mejor semana", value: Int($0.value).formatted(), unit: "pasos",
                           detail: "del \($0.key.dayMonth) · \(Int(($0.value / 7).rounded()).formatted()) al día")
            }
        case .month, .year:
            return monthRecord()
        case .quarter:
            return best(.quarter, minDays: 60, average: true).map {
                let q = (esCalendar.component(.month, from: $0.key) - 1) / 3 + 1
                return RecordInfo(title: "Mejor trimestre", value: Int($0.value.rounded()).formatted(), unit: "pasos al día",
                                  detail: "\(q).º trimestre de \(esCalendar.component(.year, from: $0.key))")
            } ?? monthRecord()
        }
    }

    // MARK: - Semana, mes, 3 meses y año

    @ViewBuilder
    private var rangeContent: some View {
        let days = range.trimmed(Array((model.history(for: range)?.days ?? []).suffix(range.days)))
        let bars = range.grouped(days)
        let withSteps = days.filter { $0.steps != nil }
        if model.history(for: range) == nil {
            if model.loading || model.longLoading { ProgressView(model.longLoading ? "Descargando hasta un año de datos…" : "").frame(maxWidth: .infinity, minHeight: 240) } else { EmptyNote(text: "El histórico no está disponible. Tira hacia abajo para reintentar.") }
        } else if withSteps.isEmpty {
            EmptyNote(text: "Sin datos en este periodo")
        } else {
            let total = withSteps.compactMap(\.steps).reduce(0, +)
            let best = withSteps.max(by: { ($0.steps ?? 0) < ($1.steps ?? 0) })
            VStack(alignment: .leading, spacing: 10) {
                Text("MEDIA DIARIA \(rangeText(days.first!.day, days.last!.day))").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                BigValue(value: Int(total / Double(withSteps.count)).formatted(), unit: "pasos")
                if let c = comparison(days: days) {
                    Label("\(abs(c.pct) < 0.005 ? "Igual" : String(format: "%@%.0f %%", c.pct > 0 ? "+" : "−", abs(c.pct) * 100)) frente a \(range == .year ? "el año anterior" : "los \(range.span) anteriores") (media \(Int(c.prev.rounded()).formatted()))",
                          systemImage: abs(c.pct) < 0.005 ? "equal" : c.pct > 0 ? "arrow.up.right" : "arrow.down.right")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                TrendChart(points: bars.compactMap { d in d.steps.map { TrendPoint(date: d.day, value: $0) } }, color: Theme.steps, range: range,
                           goal: Double(stepsGoal), format: { "\(Int($0.rounded()).formatted()) pasos" }).frame(height: 200)
                if range.unit != .day {
                    Text("Cada punto es la media diaria de \(range.unit == .month ? "ese mes" : "esa semana").").font(.caption).foregroundStyle(.secondary)
                }
            }.card()
            let dist = bars.compactMap { d in d.distanceKm.map { TrendPoint(date: d.day, value: $0) } }
            let dayDist = days.compactMap(\.distanceKm)      // la media sale de los días, no de las barras (semanas o meses de distinto tamaño)
            if !dist.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    CardHeader(icon: "location.fill", title: "Distancia · media diaria", color: Theme.steps,
                               trailing: String(format: "%.1f km", dayDist.reduce(0, +) / Double(dayDist.count)), chevron: false)
                    TrendChart(points: dist, color: Theme.steps, range: range, yStep: 1, format: { String(format: "%.2f km", $0) }).frame(height: 160)
                }.card()
            }
            let kcal = bars.compactMap { d in d.calories.map { TrendPoint(date: d.day, value: $0) } }
            if !kcal.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    CardHeader(icon: "flame.fill", title: "Calorías · media diaria", color: Theme.calories,
                               trailing: "\(Int(days.compactMap(\.calories).reduce(0, +) / Double(max(days.compactMap(\.calories).count, 1))).formatted()) kcal", chevron: false)
                    TrendChart(points: kcal, color: Theme.calories, range: range, goal: Double(caloriesGoal),
                               format: { "\(Int($0.rounded()).formatted()) kcal" }).frame(height: 160)
                }.card()
            }
            goalCard(days: withSteps)
            WorkoutsRangeCard(range: range)
            CardioLoadChartCard(range: range)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    StatCell(title: "Total", value: Int(total).formatted())
                    StatCell(title: "Distancia", value: String(format: "%.1f km", withSteps.compactMap(\.distanceKm).reduce(0, +)))
                    if days.contains(where: { $0.calories != nil }) { StatCell(title: "Calorías", value: Int(days.compactMap(\.calories).reduce(0, +)).formatted()) }
                    if days.contains(where: { $0.floors != nil }) { StatCell(title: "Pisos", value: Int(days.compactMap(\.floors).reduce(0, +)).formatted()) }
                }
                StatCell(title: "Mejor día", value: best.map { "\(Int($0.steps ?? 0).formatted()) pasos · \($0.day.dayMonth)" } ?? "—")
            }.card()
            if range.days >= 30 { weekdayCard(days: days) }
            let listTitle = range.unit == .day ? "Días" : range.unit == .month ? "Meses" : "Semanas"
            NavigationLink { ActivityLogView(title: listTitle, range: range, bars: bars) } label: {
                LogLinkRow(color: Theme.steps, detail: "\(bars.count) \(listTitle.lowercased()) · \(range.unit == .day ? "" : "media diaria · ")pasos, distancia y calorías", title: listTitle)
            }.buttonStyle(.plain)
            Text("Los totales diarios vienen de los resúmenes de Google, que no indican la fuente: se asume que son de la Air.\(range.needsLong ? " Tus datos empiezan el \(days.first!.day.formatted(.dateTime.day().month(.wide).year().locale(esES)))." : "")")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

/// Leyenda pequeña: punto de color y texto.
private struct LegendLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.icon.font(.system(size: 7)); configuration.title.foregroundStyle(.secondary) }
    }
}

/// Pasos, distancia y calorías de cada día, semana o mes del periodo (el más reciente primero).
private struct ActivityLogView: View {
    let title: String
    let range: HistRange
    let bars: [DayStat]

    var body: some View {
        List {
            Section(range.unit == .day ? "" : "Media diaria") {
                ForEach(bars.reversed()) { d in
                    HStack {
                        Text(range.bucketLabel(d.day))
                        Spacer()
                        if let k = d.calories { Text("\(Int(k.rounded()).formatted()) kcal").font(.caption).foregroundStyle(.secondary) }
                        Text(d.distanceKm.map { String(format: "%.1f km", $0) } ?? "—").font(.caption).foregroundStyle(.secondary)
                        Text(d.steps.map { Int($0).formatted() } ?? "—").font(.subheadline.monospacedDigit().weight(.semibold)).frame(width: 70, alignment: .trailing)
                    }.font(.subheadline)
                }
            }
        }
        .scrollContentBackground(.hidden).background(Theme.background)
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
    }
}

#if DEBUG
#Preview("Con datos") { ActivityView().previewScreen() }
#Preview("Sin datos") { ActivityView().previewScreen(empty: true) }
#endif
