import SwiftUI
import Charts

// MARK: - Carga cardiovascular
//
// Google la calcula con la FC de todo el día (tipo TRIMP) y no la expone en la API. Aquí se estima igual: la API sí da la media
// de FC por minuto (`dataPoints:rollUp`, ventanas de 60 s) y cada minuto suma según lo alta que esté la FC dentro de tu reserva
// cardíaca (FC reposo → FC máx.). FC máx. = 220 − edad (Ajustes).
// Calibrado con 9 días reales de Google (3–11 oct 2026: 16, 33, 11, 6, 6, 45, 58, 50, 21); hoy, 13 oct a las 19:41, marcaba 11 y el modelo 9,3: un TRIMP de Banister
// sin umbral da 3–5 veces más porque cuenta el pulso de reposo. Google solo suma por encima de ~23 % de la reserva y de forma
// cuadrática; con FC máx. 197 (23 años), reposo 63 y carga = 23·Σ max(0, reserva − 0,23)² por minuto se reproduce cada día con
// ~16 % de error (la semana 5–11 oct da ~185 frente a 197). Reajustar umbral y exponente no mejora el error. Con el pulso sin
// agrupar (una muestra cada ~2 s) sale solo ~10 % más que con la media por minuto, así que esta aproximación basta.
// OJO al comparar con la app de Google: el número grande que ve uno al abrir su pantalla de hoy puede ser el acumulado semanal.

struct LoadDay: Identifiable {
    let day: Date
    let value: Double
    var id: Date { day }
}

enum CardioLoad {
    static let ageKey = "userAge"
    static let goalKey = "cardioLoadGoal"      // 0 = automático
    static let defaultAge = 23
    /// A partir de este múltiplo del objetivo semanal se avisa de sobreentrenamiento.
    static let overtrain = 1.5

    static func maxHR(age: Int) -> Double { Double(220 - age) }

    static let threshold = 0.23    // fracción de la reserva cardíaca por debajo de la cual no suma
    static let scale = 23.0

    /// Carga de un día: por minuto, escala · max(0, reserva − umbral)², con la reserva (FC − reposo)/(máx − reposo) entre 0 y 1,2.
    static func load(_ d: HRDay, rest: Double, maxHR: Double) -> Double {
        let reserve = max(maxHR - rest, 1)
        return scale * d.minutes.reduce(0) { acc, kv in
            let x = min((Double(kv.key) - rest) / reserve, 1.2) - threshold
            return x > 0 ? acc + kv.value * x * x : acc
        }
    }

    /// Suma de los últimos `days` días (el último elemento es hoy).
    static func sum(_ l: [LoadDay], days: Int) -> Double { l.suffix(days).map(\.value).reduce(0, +) }

    /// Objetivo semanal: el de Ajustes o, en automático, lo acumulado en los 7 días completos anteriores a hoy +10 % (mínimo 165, el
    /// más bajo que ha dado Google). Con la escala actual da 214 donde Google dio 215 la semana del 12 oct.
    static func weeklyGoal(setting: Int, loads: [LoadDay]) -> Double {
        if setting > 0 { return Double(setting) }
        let recent = loads.dropLast().suffix(7).filter { $0.value > 0 }
        guard recent.count >= 5 else { return 165 }
        let weekly = recent.map(\.value).reduce(0, +) / Double(recent.count) * 7
        return max(165, (weekly * 1.1 / 5).rounded() * 5)
    }

    static func label(ratio: Double) -> (text: String, color: Color) {
        ratio > overtrain ? ("Sobreentrenamiento", .red) : ratio >= 1 ? ("Objetivo cumplido", .green)
            : ratio >= 0.6 ? ("Buen ritmo", .blue) : ("Por debajo", .orange)
    }
}

/// Carga acumulada de la semana en curso (de lunes a hoy): un punto por día, sumando lo de los días anteriores.
extension CardioLoad {
    static func weekCumulative(_ l: [LoadDay], now: Date = Date(), cal: Calendar = esCalendar) -> (start: Date, points: [(Date, Double)]) {
        let start = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? cal.startOfDay(for: now)
        var run = 0.0
        let points: [(Date, Double)] = (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
            .filter { $0 <= now }
            .map { d in run += l.first { cal.isDate($0.day, inSameDayAs: d) }?.value ?? 0; return (d, run) }
        return (start, points)
    }
}

/// Gráfica pequeña de la semana: línea acumulada de lunes a hoy y la del objetivo semanal.
private struct WeekLoadMiniChart: View {
    let start: Date
    let points: [(Date, Double)]
    let goal: Double

