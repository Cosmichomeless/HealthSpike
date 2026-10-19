import CoreBluetooth
import SwiftUI

/// Sonda de Bluetooth de la pulsera (issue #18): qué anuncia la Air y qué servicios y características expone, sin pasar por Google.
/// Es una herramienta de depuración: necesita un iPhone real y que la pulsera comparta el pulso (Google Health > Fitbit Air > Compartir
/// frecuencia cardíaca > Siempre visible); si no, no aparece como sensor.

// MARK: - Lectura de las características estándar

/// Una medición de pulso (característica 0x2A37, Heart Rate Measurement).
struct HRMeasurement {
    let bpm: Int
    let contact: Bool?          // nil = la pulsera no informa del contacto
    let energyKJ: Int?
    let rrMs: [Double]          // intervalos RR (unidad nativa 1/1024 s) en milisegundos

    static func parse(_ data: Data) -> HRMeasurement? {
        let b = [UInt8](data)
        guard b.count >= 2 else { return nil }
        let flags = b[0]
        var i = 1
        let bpm: Int
        if flags & 0x01 == 0 { bpm = Int(b[i]); i += 1 }
        else { guard b.count >= 3 else { return nil }; bpm = Int(b[i]) | Int(b[i + 1]) << 8; i += 2 }
        let contact: Bool? = flags & 0x04 != 0 ? flags & 0x02 != 0 : nil
        var energy: Int?
        if flags & 0x08 != 0, i + 1 < b.count { energy = Int(b[i]) | Int(b[i + 1]) << 8; i += 2 }
        var rr: [Double] = []
        if flags & 0x10 != 0 {
            while i + 1 < b.count { rr.append(Double(Int(b[i]) | Int(b[i + 1]) << 8) / 1024 * 1000); i += 2 }
        }
        return HRMeasurement(bpm: bpm, contact: contact, energyKJ: energy, rrMs: rr)
    }
}

enum BLENames {
    static let services: [String: String] = [
        "180D": "Frecuencia cardiaca", "180F": "Batería", "180A": "Información del dispositivo", "1800": "Acceso genérico",
        "1801": "Atributos genéricos", "1809": "Termómetro", "181D": "Báscula", "1816": "Velocidad y cadencia", "1814": "Carrera",
    ]
    static let characteristics: [String: String] = [
        "2A37": "Medición de pulso", "2A38": "Ubicación del sensor", "2A39": "Control del pulso", "2A19": "Nivel de batería",
        "2A29": "Fabricante", "2A24": "Modelo", "2A25": "Número de serie", "2A26": "Firmware", "2A27": "Hardware", "2A28": "Software",
        "2A23": "System ID", "2A50": "PnP ID", "2A00": "Nombre", "2A01": "Apariencia",
    ]
    static let bodyLocations = ["otra", "pecho", "muñeca", "dedo", "mano", "lóbulo de la oreja", "pie"]
}

// MARK: - Gestor

