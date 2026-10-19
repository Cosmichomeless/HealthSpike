import SwiftUI

struct RingView: View {
    var progress: Double
    var color: Color
    var lineWidth: CGFloat = 11

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.004, min(progress, 1)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

/// Media luna de progreso, pegada al borde superior del marco. El texto (valor sobre la base de la luna y leyenda debajo)
/// se alinea abajo; `height(width:below:)` da el alto del marco, siendo `below` lo que ocupa el texto por debajo de la base.
struct ArcMeter: View {
    var progress: Double
    var color: Color
    var lineWidth: CGFloat = 11

    static func height(width: CGFloat, lineWidth: CGFloat = 11, below: CGFloat) -> CGFloat { (width - lineWidth) / 2 + lineWidth / 2 + below }

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

/// Círculo grande con valor dentro y título/leyenda debajo (los tres de «Hoy»).
struct RingStat: View {
    let value: String, unit: String
    let progress: Double
    let color: Color
    let title: String, caption: String

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .bottom) {
                ArcMeter(progress: progress, color: color)
                VStack(spacing: 0) {
                    Text(value).font(.system(size: 22, weight: .bold)).minimumScaleFactor(0.6).lineLimit(1)
                    Text(unit).font(.caption2).foregroundStyle(.secondary)
                }.padding(.horizontal, 14)
            }
            .frame(maxWidth: 100).aspectRatio(100 / ArcMeter.height(width: 100, below: 17), contentMode: .fit)
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(color)
            Text(caption).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(2)
        }
        .frame(maxWidth: .infinity)
    }
}

struct CardHeader: View {
    let icon: String, title: String
    let color: Color
    var trailing: String?
    var chevron = true

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(color)
            Text(title).font(.headline).foregroundStyle(color)
            Spacer()
            if let trailing { Text(trailing).font(.subheadline).foregroundStyle(.secondary) }
            if chevron { Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary) }
        }
    }
}

/// Cabecera compacta para las tarjetas de media anchura.
struct MiniHeader: View {
    let icon: String, title: String
    let color: Color
    var trailing: String?
    var chevron = true

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.subheadline).foregroundStyle(color)
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 2)
            if let trailing { Text(trailing).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            if chevron { Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary) }
        }
    }
}

struct StatCell: View {
    let title: String, value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct BigValue: View {
    let value: String, unit: String
    var size: CGFloat = 38
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value).font(.system(size: size, weight: .bold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(unit).font(.subheadline).foregroundStyle(.secondary)
        }
    }
}

struct EmptyNote: View {
    let text: String
    var body: some View {
        Text(text).font(.subheadline).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 80)
    }
}

struct ErrorBanner: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote).foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Fases de la noche, una fila por fase: punto de color, duración, porcentaje y barra.
struct SleepStageRows: View {
    let night: SleepNight

    var body: some View {
        let total = night.minutes.values.reduce(0, +)
        VStack(alignment: .leading, spacing: 12) {
            ForEach(["DEEP", "LIGHT", "REM", "AWAKE"], id: \.self) { st in
                let m = night.minutes[st] ?? 0
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Circle().fill(Theme.stageColor(st)).frame(width: 9, height: 9)
                        Text(Theme.stageName(st))
                        Spacer()
                        Text(hm(m)).monospacedDigit()
                        Text("\(Int((total > 0 ? m / total * 100 : 0).rounded())) %").foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                    }.font(.subheadline)
                    GeometryReader { g in
                        Capsule().fill(Theme.stageColor(st)).frame(width: g.size.width * (total > 0 ? m / total : 0), height: 5)
                    }.frame(height: 5)
                }
            }
        }
    }
}