    var body: some View {
        let top = max(goal * 1.15, (points.last?.1 ?? 0) * 1.1)
        Chart {
            RuleMark(y: .value("Objetivo", goal)).foregroundStyle(Theme.steps.opacity(0.8)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            ForEach(points, id: \.0) { d, v in
                AreaMark(x: .value("Día", d), y: .value("Carga", v)).foregroundStyle(Theme.awake.opacity(0.15))
                LineMark(x: .value("Día", d), y: .value("Carga", v)).foregroundStyle(Theme.awake)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round)).interpolationMethod(.monotone)
            }
            if let last = points.last {
                PointMark(x: .value("Día", last.0), y: .value("Carga", last.1)).foregroundStyle(Theme.awake).symbolSize(28)
            }
        }
        .chartXScale(domain: start...(esCalendar.date(byAdding: .day, value: 6, to: start) ?? start))
        .chartYScale(domain: 0...top)
        .chartXAxis(.hidden).chartYAxis(.hidden)
    }
}

/// Tarjeta de Hoy: la carga de la semana (de lunes a hoy), que se reinicia cada lunes.
struct CardioLoadCard: View {
    @EnvironmentObject var model: HealthModel
    @AppStorage(CardioLoad.goalKey) private var goalSetting = 0
    @AppStorage(CardioLoad.ageKey) private var age = CardioLoad.defaultAge

    var body: some View {
        let loads = model.loadDays(age: age)
        let goal = CardioLoad.weeklyGoal(setting: goalSetting, loads: loads ?? [])
        NavigationLink(value: Route.activity) {
            VStack(alignment: .leading, spacing: 6) {
                MiniHeader(icon: "bolt.heart.fill", title: "Carga cardio", color: Theme.awake)
                if let loads {
                    let week = CardioLoad.weekCumulative(loads)
                    let total = week.points.last?.1 ?? 0
                    BigValue(value: Int(total.rounded()).formatted(), unit: "", size: 30)
                    WeekLoadMiniChart(start: week.start, points: week.points, goal: goal).frame(height: 56)
                    Text("de \(Int(goal)) · \(Int((total / goal * 100).rounded())) % esta semana").font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                } else {
                    Text(model.loading ? "Cargando…" : "Sin datos de pulso").font(.subheadline).foregroundStyle(.secondary)
                }
            }.miniCard()
        }.buttonStyle(.plain)
    }
}

/// Resumen de la carga de la semana; abre Actividad, donde está su gráfica.
struct CardioLoadRow: View {
    @EnvironmentObject var model: HealthModel
    @AppStorage(CardioLoad.goalKey) private var goalSetting = 0
    @AppStorage(CardioLoad.ageKey) private var age = CardioLoad.defaultAge

    var body: some View {
        if let loads = model.loadDays(age: age) {
            let goal = CardioLoad.weeklyGoal(setting: goalSetting, loads: loads)
            let total = CardioLoad.weekCumulative(loads).points.last?.1 ?? 0
            let label = CardioLoad.label(ratio: total / goal)
            NavigationLink(value: Route.activity) {
                VStack(alignment: .leading, spacing: 10) {
                    CardHeader(icon: "bolt.heart.fill", title: "Carga cardio de la semana", color: Theme.awake, trailing: "\(Int(total.rounded())) de \(Int(goal))")
                    GeometryReader { g in
                        Capsule().fill(Color.secondary.opacity(0.15))
                            .overlay(alignment: .leading) { Capsule().fill(Theme.awake).frame(width: g.size.width * min(total / goal, 1)) }
                    }.frame(height: 8)
                    Text(label.text).font(.subheadline).foregroundStyle(label.color)
                }.card()
            }.buttonStyle(.plain)
        }
    }
}

/// Tarjeta de Actividad: la carga cardio según el filtro. Día: la de ese día y lo acumulado en su semana frente al objetivo.
/// Semana, mes, 3 meses y año: la carga media diaria (por día, por semana o por mes), con el objetivo semanal repartido por día.
struct CardioLoadChartCard: View {
    @EnvironmentObject var model: HealthModel
    @AppStorage(CardioLoad.goalKey) private var goalSetting = 0
    @AppStorage(CardioLoad.ageKey) private var age = CardioLoad.defaultAge
    let range: HistRange
    var day = DayChoice.today

    private func pts(_ v: Double) -> String { Int(v.rounded()).formatted() }
    private func badge(_ l: (text: String, color: Color)) -> some View {
        Text(l.text).font(.caption.weight(.bold)).foregroundStyle(l.color)
            .padding(.horizontal, 9).padding(.vertical, 3).background(l.color.opacity(0.15), in: Capsule())
    }

