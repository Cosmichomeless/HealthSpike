import SwiftUI
import Charts

enum VitalKind: String, CaseIterable, Hashable, Identifiable {
    case resp, spo2, rhr, hrv, temp
    var id: String { rawValue }

    var title: String {
        switch self {
        case .resp: return "Frecuencia respiratoria"
        case .spo2: return "Saturación de oxígeno"
        case .rhr: return "FC en reposo"
        case .hrv: return "Variabilidad de la FC"
        case .temp: return "Temperatura cutánea"
        }
    }
    var unit: String {
        switch self { case .resp: return "rpm"; case .spo2: return "%"; case .rhr: return "lpm"; case .hrv: return "ms"; case .temp: return "°C" }
    }
    var color: Color {
        switch self { case .resp: return Theme.rem; case .spo2: return Theme.light; case .rhr: return Theme.heart; case .hrv: return Theme.sleep; case .temp: return Theme.awake }
    }
    var short: String {
        switch self { case .resp: return "Respiración"; case .spo2: return "Oxígeno"; case .rhr: return "FC reposo"; case .hrv: return "VFC"; case .temp: return "Temperatura" }
    }
    var decimals: Int { self == .rhr || self == .hrv ? 0 : 1 }
    var signed: Bool { self == .temp }
    var info: String {
        switch self {
        case .resp: return "Respiraciones por minuto durante el sueño. En reposo suele estar entre 12 y 20."
        case .spo2: return "Porcentaje medio de oxígeno en sangre durante la noche. Lo habitual es entre 95 y 100 %."
        case .rhr: return "Pulsaciones por minuto en reposo. Baja con mejor forma física y sube con estrés, enfermedad o poco descanso."
        case .hrv: return "Variación entre latidos, en milisegundos. Es muy personal: fíjate en tu tendencia, no en el valor absoluto."
        case .temp: return "Diferencia entre la temperatura cutánea de la noche y tu valor base. Cambios mantenidos pueden coincidir con enfermedad o el ciclo hormonal."
        }
    }
    func points(_ v: Vitals?) -> [VitalPoint] {
        switch self { case .resp: return v?.resp ?? []; case .spo2: return v?.spo2 ?? []; case .rhr: return v?.rhr ?? []; case .hrv: return v?.hrv ?? []; case .temp: return v?.temp ?? [] }
    }
    func text(_ v: Double) -> String {
        let s = v.formatted(.number.precision(.fractionLength(decimals)).locale(esES))
        return signed && v > 0 ? "+" + s : s
    }
}

enum VitalStatus { case inside, outside, none }

extension VitalKind {
    /// Desviación mínima, para que una serie muy estable no marque como «fuera» variaciones diminutas.
    var minSD: Double {
        switch self { case .resp, .spo2: return 0.5; case .rhr: return 2; case .hrv: return 4; case .temp: return 0.3 }
    }

    /// Tu rango habitual: media ± 1,5 desviaciones de las 30 noches anteriores a la última (hacen falta 7).
    func baseline(_ v: Vitals?) -> (mean: Double, lo: Double, hi: Double)? {
        let prev = points(v).sorted { $0.day < $1.day }.dropLast().suffix(30).map(\.value).filter(\.isFinite)
        guard prev.count >= 7 else { return nil }
        let m = prev.reduce(0, +) / Double(prev.count)
        let sd = max((prev.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(prev.count)).squareRoot(), minSD)
        return (m, m - 1.5 * sd, m + 1.5 * sd)
    }

    /// Anoche frente a tu rango habitual. Sin dato de anoche o sin historia suficiente no cuenta como «dentro».
    func status(_ v: Vitals?) -> VitalStatus {
        let cal = Calendar.current
        guard let last = points(v).max(by: { $0.day < $1.day }),
              cal.dateComponents([.day], from: last.day, to: cal.startOfDay(for: Date())).day ?? 9 <= 1,
              let b = baseline(v) else { return .none }
        return last.value >= b.lo && last.value <= b.hi ? .inside : .outside
    }
}

/// Tarjeta de media anchura de «Sueño»: cuántas de las 5 constantes de anoche están en tu rango. Abre `VitalsView`.
struct VitalsMiniCard: View {
    let vitals: Vitals?

