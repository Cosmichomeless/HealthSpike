import SwiftUI
import Charts

struct TodayView: View {
    @EnvironmentObject var model: HealthModel
    @AppStorage("stepsGoal") private var stepsGoal = 10_000
    @AppStorage("sleepGoalHours") private var sleepGoal = 8.0
    @AppStorage("caloriesGoal") private var caloriesGoal = 2_500
    @EnvironmentObject var logs: LogStore
    /// Sin observarlo: la vista de Hoy no debe repintarse con cada muestra del pulso, solo las dos piezas que lo muestran.
    @Environment(\.liveHeart) private var live

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    syncLine
                    if let e = model.error { ErrorBanner(text: e) }
                    if let t = model.today {
                        trio(t)
                        if SystemLM.status.ok { CoachTeaser() }
                        pair(heartCard(t), sleepCard(t))
                        pair(stepsCard(t), caloriesCard(t))
                        section("Recuperación") {
                            pair(RecoveryCard(), ResilienceCard())
                            VitalsTodayCard(vitals: model.vitals)
                        }
                        section("Esfuerzo") { pair(CardioLoadCard(), ZoneMinutesMiniCard(days: model.zones, loading: model.loading)) }
                        section("Registros") { pair(weightCard, moodCard) }
                    } else if model.loading || model.error == nil {
                        TodaySkeleton()
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 24)
            }
            .healthChrome("Hoy")
            .toolbar { batteryItem }
            .routeDestinations()
        }
    }

    private var syncLine: some View {
        HStack(spacing: 6) {
            if model.loading { ProgressView().controlSize(.mini) } else { Image(systemName: "arrow.triangle.2.circlepath") }
            // Se reevalúa cada pocos segundos para que el «ahora» pase a la hora al cumplirse el minuto.
            TimelineView(.periodic(from: .now, by: 5)) { ctx in Text(syncText(at: ctx.date)) }
            Spacer()
        }
        .font(.footnote).foregroundStyle(.secondary)
    }

    /// Enfrente del botón de Ajustes (que pone `healthChrome` a la derecha). Es solo un indicador: sin el fondo de botón.
    @ToolbarContentBuilder private var batteryItem: some ToolbarContent {
        if #available(iOS 26.0, *) {
            ToolbarItem(placement: .topBarLeading) { batteryLabel }.sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .topBarLeading) { batteryLabel }
        }
    }

    @ViewBuilder private var batteryLabel: some View {
        if let b = model.tracker?.batteryLevel {
            // HStack en vez de Label: la barra de navegación reduce las etiquetas a solo icono.
            HStack(spacing: 4) {
                Image(systemName: batteryIcon(b))
                Text("\(b) %").lineLimit(1)
            }
                .fixedSize()
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(batteryColor(b))
                .accessibilityLabel("Batería de la pulsera \(b) por ciento")
        }
    }

    /// Verde con batería de sobra, naranja por debajo de la mitad y rojo en el último 20 %.
    private func batteryColor(_ level: Int) -> Color {
        level <= 20 ? .red : level <= 50 ? .orange : .green
    }

    private func batteryIcon(_ level: Int) -> String {
        switch level {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    private func syncText(at now: Date) -> String {
        let day = now.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(esES))
        guard let t = model.lastRefresh else { return day }
        return now.timeIntervalSince(t) < 60 ? "\(day) · sincronizado ahora" : "\(day) · sincronizado a las \(t.hhmm)"
    }

    // MARK: - Tres círculos

    private func trio(_ t: TodayMetrics) -> some View {
        HStack(alignment: .top, spacing: 4) {
            NavigationLink(value: Route.activity) {
                RingStat(value: Int(t.steps).formatted(), unit: "pasos", progress: t.steps / Double(stepsGoal), color: Theme.steps,
                         title: "Pasos", caption: "de \(stepsGoal.formatted()) · \(Int((t.steps / Double(stepsGoal) * 100).rounded())) %")
            }
            NavigationLink(value: Route.sleep) {
                if let n = t.sleep {
                    let sc = model.sleepScore(n, goalHours: sleepGoal)
                    RingStat(value: "\(sc.value)", unit: "de 100", progress: sc.progress, color: Theme.sleep,
                             title: "Sueño", caption: "\(sc.label) · \(hmColon(t.sleepTotal)) h")
                } else {
                    RingStat(value: "—", unit: "de 100", progress: 0, color: Theme.sleep, title: "Sueño", caption: "sin datos")
                }
            }
            NavigationLink(value: Route.activity) {
                if let k = t.calories {
                    RingStat(value: Int(k.rounded()).formatted(), unit: "kcal", progress: k / Double(caloriesGoal), color: Theme.calories,
                             title: "Calorías", caption: "de \(caloriesGoal.formatted()) · \(Int((k / Double(caloriesGoal) * 100).rounded())) %")
                } else {
                    RingStat(value: "—", unit: "kcal", progress: 0, color: Theme.calories, title: "Calorías", caption: "sin datos")
                }
            }
        }
        .buttonStyle(.plain)
        .card()
    }

    // MARK: - Tarjetas (dos por fila)

    private func pair<A: View, B: View>(_ a: A, _ b: B) -> some View {
        HStack(alignment: .top, spacing: 12) { a; b }.fixedSize(horizontal: false, vertical: true)
    }

    /// Grupo con un título discreto; separa los bloques de la pantalla sin añadir otra tarjeta.
    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 4)
            content()
        }.padding(.top, 8)
    }

    private func heartCard(_ t: TodayMetrics) -> some View {
        NavigationLink(value: Route.heart) {
            VStack(alignment: .leading, spacing: 6) {
                MiniHeader(icon: "heart.fill", title: "Corazón", color: Theme.heart)
                HeartLiveValue(live: live, last: t.lastHR?.value)
                if t.lastHR != nil {
                    HeartDayChart(buckets: t.heartBuckets, domain: t.dayDomain, resting: t.resting?.value, interactive: false, compact: true).frame(height: 56)
                }
                HeartLiveCaption(live: live, last: t.lastHR, resting: t.resting?.value)
            }.miniCard()
        }.buttonStyle(.plain)
    }

    private func sleepCard(_ t: TodayMetrics) -> some View {
        NavigationLink(value: Route.sleep) {
            VStack(alignment: .leading, spacing: 6) {
                MiniHeader(icon: "moon.fill", title: "Sueño", color: Theme.sleep)
                if let n = t.sleep {
                    BigValue(value: hmColon(t.sleepTotal), unit: "h", size: 30)
                    Hypnogram(night: n, interactive: false, compact: true).frame(height: 56)
                    Text("\(n.start.hhmm) → \(n.end.hhmm)" + (t.naps.isEmpty ? "" : " · +\(t.naps.count == 1 ? "siesta" : "siestas")")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text("Sin sueño en las últimas 36 h").font(.subheadline).foregroundStyle(.secondary)
                }
            }.miniCard()
        }.buttonStyle(.plain)
    }

    private var weightCard: some View {
        NavigationLink(value: Route.weight) {
            VStack(alignment: .leading, spacing: 6) {
                MiniHeader(icon: "scalemass.fill", title: "Peso", color: Theme.light)
                if let w = logs.weights.last {
                    BigValue(value: w.kg.formatted(.number.precision(.fractionLength(1)).locale(esES)), unit: "kg", size: 30)
                    WeightMiniChart(entries: logs.weights).frame(height: 56)
                    Text(w.date.dayMonth).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Sin registros. Toca para añadir tu peso.").font(.subheadline).foregroundStyle(.secondary)
                }
            }.miniCard()
        }.buttonStyle(.plain)
    }

    private var moodCard: some View {
        NavigationLink(value: Route.mood) {
            VStack(alignment: .leading, spacing: 6) {
                MiniHeader(icon: "face.smiling", title: "Ánimo", color: Theme.rem)
                if let m = logs.moods.last {
                    HStack(spacing: 8) {
                        Text(MoodEntry.faces[m.level - 1]).font(.system(size: 30))
                        Text(MoodEntry.names[m.level - 1]).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
                    }
                    Text(m.date.dayMonth).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Sin registros. Toca para anotar cómo estás.").font(.subheadline).foregroundStyle(.secondary)
                }
            }.miniCard()
        }.buttonStyle(.plain)
    }

    /// Calorías de hoy y de los seis días anteriores. La API no da la curva del día, así que se compara con el objetivo y con los días previos.
    private func caloriesCard(_ t: TodayMetrics) -> some View {
        let startToday = esCalendar.startOfDay(for: Date())
        let previous = (model.history?.days ?? []).filter { $0.day < startToday }.suffix(6).compactMap { d in d.calories.map { (d.day, $0) } }
        let bars = previous + (t.calories.map { [(startToday, $0)] } ?? [])
        let goal = Double(caloriesGoal)
        return NavigationLink(value: Route.activity) {
            VStack(alignment: .leading, spacing: 6) {
                MiniHeader(icon: "flame.fill", title: "Calorías", color: Theme.calories)
                if let k = t.calories {
                    BigValue(value: Int(k.rounded()).formatted(), unit: "kcal", size: 30)
                    Chart {
                        ForEach(bars, id: \.0) { d, v in
                            BarMark(x: .value("Día", d, unit: .day), y: .value("kcal", v), width: .fixed(8))
                                .foregroundStyle(Theme.calories.opacity(esCalendar.isDateInToday(d) ? 1 : 0.45)).cornerRadius(2)
                        }
                        RuleMark(y: .value("Objetivo", goal)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3])).foregroundStyle(.secondary)
                    }
                    .chartXAxis(.hidden).chartYAxis(.hidden)
                    .chartYScale(domain: 0...max(goal * 1.15, (bars.map(\.1).max() ?? 0) * 1.1))
                    .frame(height: 56)
                    Text("de \(caloriesGoal.formatted()) · \(Int((k / goal * 100).rounded())) %").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text("Sin datos de calorías hoy").font(.subheadline).foregroundStyle(.secondary)
                }
            }.miniCard()
        }.buttonStyle(.plain)
    }

    private func stepsCard(_ t: TodayMetrics) -> some View {
        NavigationLink(value: Route.activity) {
            VStack(alignment: .leading, spacing: 6) {
                MiniHeader(icon: "figure.walk", title: "Pasos", color: Theme.steps)
                BigValue(value: Int(t.steps).formatted(), unit: "", size: 30)
                StepsCumChart(points: t.cumulative, midnight: t.midnight, compact: true).frame(height: 56)
                Text("\(Int((t.steps / Double(stepsGoal) * 100).rounded())) % · \(String(format: "%.2f", t.distanceKm)) km").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }.miniCard()
        }.buttonStyle(.plain)
    }
}

