import SwiftUI
import Charts

struct SleepDetailView: View {
    @EnvironmentObject var model: HealthModel
    @AppStorage("sleepGoalHours") private var sleepGoal = 8.0
    @State private var range = HistRange.day
    @State private var day = DayChoice.today

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Picker("Periodo", selection: $range) {
                    ForEach(HistRange.allCases) { Text($0.label(day: "Noche")).tag($0) }
                }.pickerStyle(.segmented)

                if let e = model.error { ErrorBanner(text: e) }
                if range == .day { DayChoicePicker(choice: $day); nightContent } else { rangeContent }
            }
            .padding(.horizontal, 16).padding(.bottom, 24)
        }
        .healthChrome("Sueño")
        .task(id: range) { if range.needsLong { await model.loadLong() } }
        .task { await model.loadVitals() }
    }

    private var lastNight: SleepNight? { model.today?.sleep ?? model.nights.last }

    /// La noche que terminó el día anterior al de la última: así «Ayer» nunca repite la de «Hoy», aunque aún no hayas dormido hoy.
    /// La descarga de «ayer» no trae sueño, por eso sale del histórico.
    private var previousNight: SleepNight? {
        guard let last = lastNight else { return nil }
        let cal = Calendar.current
        guard let before = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: last.end)) else { return nil }
        return model.nights.last { cal.isDate($0.end, inSameDayAs: before) }
    }

    // MARK: - Noche

    @ViewBuilder
    private var nightContent: some View {
        if let n = day == .today ? lastNight : previousNight {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader(icon: "moon.fill", title: "Duración del sueño", color: Theme.sleep,
                           trailing: n.end.formatted(.dateTime.weekday(.wide).day().month(.abbreviated).locale(esES)), chevron: false)
                SleepNightContent(night: n, goalHours: sleepGoal, chartHeight: 112)
            }.card()

            if day == .today, let t = model.today, t.sleep?.end == n.end, !t.naps.isEmpty { napsCard(night: n, naps: t.naps) }

            SleepScoreCard(night: n, goalHours: sleepGoal)

            // Constantes, consejo y «Esta semana» hablan de la última noche y abren pantallas con ella: solo en «Hoy».
            if day == .today {
                HStack(alignment: .top, spacing: 12) {
                    VitalsMiniCard(vitals: model.vitals)
                    WeekSleepMiniCard(night: n)
                }.fixedSize(horizontal: false, vertical: true)

                HStack(alignment: .top, spacing: 12) {
                    BedtimeMiniCard(night: n)
                    SleepAdviceMiniCard()
                }.fixedSize(horizontal: false, vertical: true)

                ScheduleNotice(night: n)
            }
        } else if model.loading {
            ProgressView().frame(maxWidth: .infinity, minHeight: 240)
        } else {
            EmptyNote(text: day == .today ? "Sin sueño en las últimas 36 h" : "Sin sueño registrado ayer")
        }
    }

    /// Siestas del día: cada sesión con su hora y duración, y el total con la noche (como la suma que da Google).
    private func napsCard(night: SleepNight, naps: [SleepNight]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(icon: "zzz", title: naps.count == 1 ? "Siesta" : "Siestas", color: Theme.sleep,
                       trailing: "Total del día: \(hm(night.asleep + naps.map(\.asleep).reduce(0, +)))", chevron: false)
            ForEach(naps) { nap in
                HStack {
                    Text("\(nap.start.hhmm)–\(nap.end.hhmm)").font(.subheadline.monospacedDigit())
                    Spacer()
                    Text(hm(nap.asleep)).font(.subheadline.weight(.semibold).monospacedDigit())
                }
                Hypnogram(night: nap, interactive: false).frame(height: 70)
            }
            Text("La noche (\(night.start.hhmm)–\(night.end.hhmm)) es la sesión más larga; la puntuación y el resto de pantallas usan solo la noche.")
                .font(.caption).foregroundStyle(.secondary)
        }.card()
    }

    // MARK: - Semana, mes, 3 meses y año

    @ViewBuilder
    private var rangeContent: some View {
        let nights = Array(model.nights(for: range).filter { $0.end >= Calendar.current.date(byAdding: .day, value: -range.days, to: Date())! }.suffix(range.days))
        let bars = range.grouped(nights)
        if model.history(for: range) == nil {
            if model.loading || model.longLoading { ProgressView(model.longLoading ? "Descargando hasta un año de datos…" : "").frame(maxWidth: .infinity, minHeight: 240) } else { EmptyNote(text: "El histórico no está disponible. Tira hacia abajo para reintentar.") }
        } else if nights.isEmpty {
            EmptyNote(text: "Sin noches en este periodo")
        } else {
            let avg = nights.map(\.asleep).reduce(0, +) / Double(nights.count)
            VStack(alignment: .leading, spacing: 10) {
                Text("MEDIA \(rangeText(nights.first!.end, nights.last!.end))").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(Int(avg) / 60)").font(.system(size: 38, weight: .bold))
                    Text("h").foregroundStyle(.secondary)
                    Text("\(Int(avg) % 60)").font(.system(size: 38, weight: .bold))
                    Text("min").foregroundStyle(.secondary)
                }
                SleepHistoryChart(nights: bars, goalMinutes: sleepGoal * 60, range: range).frame(height: 230)
                if range.unit != .day {
                    Text("Cada barra es la media por noche de \(range.unit == .month ? "ese mes" : "esa semana").").font(.caption).foregroundStyle(.secondary)
                }
            }.card()

            VStack(alignment: .leading, spacing: 10) {
                Text(range.unit == .day ? "NOCHES" : range.unit == .month ? "MESES (MEDIA POR NOCHE)" : "SEMANAS (MEDIA POR NOCHE)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(bars.reversed()) { n in
                    HStack {
                        Text(range.bucketLabel(n.end))
                        Spacer()
                        if range.unit == .day { Text("\(n.start.hhmm) → \(n.end.hhmm)").font(.caption).foregroundStyle(.secondary) }
                        Text(hm(n.asleep)).font(.subheadline.monospacedDigit().weight(.semibold)).frame(width: 90, alignment: .trailing)
                    }.font(.subheadline)
                    if n.id != bars.first?.id { Divider() }
                }
            }.card()
        }
    }
}