    var body: some View {
        let status = VitalKind.allCases.map { $0.status(vitals) }
        NavigationLink(value: Route.vitals) {
            VStack(alignment: .leading, spacing: 6) {
                MiniHeader(icon: "waveform.path.ecg", title: "Constantes vitales", color: Theme.heart)
                if vitals == nil {
                    Text("Descargando…").font(.subheadline).foregroundStyle(.secondary)
                } else {
                    BigValue(value: "\(status.filter { $0 == .inside }.count)", unit: "/ 5", size: 30)
                    Text("en tu rango anoche").font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                    HStack(spacing: 7) {
                        ForEach(Array(zip(VitalKind.allCases, status)), id: \.0) { k, s in
                            switch s {
                            case .inside: Circle().fill(k.color).frame(width: 12, height: 12)
                            case .outside: Circle().strokeBorder(k.color, lineWidth: 2).frame(width: 12, height: 12)
                            case .none: Circle().fill(Color.secondary.opacity(0.25)).frame(width: 12, height: 12)
                            }
                        }
                    }
                }
            }.miniCard()
        }.buttonStyle(.plain)
    }
}

/// Tarjeta de Hoy a ancho completo: el valor de anoche de cada constante. Punto lleno si está en tu rango habitual, hueco si no. Abre `VitalsView`.
struct VitalsTodayCard: View {
    let vitals: Vitals?

    /// Una sola línea: cinco puntos (lleno dentro de tu rango, hueco fuera, gris sin dato) y el recuento.
    var body: some View {
        let status = VitalKind.allCases.map { $0.status(vitals) }
        NavigationLink(value: Route.vitals) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg").font(.subheadline).foregroundStyle(Theme.heart)
                Text("Constantes vitales").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.heart).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                if vitals == nil {
                    Text("Descargando…").font(.caption).foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 5) {
                        ForEach(Array(zip(VitalKind.allCases, status)), id: \.0) { k, s in dot(k, s) }
                    }
                    Text("\(status.filter { $0 == .inside }.count)/5").font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.cardRadius - 2, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: Theme.cardRadius - 2, style: .continuous).strokeBorder(Theme.cardStroke, lineWidth: 1) }
        }.buttonStyle(.plain)
    }

    @ViewBuilder private func dot(_ k: VitalKind, _ s: VitalStatus) -> some View {
        switch s {
        case .inside: Circle().fill(k.color).frame(width: 10, height: 10)
        case .outside: Circle().strokeBorder(k.color, lineWidth: 2).frame(width: 10, height: 10)
        case .none: Circle().fill(Color.secondary.opacity(0.25)).frame(width: 10, height: 10)
        }
    }
}

/// Las cinco constantes vitales una debajo de otra, con un único filtro de periodo para todas las gráficas.
struct VitalsView: View {
    @EnvironmentObject var model: HealthModel
    @State private var range = HistRange.day

    /// Los datos que se descargan son de 90 días.
    private static let ranges: [HistRange] = [.day, .week, .month, .quarter]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Picker("Periodo", selection: $range) {
                    ForEach(Self.ranges) { Text($0.label(day: "Día")).tag($0) }
                }.pickerStyle(.segmented)

                if model.vitals == nil {
                    EmptyNote(text: "Descargando…")
                } else {
                    ForEach(VitalKind.allCases) { VitalChartCard(kind: $0, vitals: model.vitals, range: range) }
                    Text("Valores de la noche, calculados por Google al despertar. Día muestra la última semana y compara la última noche con tu rango; Semana, Mes y 3 meses comparan la media del periodo. La banda es tu rango habitual: la media de tus 30 noches anteriores ± 1,5 desviaciones; estar dentro suma al contador de la pantalla de sueño. Las noches sin dato quedan como hueco en la línea.")
                        .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    if let at = model.vitals?.fetchedAt {
                        Text("Última descarga: \(at.formatted(.relative(presentation: .named).locale(esES)))")
                            .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 24)
        }
        .healthChrome("Constantes vitales")
        .task { await model.loadVitals() }
    }
}

private struct VitalChartCard: View {
    let kind: VitalKind
    let vitals: Vitals?
    let range: HistRange
    @State private var selected: Double?

