import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif

// Motor de la IA local (#22): el modelo del sistema (Foundation Models, iOS 26+), sin pesos en la app ni descarga.
// Todo lo que lee el modelo sale de `DayFacts`: la app calcula las cifras y el modelo solo las redacta.
// Gemma 4 con MLX Swift se probó y se descartó (ver #22): más peso, peor formato y peor redacción.

/// Los tres resúmenes que se piden a la IA, como los de Google: el del sueño por la mañana, los entrenos y el del día por la noche.
enum SummaryKind: String, CaseIterable, Identifiable, Codable {
    case sleep = "Sueño", workouts = "Entrenos", day = "Día"
    var id: String { rawValue }

    /// Por la mañana apetece el sueño; a partir de media tarde, el día.
    static var suggested: SummaryKind {
        let h = Calendar.current.component(.hour, from: Date())
        return h < 13 ? .sleep : (h >= 19 ? .day : .workouts)
    }
    var button: String { self == .sleep ? "Resumir mi sueño" : (self == .workouts ? "Describir mis entrenos" : "Resumir mi día") }
    var cardTitle: String { self == .sleep ? "Resumen del sueño" : (self == .workouts ? "Entrenos del día" : "Resumen del día") }
    /// Lo que se le pide al modelo cuando no hay pregunta propia.
    func task(_ dayWord: String) -> String {
        switch self {
        case .sleep: "Resume cómo fue el sueño de \(dayWord): cuánto dormiste frente a tu objetivo, cómo se repartieron las fases, la puntuación y cómo está respecto a tu media reciente si hay dato."
        case .workouts: "Describe los entrenos de \(dayWord) uno por uno, con detalle: tipo, hora, duración, pulso, ritmo, zonas de pulso, calorías y distancia cuando estén. Si no hay entrenos, dilo en una frase."
        case .day: "Escribe un resumen de cómo fue el día de \(dayWord): actividad (pasos, distancia, calorías frente a objetivo), entrenos, pulso, sueño y recuperación si hay dato. Acaba con una frase sobre cómo prepararte para dormir."
        }
    }
}

extension SummaryKind {
    /// Cómo debe ser cada apartado, con el tono de las tarjetas de Google. Los ejemplos van sin cifras: los modelos pequeños copian lo que ven.
    var guide: String {
        switch self {
        case .sleep: """
            TITULAR: un titular de 4 a 8 palabras, sin cifras, coherente con la «Valoración» de los datos y sin copiar estos ejemplos: «Buen descanso para empezar el día con energía», «Una noche corta: hoy conviene ir con calma».
            RESUMEN: una o dos frases. Empieza por «Dormiste …», di cuánto frente a tu objetivo y la puntuación, y añade lo más llamativo de las fases, del horario o de la comparación con tu media.
            CONSEJO: una frase con una sugerencia concreta para hoy según cómo has dormido (p. ej. una caminata a paso ligero si has descansado bien, o acostarte pronto si ha sido corta).
            """
        case .workouts: """
            TITULAR: un titular de 4 a 8 palabras, sin cifras, coherente con la «Valoración» de los datos y sin copiar estos ejemplos: «Una caminata larga y constante», «Hoy toca descanso activo».
            RESUMEN: describe cada entreno con detalle en una o dos frases: tipo, hora, duración, pulso medio, ritmo, zonas de pulso, calorías y distancia cuando existan.
            CONSEJO: una frase sobre cómo recuperarte o qué hacer después de este esfuerzo.
            """
        case .day: """
            TITULAR: un titular de 4 a 8 palabras, sin cifras, coherente con la «Valoración» de los datos y sin copiar estos ejemplos: «Un día más tranquilo en cuanto a pasos», «Un día muy activo».
            RESUMEN: una o dos frases. Empieza por «Sumaste … pasos» y compara con tu objetivo con el porcentaje que ya viene en los datos; añade entrenos, calorías, pulso o sueño si destacan.
            CONSEJO: una frase de cierre acorde a la hora actual (p. ej. desconectar para descansar bien si es de noche).
            """
        }
    }

