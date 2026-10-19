import SwiftUI
import Combine

// Chat del Coach (#46): preguntas libres al modelo del sistema, con los datos de hoy, ayer y la última semana.
// La app calcula las cifras y el modelo solo las redacta. La ventana de contexto del modelo es corta, así que cada pregunta abre una sesión nueva
// con los datos al día y las últimas vueltas de la conversación resumidas en el propio texto, en vez de arrastrar una sesión que acabaría desbordándose.

private struct GemmaFailure: LocalizedError {
    let text: String
    var errorDescription: String? { text }
}

struct ChatLine: Identifiable, Equatable {
    var id = UUID()
    var isUser: Bool
    var text: String
    /// Cifras de la respuesta que no estaban en los datos.
    var unknown: [String] = []
}

/// Qué modelo contesta en el chat.
enum ChatEngine: String, CaseIterable, Identifiable {
    case system, gemma
    var id: String { rawValue }
    var title: String { self == .system ? "Modelo del sistema" : "Gemma 4 (E2B)" }
    var note: String { self == .system ? "Apple Intelligence, ya en el iPhone" : "Se descarga la primera vez (≈ 3,5 GB)" }
}

@MainActor
final class CoachChat: ObservableObject {
    @Published private(set) var lines: [ChatLine] = []
    @Published private(set) var running = false
    @Published private(set) var errorText: String?
    @Published var engine = ChatEngine(rawValue: UserDefaults.standard.string(forKey: "coachChatEngine") ?? "") ?? .system {
        didSet { UserDefaults.standard.set(engine.rawValue, forKey: "coachChatEngine") }
    }
    let gemma = GemmaEngine()
    private var task: Task<Void, Never>?
    private var gemmaChanges: AnyCancellable?

    init() {
        // Para que la vista se refresque con el progreso de la descarga.
        gemmaChanges = gemma.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }

    /// Lo que se muestra mientras la respuesta aún no ha empezado.
    var waitText: String {
        guard engine == .gemma else { return "Pensando…" }
        switch gemma.state {
        case .downloading(let f): return "Descargando Gemma 4… \(Int((f * 100).rounded())) %"
        case .loading: return "Cargando Gemma 4 en memoria…"
        default: return "Pensando…"
        }
    }

    static let suggestions = ["¿Qué entreno me propones para hoy?", "¿Cómo ha ido mi semana?", "¿Qué tal he dormido esta semana?"]

    private static let instructions = """
        Eres el coach de una app personal de salud. Respondes siempre en español, en segunda persona (tú), con tono cercano y directo, sin saludos, despedidas ni emojis.
        Contesta exactamente a lo que te preguntan y usa la parte de los datos que corresponde: «HOY» y «AYER» para esos días, «SEMANA PASADA» (la semana natural completa, de lunes a domingo) cuando preguntan por «mi semana» sin más, y «ESTA SEMANA» si dicen esta semana; «DÍA A DÍA» y «TOTALES Y MEDIAS» para el mes o cualquier otro periodo. La «Recuperación» de «HOY» es solo la de hoy, no la de la semana. Para un resumen de un periodo escribe una frase por cada tema —sueño, actividad (pasos), entrenos, recuperación— y una valoración final. En cada afirmación nombra el día (por ejemplo «el martes 13») y da la cifra exacta de los datos; no digas «un día» ni «algunos días» sin concretar cuál. Usa los «mejores y peores días» de «TOTALES Y MEDIAS».
        Respondes a las preguntas sobre los datos y, si te lo piden, propones un entrenamiento o un hábito concreto para hoy: tipo de actividad, intensidad dicha con palabras (suave, moderada, intensa) y una duración orientativa. Decide la propuesta según la «Recuperación», el sueño de la última noche y los entrenos de los últimos días, y explica en una frase por qué.
        Las cifras de los datos son las únicas que puedes citar como hechos: no inventes ninguna, no hagas restas, sumas ni porcentajes (usa los que ya vienen) y no des diagnósticos médicos. Si te preguntan algo que los datos no cubren, dilo en una frase.
        Respeta la «Hora actual»: de noche o de madrugada no propongas actividad diurna, sugiere descansar.
        Responde en un máximo de seis frases (siete si resumes un periodo) y pon en **negrita** (con dos asteriscos) las cifras clave.
        """

