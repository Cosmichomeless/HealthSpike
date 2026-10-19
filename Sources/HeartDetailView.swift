import SwiftUI

struct HeartDetailView: View {
    @EnvironmentObject var model: HealthModel
    @State private var range = HistRange.day
    @State private var day = DayChoice.today
    @AppStorage(CardioLoad.ageKey) private var age = CardioLoad.defaultAge
    /// Sin observarlo: solo el banner repinta con cada muestra del pulso.
    @Environment(\.liveHeart) private var live

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Picker("Periodo", selection: $range) {
                    ForEach(HistRange.allCases) { Text($0.label(day: "Día")).tag($0) }
                }.pickerStyle(.segmented)

                if let e = model.error { ErrorBanner(text: e) }
                if range == .day { DayChoicePicker(choice: $day); dayContent } else { rangeContent }
            }
            .padding(.horizontal, 16).padding(.bottom, 24)
        }
        .healthChrome("Frecuencia cardíaca")
        .task(id: range) { if range.needsLong { await model.loadLong() } }
        .task(id: day) { if day == .yesterday { await model.loadYesterday() } }
    }

    // MARK: - Día

    @ViewBuilder
    private var dayContent: some View {
        let maxHR = CardioLoad.maxHR(age: age)
        if day == .today { HeartLiveBanner(live: live, maxHR: maxHR) }
        if let t = day == .today ? model.today : model.yesterday, let lo = t.hrMin, let hi = t.hrMax {
            VStack(alignment: .leading, spacing: 10) {
                Text(day == .today ? "RANGO HOY" : "RANGO AYER").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                BigValue(value: "\(Int(lo))–\(Int(hi))", unit: "lpm")
                HeartDayChart(buckets: t.heartBuckets, domain: t.dayDomain, resting: t.resting?.value).frame(height: 220)
                HStack(spacing: 14) {
                    legend(Theme.heart.opacity(0.35), "mín–máx")
                    legend(Theme.heart, "media (10 min)")
                    if t.resting != nil { legend(Theme.resting, "reposo") }
                }
            }.card()
            let mins = HeartZone.minuteAverages(t.hr)
            if let lo = t.hr.min(by: { $0.value < $1.value }), let hi = t.hr.max(by: { $0.value < $1.value }) {
                HStack {
                    StatCell(title: "Mínimo · \(lo.time.hhmm)", value: "\(Int(lo.value)) lpm")
                    StatCell(title: "Pico · \(hi.time.hhmm)", value: "\(Int(hi.value)) lpm")
                    StatCell(title: "Media", value: "\(Int((mins.reduce(0, +) / Double(max(mins.count, 1))).rounded())) lpm")
                }.card()
            }
            HeartZonesCard(minutes: HeartZone.minutes(mins, maxHR: maxHR), maxHR: maxHR)
            if day == .today {
                if let rest = t.resting?.value, let b = VitalKind.rhr.baseline(model.vitals) { RestingGaugeCard(value: rest, lo: b.lo, hi: b.hi, mean: b.mean) }
                CardioLoadRow()
            }
            if let last = t.lastHR {
                Text("Última muestra a las \(last.time.hhmm) · \(last.source)").font(.footnote).foregroundStyle(.secondary)
            }
        } else if day == .today ? model.loading : model.yesterdayLoading {
            ProgressView().frame(maxWidth: .infinity, minHeight: 240)
        } else {
            EmptyNote(text: day == .today ? "Sin muestras hoy" : "Sin muestras ayer")
        }
    }

    // MARK: - Semana, mes, 3 meses y año

    @ViewBuilder
    private var rangeContent: some View {
        let days = range.trimmed(Array((model.history(for: range)?.days ?? []).suffix(range.days)))
        let withHR = days.filter { $0.hrMin != nil }
        let resting = model.resting(for: range)
        if model.history(for: range) == nil {
            if model.loading || model.longLoading { ProgressView(model.longLoading ? "Descargando hasta un año de datos…" : "").frame(maxWidth: .infinity, minHeight: 240) } else { EmptyNote(text: "El histórico no está disponible. Tira hacia abajo para reintentar.") }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if let a = withHR.first, let b = withHR.last, let lo = withHR.compactMap(\.hrMin).min(), let hi = withHR.compactMap(\.hrMax).max() {
                    Text("RANGO \(rangeText(a.day, b.day))").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    BigValue(value: "\(Int(lo))–\(Int(hi))", unit: "lpm")
                    HeartRangeChart(days: range.grouped(days), resting: range.grouped(resting: resting), range: range).frame(height: 220)
                    HStack(spacing: 14) {
                        legend(Theme.heart.opacity(0.35), "mín–máx")
                        legend(Theme.heart, "media")
                        legend(Theme.resting, "reposo")
                    }
                } else {
                    EmptyNote(text: "Sin datos en este periodo")
                }
            }.card()

            let rest = days.compactMap { d in resting[d.day].map { (d.day, $0) } }
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(icon: "heart.fill", title: "FC en reposo · \(range.span)", color: Theme.heart,
                           trailing: rest.isEmpty ? nil : "media \(Int((rest.map(\.1).reduce(0, +) / Double(rest.count)).rounded()))", chevron: false)
                if rest.isEmpty { EmptyNote(text: "Sin datos") } else { TrendChart(points: rest.map { TrendPoint(date: $0.0, value: $0.1) }, color: Theme.heart, range: range, zeroBased: false, yStep: 4,
                                                                format: { "\(Int($0.rounded())) lpm" }).frame(height: 130) }
            }.card()

            if let t = model.today {
                let avgs = withHR.compactMap(\.hrAvg)
                let restAvg = rest.isEmpty ? nil : rest.map(\.1).reduce(0, +) / Double(rest.count)
                HStack {
                    StatCell(title: "Reposo hoy", value: t.resting.map { "\(Int($0.value)) lpm" } ?? "—")
                    StatCell(title: "Reposo medio", value: restAvg.map { "\(Int($0.rounded())) lpm" } ?? "—")
                    StatCell(title: "FC media", value: avgs.isEmpty ? "—" : "\(Int((avgs.reduce(0, +) / Double(avgs.count)).rounded())) lpm")
                }.card()
            }
            Text("El histórico usa los resúmenes diarios de Google, que no indican la fuente: se asume que son de la Air.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func legend(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 5) { Circle().fill(c).frame(width: 9, height: 9); Text(t).font(.caption).foregroundStyle(.secondary) }
    }
}


