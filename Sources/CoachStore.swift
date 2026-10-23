import SwiftUI
import UserNotifications

// Mensajes del Coach (#46): los resúmenes de la IA local, guardados en el iPhone para poder enseñarlos como un log y consultarlos en el historial.

struct CoachMessage: Codable, Identifiable, Equatable {
    var id = UUID()
    /// Cuándo se generó.
    var created: Date
    /// Medianoche del día al que se refieren los datos (puede ser ayer aunque se genere hoy).
    var day: Date
    var kind: SummaryKind
    var title: String
    var summary: String
    var advice: String
    /// Cifras del texto que no estaban en los datos (se avisa en pantalla).
    var unknown: [String] = []
    /// Inicio de la sesión de sueño a la que se refiere (noche o siesta): dos del mismo día no se pisan.
    var session: Double?
    var isNap: Bool?
    var heading: String { isNap == true ? "Resumen de la siesta" : kind.cardTitle }
}

/// Genera y guarda los mensajes. Vive en la app entera: si cambias de pestaña mientras el modelo escribe, la generación sigue.
@MainActor
final class CoachStore: ObservableObject {
    struct Pending: Equatable { var kind: SummaryKind; var day: DayChoice }

    /// Del más nuevo al más antiguo.
    @Published private(set) var messages: [CoachMessage] = []
    @Published private(set) var pending: Pending?
    /// Lo que lleva escrito el modelo mientras genera (en el formato TITULAR / RESUMEN / CONSEJO).
    @Published private(set) var partial = ""
    @Published private(set) var errorText: String?

    private let url: URL?
    private static let maxMessages = 300
    /// Cola serie: dos guardados seguidos se escriben en orden y el último siempre gana.
    private static let writer = DispatchQueue(label: "coach.writer", qos: .utility)
    private var task: Task<Void, Never>?

    init() {
        let url = URL.applicationSupportDirectory.appending(path: "coach-messages.json")
        self.url = url
        if let data = try? Data(contentsOf: url), let list = try? JSONDecoder().decode([CoachMessage].self, from: data) {
            messages = list.sorted { $0.created > $1.created }
        }
    }

    /// Para las previews: con mensajes de ejemplo y sin tocar el disco.
    init(preview messages: [CoachMessage]) {
        url = nil
        self.messages = messages
    }

    // MARK: Generar

    /// A petición de David (botones de la pestaña).
    func generate(_ kind: SummaryKind, _ choice: DayChoice, model: HealthModel) {
        guard pending == nil, !catching else { return }
        task = Task {
            // Se anota también lo que se pide a mano: es la forma de medir cuánto tarda el modelo.
            let background = UIApplication.shared.applicationState != .active
            let logID = CoachLog.add("Generando «\(kind.cardTitle)» a mano", background: background, ok: nil)
            let start = ContinuousClock.now
            let made = await produce(kind, choice, model: model)
            let took = CoachLog.seconds(ContinuousClock.now - start)
            let ended = UIApplication.shared.applicationState != .active ? " La app ya estaba en segundo plano al terminar." : ""
            if let made {
                CoachLog.finish(logID, ok: true, detail: "Listo en \(took) s: «\(made.title)».\(ended)")
            } else {
                CoachLog.finish(logID, ok: false, detail: "Sin resultado a los \(took) s: \(timeExpired ? "iOS cortó la tarea por tiempo" : (errorText ?? "cancelado")).\(ended)")
            }
        }
    }

    func cancel() { task?.cancel() }

    /// Guarda el identificador de la tarea de fondo para poder cerrarla desde el aviso de caducidad de iOS.
    private final class Assertion: @unchecked Sendable {
        var id = UIBackgroundTaskIdentifier.invalid
        var expired = false
        func end() {
            guard id != .invalid else { return }
            UIApplication.shared.endBackgroundTask(id)
            id = .invalid
        }
    }