    func send(_ question: String, model: HealthModel) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !running else { return }
        // La conversación anterior, recortada, para que el modelo entienda «¿y mañana?».
        let history = lines.suffix(6).map { ($0.isUser ? "Pregunta: " : "Respuesta: ") + String($0.text.prefix(400)) }.joined(separator: "\n")
        lines.append(ChatLine(isUser: true, text: q))
        let answer = ChatLine(isUser: false, text: "")
        lines.append(answer)
        running = true; errorText = nil
        task = Task {
            defer { running = false }
            await model.loadYesterday()
            await model.loadWorkouts()
            let facts = Self.facts(model: model, days: engine == .gemma ? 30 : 7)
            let prompt = "Datos:\n\(facts)\n\n" + (history.isEmpty ? "" : "Conversación reciente:\n\(history)\n\n") + "Pregunta nueva: \(q)"
            do {
                switch engine {
                case .system:
                    try await SystemLM.respond(instructions: Self.instructions, prompt: prompt, structured: false) { [weak self] text in
                        self?.update(answer.id) { $0.text = text }
                    }
                case .gemma:
                    await gemma.load(.e2b)
                    if case .failed(let why) = gemma.state { throw GemmaFailure(text: "No se pudo cargar Gemma: \(why)") }
                    _ = try await gemma.respond(instructions: Self.instructions, prompt: prompt) { [weak self] text in
                        self?.update(answer.id) { $0.text = text }
                    }
                }
            } catch is CancellationError {
            } catch {
                errorText = error.localizedDescription
            }
            let text = lines.first { $0.id == answer.id }?.text ?? ""
            if text.isEmpty { lines.removeAll { $0.id == answer.id } } else {
                update(answer.id) { $0.unknown = DayFacts.unknownNumbers(in: text, facts: facts) }
            }
        }
    }

    func cancel() { task?.cancel() }

    /// Libera los ~3,5 GB de Gemma de la memoria.
    func unloadGemma() { gemma.unload() }

    func reset() {
        task?.cancel()
        lines = []; errorText = nil
    }

    private func update(_ id: UUID, _ change: (inout ChatLine) -> Void) {
        guard let i = lines.firstIndex(where: { $0.id == id }) else { return }
        change(&lines[i])
    }

    /// Todo lo que sabe la app, ya resumido para que el modelo no calcule nada: hoy, ayer y una tabla día a día de los últimos `days` días
    /// (pasos, calorías, sueño, pulso en reposo, VFC, SpO₂, respiración, temperatura, minutos en zona, recuperación, resiliencia y entrenos).
    private static func facts(model: HealthModel, days: Int) -> String {
        let d = UserDefaults.standard
        let steps = d.object(forKey: "stepsGoal") as? Int ?? 10_000
        let sleep = d.object(forKey: "sleepGoalHours") as? Double ?? 8.0
        let kcal = d.object(forKey: "caloriesGoal") as? Int ?? 2_500
        let settings = ScoreSettings()
        let cal = Calendar.current, now = Date(), today0 = cal.startOfDay(for: now)
        let es = Locale(identifier: "es_ES")
        let hm: (Double) -> String = { m in
            let t = Int(m.rounded())
            return t >= 60 ? (t % 60 == 0 ? "\(t / 60) h" : "\(t / 60) h \(t % 60) min") : "\(t) min"
        }
        let n0: (Double) -> String = { $0.formatted(.number.precision(.fractionLength(0)).locale(es)) }
        let n1: (Double) -> String = { $0.formatted(.number.precision(.fractionLength(1)).locale(es)) }
        let dayName: (Date) -> String = { $0.formatted(Date.FormatStyle().weekday(.wide).day().month(.abbreviated).locale(es)) }

        var parts = ["== HOY ==\n" + DayFacts.text(model: model, settings: settings, day: model.today, isToday: true, kind: .day, stepsGoal: steps, sleepGoal: sleep, caloriesGoal: kcal)]
        if model.yesterday != nil {
            parts.append("== AYER ==\n" + DayFacts.text(model: model, settings: settings, day: model.yesterday, isToday: false, kind: .day, stepsGoal: steps, sleepGoal: sleep, caloriesGoal: kcal))
        }

        let start = cal.date(byAdding: .day, value: -days, to: today0)!
        let stats = model.history?.days ?? []
        let nights = model.history?.nights ?? []
        let range = HistRange.month
        let rec = settings.recoverySeries(model, range: range), res = settings.resilienceSeries(model, range: range)
        let vit = model.vitals
        func vital(_ pts: [VitalPoint]?, _ day: Date) -> Double? { pts?.first { cal.isDate($0.day, inSameDayAs: day) }?.value }

        // Semanas naturales de lunes a domingo, como las cuenta Google: «mi semana» es la pasada, entera.
        var monday = cal
        monday.firstWeekday = 2
        let thisWeek = monday.dateInterval(of: .weekOfYear, for: now)?.start ?? today0
        let lastWeek = cal.date(byAdding: .day, value: -7, to: thisWeek) ?? thisWeek
        func weekBlock(_ title: String, _ from: Date, _ to: Date) -> String? {
            guard from < to, let last = cal.date(byAdding: .day, value: -1, to: to) else { return nil }
            var l = ["== \(title) (del \(dayName(from)) al \(dayName(last))) =="]
            let sv = stats.filter { $0.day >= from && $0.day < to }.compactMap(\.steps)
            if !sv.isEmpty { l.append("Pasos: media de \(n0(sv.reduce(0, +) / Double(sv.count))) al día, \(n0(sv.reduce(0, +))) en total, en \(sv.count) días (objetivo \(n0(Double(steps))) al día)") }
            let nn = nights.filter { $0.end >= from && $0.end < to }
            if !nn.isEmpty {
                let scores = nn.map { Double(model.sleepScore($0, goalHours: sleep).value) }
                l.append("Sueño: media de \(hm(nn.reduce(0) { $0 + $1.asleep } / Double(nn.count))) dormido por noche (objetivo \(hm(sleep * 60))), puntuación media de \(n1(scores.reduce(0, +) / Double(scores.count))) sobre 100, en \(nn.count) noches")
            }
            let rh = (vit?.rhr ?? []).filter { $0.day >= from && $0.day < to }.map(\.value)
            if !rh.isEmpty { l.append("Pulso en reposo: media de \(n0(rh.reduce(0, +) / Double(rh.count))) lpm") }
            let zm = (model.zones ?? []).filter { $0.day >= from && $0.day < to }.map(\.total)
            if !zm.isEmpty { l.append("Minutos en zona activa: \(n0(zm.reduce(0, +))) en total") }
            let ws = model.workouts(from: from, to: to)
            l.append(ws.isEmpty ? "Entrenos: ninguno registrado" : "Entrenos: \(ws.count), \(hm(ws.reduce(0) { $0 + $1.minutes })) en total")
            let rv = rec.filter { $0.day >= from && $0.day < to }.map { Double($0.value) }
            if !rv.isEmpty { l.append("Recuperación: media de \(n0(rv.reduce(0, +) / Double(rv.count))) de 100") }
            return l.count > 1 ? l.joined(separator: "\n") : nil
        }
        if let b = weekBlock("SEMANA PASADA", lastWeek, thisWeek) { parts.append(b) }
        if let b = weekBlock("ESTA SEMANA, SIN CONTAR HOY", thisWeek, today0) { parts.append(b) }

        // Una línea por día, del más reciente al más antiguo (sin hoy: ya está arriba).
        var log: [String] = []
        for back in 1...days {
            guard let day = cal.date(byAdding: .day, value: -back, to: today0) else { continue }
            var bits: [String] = []
            if let st = stats.first(where: { cal.isDate($0.day, inSameDayAs: day) }) {
                if let v = st.steps { bits.append("\(n0(v)) pasos") }
                if let v = st.calories { bits.append("\(n0(v)) kcal") }
                if let v = st.distanceKm { bits.append("\(n1(v)) km") }
                if let v = st.floors { bits.append("\(n0(v)) pisos") }
                if let v = st.hrAvg { bits.append("pulso medio \(n0(v)) lpm") }
            }
            // La noche que acaba ese día (se despierta por la mañana).
            if let n = nights.first(where: { cal.isDate($0.end, inSameDayAs: day) }) {
                let score = model.sleepScore(n, goalHours: sleep).value
                var s = "sueño \(hm(n.asleep)) (puntuación \(score))"
                let st = [("profundo", "DEEP"), ("REM", "REM"), ("ligero", "LIGHT")].compactMap { name, k in n.minutes[k].map { "\(name) \(hm($0))" } }
                if !st.isEmpty { s += ": " + st.joined(separator: ", ") }
                bits.append(s)
            }
            if let v = vital(vit?.rhr, day) { bits.append("pulso en reposo \(n0(v)) lpm") }
            if let v = vital(vit?.hrv, day) { bits.append("VFC \(n0(v)) ms") }
            if let v = vital(vit?.spo2, day) { bits.append("SpO₂ \(n0(v)) %") }
            if let v = vital(vit?.resp, day) { bits.append("respiración \(n1(v)) rpm") }
            if let v = vital(vit?.temp, day) { bits.append("temperatura \(v >= 0 ? "+" : "")\(n1(v)) °C sobre tu base") }
            if let z = model.zones?.first(where: { cal.isDate($0.day, inSameDayAs: day) }), z.total > 0 { bits.append("\(n0(z.total)) min en zona activa") }
            if let r = rec.first(where: { cal.isDate($0.day, inSameDayAs: day) }) { bits.append("recuperación \(r.value)") }
            if let r = res.first(where: { cal.isDate($0.day, inSameDayAs: day) }) { bits.append("resiliencia \(r.value)") }
            let ws = model.workouts(on: day)
            if !ws.isEmpty {
                bits.append("entrenos: " + ws.map { w in
                    "\(w.name) \(hm(w.minutes))" + (w.kcal.map { ", \(n0($0)) kcal" } ?? "") + (w.avgHR.map { ", pulso medio \($0) lpm" } ?? "")
                }.joined(separator: "; "))
            }
            log.append("- \(dayName(day)): " + (bits.isEmpty ? "sin datos" : bits.joined(separator: "; ")))
        }
        parts.append("== DÍA A DÍA, ÚLTIMOS \(days) DÍAS (del más reciente al más antiguo) ==\n" + log.joined(separator: "\n"))

        // Totales y medias del periodo, para no obligar al modelo a sumar.
        var sum = ["== TOTALES Y MEDIAS DE LOS ÚLTIMOS \(days) DÍAS =="]
        let ws = model.workouts(from: start, to: today0)
        sum.append(ws.isEmpty ? "Entrenos: ninguno registrado" : "Entrenos: \(ws.count), \(hm(ws.reduce(0) { $0 + $1.minutes })) en total")
        let st = stats.filter { $0.day >= start && $0.day < today0 }.compactMap(\.steps)
        if st.count >= 3 { sum.append("Pasos: media de \(n0(st.reduce(0, +) / Double(st.count))) al día (objetivo \(n0(Double(steps))))") }
        let ns = nights.filter { $0.end >= start && $0.end < today0 }
        if ns.count >= 3 { sum.append("Sueño: media de \(hm(ns.reduce(0) { $0 + $1.asleep } / Double(ns.count))) dormido en \(ns.count) noches (objetivo \(hm(sleep * 60)))") }
        let rv = rec.filter { $0.day < today0 }.map(\.value)
        if rv.count >= 3 { sum.append("Recuperación: media de \(n0(Double(rv.reduce(0, +)) / Double(rv.count))) de 100") }

        // Los mejores y peores días ya localizados, con su nombre: así el modelo no tiene que recorrer la tabla para citarlos.
        func extreme(_ label: String, _ values: [(Date, Double)], _ fmt: (Double) -> String, higherIsBetter: Bool = true) {
            guard values.count >= 3, let hi = values.max(by: { $0.1 < $1.1 }), let lo = values.min(by: { $0.1 < $1.1 }), hi.1 != lo.1 else { return }
            sum.append("\(label): más alto el \(dayName(hi.0)) (\(fmt(hi.1))), más bajo el \(dayName(lo.0)) (\(fmt(lo.1)))")
        }
        let inPeriod: (Date) -> Bool = { $0 >= start && $0 < today0 }
        extreme("Pasos", stats.filter { inPeriod($0.day) }.compactMap { s in s.steps.map { (s.day, $0) } }, n0)
        extreme("Sueño", ns.map { ($0.end, $0.asleep) }, hm)
        extreme("Recuperación", rec.filter { inPeriod($0.day) }.map { ($0.day, Double($0.value)) }, n0)
        extreme("Resiliencia", res.filter { inPeriod($0.day) }.map { ($0.day, Double($0.value)) }, n0)
        parts.append(sum.joined(separator: "\n"))
        return parts.joined(separator: "\n\n")
    }
}