/// Todo ocurre en la cola principal (`queue: nil`), igual que las vistas.
final class BluetoothProbe: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    struct Found: Identifiable {
        let id: UUID
        var name: String
        var rssi: Int
        var services: [String]
        var manufacturer: String?
        let peripheral: CBPeripheral?
        var isCandidate: Bool {
            services.contains("180D") || ["fitbit", "google"].contains { name.localizedCaseInsensitiveContains($0) }
        }
    }

    struct CharRow: Identifiable {
        let id: String
        let service: String
        let uuid: String
        let props: String
        var hex = "—"
        var text: String?
        var at: Date?
    }

    @Published var stateText = "Iniciando…"
    @Published var scanning = false
    @Published var scanAll = true
    @Published var subscribeAll = false   // suscribirse también a los canales propietarios (ruidosos y cifrados)
    @Published var found: [Found] = []
    @Published var connectedName: String?
    @Published var connecting = false
    @Published var rows: [CharRow] = []
    @Published var bpm: Int?
    @Published var contact: Bool?
    @Published var samples = 0
    @Published var samplesWithRR = 0
    @Published var lastRR: [Double] = []
    @Published var battery: Int?
    @Published var disconnects = 0
    @Published var log: [String] = []

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var lastHex: [String: String] = [:]
    private var changeCounts: [String: Int] = [:]   // cambios registrados por característica (máx. 10)
    private var logCounts: [String: Int] = [:]   // veces que se ha registrado cada característica (para no inundar el registro)
    private let hrService = CBUUID(string: "180D")

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey: true])
    }

    #if DEBUG
    /// Datos de ejemplo para las previews (el simulador no tiene Bluetooth).
    init(preview: Bool) {
        super.init()
        stateText = "Bluetooth encendido"
        connectedName = "Fitbit Air"
        bpm = 62; contact = true; samples = 128; samplesWithRR = 96; lastRR = [968, 972]; battery = 74; disconnects = 1
        rows = [
            CharRow(id: "180D-2A37", service: "180D", uuid: "2A37", props: "notify", hex: "10 3E C8 03 CC 03", text: "62 lpm · RR 968, 972 ms", at: Date()),
            CharRow(id: "180D-2A38", service: "180D", uuid: "2A38", props: "read", hex: "02", text: "muñeca", at: Date()),
            CharRow(id: "180F-2A19", service: "180F", uuid: "2A19", props: "read, notify", hex: "4A", text: "74 %", at: Date()),
            CharRow(id: "180A-2A29", service: "180A", uuid: "2A29", props: "read", hex: "47 6F 6F 67 6C 65", text: "Google", at: Date()),
        ]
        found = [
            Found(id: UUID(), name: "Fitbit Air", rssi: -52, services: ["180D"], manufacturer: "00 E0 …", peripheral: nil),
        ]
        log = ["12:00:03 conectado a Fitbit Air", "12:00:01 conectando…"]
    }

    #endif

    // MARK: Acciones

    func startScan() {
        guard central.state == .poweredOn else { note("Bluetooth no disponible: \(stateText)"); return }
        found = []
        central.scanForPeripherals(withServices: scanAll ? nil : [hrService], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        scanning = true
        note(scanAll ? "Escaneando sin filtro" : "Escaneando solo servicio 0x180D")
    }

    func stopScan() {
        guard scanning else { return }
        central.stopScan()
        scanning = false
        note("Escaneo detenido")
    }

    func connect(_ f: Found) {
        guard let p = f.peripheral, !connecting, connectedName == nil else { return }
        stopScan()
        peripheral = p
        p.delegate = self
        rows = []; logCounts = [:]; lastHex = [:]; changeCounts = [:]; bpm = nil; contact = nil; samples = 0; samplesWithRR = 0; lastRR = []; battery = nil
        connecting = true
        central.connect(p, options: nil)
        note("Conectando a \(f.name)")
    }

    func disconnect() {
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
    }

    func clearLog() { log = [] }

    var logText: String { log.reversed().joined(separator: "\n") }

    private func note(_ s: String) {
        log.insert("\(Date().formatted(date: .omitted, time: .standard)) \(s)", at: 0)
        if log.count > 400 { log.removeLast() }
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn: stateText = "Bluetooth encendido"
        case .poweredOff: stateText = "Bluetooth apagado"
        case .unauthorized: stateText = "Sin permiso de Bluetooth (Ajustes de iOS)"
        case .unsupported: stateText = "Este dispositivo no admite Bluetooth LE"
        default: stateText = "Bluetooth no disponible"
        }
        note(stateText)
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData ad: [String: Any], rssi: NSNumber) {
        let name = p.name ?? (ad[CBAdvertisementDataLocalNameKey] as? String) ?? "(sin nombre)"
        let services = ((ad[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []).map(\.uuidString)
        let manu = (ad[CBAdvertisementDataManufacturerDataKey] as? Data).map(Self.hex)
        let f = Found(id: p.identifier, name: name, rssi: rssi.intValue, services: services, manufacturer: manu, peripheral: p)
        if let i = found.firstIndex(where: { $0.id == f.id }) { found[i] = f } else {
            found.append(f)
            if f.isCandidate { note("Candidata: \(name) \(rssi) dBm \(services.joined(separator: ","))") }
        }
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        connecting = false
        connectedName = p.name ?? "(sin nombre)"
        note("Conectado a \(connectedName ?? ""); descubriendo servicios")
        p.discoverServices(nil)
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        connecting = false
        note("No se pudo conectar: \(error?.localizedDescription ?? "?")")
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        connecting = false
        connectedName = nil
        disconnects += 1
        note("Desconectado: \(error?.localizedDescription ?? "sin error")")
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { note("Error al descubrir servicios: \(error.localizedDescription)") }
        let list = p.services ?? []
        note("Servicios: \(list.map(\.uuid.uuidString).joined(separator: ", ").isEmpty ? "ninguno" : list.map(\.uuid.uuidString).joined(separator: ", "))")
        list.forEach { p.discoverCharacteristics(nil, for: $0) }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        if let error { note("Error en \(s.uuid.uuidString): \(error.localizedDescription)") }
        for ch in s.characteristics ?? [] {
            let props = Self.props(ch.properties)
            note("Característica \(s.uuid.uuidString) / \(ch.uuid.uuidString) [\(props)]")
            guard !rows.contains(where: { $0.id == "\(s.uuid.uuidString)-\(ch.uuid.uuidString)" }) else { continue }
            rows.append(CharRow(id: "\(s.uuid.uuidString)-\(ch.uuid.uuidString)", service: s.uuid.uuidString, uuid: ch.uuid.uuidString, props: props))
            if ch.properties.contains(.read) { p.readValue(for: ch) }
            let standard = ch.uuid.uuidString.count <= 4
            if (ch.properties.contains(.notify) || ch.properties.contains(.indicate)) && (standard || subscribeAll) { p.setNotifyValue(true, for: ch) }
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) {
        if let error { note("Notificaciones de \(ch.uuid.uuidString): \(error.localizedDescription)") }
        else { note("Suscrito a \(ch.uuid.uuidString): \(ch.isNotifying ? "sí" : "no")") }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        if let error { note("Lectura de \(ch.service?.uuid.uuidString ?? "?") / \(ch.uuid.uuidString): \(error.localizedDescription)"); return }
        guard let data = ch.value, let sid = ch.service?.uuid.uuidString else { return }
        let text = decode(ch.uuid.uuidString, data)
        // Pulso: las 5 primeras muestras y luego una de cada 30. El resto: sus 5 primeros valores y cada vez que cambian.
        let n = (logCounts[ch.uuid.uuidString] ?? 0) + 1
        logCounts[ch.uuid.uuidString] = n
        let hex = Self.hex(data)
        let changed = lastHex[ch.uuid.uuidString] != hex
        lastHex[ch.uuid.uuidString] = hex
        let isHR = ch.uuid.uuidString == "2A37"
        if changed && !isHR { changeCounts[ch.uuid.uuidString, default: 0] += 1 }
        if n <= 5 || (isHR && n % 30 == 0) || (!isHR && changed && changeCounts[ch.uuid.uuidString, default: 0] <= 10) {
            note("\(ch.uuid.uuidString) = \(Self.hex(data))\(text.map { " → " + $0 } ?? "")")
        }
        if let i = rows.firstIndex(where: { $0.id == "\(sid)-\(ch.uuid.uuidString)" }) {
            rows[i].hex = Self.hex(data); rows[i].text = text; rows[i].at = Date()
        }
    }

    // MARK: Decodificación

    private func decode(_ uuid: String, _ data: Data) -> String? {
        switch uuid {
        case "2A37":
            guard let m = HRMeasurement.parse(data) else { return nil }
            bpm = m.bpm; contact = m.contact; samples += 1; lastRR = m.rrMs
            if !m.rrMs.isEmpty { samplesWithRR += 1 }
            var s = "\(m.bpm) lpm"
            if !m.rrMs.isEmpty { s += " · RR " + m.rrMs.map { String(Int($0.rounded())) }.joined(separator: ", ") + " ms" }
            if let e = m.energyKJ { s += " · \(e) kJ" }
            return s
        case "2A19":
            guard let v = data.first else { return nil }
            battery = Int(v)
            return "\(v) %"
        case "2A38":
            guard let v = data.first else { return nil }
            return Int(v) < BLENames.bodyLocations.count ? BLENames.bodyLocations[Int(v)] : "\(v)"
        case "2A29", "2A24", "2A25", "2A26", "2A27", "2A28", "2A00":
            return String(data: data, encoding: .utf8)
        default:
            return nil
        }
    }

    private static func hex(_ d: Data) -> String { d.map { String(format: "%02X", $0) }.joined(separator: " ") }

    private static func props(_ p: CBCharacteristicProperties) -> String {
        var out: [String] = []
        if p.contains(.read) { out.append("read") }
        if p.contains(.write) { out.append("write") }
        if p.contains(.writeWithoutResponse) { out.append("write sin resp.") }
        if p.contains(.notify) { out.append("notify") }
        if p.contains(.indicate) { out.append("indicate") }
        return out.joined(separator: ", ")
    }
}

// MARK: - Vista

struct BluetoothProbeView: View {
    @StateObject private var ble: BluetoothProbe
    @State private var copied = false

    init(probe: BluetoothProbe? = nil) { _ble = StateObject(wrappedValue: probe ?? BluetoothProbe()) }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                statusCard
                scanCard
                if ble.connectedName != nil || !ble.rows.isEmpty { liveCard; servicesCard }
                logCard
            }.padding(.horizontal, 16).padding(.bottom, 24)
        }
        .background(Theme.background)
        .navigationTitle("Bluetooth de la pulsera")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardHeader(icon: "antenna.radiowaves.left.and.right", title: "Estado", color: Theme.light, chevron: false)
            Text(ble.stateText).font(.subheadline.weight(.semibold))
            Text("Prueba con un iPhone real. En Google Health > Fitbit Air activa «Compartir frecuencia cardíaca» y «Siempre visible»; si no, la pulsera no se anuncia como sensor. Cierra otras apps que puedan acapararla.")
                .font(.footnote).foregroundStyle(.secondary)
        }.card()
    }

    private var scanCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(icon: "dot.radiowaves.left.and.right", title: "Dispositivos cercanos", color: Theme.light, chevron: false)
            Toggle("Sin filtro (ver todo)", isOn: $ble.scanAll).disabled(ble.scanning)
            Toggle("Suscribir también a canales propietarios", isOn: $ble.subscribeAll).disabled(ble.connectedName != nil || ble.connecting)
            HStack {
                Button(ble.scanning ? "Detener" : "Buscar") { ble.scanning ? ble.stopScan() : ble.startScan() }.buttonStyle(.borderedProminent)
                if ble.connectedName != nil || ble.connecting { Button("Desconectar", role: .destructive) { ble.disconnect() }.buttonStyle(.bordered) }
                if ble.scanning { ProgressView().controlSize(.small) }
            }
            if ble.found.isEmpty {
                Text(ble.scanning ? "Buscando…" : "Pulsa «Buscar».").font(.footnote).foregroundStyle(.secondary)
            }
            // Las candidatas (0x180D o nombre Fitbit/Air/Google) primero; luego por señal.
            ForEach(ble.found.sorted { ($0.isCandidate ? 1 : 0, $0.rssi) > ($1.isCandidate ? 1 : 0, $1.rssi) }) { f in
                Button { ble.connect(f) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(f.name).font(.subheadline.weight(f.isCandidate ? .bold : .regular))
                                .foregroundStyle(f.isCandidate ? Theme.steps : .primary)
                            Spacer()
                            Text("\(f.rssi) dBm").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        if !f.services.isEmpty { Text("Servicios: \(f.services.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary) }
                        if let m = f.manufacturer { Text("Fabricante: \(m)").font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1) }
                    }
                }.buttonStyle(.plain)
                Divider()
            }
        }.card()
    }

    private var liveCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(icon: "heart.fill", title: ble.connectedName ?? "Desconectada", color: Theme.heart, chevron: false)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(ble.bpm.map(String.init) ?? "—").font(.system(size: 44, weight: .bold)).monospacedDigit()
                Text("lpm").foregroundStyle(.secondary)
                Spacer()
                if let b = ble.battery { Label("\(b) %", systemImage: "battery.75percent").font(.subheadline) }
            }
            Text("Contacto: \(ble.contact.map { $0 ? "sí" : "no" } ?? "no informado") · muestras \(ble.samples) · con RR \(ble.samplesWithRR) · desconexiones \(ble.disconnects)")
                .font(.footnote).foregroundStyle(.secondary)
            if !ble.lastRR.isEmpty {
                Text("Último RR: " + ble.lastRR.map { "\(Int($0.rounded())) ms" }.joined(separator: ", ")).font(.footnote).foregroundStyle(.secondary)
            }
        }.card()
    }

    private var servicesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(icon: "list.bullet.rectangle", title: "Servicios y características", color: Theme.light, chevron: false)
            if ble.rows.isEmpty { Text("Esperando a que la pulsera los enseñe…").font(.footnote).foregroundStyle(.secondary) }
            ForEach(Dictionary(grouping: ble.rows, by: \.service).keys.sorted(), id: \.self) { sid in
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(sid) · \(BLENames.services[sid] ?? "servicio desconocido")").font(.subheadline.weight(.semibold))
                    ForEach(ble.rows.filter { $0.service == sid }) { r in
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(r.uuid) · \(BLENames.characteristics[r.uuid] ?? "característica desconocida") (\(r.props))").font(.caption)
                            if let t = r.text { Text(t).font(.caption.weight(.semibold)) }
                            Text(r.hex).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
                Divider()
            }
        }.card()
    }

    private var logCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardHeader(icon: "text.alignleft", title: "Registro", color: .secondary, chevron: false)
            HStack {
                Button(copied ? "Copiado" : "Copiar") { UIPasteboard.general.string = ble.logText; copied = true }.buttonStyle(.bordered)
                Button("Vaciar") { ble.clearLog(); copied = false }.buttonStyle(.bordered)
            }
            ForEach(Array(ble.log.enumerated()), id: \.offset) { _, l in
                Text(l).font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
        }.card()
    }
}

#if DEBUG
#Preview { NavigationStack { BluetoothProbeView(probe: BluetoothProbe(preview: true)) } }
#endif