/// Cuándo te acostaste y cuándo te despertaste las últimas 14 noches (arriba lo más temprano), con tu hora media de acostarte.
/// La media es la de las noches anteriores a la última, la misma con la que se puntúa la hora de acostarte.
struct BedtimeCard: View {
    @EnvironmentObject var model: HealthModel
    let night: SleepNight

    private struct Bar: Identifiable {
        let id: Date, day: Date, bed: Double, wake: Double, asleep: Double, isLast: Bool
    }
    @State private var selected: Date?

    private func clock(_ m: Double) -> String {
        let t = Int(m.rounded()) % 1440
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    var body: some View {
        let cal = Calendar.current
        let prior = Scoring.priorNights(night, model.nights)
        let shown = Array(Scoring.lastPerDay(model.nights.filter { $0.end <= night.end }).suffix(14))
        if prior.count >= 3, shown.count >= 3 {
            let mean = prior.map(Scoring.bedMinutes).reduce(0, +) / Double(prior.count)
            let bars = shown.map { n -> Bar in
                let bed = Scoring.bedMinutes(n)
                return Bar(id: n.end, day: cal.startOfDay(for: n.end), bed: bed,
                           wake: bed + n.end.timeIntervalSince(n.start) / 60, asleep: n.asleep, isLast: n.end == night.end)
            }
            let lo = (bars.map(\.bed).min()! / 120).rounded(.down) * 120
            let hi = (bars.map(\.wake).max()! / 120).rounded(.up) * 120
            let dev = Scoring.bedMinutes(night) - mean
            let sel = selected.flatMap { d in bars.min { abs($0.day.timeIntervalSince(d)) < abs($1.day.timeIntervalSince(d)) } }
            VStack(alignment: .leading, spacing: 12) {
                CardHeader(icon: "bed.double.fill", title: "Hora de acostarte", color: Theme.sleep,
                           trailing: "últimas \(bars.count) noches", chevron: false)
                Text(abs(dev) <= 30 ? "Anoche te acostaste a tu hora habitual" :
                        "Anoche te acostaste \(hm(abs(dev))) \(dev > 0 ? "más tarde" : "antes") de lo habitual")
                    .font(.subheadline.weight(.semibold))
                Chart {
                    ForEach(bars) { b in
                        RectangleMark(x: .value("Noche", b.day, unit: .day), yStart: .value("Acostarte", b.bed),
                                      yEnd: .value("Despertar", b.wake), width: .ratio(0.7))
                            .cornerRadius(4)
                            .foregroundStyle(Theme.sleep.opacity((sel.map { $0.id == b.id } ?? b.isLast) ? 1 : 0.35))
                    }
                    RuleMark(y: .value("Media", mean))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .foregroundStyle(.orange)
                        .annotation(position: .top, alignment: .trailing, spacing: 2) {
                            Text("Media \(clock(mean))").font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                        }
                    if let sel {
                        let d = sel.bed - mean
                        RuleMark(x: .value("Selección", sel.day, unit: .day))
                            .foregroundStyle(Color.secondary.opacity(0.4)).lineStyle(StrokeStyle(lineWidth: 1))
                            .annotation(position: .top, spacing: 4, overflowResolution: AnnotationOverflowResolution(x: .fit(to: .chart), y: .disabled)) {
                                ScrubBubble(title: sel.day.formatted(.dateTime.weekday(.wide).day().month(.abbreviated).locale(esES)),
                                            value: "\(clock(sel.bed)) → \(clock(sel.wake))",
                                            detail: "Dormiste \(hm(sel.asleep)) · " + (abs(d) <= 30 ? "a tu hora" : "\(hm(abs(d))) \(d > 0 ? "más tarde" : "antes")"),
                                            color: Theme.sleep)
                            }
                    }
                }
                .chartXSelection(value: $selected)
                .chartYScale(domain: .automatic(includesZero: false, reversed: true))
                .chartYAxis {
                    AxisMarks(values: Array(stride(from: lo, through: hi, by: 120))) { v in
                        AxisGridLine()
                        AxisValueLabel { if let m = v.as(Double.self) { Text(clock(m)) } }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true) }
                }
                .frame(height: 190)
                
            }.card()
        }
    }
}