// MARK: - Vistas

private func md(_ s: String) -> Text {
    Text((try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s))
}

/// La conversación: tus preguntas a la derecha y las respuestas del Coach a la izquierda.
struct CoachConversation: View {
    @EnvironmentObject private var chat: CoachChat

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(chat.lines) { line in
                if line.isUser {
                    md(line.text).padding(10).background(Color.purple.opacity(0.25), in: RoundedRectangle(cornerRadius: 14))
                        .frame(maxWidth: .infinity, alignment: .trailing).id(line.id)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        if line.text.isEmpty { ProgressView(chat.waitText).font(.footnote) } else { md(line.text).textSelection(.enabled) }
                        if !line.unknown.isEmpty {
                            Label("Cifras que no están en los datos: \(line.unknown.joined(separator: ", "))", systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote).foregroundStyle(.orange)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).id(line.id)
                }
            }
            if let e = chat.errorText { Text(e).font(.footnote).foregroundStyle(.red) }
        }
    }
}

/// Caja de texto fija abajo, como en un chat.
struct CoachComposer: View {
    @EnvironmentObject private var chat: CoachChat
    @EnvironmentObject private var model: HealthModel
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Pregunta al Coach…", text: $text, axis: .vertical)
                .lineLimit(1...4).focused($focused).submitLabel(.send)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                .onSubmit(send)
            Button(action: chat.running ? chat.cancel : send) {
                Image(systemName: chat.running ? "stop.circle.fill" : "arrow.up.circle.fill").font(.system(size: 32))
            }
            .tint(.purple)
            .disabled(!chat.running && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(.bar)
    }

