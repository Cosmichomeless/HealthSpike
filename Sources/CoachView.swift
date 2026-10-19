import SwiftUI

// Pestaña Coach (#46): los resúmenes de la IA local en formato log, como el coach de Google. Todo en un único scroll;
// solo los de hoy y ayer, y los anteriores en «Historial».

/// Abre la pestaña Coach desde otras pantallas (la tarjeta de Hoy).
private struct OpenCoachKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var openCoach: () -> Void {
        get { self[OpenCoachKey.self] }
        set { self[OpenCoachKey.self] = newValue }
    }
}

extension SummaryKind {
    var icon: String { self == .sleep ? "moon.fill" : (self == .workouts ? "figure.run" : "sun.max.fill") }
}

private let clockStyle = Date.FormatStyle().hour(.twoDigits(amPM: .omitted)).minute().locale(esES)

private func md(_ s: String) -> Text {
    Text((try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s))
}

struct CoachView: View {
    @EnvironmentObject private var model: HealthModel
    @EnvironmentObject private var coach: CoachStore
    @State private var choice = DayChoice.today
    @State private var showChat = false

    private var recent: [(title: String, list: [CoachMessage])] {
        let cal = Calendar.current
        let today = coach.messages.filter { cal.isDateInToday($0.created) }
        let yesterday = coach.messages.filter { cal.isDateInYesterday($0.created) }
        return [("Hoy", today), ("Ayer", yesterday)].filter { !$0.1.isEmpty }.map { (title: $0.0, list: $0.1) }
    }

    var body: some View {
        let st = SystemLM.status
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if st.ok { generator } else { notice(st.text) }
                if coach.pending != nil || coach.errorText != nil { live }
                if recent.isEmpty && coach.pending == nil {
                    EmptyNote(text: st.ok ? "Aún no hay mensajes. Pídele un resumen al Coach." : "Cuando el modelo esté disponible, tus resúmenes aparecerán aquí.")
                }
                ForEach(recent, id: \.title) { group in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(group.title).font(.title3.weight(.bold)).padding(.bottom, 4)
                        ForEach(group.list) { m in
                            Divider()
                            CoachEntry(message: m) { coach.delete(m) }
                        }
                    }
                }
                NavigationLink { CoachHistoryView() } label: {
                    Label("Historial", systemImage: "clock.arrow.circlepath").frame(maxWidth: .infinity)
                }.buttonStyle(.bordered).tint(.purple)
            }
            .padding(.horizontal, 16).padding(.bottom, 88)
        }
        .overlay(alignment: .bottomTrailing) {
            if st.ok {
                Button { showChat = true } label: {
                    Image(systemName: "bubble.left.and.text.bubble.right.fill").font(.title2).foregroundStyle(.white)
                        .frame(width: 56, height: 56).background(Color.purple, in: Circle()).shadow(radius: 4, y: 2)
                }
                .accessibilityLabel("Abrir el chat")
                .padding(.trailing, 16).padding(.bottom, 16)
            }
        }
        .sheet(isPresented: $showChat) { CoachChatView() }
        .healthChrome("Coach")
    }

    // MARK: Pedir un resumen

    private var generator: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(icon: "sparkles", title: "Pídele un resumen", color: .purple, chevron: false)
            DayChoicePicker(choice: $choice).disabled(coach.pending != nil)
            if coach.pending != nil {
                Button { coach.cancel() } label: { Label("Parar", systemImage: "stop.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).tint(.purple)
            } else {
                HStack(spacing: 8) {
                    ForEach(SummaryKind.allCases) { (kind: SummaryKind) in kindButton(kind) }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).card()
    }

    @ViewBuilder private func kindButton(_ kind: SummaryKind) -> some View {
        let label = VStack(spacing: 4) {
            Image(systemName: kind.icon)
            Text(kind.rawValue).font(.footnote.weight(.semibold))
        }.frame(maxWidth: .infinity)
        if kind == SummaryKind.suggested {
            Button { coach.generate(kind, choice, model: model) } label: { label }.buttonStyle(.borderedProminent).tint(.purple)
        } else {
            Button { coach.generate(kind, choice, model: model) } label: { label }.buttonStyle(.bordered).tint(.purple)
        }
    }

    private func notice(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            CardHeader(icon: "sparkles", title: "Coach no disponible", color: .purple, chevron: false)
            Text(text).font(.subheadline)
            Text("Los resúmenes los escribe el modelo de Apple Intelligence, que corre en el iPhone: no sale nada del móvil.")
                .font(.footnote).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).card()
    }

    /// El mensaje que se está escribiendo (o el error si falla).
    private var live: some View {
        let b = Brief(coach.partial)
        return VStack(alignment: .leading, spacing: 8) {
            if let p = coach.pending {
                Label("\(p.kind.cardTitle) · \(p.day == .today ? "hoy" : "ayer")", systemImage: p.kind.icon)
                    .font(.footnote.weight(.semibold)).foregroundStyle(.purple)
                if b.structured {
                    if !b.title.isEmpty { md(b.title).font(.title3.weight(.semibold)) }
                    if !b.summary.isEmpty { md(b.summary).font(.body).foregroundStyle(.secondary) }
                    if !b.advice.isEmpty { md(b.advice).font(.body).foregroundStyle(.secondary) }
                } else {
                    ProgressView("Pensando…")
                }
            }
            if let e = coach.errorText { Text(e).font(.subheadline).foregroundStyle(.red) }
        }.frame(maxWidth: .infinity, alignment: .leading).card()
    }
}