    private let cal = Calendar.current
    /// «Día» enseña la semana que acaba hoy, para ver la última noche en contexto.
    private var days: Int { range == .day ? 7 : range.days }
    private var from: Date { cal.date(byAdding: .day, value: -(days - 1), to: cal.startOfDay(for: Date()))! }
    private var points: [VitalPoint] { kind.points(vitals).filter { $0.day >= from && $0.value.isFinite }.sorted { $0.day < $1.day } }
    /// Posición de un día en el eje: 0 = el primer día del periodo.
    private func x(_ d: Date) -> Double { Double(cal.dateComponents([.day], from: from, to: cal.startOfDay(for: d)).day ?? 0) }
    private func date(_ x: Int) -> Date { cal.date(byAdding: .day, value: x, to: from)! }
    /// Tramo de cada punto: una noche sin dato corta la línea en vez de unir los dos lados con una recta inventada.
    private var segment: [Int] {
        var n = 0
        return points.enumerated().map { i, p in
            if i > 0, x(p.day) - x(points[i - 1].day) > 1 { n += 1 }
            return n
        }
    }
    private var shown: VitalPoint? {
        guard let s = selected else { return nil }
        return points.min { abs(x($0.day) - s) < abs(x($1.day) - s) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(kind.title).font(.headline).foregroundStyle(kind.color)
                Spacer()
                badge
            }
            if points.isEmpty {
                EmptyNote(text: "Sin datos en este periodo")
            } else {
                summary
                chart.frame(height: range == .day ? 140 : 180)
            }
            Text(kind.info).font(.caption).foregroundStyle(.secondary)
        }.card()
    }

    /// Día: la última noche frente a tu rango. Semana, Mes y 3 meses: la media del periodo frente a ese mismo rango.
    private var periodStatus: VitalStatus {
        guard range != .day else { return kind.status(vitals) }
        guard !points.isEmpty, let b = kind.baseline(vitals) else { return .none }
        let avg = points.map(\.value).reduce(0, +) / Double(points.count)
        return avg >= b.lo && avg <= b.hi ? .inside : .outside
    }

    @ViewBuilder private var badge: some View {
        let avg = range != .day
        switch periodStatus {
        case .inside: Label(avg ? "Media en tu rango" : "En tu rango", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.steps)
        case .outside: Label(avg ? "Media fuera de tu rango" : "Fuera de tu rango", systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange)
        case .none: Text(avg ? "Sin rango todavía" : "Sin dato de anoche").foregroundStyle(.secondary)
        }
    }

    private var summary: some View {
        let v = points.map(\.value), last = points.last!
        let avg = v.reduce(0, +) / Double(v.count)
        return Group {
            if range == .day {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(kind.text(last.value)).font(.system(size: 34, weight: .bold)).monospacedDigit()
                    Text(kind.unit).foregroundStyle(.secondary)
                    Spacer()
                    Text(cal.isDateInToday(last.day) ? "Anoche" : last.day.formatted(.dateTime.weekday(.wide).day().month(.abbreviated).locale(esES)))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            } else {
                HStack {
                    StatCell(title: "Media", value: "\(kind.text(avg)) \(kind.unit)")
                    StatCell(title: "Mínimo", value: "\(kind.text(v.min()!)) \(kind.unit)")
                    StatCell(title: "Máximo", value: "\(kind.text(v.max()!)) \(kind.unit)")
                    StatCell(title: "Noches", value: "\(v.count)")
                }
            }
        }
    }

    private var yDomain: ClosedRange<Double> {
        let v = points.map(\.value), b = kind.baseline(vitals)
        let lo = min(v.min() ?? 0, b?.lo ?? .infinity), hi = max(v.max() ?? 1, b?.hi ?? -.infinity)
        // Una serie sin datos válidos no debe romper la gráfica con un rango invertido.
        guard lo.isFinite, hi.isFinite, lo <= hi else { return 0...1 }
        let pad = max((hi - lo) * 0.2, 0.5)
        return (lo - pad)...(hi + pad)
    }

    private var chart: some View {
        let span = Double(days)
        // Una marca cada día en la semana y cada 7 o 14 días en periodos largos.
        let step = days <= 7 ? 1 : days <= 30 ? 7 : 14
        return Chart {
            if let b = kind.baseline(vitals) {
                RectangleMark(xStart: .value("a", -0.5), xEnd: .value("b", span - 0.5), yStart: .value("min", b.lo), yEnd: .value("max", b.hi))
                    .foregroundStyle(kind.color.opacity(0.14))
            }
            ForEach(Array(points.enumerated()), id: \.element.day) { i, p in
                LineMark(x: .value("Día", x(p.day)), y: .value(kind.title, p.value), series: .value("Tramo", segment[i])).foregroundStyle(kind.color.opacity(0.6))
                    .interpolationMethod(.monotone)
                PointMark(x: .value("Día", x(p.day)), y: .value(kind.title, p.value)).foregroundStyle(kind.color)
                    .symbolSize(days <= 7 ? 60 : 22)
            }
            if let s = shown {
                RuleMark(x: .value("Día", x(s.day))).foregroundStyle(Color.secondary.opacity(0.5))
                    .annotation(position: .top, spacing: 4, overflowResolution: AnnotationOverflowResolution(x: .fit(to: .chart), y: .disabled)) {
                        ScrubBubble(title: s.day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(esES)),
                                    value: "\(kind.text(s.value)) \(kind.unit)", color: kind.color)
                    }
            }
        }
        .chartXSelection(value: $selected)
        .chartXScale(domain: -0.5...(span - 0.5))
        .chartYScale(domain: yDomain)
        .chartXAxis {
            AxisMarks(values: Array(stride(from: days - 1, through: 0, by: -step)).reversed().map { Double($0) }) { v in
                AxisGridLine()
                AxisValueLabel {
                    if let i = v.as(Double.self) {
                        let d = date(Int(i))
                        Text(days <= 7 ? d.formatted(.dateTime.weekday(.abbreviated).locale(esES)) : d.formatted(.dateTime.day().month(.abbreviated).locale(esES)))
                    }
                }
            }
        }
    }
}