    /// El tiempo que llevó la última generación se acabó porque iOS cortó la tarea (no porque falló el modelo).
    private var timeExpired = false

    private func produce(_ kind: SummaryKind, _ choice: DayChoice, model: HealthModel, sleep: SleepNight? = nil, nap: Bool = false) async -> CoachMessage? {
        pending = Pending(kind: kind, day: choice)
        partial = ""; errorText = nil; timeExpired = false
        // Si sales de la app mientras el modelo escribe, iOS la congela. Con esto da unos 30 s para acabar; si no llega, cancela la generación.
        let gen = Task { await run(kind, choice, model: model, sleep: sleep, nap: nap) }
        let assertion = Assertion()
        assertion.id = UIApplication.shared.beginBackgroundTask(withName: "coach.generate") {
            assertion.expired = true
            gen.cancel()
            assertion.end()
        }
        defer { assertion.end(); pending = nil }
        let made = await withTaskCancellationHandler { await gen.value } onCancel: { gen.cancel() }
        timeExpired = assertion.expired
        return made
    }

    // MARK: Automático

    private var catching = false

    /// Genera los mensajes que tocan: el del sueño y el de cada siesta en cuanto llegan nuevos, el de entrenos con cada entreno nuevo
    /// y el del día a su hora. Se llama al abrir la app, al terminar cada lectura y en el refresco en segundo plano.
    func catchUp(model: HealthModel) async {
        guard CoachAuto.enabled, SystemLM.status.ok, pending == nil, !catching, !model.isPreview, model.auth.signedIn else { return }
        catching = true
        defer { catching = false }
        let cal = Calendar.current, d = UserDefaults.standard, now = Date()
        await model.loadWorkouts()
        // Borrar un mensaje no hace que se vuelva a generar: lo ya generado hoy se recuerda aparte.
        func has(_ kind: SummaryKind) -> Bool {
            isDone(kind, now) || messages.contains { $0.kind == kind && cal.isDateInToday($0.day) && cal.isDateInToday($0.created) }
        }

        // Entrenos: la primera vez se anotan los que ya hay para no generar un mensaje por cada uno.
        let todays = model.workouts(on: now).filter { $0.end <= now }
        var seen = Set(d.stringArray(forKey: CoachAuto.seenKey) ?? [])
        if d.object(forKey: CoachAuto.seenKey) == nil, model.workouts != nil {
            d.set((model.workouts ?? []).map(\.id), forKey: CoachAuto.seenKey)
            seen = Set(d.stringArray(forKey: CoachAuto.seenKey) ?? [])
        }

        // Sueño: la noche y cada siesta nuevas (se reconocen por la hora de inicio, que no cambia al sincronizar).
        // La primera vez se anotan las que ya hay.
        let sleepID: (SleepNight) -> String = { String(Int($0.start.timeIntervalSince1970)) }
        let sessions = (model.today.map { ([$0.sleep].compactMap { $0 }) + $0.naps } ?? []).filter { $0.end <= now }
        if d.object(forKey: CoachAuto.seenSleepKey) == nil, model.today != nil {
            d.set(sessions.map(sleepID), forKey: CoachAuto.seenSleepKey)
        }
        var seenSleep = Set(d.stringArray(forKey: CoachAuto.seenSleepKey) ?? [])
        let newSleeps = d.object(forKey: CoachAuto.seenSleepKey) == nil ? [] : sessions.filter { !seenSleep.contains(sleepID($0)) }.sorted { $0.end < $1.end }

        // `fallback`: id y titular del aviso sin resumen que sale si el modelo no consigue generarlo en segundo plano (el del día ya tiene su aviso fijo).
        var items: [(kind: SummaryKind, sleep: SleepNight?, nap: Bool, fallback: (id: String, title: String)?, label: String)] = []
        for n in newSleeps {
            let nap = n.start != model.today?.sleep?.start
            items.append((.sleep, n, nap, ("sleep|" + sleepID(n), nap ? "Nueva siesta registrada" : "Nuevo sueño registrado"), nap ? "siesta" : "sueño"))
        }
        let newWorkouts = todays.filter { !seen.contains($0.id) }
        if !newWorkouts.isEmpty, d.object(forKey: CoachAuto.seenKey) != nil {
            items.append((.workouts, nil, false, ("workouts|" + newWorkouts.map(\.id).sorted().joined(separator: ","), "Nuevo entreno registrado"), "entrenos"))
        }
        if CoachAuto.passed(CoachAuto.dayMinutes), !has(.day), model.today != nil { items.append((.day, nil, false, nil, "día")) }

        if items.isEmpty {
            // Las lecturas seguidas (la del refresco y la de `lastRefresh`) no repiten la línea.
            let recent = CoachLog.entries().first.map { $0.title == "Sin mensajes pendientes" && Date().timeIntervalSince($0.date) < 60 } ?? false
            if UIApplication.shared.applicationState != .active, !recent { CoachLog.add("Sin mensajes pendientes", background: true) }
            return
        }

        for item in items {
            let background = UIApplication.shared.applicationState != .active
            guard !Task.isCancelled else {
                CoachLog.add("Mensaje de \(item.label) sin generar", "iOS canceló la tarea antes de empezar.", background: background, ok: false)
                break
            }
            let logID = CoachLog.add("Generando mensaje de \(item.label)", background: background, ok: nil)
            let start = ContinuousClock.now
            let made = await produce(item.kind, .today, model: model, sleep: item.sleep, nap: item.nap)
            let took = CoachLog.seconds(ContinuousClock.now - start)
            // Si empezó con la app abierta y acabó en segundo plano, el tiempo incluye lo que iOS la tuvo congelada o con tiempo extra.
            let ended = (UIApplication.shared.applicationState != .active) != background ? " Terminó con la app en segundo plano." : ""
            guard let m = made else {
                let why = timeExpired || Task.isCancelled ? "iOS cortó la tarea por tiempo" : (errorText ?? "sin resultado")
                CoachLog.finish(logID, ok: false, detail: "Falló a los \(took) s: \(why).\(ended) Se reintenta en el siguiente refresco o al abrir la app.")
                // Plan B: si no se pudo generar con la app fuera de primer plano, el aviso sale igualmente, sin el resumen (una sola vez por dato).
                if background, let fb = item.fallback, await CoachAuto.notifyWithoutSummary(id: fb.id, title: fb.title) {
                    CoachLog.add("Aviso sin resumen enviado", fb.title, background: background)
                }
                continue
            }
            CoachLog.finish(logID, ok: true, detail: "Listo en \(took) s: «\(m.title)».\(ended)")
            if let fb = item.fallback { CoachAuto.removeWithoutSummary(id: fb.id) }
            if item.kind == .workouts {
                seen.formUnion(todays.map(\.id))
                d.set(Array(seen), forKey: CoachAuto.seenKey)
            }
            if let n = item.sleep {
                seenSleep.insert(sleepID(n))
                d.set(Array(seenSleep), forKey: CoachAuto.seenSleepKey)
            }
            if UIApplication.shared.applicationState != .active { await CoachAuto.notify(m) }
        }
    }

