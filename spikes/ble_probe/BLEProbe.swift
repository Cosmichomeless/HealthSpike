// Sonda Core Bluetooth para Fitbit Air (Heart Rate Profile, servicio 0x180D).
// No es la app: responde a las preguntas de TEST_PLAN.md Prueba 3.
//
// Requisitos de proyecto (ver README.md): iPhone físico; Info.plist con
//   NSBluetoothAlwaysUsageDescription y UIBackgroundModes = [bluetooth-central].

import CoreBluetooth
import Foundation
import SwiftUI

// MARK: - Parseo de la característica Heart Rate Measurement (0x2A37)

struct HRSample {
    let date: Date
    let bpm: Int
    let sensorContact: String   // "n/a" | "no" | "sí"
    let energyKJ: Int?
    let rrMs: [Double]          // RR en milisegundos (unidad nativa: 1/1024 s)
    let flagsHex: String
    let rawHex: String
}

enum HRParser {
    static func parse(_ data: Data, at date: Date = Date()) -> HRSample? {
        let b = [UInt8](data)
        guard b.count >= 2 else { return nil }
        let flags = b[0]
        var i = 1
        let bpm: Int
        if flags & 0x01 == 0 { bpm = Int(b[i]); i += 1 }
        else { guard b.count >= 3 else { return nil }; bpm = Int(b[i]) | Int(b[i + 1]) << 8; i += 2 }

        let contactSupported = flags & 0x04 != 0
        let contact = contactSupported ? (flags & 0x02 != 0 ? "sí" : "no") : "n/a"

        var energy: Int?
        if flags & 0x08 != 0, i + 1 < b.count { energy = Int(b[i]) | Int(b[i + 1]) << 8; i += 2 }

        var rr: [Double] = []
        if flags & 0x10 != 0 {
            while i + 1 < b.count {
                rr.append(Double(Int(b[i]) | Int(b[i + 1]) << 8) / 1024.0 * 1000.0)
                i += 2
            }
        }
        return HRSample(date: date, bpm: bpm, sensorContact: contact, energyKJ: energy, rrMs: rr,
                        flagsHex: String(format: "0x%02X", flags),
                        rawHex: b.map { String(format: "%02X", $0) }.joined(separator: " "))
    }
}

// MARK: - Gestor BLE

