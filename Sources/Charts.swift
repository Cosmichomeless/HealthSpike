import Charts
import SwiftUI

private func axisDomain(_ lo: Double, _ hi: Double, step: Double = 10) -> ClosedRange<Double> {
    let a = (((lo - 4) / step).rounded(.down)) * step, b = (((hi + 4) / step).rounded(.up)) * step
    return a...max(b, a + step)
}

/// Elemento más cercano a la fecha que marca el dedo (`nil` si no hay selección).
private func nearest<T>(_ items: [T], to date: Date?, _ key: (T) -> Date) -> T? {
    guard let date else { return nil }
    return items.min { abs(key($0).timeIntervalSince(date)) < abs(key($1).timeIntervalSince(date)) }
}

/// Burbuja que acompaña al dedo en las gráficas: título (hora o día), valor y una línea de detalle.
struct ScrubBubble: View {
    let title: String
    let value: String
    var detail: String?
    var color: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.bold).monospacedDigit()).foregroundStyle(color)
            if let detail { Text(detail).font(.caption2).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
    }
}

extension View {
    /// Selección con el dedo solo si la gráfica es interactiva: `chartXSelection` se queda con los toques y
    /// bloquearía el enlace de las tarjetas de «Hoy», que contienen gráficas.
    @ViewBuilder fileprivate func scrub(_ on: Bool, _ selection: Binding<Date?>) -> some View {
        if on { chartXSelection(value: selection) } else { allowsHitTesting(false) }
    }
}

private let bubbleOverflow = AnnotationOverflowResolution(x: .fit(to: .chart), y: .disabled)

/// Punto de una serie por día/semana/mes.
struct TrendPoint: Identifiable {
    let date: Date
    let value: Double
    var id: Date { date }
}

/// Serie de un periodo (semana, mes, 3 meses, año): línea suave con área, objetivo opcional y burbuja al deslizar el dedo.
struct TrendChart: View {
    let points: [TrendPoint]
    let color: Color
    let range: HistRange
    var goal: Double?
    var goalLabel = "objetivo"
    var zeroBased = true
    var yStep = 10.0
    let format: (Double) -> String
    @State private var selected: Date?

    var body: some View {
        let vals = points.map(\.value) + (goal.map { [$0] } ?? [])
        let hi = vals.max() ?? 1, lo = points.map(\.value).min() ?? 0
        let sel = nearest(points, to: selected) { $0.date }
        Chart {
            ForEach(points) { p in
                AreaMark(x: .value("Día", p.date), yStart: .value("Base", zeroBased ? 0 : axisDomain(lo, hi, step: yStep).lowerBound), yEnd: .value("Valor", p.value))
                    .foregroundStyle(color.opacity(0.16)).interpolationMethod(.monotone)
                LineMark(x: .value("Día", p.date), y: .value("Valor", p.value))
                    .foregroundStyle(color).interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            }
            if let goal {
                RuleMark(y: .value("Objetivo", goal)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(.secondary)
                    .annotation(position: .top, alignment: .leading, spacing: 2) { Text(goalLabel).font(.caption2).foregroundStyle(.secondary) }
            }
            if let sel {
                RuleMark(x: .value("Selección", sel.date))
                    .foregroundStyle(Color.secondary.opacity(0.5)).lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, spacing: 4, overflowResolution: bubbleOverflow) {
                        ScrubBubble(title: range.bucketLabel(sel.date), value: format(sel.value), color: color)
                    }
                PointMark(x: .value("Selección", sel.date), y: .value("Valor", sel.value))
                    .symbolSize(60).foregroundStyle(color)
            }
        }
        .chartXSelection(value: $selected)
        .chartXScale(range: .plotDimension(startPadding: 8, endPadding: 8))
        .chartYScale(domain: zeroBased ? 0...max(hi * 1.15, 1) : axisDomain(lo, hi, step: yStep))
        .chartXAxis { dayAxis(range) }
        .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) }
    }
}

/// Serie por horas de un día (pasos, distancia): línea suave con área y burbuja al deslizar el dedo.
struct DayTrendChart: View {
    let points: [HourValue]
    let domain: ClosedRange<Date>
    let color: Color
    var interactive = true
    /// Tramos del día señalados al fondo (p. ej. los entrenos).
    var bands: [ClosedRange<Date>] = []
    let format: (Double) -> String
    @State private var selected: Date?