/// Un mensaje del log: sin tarjeta, separado de los demás por una línea.
struct CoachEntry: View {
    let message: CoachMessage
    var onDelete: (() -> Void)?

    private var dataDay: String? {
        let cal = Calendar.current
        if cal.isDate(message.day, inSameDayAs: message.created) { return nil }
        if let before = cal.date(byAdding: .day, value: -1, to: message.created), cal.isDate(message.day, inSameDayAs: before) { return "Datos de ayer" }
        return "Datos del " + message.day.formatted(Date.FormatStyle().weekday(.wide).day().month(.abbreviated).locale(esES))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(message.heading, systemImage: message.kind.icon).font(.footnote.weight(.semibold)).foregroundStyle(.purple)
                Spacer()
                Text(message.created.formatted(clockStyle)).font(.footnote).foregroundStyle(.secondary)
                if let onDelete {
                    Menu {
                        Button("Borrar", systemImage: "trash", role: .destructive, action: onDelete)
                    } label: {
                        Image(systemName: "ellipsis").font(.body.weight(.semibold)).foregroundStyle(.secondary)
                            .frame(width: 32, height: 28).contentShape(Rectangle())
                    }.accessibilityLabel("Opciones del mensaje")
                }
            }
            if let d = dataDay { Text(d).font(.footnote).foregroundStyle(.secondary) }
            md(message.title).font(.title3.weight(.semibold))
            md(message.summary).font(.body).foregroundStyle(.secondary)
            if !message.advice.isEmpty {
                Label { md(message.advice).font(.body) } icon: { Image(systemName: "lightbulb.fill").foregroundStyle(.yellow) }
            }
            if !message.unknown.isEmpty {
                Label("Cifras que no están en los datos: \(message.unknown.joined(separator: ", "))", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(.orange)
            }
        }
        .textSelection(.enabled)
        .padding(.vertical, 14).frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Los mensajes de antes de ayer, agrupados por día.
struct CoachHistoryView: View {
    @EnvironmentObject private var coach: CoachStore

    private var groups: [(day: Date, list: [CoachMessage])] {
        let cal = Calendar.current
        let older = coach.messages.filter { !cal.isDateInToday($0.created) && !cal.isDateInYesterday($0.created) }
        return Dictionary(grouping: older) { cal.startOfDay(for: $0.created) }
            .map { (day: $0.key, list: $0.value.sorted { $0.created > $1.created }) }
            .sorted { $0.day > $1.day }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if groups.isEmpty { EmptyNote(text: "Todavía no hay mensajes anteriores.") }
                ForEach(groups, id: \.day) { group in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(group.day.formatted(Date.FormatStyle().weekday(.wide).day().month(.wide).locale(esES)).capitalized)
                            .font(.title3.weight(.bold)).padding(.bottom, 4)
                        ForEach(group.list) { m in
                            Divider()
                            CoachEntry(message: m) { coach.delete(m) }
                        }
                    }
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 24)
        }
        .healthChrome("Historial")
    }
}

/// Entrada desde Hoy: el último mensaje, o la invitación a pedir uno. Solo se muestra si el modelo está disponible.
struct CoachTeaser: View {
    @EnvironmentObject private var coach: CoachStore
    @Environment(\.openCoach) private var open

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 8) {
                CardHeader(icon: "sparkles", title: "Coach", color: .purple, chevron: true)
                if let m = coach.messages.first {
                    Text(m.heading).font(.footnote).foregroundStyle(.secondary)
                    md(m.title).font(.headline).foregroundStyle(.primary)
                    md(m.summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                } else {
                    Text("Pídele un resumen de tu sueño, tus entrenos o tu día.").font(.subheadline).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).card()
        }.buttonStyle(.plain)
    }
}

#if DEBUG
#Preview("Coach") { CoachView().previewScreen() }
#Preview("Chat") { CoachChatView().previewEnvironment().environmentObject(CoachChat.preview) }
#Preview("Historial") { CoachHistoryView().previewScreen() }
#Preview("Tarjeta en Hoy") { CoachTeaser().previewEnvironment().previewCard() }
#endif