/// Anillo de duración (con el % del objetivo) + durmiendo / en cama / eficiencia + hipnograma (con hora de acostarse y despertar) + fases (desplegable).
struct SleepNightContent: View {
    let night: SleepNight
    let goalHours: Double
    var chartHeight: CGFloat = 84
    var interactive = true
    @State private var showStages = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 18) {
                ZStack(alignment: .bottom) {
                    ArcMeter(progress: night.asleep / (goalHours * 60), color: Theme.sleep)
                    VStack(spacing: 0) {
                        Text(hmColon(night.asleep)).font(.system(size: 22, weight: .bold))
                        // El número va exactamente en el centro; el «%» cuelga a su derecha sin desplazarlo.
                        Text("\(Int((night.asleep / (goalHours * 60) * 100).rounded()))")
                            .overlay(alignment: .trailing) { Text(" %").fixedSize().alignmentGuide(.trailing) { _ in 0 } }
                            .font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(Theme.sleep)
                    }
                }.frame(width: 100, height: ArcMeter.height(width: 100, below: 17))
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 0) {
                        stat("moon.zzz.fill", "Durmiendo", hm(night.asleep), color: Theme.sleep)
                        Divider().frame(height: 44).padding(.horizontal, 10)
                        stat("bed.double.fill", "En cama", hm(night.end.timeIntervalSince(night.start) / 60), color: .secondary)
                    }
                    efficiency.frame(maxWidth: 210).frame(maxWidth: .infinity)
                }
            }
            Hypnogram(night: night, interactive: interactive).frame(height: chartHeight)
            Divider()
            DisclosureGroup(isExpanded: $showStages) {
                VStack(alignment: .leading, spacing: 14) {
                    SleepStageRows(night: night)
                    Divider()
                    NightHeartRow(night: night)
                }.padding(.top, 10)
            } label: {
                Text("Fases y pulso").font(.headline)
            }.tint(.secondary)
        }
    }

    /// Eficiencia: la parte del tiempo en cama que pasas dormido. 90 % o más buena, 85–89 % normal, por debajo baja.
    private var efficiency: some View {
        let bed = max(night.end.timeIntervalSince(night.start) / 60, 1)
        let eff = min(night.asleep / bed, 1)
        let tint: Color = eff >= 0.9 ? .green : eff >= 0.85 ? .orange : .red
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "gauge.with.dots.needle.67percent").foregroundStyle(tint).frame(width: 9)
                Text("Eficiencia")
                Spacer()
                Text("\(Int((eff * 100).rounded())) %").monospacedDigit().fontWeight(.semibold)
            }.font(.subheadline)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(tint.opacity(0.18))
                    Capsule().fill(tint).frame(width: g.size.width * eff)
                }
            }.frame(height: 5)
        }
    }

    private func stat(_ icon: String, _ title: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(color).labelStyle(.titleAndIcon)
            Text(value).font(.system(.title3).weight(.bold).monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.7)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension View {
    /// Barra común a las pantallas raíz: botón de ajustes arriba a la derecha y tirar para actualizar.
    func healthChrome(_ title: String) -> some View {
        modifier(HealthChrome(title: title))
    }
}

private struct HealthChrome: ViewModifier {
    @EnvironmentObject var model: HealthModel
    @State private var showSettings = false
    let title: String

    func body(content: Content) -> some View {
        content
            .background(Theme.background)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape.fill") }.accessibilityLabel("Ajustes")
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            // Tarea independiente: SwiftUI cancela la del gesto al cambiar `loading` y la petición moría con "cancelled".
            .refreshable { await Task { await model.refresh() }.value }
    }
}

/// Hoy o ayer en las pantallas de Día.
enum DayChoice: String, CaseIterable, Identifiable {
    case today = "Hoy", yesterday = "Ayer"
    var id: String { rawValue }
}

struct DayChoicePicker: View {
    @Binding var choice: DayChoice
    var body: some View {
        Picker("Día", selection: $choice) { ForEach(DayChoice.allCases) { Text($0.rawValue).tag($0) } }
            .pickerStyle(.segmented).frame(maxWidth: 180)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

#if DEBUG
#Preview("Anillos y cabeceras") {
    @Previewable @State var day = DayChoice.today
    return ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                RingStat(value: "8.420", unit: "pasos", progress: 0.84, color: .orange, title: "Pasos", caption: "84 % del objetivo")
                RingStat(value: "7:12", unit: "h", progress: 0.9, color: Theme.sleep, title: "Sueño", caption: "Objetivo 8 h")
            }
            RingView(progress: 0.6, color: .blue).frame(width: 80, height: 80)
            CardHeader(icon: "heart.fill", title: "Corazón", color: .red, trailing: "58 lpm")
            MiniHeader(icon: "figure.walk", title: "Pasos", color: .orange, trailing: "8.420")
            HStack { StatCell(title: "Mínimo", value: "48"); StatCell(title: "Máximo", value: "142") }
            BigValue(value: "8.420", unit: "pasos")
            EmptyNote(text: "Sin datos todavía")
            ErrorBanner(text: "No se pudo descargar ayer. Vuelve a probar.")
            DayChoicePicker(choice: $day)
        }.padding(16)
    }.previewEnvironment()
}
#Preview("Noche de sueño") {
    ScrollView { SleepNightContent(night: PreviewData.night(), goalHours: 8).padding(16) }.previewEnvironment()
}
#Preview("Fases del sueño") { SleepStageRows(night: PreviewData.night()).padding(16).previewEnvironment() }
#Preview("Barra común") {
    ScrollView { Text("Contenido").padding() }.healthChrome("Título").previewScreen()
}
#endif