    #if DEBUG
    /// Prueba desde la línea de comandos: lanzar la app con `-coachTest sleep|nap|day|workout` genera ese mensaje con los datos reales
    /// y manda el aviso 30 s después (hay que salir de la app para verlo).
    func launchTest(model: HealthModel) async {
        guard let what = UserDefaults.standard.string(forKey: "coachTest"), SystemLM.status.ok else { return }
        for _ in 0..<120 where model.today == nil || catching || pending != nil { try? await Task.sleep(for: .milliseconds(500)) }
        guard let today = model.today else { print("coachTest: sin datos de hoy"); return }
        if what == "workout" {
            // Un entreno inventado que acaba de terminar: pasa por la detección real de `catchUp`.
            let end = Date().addingTimeInterval(-35 * 60)
            HealthModel.fakeWorkouts = [Workout(id: "debug-workout-\(Int(end.timeIntervalSince1970))", type: "RUNNING", name: "Carrera", start: end.addingTimeInterval(-60 * 60), end: end,
                                                kcal: 480, km: 7.2, steps: 8_600, avgHR: 152, paceMinPerKm: 8.3, zones: ["light": 5, "moderate": 25, "vigorous": 22, "peak": 8], isAir: true)]
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            print("coachTest: entreno inventado, detectando…")
            await catchUp(model: model)
            guard let m = messages.first(where: { $0.kind == .workouts && Date().timeIntervalSince($0.created) < 300 }) else { print("coachTest: no se generó el mensaje de entrenos"); return }
            await CoachAuto.notify(m, after: 30)
            print("coachTest: listo, aviso en 30 s: bloquea el móvil ya. «\(m.title)»")
            return
        }
        catching = true
        defer { catching = false }
        let kind: SummaryKind, sleep: SleepNight?
        switch what {
        case "sleep": (kind, sleep) = (.sleep, today.sleep)
        case "nap": (kind, sleep) = (.sleep, today.naps.last)
        default: (kind, sleep) = (.day, nil)
        }
        if kind == .sleep, sleep == nil { print("coachTest: no hay \(what == "nap" ? "ninguna siesta" : "sueño") hoy"); return }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        let auth = await UNUserNotificationCenter.current().notificationSettings()
        print("coachTest: permiso de avisos = \(auth.authorizationStatus.rawValue) (2 = concedido), alertas = \(auth.alertSetting.rawValue) (2 = activadas)")
        print("coachTest: generando \(what)…")
        guard let m = await produce(kind, .today, model: model, sleep: sleep, nap: what == "nap") else { print("coachTest: falló: \(errorText ?? "cancelado")"); return }
        await CoachAuto.notify(m, after: 30)
        print("coachTest: listo, aviso en 30 s: bloquea el móvil ya. «\(m.title)»")
    }
    #endif

