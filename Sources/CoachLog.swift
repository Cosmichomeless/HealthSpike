import SwiftUI

// Registro de lo que hace el Coach por su cuenta (#46): iOS reparte el segundo plano cuando quiere y no avisa de lo que pasa,
// así que cada refresco deja aquí su rastro (cuándo, con el móvil bloqueado o no, cuánto tardó el modelo y por qué falló si falló).

struct CoachLogEntry: Codable, Identifiable {
    var id = UUID()
    var date: Date
    var background: Bool
    var title: String
    var detail: String
    /// nil = en curso. Si pasa de unos minutos sin cerrarse, iOS mató la app a mitad.
    var ok: Bool?
}

enum CoachLog {
    private static let key = "coachLog", limit = 80
    /// Se escribe desde el refresco en segundo plano y desde la interfaz.
    private static let lock = NSLock()

    /// Del más reciente al más antiguo.
    static func entries() -> [CoachLogEntry] {
        lock.lock(); defer { lock.unlock() }
        return load()
    }

    @discardableResult
    static func add(_ title: String, _ detail: String = "", background: Bool, ok: Bool? = true) -> UUID {
        lock.lock(); defer { lock.unlock() }
        let entry = CoachLogEntry(date: Date(), background: background, title: title, detail: detail, ok: ok)
        var list = load()
        list.insert(entry, at: 0)
        if list.count > limit { list.removeLast(list.count - limit) }
        store(list)
        return entry.id
    }

    /// Cierra una entrada que se abrió "en curso".
    static func finish(_ id: UUID, ok: Bool, detail: String) {
        lock.lock(); defer { lock.unlock() }
        var list = load()
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        list[i].ok = ok
        list[i].detail = detail
        store(list)
    }

    static func clear() {
        lock.lock(); defer { lock.unlock() }
        UserDefaults.standard.removeObject(forKey: key)
    }

    static func seconds(_ d: Duration) -> String {
        let s = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        return s.formatted(.number.precision(.fractionLength(1)).locale(esES))
    }

    /// En qué estado está el móvil en este momento: lo que más afecta a que iOS deje trabajar a la app.
    @MainActor static var context: String {
        let app = UIApplication.shared
        let refresh: String
        switch app.backgroundRefreshStatus {
        case .available: refresh = "activada"
        case .denied: refresh = "desactivada para la app"
        case .restricted: refresh = "restringida"
        @unknown default: refresh = "desconocida"
        }
        // Con el móvil bloqueado los archivos con protección completa no se pueden abrir: es la forma de saber si lo está.
        let locked = app.isProtectedDataAvailable ? "desbloqueado" : "bloqueado"
        return "Móvil \(locked) · actualización en segundo plano \(refresh) · bajo consumo \(ProcessInfo.processInfo.isLowPowerModeEnabled ? "sí" : "no")"
    }

    private static func load() -> [CoachLogEntry] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([CoachLogEntry].self, from: data)) ?? []
    }

    private static func store(_ list: [CoachLogEntry]) {
        if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: key) }
    }
}

struct CoachLogView: View {
    @State private var entries: [CoachLogEntry] = []
    @State private var copied = false

    /// Todo el registro en texto plano, para pegarlo en un mensaje.
    private var text: String {
        entries.map { e in
            let state = e.ok == true ? "OK" : e.ok == false ? "FALLO" : "SIN CERRAR"
            let when = e.date.formatted(Date.FormatStyle(date: .numeric, time: .standard).locale(esES))
            return "[\(when)] [\(e.background ? "segundo plano" : "primer plano")] [\(state)] \(e.title)" + (e.detail.isEmpty ? "" : "\n    " + e.detail.replacingOccurrences(of: "\n", with: "\n    "))
        }.joined(separator: "\n")
    }

    var body: some View {
        List {
            if entries.isEmpty {
                Text("Aún no hay nada. Aquí aparece cada refresco en segundo plano y cada mensaje que genera el Coach por su cuenta.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(entries) { row($0) }
        }
        .navigationTitle("Registro del Coach")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    UIPasteboard.general.string = text
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(2)); copied = false }
                } label: { Label(copied ? "Copiado" : "Copiar", systemImage: copied ? "checkmark" : "doc.on.doc") }
                    .disabled(entries.isEmpty)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Borrar registro", role: .destructive) { CoachLog.clear(); entries = [] }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .onAppear { entries = CoachLog.entries() }
        .refreshable { entries = CoachLog.entries() }
    }

    private func row(_ e: CoachLogEntry) -> some View {
        // Una entrada "en curso" que lleva minutos abierta es una ejecución que iOS cortó sin avisar.
        let interrupted = e.ok == nil && Date().timeIntervalSince(e.date) > 5 * 60
        let icon: String, color: Color
        switch e.ok {
        case true?: (icon, color) = ("checkmark.circle.fill", .green)
        case false?: (icon, color) = ("xmark.circle.fill", .red)
        case nil: (icon, color) = interrupted ? ("exclamationmark.triangle.fill", .orange) : ("hourglass", .secondary)
        }
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(color).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(e.title).font(.subheadline.weight(.semibold))
                if interrupted { Text("Sin cerrar: iOS cortó la app a mitad.").font(.footnote).foregroundStyle(.orange) }
                if !e.detail.isEmpty { Text(e.detail).font(.footnote).foregroundStyle(.secondary) }
                Text("\(e.date.formatted(Date.FormatStyle(date: .abbreviated, time: .standard).locale(esES))) · \(e.background ? "segundo plano" : "primer plano")")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}