    /// Horas sin registro cuentan como 0 entre la primera hora con datos y la última.
    private var filled: [HourValue] {
        guard let a = points.first?.hour, let b = points.last?.hour else { return [] }
        let byHour = Dictionary(points.map { ($0.hour, $0.value) }, uniquingKeysWith: +)
        var out: [HourValue] = [], d = a
        while d <= b {
            out.append(HourValue(hour: d, value: byHour[d] ?? 0))
            d = Calendar.current.date(byAdding: .hour, value: 1, to: d)!
        }
        return out
    }

    var body: some View {
        let data = filled
        let sel = interactive ? nearest(data, to: selected) { $0.hour } : nil
        Chart {
            ForEach(Array(bands.enumerated()), id: \.offset) { _, b in
                RectangleMark(xStart: .value("Inicio", b.lowerBound), xEnd: .value("Fin", b.upperBound))
                    .foregroundStyle(Theme.awake.opacity(0.22))
            }
            ForEach(data) { p in
                AreaMark(x: .value("Hora", p.hour), y: .value("Valor", p.value))
                    .foregroundStyle(color.opacity(0.16)).interpolationMethod(.monotone)
                LineMark(x: .value("Hora", p.hour), y: .value("Valor", p.value))
                    .foregroundStyle(color).interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            }
            if let sel {
                RuleMark(x: .value("Selección", sel.hour))
                    .foregroundStyle(Color.secondary.opacity(0.5)).lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, spacing: 4, overflowResolution: bubbleOverflow) {
                        ScrubBubble(title: hourSpan(sel.hour), value: format(sel.value), color: color)
                    }
                PointMark(x: .value("Selección", sel.hour), y: .value("Valor", sel.value))
                    .symbolSize(60).foregroundStyle(color)
            }
        }
        .scrub(interactive, $selected)
        .chartXScale(domain: domain)
        .chartYScale(domain: 0...max((data.map(\.value).max() ?? 1) * 1.15, 1))
        .chartXAxis { hourAxis(domain) }
        .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) }
        .overlay {
            if data.isEmpty { Text("Sin datos todavía").font(.footnote).foregroundStyle(.secondary) }
        }
    }
}

private func hourSpan(_ h: Date) -> String {
    let f = Date.FormatStyle().hour(.twoDigits(amPM: .omitted)).minute().locale(esES)
    return "\(h.formatted(f))–\(h.addingTimeInterval(3600).formatted(f))"
}

/// FC del día: línea de la media por tramos de 10 min con la banda mín–máx detrás.
struct HeartDayChart: View {
    let buckets: [HRBucket]
    let domain: ClosedRange<Date>
    var resting: Double?
    var interactive = true
    var compact = false
    @State private var selected: Date?

    var body: some View {
        let lo = min(buckets.map(\.min).min() ?? 50, resting ?? 200), hi = buckets.map(\.max).max() ?? 120
        let sel = interactive ? nearest(buckets, to: selected) { $0.time } : nil
        Chart {
            ForEach(buckets) { b in
                AreaMark(x: .value("Hora", b.time), yStart: .value("Mín", b.min), yEnd: .value("Máx", b.max))
                    .foregroundStyle(Theme.heart.opacity(0.2)).interpolationMethod(.monotone)
                LineMark(x: .value("Hora", b.time), y: .value("FC", b.avg))
                    .foregroundStyle(Theme.heart).interpolationMethod(.monotone)
            }
            if let resting {
                RuleMark(y: .value("Reposo", resting))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3])).foregroundStyle(Theme.resting)
            }
            if let sel {
                RuleMark(x: .value("Selección", sel.time))
                    .foregroundStyle(Color.secondary.opacity(0.5)).lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, spacing: 4, overflowResolution: bubbleOverflow) {
                        ScrubBubble(title: sel.time.hhmm, value: "\(Int(sel.avg.rounded())) lpm", detail: "mín \(Int(sel.min)) · máx \(Int(sel.max))", color: Theme.heart)
                    }
                PointMark(x: .value("Selección", sel.time), y: .value("FC", sel.avg))
                    .symbolSize(60).foregroundStyle(Theme.heart)
            }
        }
        .scrub(interactive, $selected)
        .chartXScale(domain: domain)
        .chartYScale(domain: axisDomain(lo, hi))
        .chartXAxis { if !compact { hourAxis(domain) } }
        .chartYAxis { if !compact { AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) } }
    }
}

/// FC por periodo: línea de la media con la banda mín–máx y la FC en reposo punteada.
struct HeartRangeChart: View {
    let days: [DayStat]
    let resting: [Date: Double]
    let range: HistRange
    @State private var selected: Date?

