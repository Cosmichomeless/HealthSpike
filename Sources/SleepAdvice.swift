import SwiftUI

/// Cuánto dormir esta noche, calculado en local con las últimas noches (no es una cifra médica).
///
/// - Base: tu objetivo de sueño.
/// - Deuda: cada noche de los últimos 7 días que quedó por debajo del objetivo suma su déficit; se recupera un 25 % (máx. +60 min),
///   porque la deuda no se paga entera en una sola noche.
/// - Actividad: si hoy superas en un 50 % tu objetivo de pasos, +15 min de recuperación.
/// - Límites: entre 6 h y 10 h.
/// - Hora de acostarse: la hora a la que te despiertas mañana (la eliges tú; si no, tu hora media de los últimos 7 días)
///   menos las horas necesarias y ~15 min para dormirte.
struct SleepPlan {
    let goalMin: Double
    let debtMin: Double          // déficit acumulado en 7 días
    let debtExtra: Double        // lo que se recupera hoy
    let activityExtra: Double
    let totalMin: Double
    let wake: Date
    let habitualWake: Date
    let isCustomWake: Bool
    let bedtime: Date
    let nightsUsed: Int

    /// Día de «la próxima mañana»: hasta las 5:00 todavía cuenta como la noche en curso (despertar hoy); después, mañana.
    static func nextWakeDay(_ now: Date = Date()) -> Date {
        let cal = Calendar.current
        return cal.component(.hour, from: now) < 5 ? now : cal.date(byAdding: .day, value: 1, to: now)!
    }

    /// Lleva una hora del reloj (la que marca el selector) a su fecha real de despertar.
    static func resolveWake(_ time: Date, now: Date = Date()) -> Date {
        let cal = Calendar.current, t = cal.dateComponents([.hour, .minute], from: time)
        return cal.startOfDay(for: nextWakeDay(now)).addingTimeInterval(Double(t.hour! * 60 + t.minute!) * 60)
    }

    static func make(nights: [SleepNight], goalHours: Double, steps: Double, stepsGoal: Double, wakeChoice: Date? = nil, now: Date = Date()) -> SleepPlan? {
        let cal = Calendar.current
        let from = cal.date(byAdding: .day, value: -7, to: now)!
        let recent = Dictionary(grouping: nights.filter { $0.end >= from }) { cal.startOfDay(for: $0.end) }
            .values.compactMap { $0.max(by: { $0.asleep < $1.asleep }) }
        guard !recent.isEmpty else { return nil }
        let goal = goalHours * 60
        let debt = recent.map { max(0, goal - $0.asleep) }.reduce(0, +)
        let extra = min(debt * 0.25, 60)
        let activity = steps >= stepsGoal * 1.5 ? 15.0 : 0
        let total = min(max(goal + extra + activity, 360), 600)

        // Hora media de despertar (minutos desde medianoche) llevada al día de mañana.
        let wakeMin = recent.map { n -> Double in
            let c = cal.dateComponents([.hour, .minute], from: n.end)
            return Double(c.hour! * 60 + c.minute!)
        }.reduce(0, +) / Double(recent.count)
        let habitual = cal.startOfDay(for: nextWakeDay(now)).addingTimeInterval(wakeMin * 60)
        let wake = wakeChoice ?? habitual
        let bed = wake.addingTimeInterval(-(total + 15) * 60)
        return SleepPlan(goalMin: goal, debtMin: debt, debtExtra: extra, activityExtra: activity,
                         totalMin: total, wake: wake, habitualWake: habitual, isCustomWake: wakeChoice != nil,
                         bedtime: bed, nightsUsed: recent.count)
    }
}

struct SleepAdviceCard: View {
    let plan: SleepPlan?
    @Binding var wakeChoice: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(icon: "bed.double.fill", title: "Esta noche", color: Theme.sleep, trailing: "Recomendación", chevron: false)
            if let p = plan {
                BigValue(value: hm(p.totalMin), unit: "de sueño")
                HStack {
                    DatePicker("Me despierto mañana a las", selection: Binding(get: { wakeChoice ?? p.habitualWake }, set: { wakeChoice = $0 }),
                               displayedComponents: .hourAndMinute)
                        .environment(\.locale, esES).font(.subheadline)
                    if p.isCustomWake {
                        Button { wakeChoice = nil } label: { Image(systemName: "arrow.uturn.backward.circle") }.buttonStyle(.borderless)
                            .accessibilityLabel("Volver a la hora habitual")
                    }
                }
                HStack(spacing: 18) {
                    labeled("Acuéstate sobre las", p.bedtime.hhmm)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    labeled("Despertar", p.wake.hhmm)
                }
                if p.bedtime < Date() {
                    let left = max(0, p.wake.timeIntervalSinceNow / 60 - 15)
                    Text("Esa hora ya ha pasado: si te acuestas ya dormirías unas \(hm(left)).").font(.footnote).foregroundStyle(.orange)
                }
                VStack(alignment: .leading, spacing: 4) {
                    line("Tu objetivo", hm(p.goalMin))
                    line("Recuperar deuda (\(hm(p.debtMin)) en \(p.nightsUsed) noches)", p.debtExtra > 0 ? "+\(Int(p.debtExtra.rounded())) min" : "—")
                    if p.activityExtra > 0 { line("Día muy activo", "+\(Int(p.activityExtra)) min") }
                }
                Text(p.isCustomWake ? "Cálculo local con tus últimas noches y la hora que has elegido: no es consejo médico."
                                    : "Hora habitual: la media a la que te has despertado estos días. Cámbiala si mañana te levantas antes o después.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                EmptyNote(text: "Hacen falta noches registradas para calcularlo")
            }
        }.card()
    }

    private func labeled(_ t: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(t).font(.caption).foregroundStyle(.secondary)
            Text(v).font(.title3.weight(.semibold).monospacedDigit())
        }
    }

    private func line(_ t: String, _ v: String) -> some View {
        HStack { Text(t); Spacer(); Text(v).monospacedDigit() }.font(.subheadline)
    }
}