/// «Esta semana»: mini gráficas de las últimas 7 noches (duración, hora de acostarte, REM, profundo y eficiencia),
/// cada una con tu rango habitual en banda: media ± 1,5 desviaciones de las 30 noches anteriores (hacen falta 7).
struct WeekSleepCard: View {
    @EnvironmentObject var model: HealthModel
    let night: SleepNight

    struct Metric: Identifiable {
        let id: String
        let color: Color
        /// Mínimo de desviación para que una serie muy estable no marque como «fuera» variaciones diminutas.
        let minSD: Double
        /// Más tarde = más abajo, como en la tarjeta de hora de acostarte.
        var flip = false
        let value: (SleepNight) -> Double
        let text: (Double) -> String
    }

    struct Point: Identifiable {
        let day: Date, offset: Double, value: Double
        var id: Date { day }
    }

    private static func efficiency(_ n: SleepNight) -> Double {
        min(n.asleep / max(n.end.timeIntervalSince(n.start) / 60, 1), 1) * 100
    }

    private static func clock(_ m: Double) -> String { hmColon(m.truncatingRemainder(dividingBy: 1440)) }

    private static let metrics = [
        Metric(id: "Duración", color: Theme.sleep, minSD: 15, value: { $0.asleep }, text: { hm($0) }),
        Metric(id: "Hora de acostarte", color: Theme.light, minSD: 15, flip: true, value: { Scoring.bedMinutes($0) }, text: { clock($0) }),
        Metric(id: "REM", color: Theme.rem, minSD: 8, value: { $0.minutes["REM"] ?? 0 }, text: { hm($0) }),
        Metric(id: "Sueño profundo", color: Theme.deep, minSD: 8, value: { $0.minutes["DEEP"] ?? 0 }, text: { hm($0) }),
        Metric(id: "Eficiencia", color: .green, minSD: 1.5, value: { efficiency($0) }, text: { "\(Int($0.rounded())) %" }),
    ]

