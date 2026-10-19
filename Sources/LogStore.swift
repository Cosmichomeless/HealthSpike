import SwiftUI
import Charts

// MARK: - Registros manuales (solo en este dispositivo)

struct WeightEntry: Codable, Identifiable {
    var id = UUID()
    var date: Date
    var kg: Double
}

struct MoodEntry: Codable, Identifiable {
    var id = UUID()
    var date: Date
    var level: Int              // 1...5
    var tags: [String] = []
    var note = ""

    static let faces = ["😞", "😕", "😐", "🙂", "😄"]
    static let names = ["Muy mal", "Mal", "Normal", "Bien", "Muy bien"]
    static let allTags = ["Calma", "Energía", "Alegría", "Concentración", "Estrés", "Ansiedad", "Cansancio", "Tristeza"]
}

/// Peso y estado de ánimo anotados a mano. No salen de Google: se guardan en un JSON local y no se borran al cerrar sesión.
@MainActor
final class LogStore: ObservableObject {
    @Published private(set) var weights: [WeightEntry] = []
    @Published private(set) var moods: [MoodEntry] = []
    private static let url = URL.applicationSupportDirectory.appending(path: "manual-logs.json")
    /// Cola serie: dos guardados seguidos se escriben en orden y el último siempre gana.
    private static let writer = DispatchQueue(label: "manual-logs.writer", qos: .utility)

    private struct Disk: Codable { var weights: [WeightEntry]; var moods: [MoodEntry] }

    init() {
        guard let data = try? Data(contentsOf: Self.url) else { return }
        if let d = try? JSONDecoder().decode(Disk.self, from: data) {
            weights = d.weights.sorted { $0.date < $1.date }
            moods = d.moods.sorted { $0.date < $1.date }
        } else {
            // Un fichero ilegible se apartaría al guardar de nuevo: se conserva una copia para no perder lo anotado.
            let backup = Self.url.deletingLastPathComponent().appending(path: "manual-logs.bak.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: Self.url, to: backup)
        }
    }

#if DEBUG
    /// Registros de muestra para `#Preview`: no lee ni escribe el JSON del dispositivo.
    init(weights: [WeightEntry], moods: [MoodEntry]) { self.weights = weights; self.moods = moods }
#endif

    func add(_ w: WeightEntry) { weights.append(w); weights.sort { $0.date < $1.date }; save() }
    func add(_ m: MoodEntry) { moods.append(m); moods.sort { $0.date < $1.date }; save() }
    func removeWeight(_ id: UUID) { weights.removeAll { $0.id == id }; save() }
    func removeMood(_ id: UUID) { moods.removeAll { $0.id == id }; save() }

    private func save() {
        let d = Disk(weights: weights, moods: moods), url = Self.url
        Self.writer.async {
            try? FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(d) { try? data.write(to: url, options: .atomic) }
        }
    }
}

/// Fila de una tarjeta de Peso o Ánimo que abre la lista completa de registros.
struct LogLinkRow: View {
    let color: Color
    let detail: String
    var title = "Registros"

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "list.bullet").foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }.card()
    }
}

/// Meses (el más reciente primero) con sus registros, para los títulos de sección de las listas.
private func byMonth<T>(_ items: [T], date: (T) -> Date) -> [(month: Date, items: [T])] {
    let cal = Calendar.current
    return Dictionary(grouping: items) { cal.dateInterval(of: .month, for: date($0))!.start }
        .map { ($0.key, $0.value.sorted { date($0) > date($1) }) }
        .sorted { $0.0 > $1.0 }
}
private func monthTitle(_ d: Date) -> String { d.formatted(.dateTime.month(.wide).year().locale(esES)).capitalized }

private let logRanges: [HistRange] = [.week, .month, .quarter, .year]

private func shortDate(_ d: Date) -> String { d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(esES)) }
private func kgText(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(1)).locale(esES)) }

// MARK: - Peso

struct WeightView: View {
    @EnvironmentObject var logs: LogStore
    @State private var range = HistRange.month
    @State private var adding = false
    @State private var selected: Date?

