import SwiftUI
import WidgetKit

@main
struct HealthWidgets: WidgetBundle {
    var body: some Widget {
        SummaryWidget()
        TrioWidget()
        LockStepsWidget()
        LockSleepWidget()
        LockCaloriesWidget()
    }
}

// MARK: - Datos

struct WidgetEntry: TimelineEntry {
    let date: Date
    let data: WidgetData?

    /// Los pasos y las calorías son del día en que se guardaron: al cambiar de día se dejan en blanco hasta que la app refresque.
    var isToday: Bool { data.map { Calendar.current.isDate($0.day, inSameDayAs: date) } ?? false }
    /// Más de 12 h sin que la app haya refrescado: el dato se atenúa y se invita a abrirla.
    var isStale: Bool { data.map { date.timeIntervalSince($0.updatedAt) > 12 * 3600 } ?? true }
    var steps: Int? { isToday ? data?.steps : nil }
    var calories: Int? { isToday ? data?.calories : nil }
}

extension WidgetData {
    static let sample = WidgetData(
        updatedAt: .now, day: Calendar.current.startOfDay(for: .now), steps: 6_820, stepsGoal: 10_000,
        sleepScore: 91, sleepHours: 7.32, sleepLabel: "Excelente", calories: 1_740, caloriesGoal: 2_500,
        heartBPM: 68, heartTime: .now, resting: 54, heartMax: 197, battery: 63)
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> WidgetEntry { WidgetEntry(date: .now, data: .sample) }

    func getSnapshot(in context: Context, completion: @escaping (WidgetEntry) -> Void) {
        completion(WidgetEntry(date: .now, data: context.isPreview ? .sample : WidgetStore.load()))
    }

    /// Una entrada ahora y otra a medianoche (para que los pasos de ayer no pasen por los de hoy). La app pide recargar
    /// tras cada sincronización; si no, iOS vuelve a preguntar pasados 15 minutos.
    func getTimeline(in context: Context, completion: @escaping (Timeline<WidgetEntry>) -> Void) {
        let now = Date(), data = WidgetStore.load()
        let midnight = Calendar.current.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0), matchingPolicy: .nextTime)
        var entries = [WidgetEntry(date: now, data: data)]
        if let midnight { entries.append(WidgetEntry(date: midnight, data: data)) }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(15 * 60))))
    }
}

// MARK: - Estilo (los mismos colores que la app)

enum Palette {
    private static func hex(_ v: UInt32) -> Color {
        Color(red: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255, blue: Double(v & 255) / 255)
    }
    static let background = hex(0x0A0C10)
    static let steps = hex(0x00FF94)
    static let sleep = hex(0x7B5CFF)
    static let heart = hex(0xFF1F5A)
    static let calories = hex(0xFF9500)
}

/// Media luna de progreso, igual que `ArcMeter` de la app, pegada al borde superior del marco.
struct Arc: View {
    var progress: Double
    var color: Color
    var lineWidth: CGFloat

    static func height(width: CGFloat, lineWidth: CGFloat, below: CGFloat) -> CGFloat { (width - lineWidth) / 2 + lineWidth / 2 + below }

    var body: some View {
        let p = max(0.02, min(progress, 1))
        GeometryReader { g in
            let d = g.size.width - lineWidth
            ZStack {
                Circle().trim(from: 0, to: 0.5).stroke(color.opacity(0.24), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                Circle().trim(from: 0, to: 0.5 * p).stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            }
            .rotationEffect(.degrees(180))
            .frame(width: d, height: d)
            .position(x: g.size.width / 2, y: lineWidth / 2 + d / 2)
        }
    }
}

/// Media luna con el valor dentro y la unidad (o un icono) bajo la base, con las proporciones de `RingStat` en la app.
struct ArcStat: View {
    let value: String
    var unit: String = ""
    var icon: String?
    let progress: Double
    let color: Color
    let width: CGFloat

