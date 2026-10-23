import HealthKit
import SwiftUI

/// Sonda de Apple Salud (fase 0 de docs/UNIVERSAL.md): qué fuentes escriben cada tipo de dato en este iPhone, con su app (bundle id),
/// su dispositivo y cuántas muestras tienen en el periodo elegido (7, 30, 90 o 365 días). Sirve para saber qué app de Google/Fitbit escribe en Apple Salud
/// y qué métricas llegan duplicadas. Solo lee; HealthSpike no escribe nunca en Apple Salud.
/// Necesita un iPhone real con datos: en el simulador no hay nada que listar.

struct ProbeRow: Identifiable {
    let id = UUID()
    let type: String
    let source: String
    let bundle: String
    let device: String
    let samples: String
    let last: String
}

@MainActor
final class HealthKitProbe: ObservableObject {
    @Published var rows: [ProbeRow] = []
    @Published var status = "Sin consultar"
    @Published var running = false
    @Published var days = 30

    private let store = HKHealthStore()

    /// (nombre en español, tipo). El sueño es de categoría; los entrenos, de muestra propia.
    private static let types: [(String, HKSampleType)] = {
        func q(_ id: HKQuantityTypeIdentifier) -> HKSampleType { HKQuantityType(id) }
        return [
            ("Pasos", q(.stepCount)), ("Distancia andando", q(.distanceWalkingRunning)), ("Pisos", q(.flightsClimbed)),
            ("Calorías activas", q(.activeEnergyBurned)), ("Calorías en reposo", q(.basalEnergyBurned)),
            ("Pulso", q(.heartRate)), ("Pulso en reposo", q(.restingHeartRate)), ("VFC (SDNN)", q(.heartRateVariabilitySDNN)),
            ("SpO₂", q(.oxygenSaturation)), ("Respiración", q(.respiratoryRate)), ("Temperatura de muñeca", q(.appleSleepingWristTemperature)),
            ("Sueño", HKCategoryType(.sleepAnalysis)), ("Entrenos", HKObjectType.workoutType()),
        ]
    }()

    func run() async {
        guard HKHealthStore.isHealthDataAvailable() else { status = "Apple Salud no está disponible en este dispositivo."; return }
        running = true; rows = []
        defer { running = false }
        do {
            try await store.requestAuthorization(toShare: [], read: Set(Self.types.map(\.1)))
        } catch {
            status = "Permiso fallido: \(error.localizedDescription)"; return
        }
        status = "Consultando…"
        let week = HKQuery.predicateForSamples(withStart: Date().addingTimeInterval(-Double(days) * 86_400), end: nil)
        var out: [ProbeRow] = []
        for (name, type) in Self.types {
            let sources = await sources(for: type, predicate: week)
            if sources.isEmpty { out.append(ProbeRow(type: name, source: "—", bundle: "", device: "", samples: "0", last: "")); continue }
            for s in sources.sorted(by: { $0.name < $1.name }) {
                out.append(await row(name, type, s, week))
            }
        }
        rows = out
        status = "Listo: \(out.filter { $0.source != "—" }.count) pares tipo/fuente. Los tipos sin permiso salen como «—» (Apple Salud no distingue «denegado» de «sin datos»)."
    }

    private func sources(for type: HKSampleType, predicate: NSPredicate) async -> Set<HKSource> {
        await withCheckedContinuation { c in
            let q = HKSourceQuery(sampleType: type, samplePredicate: predicate) { _, set, _ in c.resume(returning: set ?? []) }
            store.execute(q)
        }
    }

    private func row(_ name: String, _ type: HKSampleType, _ source: HKSource, _ week: NSPredicate) async -> ProbeRow {
        let bySource = HKQuery.predicateForObjects(from: [source])
        let both = NSCompoundPredicate(andPredicateWithSubpredicates: [bySource, week])
        let cap = 5_000
        let samples: [HKSample] = await withCheckedContinuation { c in
            let q = HKSampleQuery(sampleType: type, predicate: both, limit: cap,
                                  sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]) { _, s, _ in
                c.resume(returning: s ?? [])
            }
            store.execute(q)
        }
        let device = samples.first?.device
        let dev = [device?.name, device?.model, device?.manufacturer].compactMap { $0 }.joined(separator: " · ")
        let last = samples.first.map { $0.endDate.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(esES)) } ?? ""
        return ProbeRow(type: name, source: source.name, bundle: source.bundleIdentifier, device: dev,
                        samples: samples.count >= cap ? "≥\(cap)" : "\(samples.count)", last: last)
    }

    /// Texto plano para pegarlo en un chat o en una nota.
    var report: String {
        rows.map { "\($0.type) | \($0.source) | \($0.bundle) | \($0.device) | \($0.samples) | \($0.last)" }.joined(separator: "\n")
    }
}

struct HealthKitProbeView: View {
    @StateObject private var probe = HealthKitProbe()

    var body: some View {
        List {
            Section {
                Picker("Periodo", selection: $probe.days) {
                    ForEach([7, 30, 90, 365], id: \.self) { Text("\($0) días").tag($0) }
                }.pickerStyle(.segmented).disabled(probe.running)
                Button(probe.running ? "Consultando…" : "Pedir permiso y listar fuentes") { Task { await probe.run() } }
                    .disabled(probe.running)
                Text(probe.status).font(.footnote).foregroundStyle(.secondary)
            } footer: {
                Text("Lista las apps y dispositivos que escriben en Apple Salud durante el periodo elegido (cada fuente cuenta hasta 5.000 muestras). Solo lectura. Sirve para ver qué llega de Google Health/Fitbit y de otros relojes.")
            }
            if !probe.rows.isEmpty {
                Section {
                    ForEach(probe.rows) { r in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack { Text(r.type).font(.subheadline.weight(.semibold)); Spacer(); Text(r.samples).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                            Text(r.source).font(.footnote)
                            if !r.bundle.isEmpty { Text(r.bundle).font(.caption2).foregroundStyle(.secondary) }
                            if !r.device.isEmpty { Text(r.device).font(.caption2).foregroundStyle(.secondary) }
                            if !r.last.isEmpty { Text("Último: \(r.last)").font(.caption2).foregroundStyle(.secondary) }
                        }
                    }
                }
                Section { ShareLink("Compartir informe", item: probe.report) }
            }
        }
        .navigationTitle("Apple Salud (fuentes)")
        .navigationBarTitleDisplayMode(.inline)
    }
}