    /// Las cinco series de la semana que acaba en `night`, con su banda habitual (nil si hay menos de 7 noches de base).
    static func rows(_ nights: [SleepNight], night: SleepNight) -> [(metric: Metric, points: [Point], band: (lo: Double, hi: Double)?)] {
        let cal = Calendar.current
        let all = Scoring.lastPerDay(nights.filter { $0.end <= night.end })
        let lastDay = cal.startOfDay(for: night.end)
        let week = all.filter { (cal.dateComponents([.day], from: cal.startOfDay(for: $0.end), to: lastDay).day ?? 99) < 7 }
        guard week.count >= 2 else { return [] }
        return metrics.map { m in
            let pts = week.map { n in
                Point(day: cal.startOfDay(for: n.end),
                      offset: Double(cal.dateComponents([.day], from: cal.startOfDay(for: n.end), to: lastDay).day ?? 0) * -1,
                      value: m.value(n))
            }
            return (m, pts, band(all.dropLast().suffix(30).map(m.value), minSD: m.minSD))
        }
    }

    /// `true` dentro de tu rango, `false` fuera y `nil` sin banda o sin dato de anoche.
    static func status(_ row: (metric: Metric, points: [Point], band: (lo: Double, hi: Double)?), lastDay: Date) -> Bool? {
        guard let band = row.band, let last = row.points.last, last.day == lastDay else { return nil }
        return last.value >= band.lo && last.value <= band.hi
    }

    var body: some View {
        let lastDay = Calendar.current.startOfDay(for: night.end)
        let rows = Self.rows(model.nights, night: night)
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                CardHeader(icon: "calendar", title: "Esta semana", color: Theme.sleep, trailing: "últimos 7 días", chevron: false)
                ForEach(Array(rows.enumerated()), id: \.element.metric.id) { i, r in
                    if i > 0 { Divider() }
                    WeekMetricRow(metric: r.metric, points: r.points, band: r.band, lastDay: lastDay, showDays: i == rows.count - 1)
                }
                Text("La banda es tu rango habitual: la media de tus 30 noches anteriores ± 1,5 desviaciones. Desliza el dedo por una gráfica para ver cada noche.")
                    .font(.footnote).foregroundStyle(.secondary)
            }.card()
        }
    }

    fileprivate static func band(_ v: [Double], minSD: Double) -> (lo: Double, hi: Double)? {
        guard v.count >= 7 else { return nil }
        let mean = v.reduce(0, +) / Double(v.count)
        let sd = max((v.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(v.count)).squareRoot(), minSD)
        return (mean - 1.5 * sd, mean + 1.5 * sd)
    }
}

private struct WeekMetricRow: View {
    let metric: WeekSleepCard.Metric
    let points: [WeekSleepCard.Point]
    let band: (lo: Double, hi: Double)?
    let lastDay: Date
    let showDays: Bool
    @State private var selected: Double?

    private var shown: WeekSleepCard.Point? {
        guard let last = points.last else { return nil }
        guard let s = selected else { return last }
        return points.min { abs($0.offset - s) < abs($1.offset - s) } ?? last
    }

    private func y(_ v: Double) -> Double { metric.flip ? -v : v }

    private var yDomain: ClosedRange<Double> {
        let v = points.map { y($0.value) } + (band.map { [y($0.lo), y($0.hi)] } ?? [])
        let lo = v.min() ?? 0, hi = v.max() ?? 1
        let pad = max((hi - lo) * 0.15, 0.5)
        return (lo - pad)...(hi + pad)
    }