    /// Como `guide`, para el mensaje de una siesta (no se compara con el objetivo de la noche).
    static let napGuide = """
        TITULAR: un titular de 4 a 8 palabras, sin cifras, sobre la siesta y sin copiar estos ejemplos: «Una siesta breve para recargar», «Una siesta larga a media tarde».
        RESUMEN: una o dos frases. Empieza por «Echaste una siesta …», di a qué hora y cuánto dormiste, añade las fases si hay datos y cuánto suma con la noche en el «Sueño total del día».
        CONSEJO: una frase acorde a la «Hora actual» (p. ej. si es tarde, cuidar que la siesta no te robe el sueño de esta noche).
        """
    /// Lo que se le pide al modelo para una siesta.
    static let napTask = "Resume la siesta de hoy: a qué hora fue, cuánto dormiste, cómo se repartieron las fases si hay dato y cuánto suma con la noche."

    /// Instrucciones comunes a los dos modelos. Con pregunta propia se responde en libre; sin ella, con el formato de tres apartados.
    func instructions(asking: Bool, nap: Bool = false) -> String {
        let base = """
            Eres el coach de una app personal de salud. Respondes siempre en español, en segunda persona (tú), con tono cercano, directo y sin saludos, despedidas ni emojis.
            Usa SOLO las cifras de los datos que te dan: no inventes ninguna, no hagas ninguna resta, suma ni porcentaje (usa los que ya vienen en los datos) y no des diagnósticos médicos. Si un dato no aparece, no lo menciones, y di que falta algo solo si los datos lo dicen con «sin datos».
            Valora con honestidad: por debajo del 50 % del objetivo es un día tranquilo, no «buen esfuerzo»; dormir menos que el objetivo es una noche corta. Compara cada cosa con lo que dicen los datos («Frente al objetivo», «Frente a tu media»), sin mezclarlas.
            El consejo debe encajar con la «Hora actual» si aparece: de noche o de madrugada, nada de actividades diurnas; sugiere descansar.
            Pon en **negrita** (con dos asteriscos) las cifras clave.
            """
        if asking { return base + "\nResponde a la pregunta en un máximo de cuatro frases." }
        return base + """

            Responde EXACTAMENTE con estas tres líneas, sin nada más:
            \(nap ? Self.napGuide : guide)
            En CONSEJO no des datos: solo una sugerencia. Pon en **negrita** las cifras clave del RESUMEN y la acción del CONSEJO.
            """
    }
}

/// La respuesta partida en titular, resumen y consejo (las tarjetas de Google). Tolera que el modelo se salte el formato y que aún esté escribiendo.
struct Brief {
    var title = "", summary = "", advice = ""
    var structured: Bool { !title.isEmpty || !summary.isEmpty || !advice.isEmpty }

    init(_ text: String) {
        // Los modelos pequeños a veces juntan los apartados en una línea: se separan antes de leerlos.
        var t = text
        if let split = try? NSRegularExpression(pattern: #"\s*((?:\*\*)?(?:TITULAR|RESUMEN|CONSEJO)\s*(?:\*\*)?:)"#) {
            t = split.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "\n$1")
        }
        let label = try? Regex(#"^[*#\s]*(titular|resumen|consejo)\s*(?:\*\*)?\s*:\s*(?:\*\*(?=\s))?\s*"#).ignoresCase()
        var current: WritableKeyPath<Brief, String>?
        for raw in t.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let label, let m = line.prefixMatch(of: label), let key = m.output[1].substring?.lowercased() {
                current = key == "titular" ? \.title : (key == "resumen" ? \.summary : \.advice)
                self[keyPath: current!] = String(line[m.range.upperBound...])
            } else if let path = current {
                self[keyPath: path] += (self[keyPath: path].isEmpty ? "" : " ") + line
            }
        }
        title = title.replacingOccurrences(of: "**", with: "")
        for path in [\Brief.title, \.summary, \.advice] { self[keyPath: path] = Self.tidy(self[keyPath: path]) }
    }

    /// Mayúscula inicial y sin `**` sueltos (si quedan impares, se quitan todos para que no se vean).
    private static func tidy(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.components(separatedBy: "**").count % 2 == 0 { t = t.replacingOccurrences(of: "**", with: "") }
        return t.prefix(1).uppercased() + t.dropFirst()
    }

    /// Texto sobre el que se comprueban las cifras: el consejo no afirma datos.
    var claims: String { title + " " + summary }
}

