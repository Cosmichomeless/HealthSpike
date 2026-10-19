import SwiftUI

/// Todo lo que la app lee de Google Health API v4, sin filtrar por fuente, en bloques desplegables.
/// Las listas largas (pulso: ~24.000 muestras al día) se limitan a las últimas filas.
struct RawDataSection: View {
    @EnvironmentObject var model: HealthModel
    private let maxRows = 50

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            CardHeader(icon: "tray.full.fill", title: "Datos de la API", color: .secondary,
                       trailing: model.snapshot?.fetchedAt.hhmm, chevron: false)
            Text("Todo lo recibido de Google Health, incluida la fuente de cada punto.")
                .font(.caption).foregroundStyle(.secondary).padding(.bottom, 6)
            if let s = model.snapshot {
                group("Pasos de hoy", detail: "\(s.steps.count) intervalos", rows: readings(s.steps, unit: "pasos", decimals: 0))
                group("Distancia de hoy", detail: "\(s.distanceKm.count) intervalos", rows: readings(s.distanceKm, unit: "km", decimals: 3))
                group("Pulso de hoy", detail: "\(s.heartRate.count.formatted()) muestras", rows: heartRows(s.heartRate))
                group("Pulso en reposo", detail: s.restingHR.map { "\(Int($0.value)) lpm" } ?? "sin dato", rows: restingRows(s))
                group("Sueño (última noche)", detail: s.sleep.map { hm($0.asleep) } ?? "sin dato", rows: sleepRows(s.sleep))
            } else {
                Text(model.loading ? "Cargando los datos de hoy…" : "Sin lectura de hoy.")
                    .font(.footnote).foregroundStyle(.secondary).padding(.vertical, 4)
            }
            if let h = model.history {
                group("Histórico diario", detail: "\(h.days.count) días", rows: dayRows(h.days))
                group("Pulso en reposo (histórico)", detail: "\(h.resting.count) días", rows: readings(h.resting, unit: "lpm", decimals: 0, dayOnly: true))
                group("Noches de sueño (histórico)", detail: "\(h.nights.count) noches", rows: nightRows(h.nights))
            } else {
                Text(model.loading ? "Cargando el histórico…" : "Histórico no disponible.")
                    .font(.footnote).foregroundStyle(.secondary).padding(.top, 4)
            }
        }
        .card()
    }

    // MARK: - Bloque desplegable

    private struct Row {
        let left: String, right: String
    }

    /// `rows` se calcula al desplegar el bloque, no en cada repintado (el pulso de un día son decenas de miles de muestras).
    private func group(_ title: String, detail: String, rows: @autoclosure @escaping () -> [Row]) -> some View {
        DisclosureGroup {
            let rows = rows()
            if rows.isEmpty {
                Text("Sin datos").font(.footnote).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 6) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                        HStack(alignment: .firstTextBaseline) {
                            Text(r.left).foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            Text(r.right).monospacedDigit().multilineTextAlignment(.trailing)
                        }.font(.caption)
                    }
                }.padding(.vertical, 6)
            }
        } label: {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Filas

    private func clock(_ d: Date) -> String { d.formatted(Date.FormatStyle(date: .omitted, time: .standard).locale(esES)) }
    private func dayTime(_ d: Date) -> String { "\(d.dayMonth) \(clock(d))" }
    private func src(_ r: Reading) -> String { r.isAir ? "Air" : r.source }
    private func num(_ v: Double, _ decimals: Int) -> String { String(format: "%.\(decimals)f", v) }

    /// Primera fila con el reparto por fuente (Air frente a Apple Health u otras).
    private func sourceRow(_ rs: [Reading]) -> Row? {
        guard !rs.isEmpty else { return nil }
        let by = Dictionary(grouping: rs, by: src)
        return Row(left: "Fuentes", right: by.keys.sorted().map { "\($0): \(by[$0]!.count.formatted())" }.joined(separator: " · "))
    }

    private func readings(_ rs: [Reading], unit: String, decimals: Int, dayOnly: Bool = false) -> [Row] {
        let sorted = rs.sorted { $0.time > $1.time }
        var rows = [sourceRow(rs)].compactMap { $0 }
        rows += sorted.prefix(maxRows).map {
            Row(left: "\(dayOnly ? $0.time.dayMonth : dayTime($0.time)) · \(src($0))", right: "\(num($0.value, decimals)) \(unit)")
        }
        if sorted.count > maxRows { rows.append(Row(left: "…", right: "\(sorted.count - maxRows) más")) }
        return rows
    }

    private func heartRows(_ rs: [Reading]) -> [Row] {
        guard let first = rs.min(by: { $0.time < $1.time }), let last = rs.max(by: { $0.time < $1.time }) else { return [] }
        let vals = rs.map(\.value)
        var rows = [sourceRow(rs)].compactMap { $0 }
        rows.append(Row(left: "Primera / última", right: "\(clock(first.time)) / \(clock(last.time))"))
        rows.append(Row(left: "Mín / media / máx", right: "\(Int(vals.min()!)) / \(Int((vals.reduce(0, +) / Double(vals.count)).rounded())) / \(Int(vals.max()!)) lpm"))
        rows += rs.sorted { $0.time > $1.time }.prefix(maxRows).map {
            Row(left: "\(clock($0.time)) · \(src($0))", right: "\(Int($0.value)) lpm")
        }
        if rs.count > maxRows { rows.append(Row(left: "…", right: "\((rs.count - maxRows).formatted()) más")) }
        return rows
    }

    private func restingRows(_ s: Snapshot) -> [Row] {
        guard let r = s.restingHR else { return [] }
        return [Row(left: "\(r.time.dayMonth) · \(src(r))", right: "\(Int(r.value)) lpm")]
    }

    private func sleepRows(_ n: SleepNight?) -> [Row] {
        guard let n else { return [] }
        var rows = [
            Row(left: "Inicio / fin", right: "\(dayTime(n.start)) / \(dayTime(n.end))"),
            Row(left: "Fuente", right: n.isAir ? "Air" : "Otra"),
            Row(left: "Dormido", right: hm(n.asleep)),
        ]
        for st in ["DEEP", "REM", "LIGHT", "AWAKE"] {
            rows.append(Row(left: Theme.stageName(st), right: hm(n.minutes[st] ?? 0)))
        }
        rows += n.segments.map { Row(left: "\(clock($0.start))–\(clock($0.end))", right: Theme.stageName($0.stage)) }
        return rows
    }

    private func dayRows(_ days: [DayStat]) -> [Row] {
        days.reversed().map { d in
            let steps = d.steps.map { "\(Int($0).formatted()) pasos" } ?? "— pasos"
            let km = d.distanceKm.map { num($0, 2) + " km" } ?? "— km"
            let hr = d.hrMin.map { lo in "\(Int(lo))/\(Int(d.hrAvg ?? 0))/\(Int(d.hrMax ?? 0)) lpm" } ?? "— lpm"
            return Row(left: d.day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(esES)),
                       right: "\(steps) · \(km) · \(hr)")
        }
    }

    private func nightRows(_ nights: [SleepNight]) -> [Row] {
        nights.reversed().map { n in
            Row(left: "\(n.end.dayMonth) · \(clock(n.start))–\(clock(n.end))\(n.isAir ? "" : " · otra fuente")",
                right: "\(hm(n.asleep)) (prof. \(hm(n.minutes["DEEP"] ?? 0)))")
        }
    }
}

#if DEBUG
#Preview { ScrollView { RawDataSection().padding(16) }.previewEnvironment() }
#endif