extension Binding where Value == Double {
    /// Hora de despertar elegida, guardada como instante absoluto (0 = ninguna): se conserva al salir de la vista y caduca al llegar esa hora.
    var wakeChoice: Binding<Date?> {
        Binding<Date?>(get: { wrappedValue > Date().timeIntervalSince1970 ? Date(timeIntervalSince1970: wrappedValue) : nil },
                       set: { wrappedValue = $0.map { SleepPlan.resolveWake($0).timeIntervalSince1970 } ?? 0 })
    }
}

extension HealthModel {
    /// Recomendación de esta noche con las noches descargadas y la de anoche.
    func sleepPlan(goalHours: Double, stepsGoal: Int, wake: Date?) -> SleepPlan? {
        let last = today?.sleep ?? nights.last
        return SleepPlan.make(nights: nights + (last.map { [$0] } ?? []), goalHours: goalHours, steps: today?.steps ?? 0,
                              stepsGoal: Double(stepsGoal), wakeChoice: wake)
    }
}

/// Tarjeta de media anchura de «Sueño»: horas recomendadas y hora de acostarse. Abre `SleepAdviceView`.
struct SleepAdviceMiniCard: View {
    @EnvironmentObject var model: HealthModel
    @AppStorage("sleepGoalHours") private var sleepGoal = 8.0
    @AppStorage("stepsGoal") private var stepsGoal = 10_000
    @AppStorage("wakeChoiceTS") private var wakeChoiceTS = 0.0

    var body: some View {
        let plan = model.sleepPlan(goalHours: sleepGoal, stepsGoal: stepsGoal, wake: $wakeChoiceTS.wakeChoice.wrappedValue)
        NavigationLink(value: Route.sleepAdvice) {
            VStack(alignment: .leading, spacing: 6) {
                MiniHeader(icon: "bed.double.fill", title: "Esta noche", color: Theme.sleep)
                if let p = plan {
                    BigValue(value: hmColon(p.totalMin), unit: "h", size: 30)
                    Text("de sueño recomendado").font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                    Text("Acuéstate sobre las \(p.bedtime.hhmm)").font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                } else {
                    Text("Hacen falta noches registradas").font(.subheadline).foregroundStyle(.secondary)
                }
            }.miniCard()
        }.buttonStyle(.plain)
    }
}

/// Recomendación de esta noche a pantalla completa, con selector de la hora de despertar.
struct SleepAdviceView: View {
    @EnvironmentObject var model: HealthModel
    @AppStorage("sleepGoalHours") private var sleepGoal = 8.0
    @AppStorage("stepsGoal") private var stepsGoal = 10_000
    @AppStorage("wakeChoiceTS") private var wakeChoiceTS = 0.0

    var body: some View {
        let wake = $wakeChoiceTS.wakeChoice
        ScrollView {
            SleepAdviceCard(plan: model.sleepPlan(goalHours: sleepGoal, stepsGoal: stepsGoal, wake: wake.wrappedValue), wakeChoice: wake)
                .padding(.horizontal, 16).padding(.bottom, 24)
        }
        .healthChrome("Esta noche")
    }
}

#if DEBUG
#Preview("Consejo") {
    @Previewable @State var wake: Date?
    return SleepAdviceCard(plan: HealthModel.preview.sleepPlan(goalHours: 8, stepsGoal: 10_000, wake: wake), wakeChoice: $wake)
        .previewCard().previewEnvironment()
}
#Preview("Tarjeta pequeña") { SleepAdviceMiniCard().frame(width: 180, height: 140).previewCard().previewScreen() }
#Preview("Pantalla") { SleepAdviceView().previewScreen() }
#endif