    var body: some View {
        let withHR = days.filter { $0.hrMin != nil && $0.hrMax != nil }
        let rest = days.compactMap { d in resting[d.day].map { TrendPoint(date: d.day, value: $0) } }
        let lo = min(withHR.compactMap(\.hrMin).min() ?? 40, rest.map(\.value).min() ?? 200), hi = withHR.compactMap(\.hrMax).max() ?? 160
        let sel = nearest(withHR, to: selected) { $0.day }
        Chart {
            ForEach(withHR) { d in
                AreaMark(x: .value("Día", d.day), yStart: .value("Mín", d.hrMin!), yEnd: .value("Máx", d.hrMax!), series: .value("Serie", "banda"))
                    .foregroundStyle(Theme.heart.opacity(0.2)).interpolationMethod(.monotone)
                if let a = d.hrAvg {
                    LineMark(x: .value("Día", d.day), y: .value("Media", a), series: .value("Serie", "media"))
                        .foregroundStyle(Theme.heart).interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                }
            }
            ForEach(rest) { r in
                LineMark(x: .value("Día", r.date), y: .value("Reposo", r.value), series: .value("Serie", "reposo"))
                    .foregroundStyle(Theme.resting).interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            }
            if let sel {
                RuleMark(x: .value("Selección", sel.day))
                    .foregroundStyle(Color.secondary.opacity(0.5)).lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, spacing: 4, overflowResolution: bubbleOverflow) {
                        ScrubBubble(title: range.bucketLabel(sel.day),
                                    value: sel.hrAvg.map { "\(Int($0.rounded())) lpm" } ?? "mín \(Int(sel.hrMin!)) · máx \(Int(sel.hrMax!))",
                                    detail: "mín \(Int(sel.hrMin!)) · máx \(Int(sel.hrMax!))" + (resting[sel.day].map { " · reposo \(Int($0.rounded()))" } ?? ""),
                                    color: Theme.heart)
                    }
                if let a = sel.hrAvg {
                    PointMark(x: .value("Selección", sel.day), y: .value("Media", a)).symbolSize(60).foregroundStyle(Theme.heart)
                }
            }
        }
        .chartXSelection(value: $selected)
        .chartXScale(range: .plotDimension(startPadding: 8, endPadding: 8))
        .chartYScale(domain: axisDomain(lo, hi))
        .chartXAxis { dayAxis(range) }
        .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) }
    }
}

/// Hipnograma: un bloque por tramo en cuatro filas (Despierto arriba, Profundo abajo). El eje Y es numérico
/// para que ninguna fila quede recortada; los nombres de fila son las marcas del eje.
struct Hypnogram: View {
    let night: SleepNight
    var interactive = true
    var compact = false              // sin ejes ni etiquetas, para las tarjetas pequeñas
    @State private var selected: Date?

    /// Solo para dibujar: los tramos de menos de 3 min (salvo «Despierto») se funden con el anterior y los vecinos
    /// de la misma fase se unen, para que no salga una maraña de bloques diminutos.
    private static func smoothed(_ all: [SleepSegment]) -> [SleepSegment] {
        var out: [SleepSegment] = []
        for s in all.sorted(by: { $0.start < $1.start }) {
            if let last = out.last, last.stage == s.stage || (s.stage != "AWAKE" && s.end.timeIntervalSince(s.start) < 180) {
                out[out.count - 1] = SleepSegment(id: last.id, stage: last.stage, start: last.start, end: s.end)
            } else {
                out.append(s)
            }
        }
        return out
    }

    private func row(_ stage: String) -> Double { Double(Theme.stageOrder.count - 1 - (Theme.stageOrder.firstIndex(of: stage) ?? 0)) }