    /// Inicio del periodo: el día de hace `range.days` a las 00:00, para que el eje y el filtro coincidan.
    private var from: Date { Calendar.current.startOfDay(for: Calendar.current.date(byAdding: .day, value: -range.days, to: Date())!) }
    private var shown: [WeightEntry] { logs.weights.filter { $0.date >= from } }
    private var picked: WeightEntry? {
        guard let s = selected else { return nil }
        return shown.min { abs($0.date.timeIntervalSince(s)) < abs($1.date.timeIntervalSince(s)) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Picker("Periodo", selection: $range) { ForEach(logRanges) { Text($0.label(day: "")).tag($0) } }.pickerStyle(.segmented)
                if let last = logs.weights.last {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .firstTextBaseline) {
                            BigValue(value: kgText(last.kg), unit: "kg")
                            Spacer()
                            Text(shortDate(last.date)).font(.subheadline).foregroundStyle(.secondary)
                        }
                        if shown.count >= 2 {
                            // Redondeado a 0,1 kg para que un cambio ínfimo no salga como «-0,0».
                            let ws = shown.map(\.kg), delta = ((shown.last!.kg - shown.first!.kg) * 10).rounded() / 10
                            HStack {
                                StatCell(title: "Cambio", value: (delta > 0 ? "+" : "") + kgText(delta) + " kg")
                                StatCell(title: "Media", value: kgText(ws.reduce(0, +) / Double(ws.count)) + " kg")
                                StatCell(title: "Mín.", value: kgText(ws.min()!) + " kg")
                                StatCell(title: "Máx.", value: kgText(ws.max()!) + " kg")
                            }
                        }
                    }.card()
                    if shown.isEmpty { EmptyNote(text: "Sin registros en este periodo") } else { chartCard }
                    historyCard
                } else {
                    EmptyNote(text: "Aún no has anotado tu peso")
                }
                Text("El peso se anota a mano y se guarda solo en este iPhone: no pasa por Google.")
                    .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16).padding(.bottom, 24)
        }
        .background(Theme.background)
        .navigationTitle("Peso")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { adding = true } label: { Image(systemName: "plus") } } }
        .sheet(isPresented: $adding) { AddWeightSheet() }
    }

    private var chartCard: some View {
        let lo = shown.map(\.kg).min()!, hi = shown.map(\.kg).max()!, pad = max((hi - lo) * 0.3, 0.5)
        return VStack(alignment: .leading, spacing: 8) {
            Text("EVOLUCIÓN").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Chart {
                ForEach(shown) { w in
                    LineMark(x: .value("Fecha", w.date), y: .value("kg", w.kg)).foregroundStyle(Theme.light.opacity(0.6)).interpolationMethod(.monotone)
                    PointMark(x: .value("Fecha", w.date), y: .value("kg", w.kg)).foregroundStyle(Theme.light).symbolSize(range == .week ? 60 : 24)
                }
                if let p = picked {
                    RuleMark(x: .value("Fecha", p.date)).foregroundStyle(Color.secondary.opacity(0.5))
                        .annotation(position: .top, spacing: 4, overflowResolution: AnnotationOverflowResolution(x: .fit(to: .chart), y: .disabled)) {
                            ScrubBubble(title: shortDate(p.date), value: "\(kgText(p.kg)) kg", color: Theme.light)
                        }
                }
            }
            .chartXSelection(value: $selected)
            // El eje cubre todo el periodo: con pocos registros se ve cuánto tiempo hay entre ellos.
            .chartXScale(domain: from...Date().addingTimeInterval(Double(range.days) * 86400 * 0.02))
            .chartYScale(domain: (lo - pad)...(hi + pad))
            .frame(height: 200)
        }.card()
    }

    private var historyCard: some View {
        NavigationLink { WeightLogView() } label: {
            LogLinkRow(color: Theme.light, detail: "\(logs.weights.count) en total · último \(shortDate(logs.weights.last?.date ?? Date()))")
        }.buttonStyle(.plain)
    }
}

/// Todos los pesos anotados, por meses. Se borran deslizando la fila.
private struct WeightLogView: View {
    @EnvironmentObject var logs: LogStore