// MARK: - Zonas de pulso

/// Zonas por porcentaje de la FC máxima (220 − edad), las mismas franjas que usan los relojes: por debajo del 50 % es actividad ligera.
enum HeartZone: CaseIterable {
    case light, fat, cardio, peak

    init(bpm: Double, maxHR: Double) {
        switch bpm / maxHR {
        case ..<0.5: self = .light
        case ..<0.7: self = .fat
        case ..<0.85: self = .cardio
        default: self = .peak
        }
    }

    var name: String {
        switch self { case .light: return "Ligera"; case .fat: return "Quema de grasa"; case .cardio: return "Cardio"; case .peak: return "Pico" }
    }
    var range: String {
        switch self { case .light: return "< 50 %"; case .fat: return "50–69 %"; case .cardio: return "70–84 %"; case .peak: return "≥ 85 %" }
    }
    /// Los mismos colores que la tarjeta de Zona activa.
    var color: Color {
        switch self { case .light: return Color.secondary.opacity(0.45); case .fat: return Theme.steps; case .cardio: return Theme.awake; case .peak: return Theme.heart }
    }

    /// Media de FC por cada minuto con muestras: así la densidad de muestreo no pesa en el tiempo ni en la media.
    static func minuteAverages(_ hr: [Reading]) -> [Double] {
        Dictionary(grouping: hr) { Int($0.time.timeIntervalSince1970 / 60) }.values.map { $0.map(\.value).reduce(0, +) / Double($0.count) }
    }