    var body: some View {
        let segs = Self.smoothed(night.segments)
        let seg = interactive ? selected.flatMap { d in segs.first { $0.start <= d && d < $0.end } } : nil
        Chart {
            // Conectores entre fases consecutivas, con degradado del color de una al de la siguiente.
            ForEach(Array(zip(segs, segs.dropFirst())), id: \.0.id) { a, b in
                let ya = row(a.stage) + 0.5, yb = row(b.stage) + 0.5
                if a.stage != b.stage {
                    RectangleMark(x: .value("Cambio", b.start), yStart: .value("De", min(ya, yb)), yEnd: .value("A", max(ya, yb)), width: 2)
                        .cornerRadius(3)
                        .foregroundStyle(LinearGradient(colors: ya > yb ? [Theme.stageColor(a.stage), Theme.stageColor(b.stage)]
                                                                         : [Theme.stageColor(b.stage), Theme.stageColor(a.stage)],
                                                        startPoint: .top, endPoint: .bottom))
                        .opacity(seg == nil ? 0.9 : 0.3)
                }
            }
            ForEach(segs) { s in
                RectangleMark(xStart: .value("Inicio", s.start), xEnd: .value("Fin", s.end),
                              yStart: .value("Fase", row(s.stage) + 0.15), yEnd: .value("Fase", row(s.stage) + 0.8))
                    .foregroundStyle(Theme.stageColor(s.stage).opacity(seg == nil || seg?.id == s.id ? 1 : 0.35)).cornerRadius(5)
            }
            if let seg {
                RuleMark(x: .value("Selección", selected ?? seg.start))
                    .foregroundStyle(Color.secondary.opacity(0.5)).lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, spacing: 4, overflowResolution: bubbleOverflow) {
                        ScrubBubble(title: "\(seg.start.hhmm)–\(seg.end.hhmm)", value: Theme.stageName(seg.stage),
                                    detail: hm(seg.end.timeIntervalSince(seg.start) / 60), color: Theme.stageColor(seg.stage))
                    }
            }
        }
        .scrub(interactive, $selected)
        .chartXScale(domain: night.start...night.end)
        .chartYScale(domain: 0...Double(Theme.stageOrder.count))
        .chartXAxis {
            // Solo los extremos: a qué hora te acostaste y a qué hora te despertaste.
            if !compact { AxisMarks(values: [night.start, night.end]) { v in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.4))
                AxisValueLabel(anchor: v.index == 0 ? .topLeading : .topTrailing) {
                    if let d = v.as(Date.self) { Text(d.hhmm).font(.caption.weight(.semibold).monospacedDigit()) }
                }
            } }
        }
        .chartYAxis {
            if !compact { AxisMarks(position: .leading, values: Array(0..<Theme.stageOrder.count).map { Double($0) + 0.5 }) { v in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.4))
                AxisValueLabel(horizontalSpacing: 6) {
                    if let y = v.as(Double.self) { Text(Theme.stageName(Theme.stageOrder[Theme.stageOrder.count - 1 - Int(y)])).font(.caption2) }
                }
            } }
        }
    }
}

/// Noches apiladas por fase con la línea del objetivo y burbuja con el desglose al deslizar el dedo.
struct SleepHistoryChart: View {
    let nights: [SleepNight]
    let goalMinutes: Double
    let range: HistRange
    @State private var selected: Date?

    var body: some View {
        // Las barras ocupan un periodo entero (día, semana, mes): se elige la que contiene el punto tocado.
        let sel = selected.flatMap { d in nights.first { range.bucketStart($0.end) == range.bucketStart(d) } }
        Chart {
            ForEach(nights) { n in
                ForEach(["DEEP", "LIGHT", "REM"], id: \.self) { st in
                    BarMark(x: .value("Noche", n.end, unit: range.unit), y: .value("Min", n.minutes[st] ?? 0), width: range == .week ? .fixed(28) : .automatic)
                        .foregroundStyle(by: .value("Fase", Theme.stageName(st)))
                        .opacity(sel == nil || sel?.id == n.id ? 1 : 0.4)
                }
            }
            RuleMark(y: .value("Objetivo", goalMinutes)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(.secondary)
                .annotation(position: .top, alignment: .trailing, spacing: 2) { Text("objetivo \(hoursText(goalMinutes / 60))").font(.caption2).foregroundStyle(.secondary) }
            if let sel {
                RuleMark(x: .value("Selección", sel.end, unit: range.unit))
                    .foregroundStyle(Color.clear)
                    .annotation(position: .top, spacing: 4, overflowResolution: bubbleOverflow) {
                        ScrubBubble(title: range.bucketLabel(sel.end), value: hm(sel.asleep),
                                    detail: "Prof. \(Int(sel.minutes["DEEP"] ?? 0)) · Lig. \(Int(sel.minutes["LIGHT"] ?? 0)) · REM \(Int(sel.minutes["REM"] ?? 0)) min",
                                    color: Theme.sleep)
                    }
            }
        }
        .chartXSelection(value: $selected)
        .chartForegroundStyleScale(["Profundo": Theme.deep, "Ligero": Theme.light, "REM": Theme.rem])
        .chartLegend(position: .bottom, alignment: .leading)
        .chartXAxis { dayAxis(range) }
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 240, 480]) { v in
                AxisGridLine()
                AxisValueLabel { if let m = v.as(Double.self) { Text("\(Int(m) / 60) h") } }
            }
        }
    }
}