    private func send() {
        chat.send(text, model: model)
        text = ""
    }
}

/// Preguntas de ejemplo mientras no hay conversación.
struct CoachSuggestions: View {
    @EnvironmentObject private var chat: CoachChat
    @EnvironmentObject private var model: HealthModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pregúntale lo que quieras").font(.footnote).foregroundStyle(.secondary)
            ForEach(CoachChat.suggestions, id: \.self) { s in
                Button(s) { chat.send(s, model: model) }.buttonStyle(.bordered).tint(.purple)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

#if DEBUG
extension CoachChat {
    static var preview: CoachChat {
        let c = CoachChat()
        c.lines = [ChatLine(isUser: true, text: "¿Qué entreno me propones para hoy?"),
                   ChatLine(isUser: false, text: "Tu recuperación es **alta** y dormiste casi lo que querías: una **caminata a paso ligero** o un rodaje suave encaja bien hoy.")]
        return c
    }
}
#endif

/// La vista del chat, que se abre desde la burbuja de la pestaña Coach.
struct CoachChatView: View {
    @EnvironmentObject private var chat: CoachChat
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if chat.lines.isEmpty { CoachSuggestions() } else { CoachConversation() }
                    }.padding(16)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: chat.lines.last?.id) { _, id in if let id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } } }
            }
            .background(Theme.background)
            .safeAreaInset(edge: .bottom) { CoachComposer() }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Borrar", role: .destructive) { chat.reset() }.disabled(chat.lines.isEmpty || chat.running)
                }
                ToolbarItem(placement: .principal) {
                    Menu {
                        Picker("Modelo", selection: $chat.engine) {
                            ForEach(ChatEngine.allCases) { e in Text("\(e.title) · \(e.note)").tag(e) }
                        }
                        if chat.gemma.isReady { Button("Liberar memoria de Gemma", systemImage: "memorychip") { chat.unloadGemma() } }
                    } label: {
                        Label(chat.engine == .system ? "Chat · Sistema" : "Chat · Gemma", systemImage: "chevron.down").labelStyle(.titleAndIcon)
                            .font(.headline)
                    }.disabled(chat.running)
                }
                ToolbarItem(placement: .topBarTrailing) { Button("Cerrar") { dismiss() } }
            }
        }
    }
}