/// «Minutos en zona activa» como en Google Health: minutos del día elegido, semana (desde el lunes, igual que en Hoy) frente al objetivo de 150 min y barras por zona.
struct ZoneMinutesCard: View {
    let days: [ZoneDay]?
    var day = DayChoice.today
    @AppStorage("zoneGoalWeek") private var goal = 150
    @State private var selected: Date?

    private let cal = Calendar.current
    private var weekStart: Date { esCalendar.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date() }
    private var weekDays: [ZoneDay] { days?.filter { $0.day >= weekStart } ?? [] }
    private var shown: Double {
        let d = day == .today ? Date() : cal.date(byAdding: .day, value: -1, to: Date())!
        return days?.first { cal.isDate($0.day, inSameDayAs: d) }?.total ?? 0
    }
    private var week: Double { weekDays.map(\.total).reduce(0, +) }
    private var picked: ZoneDay? { selected.flatMap { s in weekDays.first { cal.isDate($0.day, inSameDayAs: s) } } }
    private static let zoneNames = [("Quema de grasa", Theme.steps), ("Cardio", Theme.awake), ("Pico", Theme.heart)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(icon: "bolt.heart.fill", title: "Minutos en zona activa", color: Theme.awake,
                       trailing: "Esta semana", chevron: false)
            if let days {
                HStack(alignment: .firstTextBaseline, spacing: 18) {
                    VStack(alignment: .leading, spacing: 2) {
                        BigValue(value: Int(shown.rounded()).formatted(), unit: day == .today ? "min hoy" : "min ayer")
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(Int(week.rounded())) / \(goal) min").font(.headline.monospacedDigit())
                        Text("objetivo semanal").font(.caption).foregroundStyle(.secondary)
                    }
                }
                ProgressView(value: min(week / Double(max(goal, 1)), 1)).tint(Theme.awake)
                Chart {
                    ForEach(weekDays) { d in
                        ForEach(Array(zip(Self.zoneNames.indices, [d.fat, d.cardio, d.peak])), id: \.0) { i, v in
                            BarMark(x: .value("Día", d.day, unit: .day), y: .value("Min", v))
                                .foregroundStyle(by: .value("Zona", Self.zoneNames[i].0))
                                .opacity(picked == nil || picked?.day == d.day ? 1 : 0.35)
                        }
                    }
                    if let p = picked {
                        RuleMark(x: .value("Día", p.day.addingTimeInterval(43200))).foregroundStyle(Color.clear)
                            .annotation(position: .top, spacing: 4, overflowResolution: AnnotationOverflowResolution(x: .fit(to: .chart), y: .disabled)) {
                                ScrubBubble(title: p.day.formatted(.dateTime.weekday(.wide).day().month(.abbreviated).locale(esES)),
                                            value: "\(Int(p.total.rounded())) min",
                                            detail: "Grasa \(Int(p.fat)) · Cardio \(Int(p.cardio)) · Pico \(Int(p.peak))")
                            }
                    }
                }
                .chartXSelection(value: $selected)
                .chartXScale(domain: weekStart...weekStart.addingTimeInterval(7 * 86400))
                .chartForegroundStyleScale(domain: Self.zoneNames.map(\.0), range: Self.zoneNames.map(\.1))
                .chartXAxis { AxisMarks(values: .stride(by: .day)) { v in
                    AxisValueLabel { if let d = v.as(Date.self) { Text(String(esCalendar.shortWeekdaySymbols[esCalendar.component(.weekday, from: d) - 1].prefix(1)).uppercased()) } }
                } }
                .chartLegend(position: .bottom, alignment: .leading)
                .frame(height: 170)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 80)
            }
        }.card()
    }
}