    static func minutes(_ averages: [Double], maxHR: Double) -> [HeartZone: Int] {
        averages.reduce(into: [:]) { $0[HeartZone(bpm: $1, maxHR: maxHR), default: 0] += 1 }
    }
}

private func hoursMinutes(_ m: Int) -> String { m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(m) min" }

/// Banner de pulso en directo: solo aparece mientras llegan muestras de la pulsera por Bluetooth.
private struct HeartLiveBanner: View {
    @ObservedObject var live: LiveHeart
    let maxHR: Double

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            if live.isLive(at: ctx.date), let bpm = live.bpm {
                let zone = HeartZone(bpm: Double(bpm), maxHR: maxHR)
                HStack(spacing: 12) {
                    Image(systemName: "heart.fill").font(.title).foregroundStyle(Theme.heart).symbolEffect(.pulse)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("EN DIRECTO").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        BigValue(value: "\(bpm)", unit: "lpm")
                    }
                    Spacer()
                    Text(zone.name).font(.subheadline.weight(.semibold)).foregroundStyle(zone == .light ? Color.secondary : zone.color)
                }.card()
            }
        }
    }
}

/// Tiempo de hoy en cada zona, de la más intensa a la más suave.
private struct HeartZonesCard: View {
    let minutes: [HeartZone: Int]
    let maxHR: Double

    var body: some View {
        let top = max(minutes.values.max() ?? 0, 1)
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(icon: "chart.bar.fill", title: "Tiempo en cada zona", color: Theme.heart, trailing: "FC máx. \(Int(maxHR))", chevron: false)
            if minutes.isEmpty {
                EmptyNote(text: "Sin datos")
            } else {
                ForEach(Array(HeartZone.allCases.reversed()), id: \.self) { z in
                    let m = minutes[z] ?? 0
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(z.name).font(.subheadline)
                            Text(z.range).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text(hoursMinutes(m)).font(.subheadline.monospacedDigit()).foregroundStyle(m == 0 ? .secondary : .primary)
                        }
                        GeometryReader { g in
                            Capsule().fill(Color.secondary.opacity(0.15))
                                .overlay(alignment: .leading) { Capsule().fill(z.color).frame(width: m == 0 ? 0 : max(6, g.size.width * Double(m) / Double(top))) }
                        }.frame(height: 6)
                    }
                }
                Text("Según el porcentaje de tu FC máxima (220 − edad, ajustable en Ajustes). Cuenta los minutos con muestras.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.card()
    }
}

// MARK: - Reposo frente a tu normal

private struct RestingGaugeCard: View {
    let value: Double, lo: Double, hi: Double, mean: Double

    var body: some View {
        let a = min(lo, value) - 3, b = max(hi, value) + 3
        let pos = { (v: Double) in (v - a) / (b - a) }
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(icon: "heart.fill", title: "Reposo frente a tu normal", color: Theme.resting, trailing: "\(Int(value.rounded())) lpm", chevron: false)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15)).frame(height: 8)
                    Capsule().fill(Theme.resting.opacity(0.45)).frame(width: g.size.width * (pos(hi) - pos(lo)), height: 8).offset(x: g.size.width * pos(lo))
                    Circle().fill(Theme.resting).overlay(Circle().stroke(.white, lineWidth: 2)).frame(width: 16, height: 16)
                        .offset(x: g.size.width * pos(value) - 8)
                }.frame(maxHeight: .infinity)
            }.frame(height: 18)
            Text(status).font(.subheadline)
            Text("Tu rango habitual: \(Int(lo.rounded()))–\(Int(hi.rounded())) lpm (media \(Int(mean.rounded()))), según tus últimas 30 noches.")
                .font(.footnote).foregroundStyle(.secondary)
        }.card()
    }

    private var status: String {
        value < lo ? "Más baja que tu rango habitual" : value > hi ? "Más alta que tu rango habitual" : "Dentro de tu rango habitual"
    }
}

#if DEBUG
#Preview("Con datos") { HeartDetailView().previewScreen() }
#Preview("Sin datos") { HeartDetailView().previewScreen(empty: true) }
#endif