    var body: some View {
        List {
            ForEach(byMonth(logs.weights, date: \.date), id: \.month) { month, items in
                Section(monthTitle(month)) {
                    ForEach(items) { w in
                        row(w).swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) { logs.removeWeight(w.id) } label: { Label("Borrar", systemImage: "trash") }
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden).background(Theme.background)
        .navigationTitle("Registros de peso").navigationBarTitleDisplayMode(.inline)
        .overlay { if logs.weights.isEmpty { ContentUnavailableView("Sin registros", systemImage: "scalemass") } }
        .safeAreaInset(edge: .bottom) {
            Text("Desliza una fila hacia la izquierda para borrarla.").font(.footnote).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(.vertical, 8).background(.bar)
        }
    }

    private func row(_ w: WeightEntry) -> some View {
        // Cambio frente al registro anterior; no se enseña si no llega a 0,1 kg.
        let prev = logs.weights.last { $0.date < w.date }
        let delta = prev.map { ((w.kg - $0.kg) * 10).rounded() / 10 }
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(w.date.formatted(.dateTime.day().month(.abbreviated).locale(esES))).font(.subheadline)
                Text(w.date.formatted(.dateTime.weekday(.wide).hour().minute().locale(esES))).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(kgText(w.kg)) kg").font(.subheadline.weight(.semibold).monospacedDigit())
                if let d = delta, d != 0 {
                    Text((d > 0 ? "+" : "") + kgText(d) + " kg").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Gráfica sin ejes para la card de Hoy: los registros de los últimos 90 días (o los que haya).
struct WeightMiniChart: View {
    let entries: [WeightEntry]

    var body: some View {
        let from = Calendar.current.date(byAdding: .day, value: -90, to: Date())!
        let pts = entries.filter { $0.date >= from }
        let shown = pts.isEmpty ? Array(entries.suffix(1)) : pts
        let lo = shown.map(\.kg).min() ?? 0, hi = shown.map(\.kg).max() ?? 0, pad = max((hi - lo) * 0.3, 0.5)
        Chart(shown) { w in
            if shown.count > 1 {
                AreaMark(x: .value("Fecha", w.date), yStart: .value("Base", lo - pad), yEnd: .value("kg", w.kg)).foregroundStyle(Theme.light.opacity(0.15)).interpolationMethod(.monotone)
                LineMark(x: .value("Fecha", w.date), y: .value("kg", w.kg)).foregroundStyle(Theme.light)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round)).interpolationMethod(.monotone)
            }
            PointMark(x: .value("Fecha", w.date), y: .value("kg", w.kg)).foregroundStyle(Theme.light).symbolSize(shown.count > 12 ? 8 : 24)
        }
        .chartXAxis(.hidden).chartYAxis(.hidden)
        .chartYScale(domain: (lo - pad)...(hi + pad))
        .clipped()
    }
}

private struct AddWeightSheet: View {
    @EnvironmentObject var logs: LogStore
    @Environment(\.dismiss) private var dismiss
    @State private var kg = 70
    @State private var g = 0
    @State private var date = Date()
    @State private var primed = false

    var body: some View {
        NavigationStack {
            Form {
                HStack(spacing: 0) {
                    Picker("Kilos", selection: $kg) { ForEach(20...300, id: \.self) { Text("\($0) kg").tag($0) } }
                        .pickerStyle(.wheel).frame(maxWidth: .infinity)
                    Picker("Gramos", selection: $g) { ForEach(Array(stride(from: 0, through: 900, by: 100)), id: \.self) { Text("\($0) g").tag($0) } }
                        .pickerStyle(.wheel).frame(maxWidth: .infinity)
                }.labelsHidden().frame(height: 150)
                DatePicker("Fecha", selection: $date, in: ...Date()).environment(\.locale, esES)
            }
            .navigationTitle("Añadir peso").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") { logs.add(WeightEntry(date: date, kg: Double(kg) + Double(g) / 1000)); dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .onAppear {
            // Parte del último peso anotado.
            guard !primed, let last = logs.weights.last?.kg else { return }
            primed = true
            let grams = Int((last * 10).rounded()) * 100
            kg = min(max(grams / 1000, 20), 300); g = grams % 1000
        }
    }
}

// MARK: - Bienestar mental

struct MoodView: View {
    @EnvironmentObject var logs: LogStore
    @State private var range = HistRange.month
    @State private var adding = false
    @State private var selected: Date?

    private let cal = Calendar.current
    /// Inicio del periodo: el día de hace `range.days` a las 00:00, para que el eje, el resumen y la gráfica cuenten los mismos registros.
    private var from: Date { cal.startOfDay(for: cal.date(byAdding: .day, value: -range.days, to: Date())!) }

    /// Un punto por día con la media de los registros de ese día.
    private var daily: [(day: Date, level: Double)] {
        let g = Dictionary(grouping: logs.moods.filter { $0.date >= from }) { cal.startOfDay(for: $0.date) }
        return g.map { ($0.key, Double($0.value.map(\.level).reduce(0, +)) / Double($0.value.count)) }.sorted { $0.day < $1.day }
    }
    private var picked: (day: Date, level: Double)? {
        guard let s = selected else { return nil }
        return daily.min { abs($0.day.timeIntervalSince(s)) < abs($1.day.timeIntervalSince(s)) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Picker("Periodo", selection: $range) { ForEach(logRanges) { Text($0.label(day: "")).tag($0) } }.pickerStyle(.segmented)
                if logs.moods.isEmpty {
                    EmptyNote(text: "Aún no has anotado cómo te sientes")
                } else {
                    if daily.count >= 2 { chartCard }
                    summaryCard
                    historyCard
                }
                Button { adding = true } label: { Label("Anotar cómo me siento", systemImage: "plus.circle.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                Text("Los registros se anotan a mano y se guardan solo en este iPhone: no pasan por Google.")
                    .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16).padding(.bottom, 24)
        }
        .background(Theme.background)
        .navigationTitle("Bienestar mental")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { adding = true } label: { Image(systemName: "plus") } } }
        .sheet(isPresented: $adding) { AddMoodSheet() }
    }

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ÁNIMO MEDIO POR DÍA").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Chart {
                ForEach(daily, id: \.day) { d in
                    LineMark(x: .value("Día", d.day, unit: .day), y: .value("Ánimo", d.level)).foregroundStyle(Theme.rem.opacity(0.6)).interpolationMethod(.monotone)
                    PointMark(x: .value("Día", d.day, unit: .day), y: .value("Ánimo", d.level)).foregroundStyle(Theme.rem).symbolSize(range == .week ? 60 : 24)
                }
                if let p = picked {
                    RuleMark(x: .value("Día", p.day, unit: .day)).foregroundStyle(Color.secondary.opacity(0.5))
                        .annotation(position: .top, spacing: 4, overflowResolution: AnnotationOverflowResolution(x: .fit(to: .chart), y: .disabled)) {
                            ScrubBubble(title: shortDate(p.day), value: "\(MoodEntry.faces[Int(p.level.rounded()) - 1]) " + p.level.formatted(.number.precision(.fractionLength(1)).locale(esES)) + " / 5")
                        }
                }
            }
            .chartXSelection(value: $selected)
            .chartXScale(domain: from...cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date()))!)
            .chartYScale(domain: 0.5...5.5)
            .chartYAxis {
                AxisMarks(values: [1, 2, 3, 4, 5]) { v in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                    AxisValueLabel { if let y = v.as(Int.self) { Text(MoodEntry.faces[y - 1]) } }
                }
            }
            .frame(height: 200)
        }.card()
    }

    private var summaryCard: some View {
        let list = logs.moods.filter { $0.date >= from }
        let avg = list.isEmpty ? nil : Double(list.map(\.level).reduce(0, +)) / Double(list.count)
        let tags = Dictionary(grouping: list.flatMap(\.tags)) { $0 }.mapValues(\.count).sorted { $0.value > $1.value }.prefix(4)
        return VStack(alignment: .leading, spacing: 10) {
            Text("RESUMEN").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack {
                StatCell(title: "Registros", value: "\(list.count)")
                StatCell(title: "Ánimo medio", value: avg.map { $0.formatted(.number.precision(.fractionLength(1)).locale(esES)) + " / 5" } ?? "—")
            }
            if !tags.isEmpty {
                Text("Lo más anotado: " + tags.map { "\($0.key) (\($0.value))" }.joined(separator: ", ")).font(.footnote).foregroundStyle(.secondary)
            }
        }.card()
    }

    private var historyCard: some View {
        NavigationLink { MoodLogView() } label: {
            LogLinkRow(color: Theme.rem, detail: "\(logs.moods.count) en total · último \(shortDate(logs.moods.last?.date ?? Date()))")
        }.buttonStyle(.plain)
    }
}