/// Las cifras del día en texto plano, tal y como se le pasan al modelo (y como las ve David en pantalla para comprobarlas).
@MainActor enum DayFacts {
    static func text(model: HealthModel, settings: ScoreSettings, day: TodayMetrics?, isToday: Bool = true, kind: SummaryKind = .day, nap: SleepNight? = nil,
                     stepsGoal: Int, sleepGoal: Double, caloriesGoal: Int) -> String {
        guard let d = day else { return "" }
        let num: (Double) -> String = { Int($0.rounded()).formatted(.number.locale(esES)) }
        let hm: (Double) -> String = { m in
            let t = Int(m.rounded())
            return t >= 60 ? (t % 60 == 0 ? "\(t / 60) h" : "\(t / 60) h \(t % 60) min") : "\(t) min"
        }
        let clock: (Date) -> String = { $0.formatted(Date.FormatStyle().hour(.twoDigits(amPM: .omitted)).minute().locale(esES)) }
        var l = ["Fecha: \(d.midnight.formatted(Date.FormatStyle().weekday(.wide).day().month(.wide).locale(esES)))"]
        if isToday { l.append("Hora actual: \(clock(Date()))") }

        func sleepLines() {
            // La descarga de "ayer" no trae sueño: se busca en el histórico la noche que terminó ese día.
            let next = Calendar.current.date(byAdding: .day, value: 1, to: d.midnight)!
            let night = d.sleep ?? model.history?.nights.last { $0.end >= d.midnight && $0.end < next }
            guard let n = night else { l.append("Sueño: sin datos de la noche"); return }
            let sc = model.sleepScore(n, goalHours: sleepGoal)
            l.append("Sueño de \(isToday ? "la última noche" : "la noche que terminó ese día"): \(hm(n.asleep)) dormido (objetivo \(hm(sleepGoal * 60))), puntuación \(sc.value) de 100 (\(sc.label))")
            l.append("Horario: de \(clock(n.start)) a \(clock(n.end)), \(hm(n.end.timeIntervalSince(n.start) / 60)) en la cama")
            let diff = n.asleep - sleepGoal * 60
            l.append(diff >= 0 ? "Frente al objetivo: \(hm(diff)) de más" : "Frente al objetivo: \(hm(-diff)) de menos")
            // Provisional: el modelo no juzga si una noche fue buena o mala, la app se lo dice.
            l.append("Valoración de la noche: " + (diff >= 30 ? "larga, por encima del objetivo" : (diff > -30 ? "dentro del objetivo" : (diff > -90 ? "algo corta" : "corta, bastante por debajo del objetivo"))))
            let st = [("profundo", "DEEP"), ("REM", "REM"), ("ligero", "LIGHT"), ("despierto", "AWAKE")].compactMap { name, k in
                n.minutes[k].map { "\(name) \(hm($0)) (\(num($0 / max(n.asleep + (n.minutes["AWAKE"] ?? 0), 1) * 100) ) %)" }
            }
            if !st.isEmpty { l.append("Fases: " + st.joined(separator: ", ")) }
            let prev = (model.history?.nights ?? []).filter { $0.end < n.start }.suffix(7)
            if prev.count >= 3 {
                let avg = prev.reduce(0) { $0 + $1.asleep } / Double(prev.count)
                l.append("Media de las \(prev.count) noches anteriores: \(hm(avg)) dormido")
                let dm = n.asleep - avg
                l.append(abs(dm) < 5 ? "Frente a tu media: igual" : "Frente a tu media: \(hm(abs(dm))) de \(dm > 0 ? "más" : "menos")")
            }
            if let r = d.resting { l.append("Pulso en reposo: \(num(r.value)) lpm") }
            if !d.naps.isEmpty { l.append("Siestas: \(d.naps.count), \(hm(d.naps.reduce(0) { $0 + $1.asleep })) en total") }
            if !d.naps.isEmpty { l.append("Sueño total del día (noche y siestas): \(hm(d.sleepTotal))") }
        }

        func napLines(_ n: SleepNight) {
            l.append("Siesta: de \(clock(n.start)) a \(clock(n.end)), \(hm(n.asleep)) dormido")
            let st = [("profundo", "DEEP"), ("REM", "REM"), ("ligero", "LIGHT"), ("despierto", "AWAKE")].compactMap { name, k in
                n.minutes[k].map { "\(name) \(hm($0))" }
            }
            if !st.isEmpty { l.append("Fases de la siesta: " + st.joined(separator: ", ")) }
            if let night = d.sleep, night.start != n.start { l.append("Sueño de la última noche: \(hm(night.asleep)) dormido") }
            l.append("Sueño total del día (noche y siestas): \(hm(d.sleepTotal))")
        }

        func workoutLines() {
            let ws = model.workouts(on: d.midnight)
            if ws.isEmpty { l.append("Entrenos: ninguno registrado"); return }
            for (i, w) in ws.enumerated() {
                var p = ["\(w.name) a las \(clock(w.start))", hm(w.minutes)]
                if let k = w.kcal { p.append("\(num(k)) kcal") }
                if let km = w.km { p.append("\(km.formatted(.number.precision(.fractionLength(2)).locale(esES))) km") }
                if let s = w.steps { p.append("\(s.formatted(.number.locale(esES))) pasos") }
                if let h = w.avgHR { p.append("pulso medio \(h) lpm") }
                if let pace = w.paceMinPerKm {
                    let m = Int(pace), sec = Int(((pace - Double(m)) * 60).rounded())
                    p.append(sec == 60 ? "ritmo \(m + 1):00 min/km" : String(format: "ritmo %d:%02d min/km", m, sec))
                }
                let zs = [("ligera", "light"), ("moderada", "moderate"), ("intensa", "vigorous"), ("pico", "peak")].compactMap { name, k in
                    (w.zones[k] ?? 0) > 0 ? "\(name) \(w.zones[k]!) min" : nil
                }
                if !zs.isEmpty { p.append("zonas de pulso: " + zs.joined(separator: ", ")) }
                l.append("Entreno \(i + 1): " + p.joined(separator: "; "))
            }
        }

        switch kind {
        case .sleep: if let nap { napLines(nap) } else { sleepLines() }
        case .workouts: workoutLines()
        case .day:
            let pct: (Double, Double) -> Int = { Int(($0 / max($1, 1) * 100).rounded()) }
            let left = Double(stepsGoal) - d.steps
            l.append("Pasos: \(num(d.steps)), el \(pct(d.steps, Double(stepsGoal))) % de tu objetivo de \(num(Double(stepsGoal))) (\(left > 0 ? "faltaron \(num(left))" : "superado en \(num(-left))"))")
            let sp = d.steps / max(Double(stepsGoal), 1)
            l.append("Valoración de la actividad: " + (sp >= 1 ? "objetivo de pasos cumplido" : (sp >= 0.75 ? "día bastante activo" : (sp >= 0.4 ? "día tranquilo" : "día muy tranquilo, pocos pasos"))))
            l.append("Distancia: \(d.distanceKm.formatted(.number.precision(.fractionLength(1)).locale(esES))) km")
            if let c = d.calories { l.append("Calorías: \(num(c)) kcal, el \(pct(c, Double(caloriesGoal))) % de tu objetivo de \(num(Double(caloriesGoal))) kcal") }
            if let f = d.floors { l.append("Pisos: \(num(f))") }
            var hr: [String] = []
            if let h = d.lastHR { hr.append("último \(num(h.value)) lpm") }
            if let a = d.hrMin { hr.append("mínimo \(num(a)) lpm") }
            if let b = d.hrMax { hr.append("máximo \(num(b)) lpm") }
            if let r = d.resting { hr.append("en reposo \(num(r.value)) lpm") }
            if !hr.isEmpty { l.append("Pulso: " + hr.joined(separator: ", ")) }
            workoutLines()
            sleepLines()
            // Recuperación y resiliencia son las actuales: no se mezclan con los datos de ayer.
            if isToday, let r = settings.recovery(model) { l.append("Recuperación: \(r.value) de 100 (\(Scoring.recoveryLabel(r.value)))") }
            if isToday, let r = settings.resilience(model) { l.append("Resiliencia: \(r.value) de 100 (\(Scoring.resilienceLabel(r.value)))") }
        }
        return l.joined(separator: "\n")
    }