    var body: some View {
        if let loads = model.loadDays(age: age) {
            let goal = CardioLoad.weeklyGoal(setting: goalSetting, loads: loads)
            VStack(alignment: .leading, spacing: 10) {
                if range == .day { dayBody(loads, goal: goal) } else { rangeBody(loads, goal: goal) }
                Text("Estimada con tu pulso medio por minuto, no es el dato de Google: cada minuto suma según lo cerca que esté tu pulso de tu máximo (220 − edad = \(Int(CardioLoad.maxHR(age: age))) lpm, se cambia en Ajustes) respecto a tu pulso en reposo (\(Int(model.restingBaseline.rounded())) lpm). Se acerca al de Google (error medio ~16 %) pero no coincide al punto. El objetivo semanal es \(goalSetting > 0 ? "el de Ajustes" : "automático (tus últimos 7 días +10 %)").")
                    .font(.caption2).foregroundStyle(.secondary)
            }.card()
        } else {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(icon: "bolt.heart.fill", title: "Carga cardio", color: Theme.awake, chevron: false)
                if model.loading || model.hrLoading { ProgressView().frame(maxWidth: .infinity, minHeight: 80) }
                else { Text("Sin datos de pulso").font(.subheadline).foregroundStyle(.secondary) }
            }.card()
        }
    }

    private func dayBody(_ loads: [LoadDay], goal: Double) -> some View {
        let cal = esCalendar
        let date = cal.date(byAdding: .day, value: day == .today ? 0 : -1, to: cal.startOfDay(for: Date()))!
        let week = CardioLoad.weekCumulative(loads, now: date)
        let total = week.points.last?.1 ?? 0
        let dayLoad = loads.first { cal.isDate($0.day, inSameDayAs: date) }?.value ?? 0
        return VStack(alignment: .leading, spacing: 10) {
            CardHeader(icon: "bolt.heart.fill", title: "Carga cardio", color: Theme.awake, trailing: "Semana: \(pts(total)) de \(pts(goal))", chevron: false)
            HStack(alignment: .firstTextBaseline) {
                BigValue(value: pts(dayLoad), unit: day == .today ? "hoy" : "ayer")
                Spacer()
                badge(CardioLoad.label(ratio: total / goal))
            }
            WeekLoadMiniChart(start: week.start, points: week.points, goal: goal).frame(height: 90)
            Text("Línea: lo acumulado de lunes a \(day == .today ? "hoy" : "ayer"); discontinua, el objetivo semanal.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func rangeBody(_ loads: [LoadDay], goal: Double) -> some View {
        // Los días iniciales sin carga (antes de tener la pulsera) no cuentan en los periodos largos.
        let days = Array(loads.suffix(range.days).drop { range.needsLong && $0.value == 0 })
        let weekly = days.isEmpty ? 0 : days.map(\.value).reduce(0, +) / Double(days.count) * 7
        let points = Dictionary(grouping: days) { range.bucketStart($0.day) }
            .map { TrendPoint(date: $0.key, value: $0.value.map(\.value).reduce(0, +) / Double($0.value.count)) }
            .sorted { $0.date < $1.date }
        let partial = days.count < range.days && (model.hrLoading || !range.needsLong)
        return VStack(alignment: .leading, spacing: 10) {
            CardHeader(icon: "bolt.heart.fill", title: "Carga cardio · media diaria", color: Theme.awake, trailing: "\(pts(weekly)) por semana", chevron: false)
            if days.isEmpty {
                if model.hrLoading { ProgressView().frame(maxWidth: .infinity, minHeight: 120) }
                else { Text("Sin datos en este periodo").font(.subheadline).foregroundStyle(.secondary) }
            } else {
                badge(CardioLoad.label(ratio: weekly / goal))
                TrendChart(points: points, color: Theme.awake, range: range, goal: goal / 7, goalLabel: "objetivo diario",
                           yStep: 10, format: { "\(Int($0.rounded()).formatted()) de media" }).frame(height: 160)
                if range.unit != .day {
                    Text("Cada punto es la carga media diaria de \(range.unit == .month ? "ese mes" : "esa semana").").font(.caption).foregroundStyle(.secondary)
                }
                if model.hrLoading && days.count < range.days {
                    Label("Descargando el pulso del periodo…", systemImage: "arrow.down.circle").font(.caption).foregroundStyle(.secondary)
                } else if partial {
                    Text("Solo hay pulso de \(days.count) días de este periodo.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

#if DEBUG
#Preview("Tarjeta") { CardioLoadCard().previewCard().previewEnvironment() }
#Preview("Actividad") { CardioLoadChartCard(range: .month).previewCard().previewEnvironment() }
#endif