/// El pulso en directo llega cada segundo: solo estas dos piezas observan `LiveHeart`; la gráfica de la tarjeta no se repinta.
private struct HeartLiveValue: View {
    @ObservedObject var live: LiveHeart
    let last: Double?

    var body: some View {
        // Se reevalúa cada segundo: la pulsera manda una muestra por segundo y, al faltar, vuelve a los datos de la API.
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let liveBPM = live.isLive(at: ctx.date) ? live.bpm : nil
            if let v = liveBPM ?? last.map({ Int($0) }) {
                BigValue(value: "\(v)", unit: "lpm", size: 30)
            } else {
                Text("Sin muestras hoy").font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

private struct HeartLiveCaption: View {
    @ObservedObject var live: LiveHeart
    let last: Reading?
    let resting: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let isLive = live.isLive(at: ctx.date) && live.bpm != nil
            if let last {
                Text("Reposo \(resting.map { "\(Int($0))" } ?? "—") · \(isLive ? "en directo" : last.time.hhmm)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else if isLive {
                Text("En directo").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Esqueleto de la pantalla mientras llega la primera lectura: mismas formas que las tarjetas reales, con un latido suave.
private struct TodaySkeleton: View {
    @State private var dim = false

    var body: some View {
        VStack(spacing: 16) {
            block(height: 150, radius: Theme.cardRadius)
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: 12) { block(height: 140, radius: Theme.cardRadius - 2); block(height: 140, radius: Theme.cardRadius - 2) }
            }
        }
        .opacity(dim ? 0.45 : 1)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: dim)
        .onAppear { dim = true }
        .accessibilityElement().accessibilityLabel("Leyendo Google Health")
    }

    private func block(height: CGFloat, radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Theme.cardFill)
            .overlay { RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.cardStroke, lineWidth: 1) }
            .frame(height: height)
    }
}

#if DEBUG
#Preview("Con datos") { TodayView().previewEnvironment() }
#Preview("Sin datos") { TodayView().previewEnvironment(empty: true) }
#endif
