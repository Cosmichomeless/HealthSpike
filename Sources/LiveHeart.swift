import CoreBluetooth
import SwiftUI

/// Pulso en directo de la pulsera por el perfil estándar 0x180D, solo mientras la app está abierta.
/// Necesita que la pulsera comparta el pulso (Google Health > Fitbit Air > Compartir frecuencia cardíaca > Siempre visible);
/// si no, no aparece como sensor y la tarjeta se queda con los datos de la API. Todo ocurre en la cola principal (`queue: nil`).
final class LiveHeart: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published private(set) var bpm: Int?
    @Published private(set) var lastSample: Date?

    /// Una muestra llega cada segundo: pasados unos segundos sin ninguna, el dato ya no es «en directo».
    func isLive(at now: Date) -> Bool {
        guard bpm != nil, let t = lastSample else { return false }
        return now.timeIntervalSince(t) < 8
    }

    private static let hrService = CBUUID(string: "180D")
    private static let hrMeasurement = CBUUID(string: "2A37")
    private static let savedKey = "liveHeartPeripheral"

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var wanted = false

    /// La primera vez crea el gestor, y es entonces cuando iOS pide el permiso de Bluetooth.
    func start() {
        wanted = true
        if central == nil { central = CBCentralManager(delegate: self, queue: nil) }
        else { connectIfPossible() }
    }

    func stop() {
        wanted = false
        central?.stopScan()
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        peripheral = nil
        bpm = nil; lastSample = nil
    }

    private func connectIfPossible() {
        guard wanted, let c = central, c.state == .poweredOn, peripheral == nil else { return }
        // Primero la pulsera que ya usamos, luego las que ya estén conectadas al sistema; si no, buscarla.
        if let s = UserDefaults.standard.string(forKey: Self.savedKey), let id = UUID(uuidString: s),
           let p = c.retrievePeripherals(withIdentifiers: [id]).first { connect(p); return }
        if let p = c.retrieveConnectedPeripherals(withServices: [Self.hrService]).first(where: Self.isAir) { connect(p); return }
        c.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    private func connect(_ p: CBPeripheral) {
        central?.stopScan()
        peripheral = p
        p.delegate = self
        central?.connect(p)       // no caduca: se conecta cuando la pulsera esté a mano
    }

    private static func isAir(_ p: CBPeripheral) -> Bool {
        let n = (p.name ?? "").lowercased()
        return n.contains("fitbit") || n.contains("google")
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        if c.state == .poweredOn { connectIfPossible() }
        else { peripheral = nil; bpm = nil; lastSample = nil }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
        let l = name.lowercased()
        guard peripheral == nil, l.contains("fitbit") || l.contains("google") else { return }
        connect(p)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        UserDefaults.standard.set(p.identifier.uuidString, forKey: Self.savedKey)
        p.discoverServices([Self.hrService])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        peripheral = nil
        connectIfPossible()
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        peripheral = nil
        connectIfPossible()       // si seguimos en primer plano, a por ella otra vez
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for s in p.services ?? [] where s.uuid == Self.hrService { p.discoverCharacteristics([Self.hrMeasurement], for: s) }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] where ch.uuid == Self.hrMeasurement { p.setNotifyValue(true, for: ch) }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard ch.uuid == Self.hrMeasurement, let data = ch.value, let m = HRMeasurement.parse(data), m.bpm > 0 else { return }
        bpm = m.bpm
        lastSample = Date()
    }
}