/// Curva acumulada del día (para la tarjeta de «Hoy»), sobre las 24 h completas.
struct StepsCumChart: View {
    let points: [CumPoint]
    let midnight: Date
    var compact = false
    var body: some View {
        Chart(points) { p in
            AreaMark(x: .value("Hora", p.time), y: .value("Pasos", p.value)).foregroundStyle(Theme.steps.opacity(0.18)).interpolationMethod(.monotone)
            LineMark(x: .value("Hora", p.time), y: .value("Pasos", p.value)).foregroundStyle(Theme.steps).interpolationMethod(.monotone)
        }
        .chartXScale(domain: midnight...midnight.addingTimeInterval(24 * 3600))
        .chartXAxis { if !compact { AxisMarks(values: .stride(by: .hour, count: 6)) { _ in AxisValueLabel(format: .dateTime.hour()) } } }
        .chartYAxis(.hidden)
    }
}

/// Eje horizontal de un día: una marca cada 3 h, sin la etiqueta pegada al borde derecho.
@AxisContentBuilder
private func hourAxis(_ domain: ClosedRange<Date>) -> some AxisContent {
    AxisMarks(values: .stride(by: .hour, count: 3)) { v in
        AxisGridLine()
        if let d = v.as(Date.self), d < domain.upperBound.addingTimeInterval(-1800) { AxisValueLabel(format: .dateTime.hour()) }
    }
}

/// Eje horizontal según el periodo: días de la semana, una marca por semana, cada 3 semanas o cada mes.
@AxisContentBuilder
private func dayAxis(_ range: HistRange) -> some AxisContent {
    switch range {
    case .day, .week:
        AxisMarks(values: .stride(by: .day)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.weekday(.abbreviated).locale(esES)) }
    case .month:
        AxisMarks(values: .stride(by: .day, count: 7)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.day().month(.abbreviated).locale(esES)) }
    case .quarter:
        AxisMarks(values: .stride(by: .weekOfYear, count: 3)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.day().month(.abbreviated).locale(esES)) }
    case .year:
        AxisMarks(values: .stride(by: .month)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.month(.narrow).locale(esES)) }
    }
}

#if DEBUG
#Preview("Series y burbuja") {
    let h = PreviewData.history(days: 30)
    let steps = h.days.map { TrendPoint(date: $0.day, value: $0.steps ?? 0) }
    return ScrollView {
        VStack(alignment: .leading, spacing: 24) {
            ScrubBubble(title: "mar 14", value: "8.420", detail: "pasos", color: .orange)
            TrendChart(points: steps, color: .orange, range: .month, goal: 10_000, yStep: 2_000) { $0.formatted(.number.locale(esES)) }
                .frame(height: 180)
            SleepHistoryChart(nights: h.nights, goalMinutes: 480, range: .month).frame(height: 180)
            HeartRangeChart(days: h.days, resting: Dictionary(uniqueKeysWithValues: h.resting.map { (Calendar.current.startOfDay(for: $0.time), $0.value) }), range: .month)
                .frame(height: 180)
        }.padding(16)
    }.previewEnvironment()
}
#Preview("Gráficas del día") {
    let m = HealthModel.preview.today!
    let domain = m.midnight...m.midnight.addingTimeInterval(24 * 3600)
    var run = 0.0
    let cum = m.hourlySteps.map { h -> CumPoint in run += h.steps; return CumPoint(time: h.hour, value: run) }
    return ScrollView {
        VStack(alignment: .leading, spacing: 24) {
            DayTrendChart(points: m.hourlySteps.map { HourValue(hour: $0.hour, value: $0.steps) }, domain: domain, color: .orange) { "\(Int($0))" }
                .frame(height: 160)
            HeartDayChart(buckets: m.heartBuckets, domain: domain, resting: m.resting?.value).frame(height: 160)
            StepsCumChart(points: cum, midnight: m.midnight).frame(height: 160)
            if let night = m.sleep { Hypnogram(night: night).frame(height: 100) }
        }.padding(16)
    }.previewEnvironment()
}
#Preview("Hipnograma") {
    VStack(spacing: 24) {
        Hypnogram(night: PreviewData.night()).frame(height: 84)
        Hypnogram(night: PreviewData.night(), compact: true).frame(height: 50)
    }.padding(16).previewEnvironment()
}
#endif