    var body: some View {
        let s = shown
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(metric.id).font(.subheadline.weight(.semibold)).foregroundStyle(metric.color)
                Spacer()
                if let s {
                    Text(metric.text(s.value)).font(.subheadline.weight(.bold).monospacedDigit())
                    Text(s.day == lastDay && selected == nil ? "Anoche" : s.day.formatted(.dateTime.weekday(.abbreviated).locale(esES)))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let band, let last = points.last {
                let inside = last.value >= band.lo && last.value <= band.hi
                Label(inside ? "En tu rango" : "Fuera de tu rango", systemImage: inside ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.caption).foregroundStyle(inside ? Theme.steps : .orange)
            }
            Chart {
                if let band {
                    RectangleMark(xStart: .value("a", -6.5), xEnd: .value("b", 0.5), yStart: .value("min", y(band.lo)), yEnd: .value("max", y(band.hi)))
                        .foregroundStyle(metric.color.opacity(0.14))
                }
                ForEach(points) { p in
                    LineMark(x: .value("Día", p.offset), y: .value(metric.id, y(p.value))).foregroundStyle(metric.color.opacity(0.6))
                        .interpolationMethod(.monotone)
                    PointMark(x: .value("Día", p.offset), y: .value(metric.id, y(p.value))).foregroundStyle(metric.color)
                        .symbolSize(p.id == s?.id ? 90 : 36)
                }
                if selected != nil, let s {
                    RuleMark(x: .value("Día", s.offset)).foregroundStyle(Color.secondary.opacity(0.5))
                }
            }
            .chartXSelection(value: $selected)
            .chartXScale(domain: -6.5...0.5)
            .chartYScale(domain: yDomain)
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks(values: points.map(\.offset)) { v in
                    AxisGridLine()
                    if showDays {
                        AxisValueLabel {
                            if let o = v.as(Double.self), let d = Calendar.current.date(byAdding: .day, value: Int(o), to: lastDay) {
                                Text(d.formatted(.dateTime.weekday(.narrow).locale(esES)))
                            }
                        }
                    }
                }
            }
            .frame(height: showDays ? 84 : 64)
        }
    }
}

/// Tarjeta de media anchura: hora a la que te acostaste anoche frente a tu media. Abre `BedtimeView`.
struct BedtimeMiniCard: View {
    @EnvironmentObject var model: HealthModel
    let night: SleepNight

    var body: some View {
        let prior = Scoring.priorNights(night, model.nights)
        NavigationLink(value: Route.bedtime) {
            VStack(alignment: .leading, spacing: 6) {
                MiniHeader(icon: "clock.fill", title: "Hora de acostarte", color: Theme.sleep)
                if prior.count >= 3 {
                    let mean = prior.map(Scoring.bedMinutes).reduce(0, +) / Double(prior.count)
                    let dev = Scoring.bedMinutes(night) - mean
                    BigValue(value: night.start.hhmm, unit: "", size: 30)
                    Text(abs(dev) <= 30 ? "a tu hora habitual" : "\(hm(abs(dev))) \(dev > 0 ? "más tarde" : "antes") de tu media")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                    let recent = Scoring.lastPerDay(model.nights.filter { $0.end <= night.end }).suffix(14)
                    Chart {
                        RuleMark(y: .value("Media", -mean)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 2])).foregroundStyle(.orange)
                        ForEach(Array(recent), id: \.id) { n in
                            LineMark(x: .value("Noche", n.end), y: .value("Acostarte", -Scoring.bedMinutes(n)))
                                .foregroundStyle(Theme.sleep.opacity(0.5)).interpolationMethod(.monotone)
                                .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                            PointMark(x: .value("Noche", n.end), y: .value("Acostarte", -Scoring.bedMinutes(n)))
                                .symbolSize(n.end == night.end ? 40 : 16).foregroundStyle(Theme.sleep.opacity(n.end == night.end ? 1 : 0.5))
                        }
                    }
                    .chartXAxis(.hidden).chartYAxis(.hidden).chartYScale(domain: .automatic(includesZero: false))
                    .frame(height: 30).allowsHitTesting(false)
                } else {
                    Text("Hacen falta más noches registradas").font(.subheadline).foregroundStyle(.secondary)
                }
            }.miniCard()
        }.buttonStyle(.plain)
    }
}

