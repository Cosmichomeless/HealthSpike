import SwiftUI

/// Cobertura de datos y frescura: los dataTypes de la API, cuántos puntos hay y cuándo fue el último.
/// Vive en Ajustes > Datos de la API, con todos los tipos juntos.
struct CoverageSection: View {
    @EnvironmentObject var model: HealthModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(icon: "list.bullet.rectangle.fill", title: "Cobertura de datos y frescura", color: .secondary,
                       trailing: model.coverageAt?.hhmm, chevron: false)
            Text("Datos de la API en los últimos 14 días.")
                .font(.caption).foregroundStyle(.secondary)
            if let rows = model.coverage {
                ForEach(rows) { r in
                    Divider()
                    row(r)
                }
                if rows.contains(where: { $0.type == "heart-rate" }) {
                    Text("Pulso: solo los datos de hoy, porque 14 días son ~300.000 muestras (~200 MB).").font(.footnote).foregroundStyle(.secondary)
                }
                Text("“Otras fuentes” son puntos de Apple Health que Google mezcla en la misma lista.").font(.footnote).foregroundStyle(.secondary)
            } else if model.coverageLoading {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Consultando los tipos de dato…").font(.footnote).foregroundStyle(.secondary) }
                    .padding(.vertical, 8)
            }
            Button {
                Task { await model.loadCoverage() }
            } label: {
                Label(model.coverage == nil ? "Cargar cobertura" : "Actualizar cobertura", systemImage: "arrow.clockwise")
            }
            .font(.footnote).disabled(model.coverageLoading)
        }
        .card()
        // La antigüedad de cada tipo se mide contra la hora de la consulta: si es vieja, se repite al abrir.
        .task { if model.coverageAt.map({ Date().timeIntervalSince($0) > 600 }) ?? true { await model.loadCoverage() } }
    }

    private func row(_ r: CoverageRow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(r.label).font(.subheadline.weight(.semibold))
                Spacer()
                Text("HTTP \(r.http)").font(.caption2.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background((r.http == 200 ? Color.green : Color.red).opacity(0.18), in: Capsule())
                    .foregroundStyle(r.http == 200 ? Color.green : Color.red)
            }
            Text("\(r.type) · \(r.kind)").font(.caption2.monospaced()).foregroundStyle(.tertiary)
            HStack {
                StatCell(title: "Puntos", value: r.n.formatted())
                StatCell(title: "Otras fuentes", value: r.other > 0 ? r.other.formatted() : "–")
            }
            if let a = r.first, let b = r.last {
                Text("\(stamp(a, r)) → \(stamp(b, r))\(ageText(r))").font(.caption).foregroundStyle(.secondary)
            } else if let n = r.note {
                Text(n).font(.caption).foregroundStyle(.red)
            } else {
                Text("Sin puntos").font(.caption).foregroundStyle(.secondary)
            }
            if r.capped { Text("Lista recortada: hay más puntos de los contados.").font(.caption).foregroundStyle(.orange) }
        }
    }

    private func stamp(_ d: Date, _ r: CoverageRow) -> String {
        r.dayOnly ? d.formatted(.dateTime.day().month(.abbreviated).locale(esES))
                  : d.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(esES))
    }

    /// “hace 21 min”, “hace 3 h”, “hace 2 d”. Los tipos diarios no llevan antigüedad.
    private func ageText(_ r: CoverageRow) -> String {
        guard !r.dayOnly, let last = r.last else { return "" }
        let m = Int(Date().timeIntervalSince(last) / 60)
        let s = m < 1 ? "ahora" : m < 60 ? "hace \(m) min" : m < 1440 ? "hace \(m / 60) h" : "hace \(m / 1440) d"
        return " · \(s)"
    }
}

#if DEBUG
#Preview { ScrollView { CoverageSection().padding(16) }.previewEnvironment() }
#endif