    private func run(_ kind: SummaryKind, _ choice: DayChoice, model: HealthModel, sleep: SleepNight? = nil, nap: Bool = false) async -> CoachMessage? {
        let word = choice == .today ? "hoy" : "ayer"
        if choice == .yesterday { await model.loadYesterday() }
        await model.loadWorkouts()
        let metrics = choice == .today ? model.today : model.yesterday
        let d = UserDefaults.standard
        let facts = DayFacts.text(model: model, settings: ScoreSettings(), day: metrics, isToday: choice == .today, kind: kind, nap: nap ? sleep : nil,
                                  stepsGoal: d.object(forKey: "stepsGoal") as? Int ?? 10_000,
                                  sleepGoal: d.object(forKey: "sleepGoalHours") as? Double ?? 8.0,
                                  caloriesGoal: d.object(forKey: "caloriesGoal") as? Int ?? 2_500)
        guard let day = metrics?.midnight, !facts.isEmpty else { errorText = "Aún no hay datos de \(word)."; return nil }
        let prompt = "Datos de \(word):\n\(facts)\n\n\(nap ? SummaryKind.napTask : kind.task(word))\n\nResponde con tres líneas que empiecen por «TITULAR:», «RESUMEN:» y «CONSEJO:»."
        do {
            try await SystemLM.respond(instructions: kind.instructions(asking: false, nap: nap), prompt: prompt, structured: true) { partial = $0 }
        } catch is CancellationError {
            return nil
        } catch {
            errorText = error.localizedDescription
            return nil
        }
        let b = Brief(partial)
        guard b.structured, !Task.isCancelled else {
            if !Task.isCancelled { errorText = "El modelo no devolvió un resumen. Inténtalo de nuevo." }
            return nil
        }
        var m = CoachMessage(created: Date(), day: day, kind: kind, title: b.title, summary: b.summary, advice: b.advice,
                             unknown: DayFacts.unknownNumbers(in: b.claims, facts: facts))
        m.session = kind == .sleep ? (sleep ?? (choice == .today ? metrics?.sleep : nil))?.start.timeIntervalSince1970 : nil
        m.isNap = nap ? true : nil
        add(m)
        return m
    }