/// Tarjeta de media anchura: cuántas de las cinco medidas de anoche caen en tu rango. Abre `SleepWeekView`.
struct WeekSleepMiniCard: View {
    @EnvironmentObject var model: HealthModel
    let night: SleepNight

    var body: some View {
        let lastDay = Calendar.current.startOfDay(for: night.end)
        let rows = WeekSleepCard.rows(model.nights, night: night)
        let status = rows.map { WeekSleepCard.status($0, lastDay: lastDay) }
        NavigationLink(value: Route.sleepWeek) {
            VStack(alignment: .leading, spacing: 6) {
                MiniHeader(icon: "calendar", title: "Esta semana", color: Theme.sleep)
                if rows.isEmpty {
                    Text("Hacen falta más noches registradas").font(.subheadline).foregroundStyle(.secondary)
                } else {
                    BigValue(value: "\(status.filter { $0 == true }.count)", unit: "/ \(rows.count)", size: 30)
                    Text("en tu rango anoche").font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                    HStack(spacing: 7) {
                        ForEach(Array(zip(rows, status)), id: \.0.metric.id) { r, s in
                            switch s {
                            case true?: Circle().fill(r.metric.color).frame(width: 12, height: 12)
                            case false?: Circle().strokeBorder(r.metric.color, lineWidth: 2).frame(width: 12, height: 12)
                            case nil: Circle().fill(Color.secondary.opacity(0.25)).frame(width: 12, height: 12)
                            }
                        }
                    }
                }
            }.miniCard()
        }.buttonStyle(.plain)
    }
}

/// Hora de acostarte a pantalla completa.
struct BedtimeView: View {
    @EnvironmentObject var model: HealthModel

    var body: some View {
        ScrollView {
            if let n = model.today?.sleep ?? model.nights.last {
                BedtimeCard(night: n).padding(.horizontal, 16).padding(.bottom, 24)
            } else {
                EmptyNote(text: "Sin sueño registrado").padding(.horizontal, 16)
            }
        }
        .healthChrome("Hora de acostarte")
    }
}

/// «Esta semana» a pantalla completa.
struct SleepWeekView: View {
    @EnvironmentObject var model: HealthModel

    var body: some View {
        ScrollView {
            if let n = model.today?.sleep ?? model.nights.last {
                WeekSleepCard(night: n).padding(.horizontal, 16).padding(.bottom, 24)
            } else {
                EmptyNote(text: "Sin sueño registrado").padding(.horizontal, 16)
            }
        }
        .healthChrome("Esta semana")
    }
}

/// Aviso cuando el horario cambió mucho en la última semana: diferencia entre la hora más temprana y la más tardía de despertar
/// y de acostarte en las últimas 7 noches (desde 1 h). Si todo estuvo estable no se muestra nada.
struct ScheduleNotice: View {
    @EnvironmentObject var model: HealthModel
    let night: SleepNight

    /// Variación mínima, en minutos, para avisar.
    private static let threshold = 60.0

    private func wakeMinutes(_ n: SleepNight) -> Double {
        let c = Calendar.current.dateComponents([.hour, .minute], from: n.end)
        return Double((c.hour ?? 0) * 60 + (c.minute ?? 0))
    }

    private func clock(_ m: Double) -> String { hmColon(m.truncatingRemainder(dividingBy: 1440)) }

