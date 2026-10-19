import SwiftUI

// Pantalla de depuración del motor de IA local (Ajustes › Para depurar): resumen suelto con tiempos, memoria y comprobación de cifras.
// Los mensajes de verdad viven en la pestaña Coach (`CoachView`).

/// Memoria que el sistema le cuenta a la app (la del modelo del sistema vive en otro proceso y no sale aquí).
private func footprintMB() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return kr == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : 0
}

private func thermalText(_ s: ProcessInfo.ThermalState) -> String {
    switch s {
    case .nominal: "normal"
    case .fair: "templado"
    case .serious: "caliente"
    case .critical: "crítico"
    @unknown default: "?"
    }
}

struct LocalAIView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 16) { LocalAIPanel() }.padding(.horizontal, 16).padding(.bottom, 24)
        }
        .background(Theme.background)
        .navigationTitle("Resumen con IA local")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct LocalAIPanel: View {
    struct Run: Identifiable {
        let id: Int
        let question: String
        let firstToken: Double?
        let total: Double
        let tokens: Int
        let unknown: [String]
        let memoryMB: Int
        let thermal: String
        let chars: Int
    }

    @EnvironmentObject private var model: HealthModel
    private let settings = ScoreSettings()
    @AppStorage("stepsGoal") private var stepsGoal = 10_000
    @AppStorage("sleepGoalHours") private var sleepGoal = 8.0
    @AppStorage("caloriesGoal") private var caloriesGoal = 2_500

    @State private var day = DayChoice.today
    @State private var kind = SummaryKind.suggested
    @State private var question = ""
    @State private var output = ""
    @State private var generatedAt: Date?
    @State private var generatedBy = ""
    @State private var generatedAsking = false
    @State private var running = false
    @State private var errorText: String?
    @State private var runs: [Run] = []
    @State private var showFacts = false
    @State private var task: Task<Void, Never>?

    private var dayMetrics: TodayMetrics? { day == .today ? model.today : model.yesterday }
    private var dayWord: String { day == .today ? "hoy" : "ayer" }
    private var facts: String {
        DayFacts.text(model: model, settings: settings, day: dayMetrics, isToday: day == .today, kind: kind, stepsGoal: stepsGoal, sleepGoal: sleepGoal, caloriesGoal: caloriesGoal)
    }

    var body: some View {
        systemCard
            .task(id: day) { if day == .yesterday { await model.loadYesterday() } }
            .task { await model.loadWorkouts() }
        if SystemLM.status.ok { controls }
        if running || !output.isEmpty || errorText != nil { result }
        if !runs.isEmpty { metrics }
        factsCard
    }

    // MARK: Estado de cada modelo

    private var systemCard: some View {
        let st = SystemLM.status
        return VStack(alignment: .leading, spacing: 8) {
            CardHeader(icon: "brain", title: "Modelo del sistema", color: .purple, chevron: false)
            Label(st.text, systemImage: st.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(st.ok ? .green : .red).font(.subheadline)
            Text("Lo gestiona iOS: la app no guarda pesos ni descarga nada, y no sale nada del móvil.").font(.footnote).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).card()
    }

    // MARK: Pedir y mostrar

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(icon: "text.bubble", title: kind.cardTitle, color: .purple, chevron: false)
            Picker("Resumen", selection: $kind) { ForEach(SummaryKind.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).disabled(running)
            DayChoicePicker(choice: $day).disabled(running)
            TextField("Pregunta opcional (p. ej. ¿cómo he dormido?)", text: $question, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(1...3)
            HStack {
                Button {
                    running ? task?.cancel() : start()
                } label: {
                    Label(running ? "Parar" : (question.isEmpty ? kind.button : "Preguntar"), systemImage: running ? "stop.fill" : "sparkles")
                }.buttonStyle(.borderedProminent).tint(.purple).disabled(facts.isEmpty && !running)
                if facts.isEmpty { Text(day == .yesterday && model.yesterdayLoading ? "Descargando ayer…" : "Aún no hay datos de \(dayWord).").font(.footnote).foregroundStyle(.secondary) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).card()
    }

    private var result: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let e = errorText { Text(e).font(.subheadline).foregroundStyle(.red) }
            if output.isEmpty && running { ProgressView("Pensando…") }
            if !output.isEmpty { briefView }
        }.frame(maxWidth: .infinity, alignment: .leading).card()
    }

    private func md(_ s: String) -> Text {
        Text((try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s))
    }

    /// Como las tarjetas del coach de Google: marca, titular, resumen con cifras en negrita y consejo.
    @ViewBuilder private var briefView: some View {
        let b = Brief(output)
        VStack(alignment: .leading, spacing: 10) {
            Label("\(generatedAt.map { $0.formatted(Date.FormatStyle().hour(.twoDigits(amPM: .omitted)).minute().locale(esES)) } ?? "") · \(generatedBy)", systemImage: "sparkles")
                .font(.footnote).foregroundStyle(.secondary)
            if generatedAsking || !b.structured {
                md(output).font(.body)
            } else {
                if !b.title.isEmpty { md(b.title).font(.title3.weight(.semibold)) }
                if !b.summary.isEmpty { md(b.summary).font(.body).foregroundStyle(.secondary) }
                if !b.advice.isEmpty { md(b.advice).font(.body).foregroundStyle(.secondary) }
            }
        }.textSelection(.enabled)
    }

    private var metrics: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardHeader(icon: "stopwatch", title: "Rendimiento y fiabilidad", color: .orange, chevron: false)
            Text("La primera ejecución es la más lenta. Los tokens son una estimación (caracteres ÷ 3,5). La memoria es la de esta app: el modelo del sistema vive en otro proceso y no suma aquí.")
                .font(.footnote).foregroundStyle(.secondary)
            ForEach(runs) { r in
                VStack(alignment: .leading, spacing: 2) {
                    Text("#\(r.id) · \(r.question.isEmpty ? "Resumen" : r.question)").font(.subheadline.weight(.semibold)).lineLimit(1)
                    let rate = Double(r.tokens) / max(r.total - (r.firstToken ?? 0), 0.1)
                    Text("1.er token \(r.firstToken.map { String(format: "%.1f s", $0) } ?? "—") · total \(String(format: "%.1f s", r.total)) · ≈\(r.tokens) tokens · ≈\(String(format: "%.0f", rate)) tok/s")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("\(r.chars) caracteres · app \(r.memoryMB) MB · temperatura \(r.thermal)").font(.footnote).foregroundStyle(.secondary)
                    Text(r.unknown.isEmpty ? "Todas las cifras están en los datos" : "Cifras que no están en los datos: \(r.unknown.joined(separator: ", "))")
                        .font(.footnote).foregroundStyle(r.unknown.isEmpty ? .green : .red)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).card()
    }

    private var factsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation { showFacts.toggle() } } label: {
                CardHeader(icon: "list.bullet.rectangle", title: "Datos que recibe el modelo", color: .blue, chevron: false)
                    .overlay(alignment: .trailing) { Image(systemName: showFacts ? "chevron.up" : "chevron.down").foregroundStyle(.secondary) }
            }.buttonStyle(.plain)
            if showFacts { Text(facts.isEmpty ? "Sin datos de \(dayWord)." : facts).font(.footnote.monospaced()).textSelection(.enabled) }
        }.frame(maxWidth: .infinity, alignment: .leading).card()
    }

    // MARK: Generación

    private func start() {
        let facts = self.facts, dayWord = self.dayWord, kind = self.kind, q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !facts.isEmpty else { return }
        output = ""; errorText = nil; running = true; generatedAt = Date(); generatedBy = "Sistema"; generatedAsking = !q.isEmpty
        task = Task {
            defer { running = false }
            let instructions = kind.instructions(asking: !q.isEmpty)
            let prompt = "Datos de \(dayWord):\n\(facts)\n\n" + (q.isEmpty ? kind.task(dayWord) + "\n\nResponde con tres líneas que empiecen por «TITULAR:», «RESUMEN:» y «CONSEJO:»." : "Pregunta: \(q)")
            let t0 = ContinuousClock.now
            var first: Double?
            func secs(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }
            let onText: @MainActor (String) -> Void = { text in
                if first == nil { first = secs(ContinuousClock.now - t0) }
                output = text
            }
            do {
                try await SystemLM.respond(instructions: instructions, prompt: prompt, structured: q.isEmpty, onText: onText)
            } catch is CancellationError {
            } catch {
                errorText = error.localizedDescription
            }
            guard !output.isEmpty else { return }
            runs.insert(Run(id: (runs.first?.id ?? 0) + 1, question: q, firstToken: first, total: secs(ContinuousClock.now - t0),
                            tokens: Int((Double(output.count) / 3.5).rounded()),
                            unknown: DayFacts.unknownNumbers(in: q.isEmpty && Brief(output).structured ? Brief(output).claims : output, facts: facts), memoryMB: footprintMB(),
                            thermal: thermalText(ProcessInfo.processInfo.thermalState), chars: output.count), at: 0)
        }
    }
}

#if DEBUG
#Preview("Resumen con IA local") { LocalAIView().previewScreen() }
#endif