    var body: some View {
        ZStack(alignment: .bottom) {
            Arc(progress: progress, color: color, lineWidth: width * 0.11)
            VStack(spacing: 0) {
                Text(value).font(.system(size: width * 0.22, weight: .bold).monospacedDigit())
                    .foregroundStyle(.primary).minimumScaleFactor(0.6).lineLimit(1)
                if let icon {
                    Image(systemName: icon).font(.system(size: width * 0.15, weight: .semibold)).foregroundStyle(color)
                } else {
                    Text(unit).font(.system(size: max(8, width * 0.11))).foregroundStyle(.secondary).lineLimit(1)
                }
            }.padding(.horizontal, width * 0.14)
        }
        .frame(width: width, height: Arc.height(width: width, lineWidth: width * 0.11, below: width * (icon == nil ? 0.17 : 0.2)))
    }
}

private extension View {
    /// Fondo estándar de widget: el sistema lo pinta y se adapta al modo claro u oscuro; el texto también.
    func appBackground() -> some View {
        containerBackground(.fill.tertiary, for: .widget)
    }
}

/// Aviso cuando no hay datos o llevan mucho tiempo sin actualizarse.
private func staleNote(_ e: WidgetEntry) -> String? {
    if e.data == nil { return "Abre la app" }
    return e.isStale ? "Abre la app" : nil
}

private func percent(_ p: Double) -> Int { Int((p * 100).rounded()) }
private func fraction(_ n: Int?, of total: Int?) -> Double { Double(n ?? 0) / Double(max(total ?? 1, 1)) }
/// «7:19», como `hmColon` en la app.
private func hoursText(_ h: Double) -> String { String(format: "%d:%02d", Int(h), Int(((h - Double(Int(h))) * 60).rounded()) % 60) }

// MARK: - Cuatro anillos (sueño, pasos, calorías, pulso)

struct SummaryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetStore.kind.summary, provider: Provider()) { SummaryView(entry: $0) }
            .configurationDisplayName("Hoy")
            .description("Puntuación de sueño, pasos, calorías y último pulso guardado.")
            .supportedFamilies([.systemSmall])
    }
}

struct SummaryView: View {
    let entry: WidgetEntry

    /// Las cuatro lunas miran a su esquina con el lado plano hacia el centro, y juntas dibujan un cuadrado.
    var body: some View {
        let d = entry.data
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                CornerStat(value: d?.sleepScore.map { "\($0)" }, icon: "moon.fill", progress: fraction(d?.sleepScore, of: 100),
                           color: Palette.sleep, x: -1, y: -1)
                CornerStat(value: entry.steps.map { $0.formatted() }, icon: "figure.walk", progress: fraction(entry.steps, of: d?.stepsGoal),
                           color: Palette.steps, x: 1, y: -1)
            }
            HStack(spacing: 0) {
                CornerStat(value: entry.calories.map { $0.formatted() }, icon: "flame.fill", progress: fraction(entry.calories, of: d?.caloriesGoal),
                           color: Palette.calories, x: -1, y: 1)
                CornerStat(value: d?.heartBPM.map { "\($0)" }, icon: "heart.fill", progress: fraction(d?.heartBPM, of: d?.heartMax ?? 195),
                           color: Palette.heart, x: 1, y: 1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(entry.isStale ? 0.6 : 1)
        .appBackground()
    }
}

/// Media luna cuyo arco mira a la esquina (`x`, `y` = ±1); el valor y el icono van sobre el centro, algo hacia fuera.
struct CornerStat: View {
    let value: String?
    let icon: String
    let progress: Double
    let color: Color
    let x: CGFloat, y: CGFloat
    var width: CGFloat = 66

    var body: some View {
        let lw = width * 0.11, d = width - lw
        let p = max(0.02, min(progress, 1))
        ZStack {
            ZStack {
                Circle().trim(from: 0, to: 0.5).stroke(color.opacity(0.24), style: StrokeStyle(lineWidth: lw, lineCap: .round))
                Circle().trim(from: 0, to: 0.5 * p).stroke(color, style: StrokeStyle(lineWidth: lw, lineCap: .round))
            }
            .rotationEffect(.degrees(180 + atan2(Double(x), Double(-y)) * 180 / .pi))
            .frame(width: d, height: d)
            VStack(spacing: 1) {
                Text(value ?? "—").font(.system(size: width * 0.19, weight: .bold).monospacedDigit())
                    .foregroundStyle(.primary).minimumScaleFactor(0.5).lineLimit(1)
                Image(systemName: icon).font(.system(size: width * 0.13, weight: .semibold)).foregroundStyle(color)
            }
            .frame(width: width * 0.58)
            .offset(x: x * width * 0.03, y: y * width * 0.03)
        }
        .frame(width: width, height: width)
    }
}

// MARK: - Pasos, sueño y calorías (la tarjeta de «Hoy»)

struct TrioWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetStore.kind.trio, provider: Provider()) { TrioView(entry: $0) }
            .configurationDisplayName("Pasos, sueño y calorías")
            .description("La tarjeta de «Hoy» de la app, a todo el ancho.")
            .supportedFamilies([.systemMedium])
    }
}

struct TrioView: View {
    let entry: WidgetEntry