    // MARK: Guardar

    private static let doneKey = "coachDone"
    private static func doneID(_ kind: SummaryKind, _ day: Date) -> String {
        "\(kind.rawValue)|\(Int(Calendar.current.startOfDay(for: day).timeIntervalSince1970))"
    }

    private func isDone(_ kind: SummaryKind, _ day: Date) -> Bool {
        (UserDefaults.standard.stringArray(forKey: Self.doneKey) ?? []).contains(Self.doneID(kind, day))
    }

    private func markDone(_ m: CoachMessage) {
        let limit = Date().addingTimeInterval(-14 * 86_400).timeIntervalSince1970
        var ids = (UserDefaults.standard.stringArray(forKey: Self.doneKey) ?? []).filter {
            Double($0.split(separator: "|").last ?? "").map { $0 > limit } ?? false
        }
        ids.append(Self.doneID(m.kind, m.day))
        UserDefaults.standard.set(ids, forKey: Self.doneKey)
    }

    /// Volver a pedir el mismo resumen del mismo día (y de la misma sesión de sueño) sustituye al anterior.
    private func add(_ m: CoachMessage) {
        markDone(m)
        messages.removeAll { $0.kind == m.kind && $0.session == m.session && Calendar.current.isDate($0.day, inSameDayAs: m.day) }
        messages.insert(m, at: 0)
        if messages.count > Self.maxMessages { messages.removeLast(messages.count - Self.maxMessages) }
        save()
    }

    func delete(_ m: CoachMessage) {
        messages.removeAll { $0.id == m.id }
        save()
    }

    /// Al cerrar sesión: los mensajes salen de datos de la cuenta.
    func clear() {
        task?.cancel()
        messages = []
        UserDefaults.standard.removeObject(forKey: CoachAuto.seenKey)
        UserDefaults.standard.removeObject(forKey: CoachAuto.seenSleepKey)
        UserDefaults.standard.removeObject(forKey: Self.doneKey)
        guard let url else { return }
        Self.writer.async { try? FileManager.default.removeItem(at: url) }
    }

    private func save() {
        guard let url else { return }
        let snapshot = messages
        Self.writer.async {
            try? FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
    }
}

#if DEBUG
extension CoachStore {
    static var preview: CoachStore {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!
        let old = cal.date(byAdding: .day, value: -4, to: today)!
        func at(_ day: Date, _ hour: Int) -> Date { cal.date(byAdding: .hour, value: hour, to: day)! }
        return CoachStore(preview: [
            CoachMessage(created: at(today, 8), day: today, kind: .sleep, title: "Una noche redonda",
                         summary: "Dormiste **7 h 19 min**, a solo 41 minutos de tu objetivo, con una eficiencia del **97 %** y una puntuación de **91 de 100**.",
                         advice: "Mantén esta hora de acostarte y deja las pantallas una hora antes: te está funcionando."),
            CoachMessage(created: at(yesterday, 21), day: yesterday, kind: .day, title: "Un día tranquilo",
                         summary: "Diste **6.200 pasos** (el 62 % de tu objetivo) y quemaste **2.180 kcal**. Sin entrenos registrados.",
                         advice: "Un paseo corto antes de cenar te ayudaría a llegar a tu objetivo."),
            CoachMessage(created: at(old, 9), day: old, kind: .sleep, title: "Descanso dentro de lo previsto",
                         summary: "Dormiste **7 h 50 min**, casi tu objetivo.", advice: "Mantén el horario de estos días."),
        ])
    }
}
#endif