/// Todos los registros de ánimo, por meses. Se borran deslizando la fila.
private struct MoodLogView: View {
    @EnvironmentObject var logs: LogStore

    var body: some View {
        List {
            ForEach(byMonth(logs.moods, date: \.date), id: \.month) { month, items in
                Section(monthTitle(month)) {
                    ForEach(items) { m in
                        row(m).swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) { logs.removeMood(m.id) } label: { Label("Borrar", systemImage: "trash") }
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden).background(Theme.background)
        .navigationTitle("Registros de ánimo").navigationBarTitleDisplayMode(.inline)
        .overlay { if logs.moods.isEmpty { ContentUnavailableView("Sin registros", systemImage: "face.smiling") } }
        .safeAreaInset(edge: .bottom) {
            Text("Desliza una fila hacia la izquierda para borrarla.").font(.footnote).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(.vertical, 8).background(.bar)
        }
    }

    private func row(_ m: MoodEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(MoodEntry.faces[m.level - 1]).font(.title2)
            VStack(alignment: .leading, spacing: 3) {
                Text(MoodEntry.names[m.level - 1]).font(.subheadline.weight(.semibold))
                Text(m.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute().locale(esES)))
                    .font(.caption).foregroundStyle(.secondary)
                if !m.tags.isEmpty { Text(m.tags.joined(separator: " · ")).font(.caption).foregroundStyle(Theme.rem) }
                if !m.note.isEmpty { Text(m.note).font(.footnote).padding(.top, 1) }
            }
        }
    }
}