    var body: some View {
        let d = entry.data
        let steps = fraction(entry.steps, of: d?.stepsGoal), cal = fraction(entry.calories, of: d?.caloriesGoal)
        HStack(alignment: .top, spacing: 4) {
            stat(entry.steps.map { $0.formatted() }, "pasos", steps, Palette.steps, "Pasos",
                 "de \((d?.stepsGoal ?? 10_000).formatted()) · \(percent(steps)) %")
            stat(d?.sleepScore.map { "\($0)" }, "de 100", fraction(d?.sleepScore, of: 100), Palette.sleep, "Sueño",
                 staleNote(entry) ?? sleepCaption(d))
            stat(entry.calories.map { $0.formatted() }, "kcal", cal, Palette.calories, "Calorías",
                 "de \((d?.caloriesGoal ?? 2_500).formatted()) · \(percent(cal)) %")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(entry.isStale ? 0.6 : 1)
        .appBackground()
    }

    private func sleepCaption(_ d: WidgetData?) -> String {
        guard let d, d.sleepScore != nil else { return "sin datos" }
        return [d.sleepLabel, d.sleepHours.map { "\(hoursText($0)) h" }].compactMap { $0 }.joined(separator: " · ")
    }

    private func stat(_ value: String?, _ unit: String, _ progress: Double, _ color: Color, _ title: String, _ caption: String) -> some View {
        VStack(spacing: 4) {
            ArcStat(value: value ?? "—", unit: unit, progress: progress, color: color, width: 100)
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(color)
            Text(caption).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(2)
        }.frame(maxWidth: .infinity)
    }
}

// MARK: - Pantalla de bloqueo (un círculo por métrica)

/// Una media luna con el valor y el icono, en el círculo de la pantalla de bloqueo; iOS la pinta en blanco.
struct LockStatView: View {
    enum Metric { case steps, sleep, calories }
    let entry: WidgetEntry
    let metric: Metric

    var body: some View {
        let d = entry.data
        let stat: (value: String?, icon: String, progress: Double, color: Color) = switch metric {
        case .steps: (entry.steps.map { $0.formatted() }, "figure.walk", fraction(entry.steps, of: d?.stepsGoal), Palette.steps)
        case .sleep: (d?.sleepScore.map { "\($0)" }, "moon.fill", fraction(d?.sleepScore, of: 100), Palette.sleep)
        case .calories: (entry.calories.map { $0.formatted() }, "flame.fill", fraction(entry.calories, of: d?.caloriesGoal), Palette.calories)
        }
        ZStack {
            GeometryReader { g in
                let side = min(g.size.width, g.size.height), lw = side * 0.095
                let p = max(0.02, min(stat.progress, 1))
                ZStack {
                    // Anillo abierto por abajo (270°), para aprovechar todo el círculo.
                    Circle().trim(from: 0, to: 0.75).stroke(stat.color.opacity(0.24), style: StrokeStyle(lineWidth: lw, lineCap: .round))
                        .rotationEffect(.degrees(135))
                    Circle().trim(from: 0, to: 0.75 * p).stroke(stat.color, style: StrokeStyle(lineWidth: lw, lineCap: .round))
                        .rotationEffect(.degrees(135))
                        .widgetAccentable()
                    Text(stat.value ?? "—").font(.system(size: side * 0.27, weight: .bold).monospacedDigit())
                        .minimumScaleFactor(0.5).lineLimit(1).padding(.horizontal, lw * 1.6)
                        .offset(y: -side * 0.03)
                    Image(systemName: stat.icon).font(.system(size: side * 0.17, weight: .semibold))
                        .offset(y: side * 0.33)
                }
                .padding(lw / 2)
                .frame(width: g.size.width, height: g.size.height)
            }
        }
        .opacity(entry.isStale ? 0.6 : 1)
        .containerBackground(for: .widget) { Color.clear }
    }
}

struct LockStepsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetStore.kind.lockSteps, provider: Provider()) { LockStatView(entry: $0, metric: .steps) }
            .configurationDisplayName("Pasos")
            .description("Los pasos de hoy en la pantalla de bloqueo.")
            .supportedFamilies([.accessoryCircular])
    }
}

struct LockSleepWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetStore.kind.lockSleep, provider: Provider()) { LockStatView(entry: $0, metric: .sleep) }
            .configurationDisplayName("Sueño")
            .description("La puntuación de sueño en la pantalla de bloqueo.")
            .supportedFamilies([.accessoryCircular])
    }
}

struct LockCaloriesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetStore.kind.lockCalories, provider: Provider()) { LockStatView(entry: $0, metric: .calories) }
            .configurationDisplayName("Calorías")
            .description("Las calorías de hoy en la pantalla de bloqueo.")
            .supportedFamilies([.accessoryCircular])
    }
}

#if DEBUG
#Preview("Hoy", as: .systemSmall) { SummaryWidget() } timeline: { WidgetEntry(date: .now, data: .sample); WidgetEntry(date: .now, data: nil) }
#Preview("Pasos, sueño y calorías", as: .systemMedium) { TrioWidget() } timeline: { WidgetEntry(date: .now, data: .sample); WidgetEntry(date: .now, data: nil) }
#Preview("Pasos (bloqueo)", as: .accessoryCircular) { LockStepsWidget() } timeline: { WidgetEntry(date: .now, data: .sample) }
#endif