/// Versión de media anchura de «Minutos en zona activa» para Hoy: minutos de hoy, semana (desde el lunes) frente al objetivo y barras por día.
struct ZoneMinutesMiniCard: View {
    let days: [ZoneDay]?
    var loading = true
    @AppStorage("zoneGoalWeek") private var goal = 150

    private var weekStart: Date { esCalendar.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date() }
    private var weekDays: [ZoneDay] { days?.filter { $0.day >= weekStart } ?? [] }
    private var today: Double { weekDays.last { esCalendar.isDateInToday($0.day) }?.total ?? 0 }
    private var week: Double { weekDays.map(\.total).reduce(0, +) }

    var body: some View {
        NavigationLink(value: Route.activity) {
            VStack(alignment: .leading, spacing: 6) {
                MiniHeader(icon: "bolt.heart.fill", title: "Zona activa", color: Theme.awake)
                if days != nil {
                    BigValue(value: Int(today.rounded()).formatted(), unit: "min hoy", size: 30)
                    Chart(weekDays) { d in
                        BarMark(x: .value("Día", d.day, unit: .day), y: .value("Min", d.total), width: .fixed(8))
                            .foregroundStyle(Theme.awake).cornerRadius(2)
                    }
                    .chartXScale(domain: weekStart...weekStart.addingTimeInterval(7 * 86400))
                    .chartXAxis(.hidden).chartYAxis(.hidden)
                    .frame(height: 56)
                    Text("\(Int(week.rounded())) de \(goal) min · \(Int((week / Double(max(goal, 1)) * 100).rounded())) % esta semana")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                } else if loading {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 80)
                } else {
                    Text("Sin datos de zona activa").font(.subheadline).foregroundStyle(.secondary)
                }
            }.miniCard()
        }.buttonStyle(.plain)
    }
}

#if DEBUG
#Preview("Tarjeta de Hoy") { VitalsTodayCard(vitals: PreviewData.vitals()).previewCard().previewEnvironment() }
#Preview("Tarjeta pequeña") { VitalsMiniCard(vitals: PreviewData.vitals()).previewCard().previewEnvironment() }
#Preview("Pantalla") { VitalsView().previewScreen() }
#Preview("Gráfica") {
    ScrollView { VStack(spacing: 16) { ForEach(VitalKind.allCases) { VitalChartCard(kind: $0, vitals: PreviewData.vitals(), range: .month) } }.padding(16) }
        .background(Color(.systemGroupedBackground)).previewEnvironment()
}
#Preview("Zona activa en Hoy") { ZoneMinutesMiniCard(days: PreviewData.zones()).previewCard().previewEnvironment() }
#Preview("Minutos en zona") { ZoneMinutesCard(days: PreviewData.zones()).previewCard().previewEnvironment() }
#endif