private struct AddMoodSheet: View {
    @EnvironmentObject var logs: LogStore
    @Environment(\.dismiss) private var dismiss
    @State private var level = 4
    @State private var tags: Set<String> = []
    @State private var note = ""
    @State private var date = Date()

    var body: some View {
        NavigationStack {
            Form {
                Section("¿Cómo te sientes?") {
                    HStack {
                        ForEach(1...5, id: \.self) { l in
                            Button { level = l } label: {
                                Text(MoodEntry.faces[l - 1]).font(.system(size: 34)).frame(maxWidth: .infinity)
                                    .opacity(level == l ? 1 : 0.35).scaleEffect(level == l ? 1.15 : 1)
                            }.buttonStyle(.plain)
                        }
                    }
                    Text(MoodEntry.names[level - 1]).font(.headline).frame(maxWidth: .infinity)
                }
                Section("Etiquetas") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                        ForEach(MoodEntry.allTags, id: \.self) { t in
                            Button { if tags.contains(t) { tags.remove(t) } else { tags.insert(t) } } label: {
                                Text(t).font(.subheadline).frame(maxWidth: .infinity).padding(.vertical, 6)
                                    .background(tags.contains(t) ? Theme.rem.opacity(0.35) : Color(.tertiarySystemFill), in: Capsule())
                            }.buttonStyle(.plain)
                        }
                    }
                }
                Section("Nota") { TextField("Opcional", text: $note, axis: .vertical).lineLimit(1...4) }
                DatePicker("Fecha", selection: $date, in: ...Date()).environment(\.locale, esES)
            }
            .navigationTitle("Bienestar").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") {
                        logs.add(MoodEntry(date: date, level: level, tags: MoodEntry.allTags.filter(tags.contains), note: note))
                        dismiss()
                    }
                }
            }
        }
    }
}

#if DEBUG
#Preview("Peso") { WeightView().previewScreen() }
#Preview("Peso (mini)") { WeightMiniChart(entries: LogStore.preview.weights).frame(height: 60).previewCard().previewEnvironment() }
#Preview("Peso (sin datos)") { WeightView().previewScreen(empty: true) }
#Preview("Anotar peso") { AddWeightSheet().previewEnvironment() }
#Preview("Ánimo") { MoodView().previewScreen() }
#Preview("Ánimo (sin datos)") { MoodView().previewScreen(empty: true) }
#Preview("Registros de peso") { NavigationStack { WeightLogView() }.previewEnvironment() }
#Preview("Registros de ánimo") { NavigationStack { MoodLogView() }.previewEnvironment() }
#Preview("Anotar ánimo") { AddMoodSheet().previewEnvironment() }
#endif