    var body: some View {
        let cal = Calendar.current
        let lastDay = cal.startOfDay(for: night.end)
        let week = Scoring.lastPerDay(model.nights.filter { $0.end <= night.end })
            .filter { (cal.dateComponents([.day], from: cal.startOfDay(for: $0.end), to: lastDay).day ?? 99) < 7 }
        let notes = week.count >= 4 ? [("despertaste", week.map(wakeMinutes)), ("te acostaste", week.map(Scoring.bedMinutes))]
            .compactMap { (verb, v) -> String? in
                guard let lo = v.min(), let hi = v.max(), hi - lo >= Self.threshold else { return nil }
                return "La hora a la que \(verb) varió \(hm(hi - lo)) esta semana (de \(clock(lo)) a \(clock(hi)))"
            } : []
        if !notes.isEmpty {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "clock.badge.exclamationmark.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(notes, id: \.self) { Text($0).font(.subheadline.weight(.semibold)).foregroundStyle(.orange) }
                    Text("Un horario regular ayuda a dormir mejor.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

#if DEBUG
#Preview("Con datos") { SleepDetailView().previewScreen() }
#Preview("Sin datos") { SleepDetailView().previewScreen(empty: true) }
#Preview("Tarjetas pequeñas") {
    HStack(alignment: .top, spacing: 12) { WeekSleepMiniCard(night: PreviewData.night()); BedtimeMiniCard(night: PreviewData.night()) }
        .fixedSize(horizontal: false, vertical: true).previewCard().previewScreen()
}
#Preview("Pantalla hora de acostarte") { BedtimeView().previewScreen() }
#Preview("Pantalla esta semana") { SleepWeekView().previewScreen() }
/// Pulso de la noche: mínimo, media y máximo, y la misma gráfica que la de frecuencia cardiaca (banda mín–máx y media cada 10 min) entre acostarte y despertar.
struct NightHeartRow: View {
    let night: SleepNight
    @EnvironmentObject private var model: HealthModel
    @State private var readings: [Reading]?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "heart.fill").foregroundStyle(Theme.heart)
                Text("Pulso durante la noche")
            }.font(.subheadline)
            if let r = readings {
                let pts = model.airOnly ? r.filter(\.isAir) : r
                if pts.count < 10 { Text("Sin pulso suficiente esta noche").font(.footnote).foregroundStyle(.secondary) }
                else { content(pts) }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 60)
            }
        }
        .task(id: night.end) { readings = await model.nightHeart(night) }
    }

    @ViewBuilder
    private func content(_ pts: [Reading]) -> some View {
        let values = pts.map(\.value)
        HStack {
            stat("Mínimo", values.min() ?? 0)
            Spacer()
            stat("Media", values.reduce(0, +) / Double(values.count))
            Spacer()
            stat("Máximo", values.max() ?? 0)
        }
        HeartDayChart(buckets: Self.buckets(pts), domain: night.start...night.end).frame(height: 160)
    }

    /// Muestras agrupadas en tramos de 10 min (mín/máx/media), como en la gráfica del día.
    private static func buckets(_ pts: [Reading]) -> [HRBucket] {
        let width = 600.0
        let groups = Dictionary(grouping: pts) { Int($0.time.timeIntervalSinceReferenceDate / width) }
        return groups.map { key, items in
            let vals = items.map(\.value)
            return HRBucket(time: Date(timeIntervalSinceReferenceDate: Double(key) * width + width / 2),
                            min: vals.min() ?? 0, max: vals.max() ?? 0, avg: vals.reduce(0, +) / Double(vals.count))
        }.sorted { $0.time < $1.time }
    }

    private func stat(_ t: String, _ v: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(t).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(Int(v.rounded()))").font(.title3.weight(.semibold).monospacedDigit())
                Text("lpm").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

#Preview("Pulso nocturno") { NightHeartRow(night: PreviewData.night()).padding(16).previewEnvironment() }
#Preview("Aviso de horario") { ScheduleNotice(night: PreviewData.night()).previewEnvironment().previewCard() }
#Preview("Esta semana") { WeekSleepCard(night: PreviewData.night()).previewEnvironment().previewCard() }
#Preview("Hora de acostarte") { BedtimeCard(night: PreviewData.night()).previewEnvironment().previewCard() }
#endif