final class BLEProbe: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    struct Found: Identifiable { let id: UUID; var name: String; var rssi: Int; var advertises180D: Bool; let peripheral: CBPeripheral }

    static let hrService = CBUUID(string: "180D")
    static let hrMeasurement = CBUUID(string: "2A37")
    static let restoreID = "com.example.fitbitprobe.central"   // cambiar por tu bundle id

    @Published var state = "init"
    @Published var found: [Found] = []
    @Published var log: [String] = []
    @Published var connected: String?
    @Published var lastBPM: Int?
    @Published var samples = 0
    @Published var samplesWithRR = 0
    @Published var disconnects = 0
    @Published var scanAll = true            // true = sin filtro (ve si la Air publica 0x180D); false = filtra 0x180D
    @Published var sendToBackend = false
    @Published var backendURL = "http://192.168.1.10:8787/hr"   // receiver.py

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var logHandle: FileHandle?
    private var lastConnectedID: UUID? { get { UserDefaults.standard.string(forKey: "lastPeripheral").flatMap(UUID.init) }
                                         set { UserDefaults.standard.set(newValue?.uuidString, forKey: "lastPeripheral") } }

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil,
                                   options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restoreID])
        openLogFile()
    }

    // Log a pantalla y a fichero (Documents/ble-probe-<fecha>.jsonl; visible en Archivos si se activa UIFileSharingEnabled)
    private func openLogFile() {
        let df = ISO8601DateFormatter()
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ble-probe-\(df.string(from: Date())).jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        logHandle = try? FileHandle(forWritingTo: url)
    }

    private func note(_ s: String) {
        DispatchQueue.main.async { self.log.insert("\(Date().formatted(date: .omitted, time: .standard)) \(s)", at: 0)
            if self.log.count > 300 { self.log.removeLast() } }
        writeLine(["t": Date().timeIntervalSince1970, "event": s])
    }

    private func writeLine(_ obj: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj), let h = logHandle else { return }
        h.write(d); h.write(Data("\n".utf8))
    }

    // MARK: Acciones
    func startScan() {
        guard central.state == .poweredOn else { note("Bluetooth no está encendido (\(central.state.rawValue))"); return }
        found = []
        let services: [CBUUID]? = scanAll ? nil : [Self.hrService]
        central.scanForPeripherals(withServices: services, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        note("scan \(scanAll ? "SIN filtro" : "solo 0x180D")")
    }
    func stopScan() { central.stopScan(); note("scan detenido") }
    func connect(_ f: Found) {
        central.stopScan(); peripheral = f.peripheral; f.peripheral.delegate = self
        lastConnectedID = f.id
        central.connect(f.peripheral, options: nil)
        note("conectando a \(f.name)")
    }
    func disconnect() { if let p = peripheral { central.cancelPeripheralConnection(p) }; lastConnectedID = nil }

    // MARK: CBCentralManagerDelegate
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        DispatchQueue.main.async { self.state = "\(c.state.rawValue)" }
        note("estado central = \(c.state.rawValue) (5 = poweredOn)")
        if c.state == .poweredOn, let id = lastConnectedID, peripheral == nil,
           let p = c.retrievePeripherals(withIdentifiers: [id]).first {
            peripheral = p; p.delegate = self; c.connect(p, options: nil)   // reconexión tras relanzar
        }
    }

    // iOS relanza la app en segundo plano y entrega aquí lo que tenía conectado
    func centralManager(_ c: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let ps = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral], let p = ps.first {
            peripheral = p; p.delegate = self
            note("state restoration: \(p.name ?? p.identifier.uuidString)")
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData ad: [String: Any], rssi: NSNumber) {
        let name = p.name ?? (ad[CBAdvertisementDataLocalNameKey] as? String) ?? "(sin nombre)"
        let uuids = (ad[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let f = Found(id: p.identifier, name: name, rssi: rssi.intValue, advertises180D: uuids.contains(Self.hrService), peripheral: p)
        DispatchQueue.main.async {
            if let i = self.found.firstIndex(where: { $0.id == f.id }) { self.found[i] = f } else { self.found.append(f) }
        }
        if f.advertises180D || name.localizedCaseInsensitiveContains("fitbit") || name.localizedCaseInsensitiveContains("air") {
            writeLine(["event": "discover", "name": name, "rssi": rssi.intValue, "adv": ad.description])
        }
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        DispatchQueue.main.async { self.connected = p.name }
        note("conectado; descubriendo servicios (todos, para ver qué expone)")
        p.discoverServices(nil)    // nil a propósito: queremos ver TODO lo que expone la Air
    }
    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        note("fallo al conectar: \(error?.localizedDescription ?? "?")")
    }
    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        DispatchQueue.main.async { self.connected = nil; self.disconnects += 1 }
        note("desconectado: \(error?.localizedDescription ?? "sin error") — reintentando")
        if lastConnectedID != nil { c.connect(p, options: nil) }   // la conexión pendiente sobrevive en segundo plano
    }

    // MARK: CBPeripheralDelegate
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for s in p.services ?? [] {
            note("servicio \(s.uuid.uuidString)")
            p.discoverCharacteristics(nil, for: s)
        }
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] {
            note("  char \(ch.uuid.uuidString) props=\(ch.properties.rawValue)")
            if ch.uuid == Self.hrMeasurement { p.setNotifyValue(true, for: ch); note("  → notificaciones HR activadas") }
        }
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard ch.uuid == Self.hrMeasurement, let data = ch.value, let s = HRParser.parse(data) else { return }
        DispatchQueue.main.async {
            self.lastBPM = s.bpm; self.samples += 1
            if !s.rrMs.isEmpty { self.samplesWithRR += 1 }
        }
        let obj: [String: Any] = ["t": s.date.timeIntervalSince1970, "event": "hr", "bpm": s.bpm, "rr_ms": s.rrMs,
                                  "contact": s.sensorContact, "flags": s.flagsHex, "raw": s.rawHex]
        writeLine(obj)
        if sendToBackend { post(obj) }
    }

    // MARK: Envío al backend (una petición por muestra: suficiente para medir latencia en la prueba)
    private func post(_ obj: [String: Any]) {
        guard let url = URL(string: backendURL), let body = try? JSONSerialization.data(withJSONObject: obj) else { return }
        var req = URLRequest(url: url); req.httpMethod = "POST"; req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let sent = Date()
        URLSession.shared.dataTask(with: req) { [weak self] _, resp, err in
            let ms = Int(Date().timeIntervalSince(sent) * 1000)
            if let err { self?.note("POST error: \(err.localizedDescription)") }
            else if (resp as? HTTPURLResponse)?.statusCode ?? 0 >= 300 { self?.note("POST HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)") }
            else { self?.writeLine(["event": "post_ok", "latency_ms": ms]) }
        }.resume()
    }
}

// MARK: - UI mínima

struct ProbeView: View {
    @StateObject private var ble = BLEProbe()
    var body: some View {
        NavigationStack {
            List {
                Section("Estado") {
                    Text("Central: \(ble.state) · Conectado: \(ble.connected ?? "no")")
                    Text("BPM: \(ble.lastBPM.map(String.init) ?? "—") · muestras \(ble.samples) · con RR \(ble.samplesWithRR) · desconexiones \(ble.disconnects)")
                }
                Section("Escaneo") {
                    Toggle("Sin filtro (ver todo)", isOn: $ble.scanAll)
                    HStack { Button("Scan") { ble.startScan() }; Spacer(); Button("Stop") { ble.stopScan() }; Spacer(); Button("Desconectar") { ble.disconnect() } }
                    ForEach(ble.found.sorted { $0.rssi > $1.rssi }) { f in
                        Button { ble.connect(f) } label: {
                            HStack { Text(f.name); Spacer(); if f.advertises180D { Text("0x180D").font(.caption).foregroundStyle(.green) }; Text("\(f.rssi) dBm").font(.caption) }
                        }
                    }
                }
                Section("Backend") {
                    Toggle("Send to backend", isOn: $ble.sendToBackend)
                    TextField("URL", text: $ble.backendURL).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section("Log") { ForEach(ble.log, id: \.self) { Text($0).font(.system(.caption, design: .monospaced)) } }
            }
            .navigationTitle("Air BLE probe")
        }
    }
}

@main
struct BLEProbeApp: App { var body: some Scene { WindowGroup { ProbeView() } } }