    /// Cifras del texto generado que no aparecen en los datos: señal barata de que el modelo ha inventado o calculado algo por su cuenta.
    static func unknownNumbers(in output: String, facts: String) -> [String] {
        // Primero las duraciones enteras («6 h 21 min»): sus cifras sueltas podrían estar en los datos por separado y colar una inventada.
        let duration = try! Regex(#"(\d+) ?h(?: ?(\d+) ?min)?|(\d+) ?min"#)
        func minutes(_ m: Regex<AnyRegexOutput>.Match) -> Int {
            let o = m.output
            if let mm = o[3].substring { return Int(mm) ?? 0 }
            return (Int(o[1].substring ?? "") ?? 0) * 60 + (Int(o[2].substring ?? "") ?? 0)
        }
        func durations(_ s: String) -> [(text: String, min: Int)] { s.matches(of: duration).map { (String(s[$0.range]), minutes($0)) } }
        func rest(_ s: String) -> String { s.replacing(duration, with: " ") }
        func numbers(_ s: String) -> [String] {
            (try? Regex(#"\d+(?:[.,]\d+)*"#)).map { re in s.matches(of: re).map { String(s[$0.range]) } } ?? []
        }
        func key(_ n: String) -> String { n.filter(\.isNumber) }
        let knownDur = Set(durations(facts).map(\.min))
        let known = Set(numbers(facts).map(key))
        var seen = Set<String>()
        let badDur = durations(output).filter { !knownDur.contains($0.min) }.map(\.text)
        let bad = numbers(rest(output)).filter { !known.contains(key($0)) }
        return (badDur + bad).filter { seen.insert(key($0)).inserted }
    }
}

/// El modelo del sistema (Foundation Models). Todo lo que toca el framework queda aquí, protegido para iOS 17–25.
#if canImport(FoundationModels)
@available(iOS 26, *)
@Generable struct BriefGen {
    @Guide(description: "Titular de 4 a 8 palabras, sin cifras, con mayúscula inicial")
    var titular: String
    @Guide(description: "Una o dos frases en segunda persona con las cifras clave en **negrita**, usando solo los datos recibidos")
    var resumen: String
    @Guide(description: "Una frase con una sugerencia concreta, sin datos nuevos")
    var consejo: String
}
#endif

@MainActor enum SystemLM {
    static var status: (ok: Bool, text: String) {
        #if canImport(FoundationModels)
        if #available(iOS 26, *) {
            let lm = SystemLanguageModel.default
            switch lm.availability {
            case .available:
                return lm.supportsLocale(Locale(identifier: "es_ES"))
                    ? (true, "Disponible, en el iPhone, con español")
                    : (false, "Disponible, pero sin soporte de español")
            case .unavailable(let why):
                switch why {
                case .deviceNotEligible: return (false, "Este iPhone no es compatible con Apple Intelligence.")
                case .appleIntelligenceNotEnabled: return (false, "Apple Intelligence está desactivada en Ajustes.")
                case .modelNotReady: return (false, "El modelo aún se está descargando o preparando. Vuelve a probar más tarde.")
                @unknown default: return (false, "El modelo no está disponible.")
                }
            }
        }
        #endif
        return (false, "Necesita iOS 26 o superior.")
    }

    /// Con `structured` el framework rellena titular, resumen y consejo (generación guiada): el formato no depende de que el modelo lo respete.
    static func respond(instructions: String, prompt: String, structured: Bool, onText: @MainActor (String) -> Void) async throws {
        #if canImport(FoundationModels)
        if #available(iOS 26, *) {
            let session = LanguageModelSession(instructions: instructions)
            if structured {
                for try await partial in session.streamResponse(to: prompt, generating: BriefGen.self, options: GenerationOptions(temperature: 0.3)) {
                    let c = partial.content
                    onText("TITULAR: \(c.titular ?? "")\nRESUMEN: \(c.resumen ?? "")\nCONSEJO: \(c.consejo ?? "")")
                }
                return
            }
            for try await partial in session.streamResponse(to: prompt, options: GenerationOptions(temperature: 0.3)) { onText(partial.content) }
        }
        #endif
    }
}

