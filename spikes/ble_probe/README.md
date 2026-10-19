# Sonda Core Bluetooth (Prueba 3)

`BLEProbe.swift` es un único archivo con una app SwiftUI completa (escaneo, conexión, parseo de
0x2A37 con detección de RR, log a fichero, reintento/restauración en segundo plano y envío opcional al backend).

> **Estado: sin compilar ni ejecutar.** Se escribió en un contenedor Linux sin Xcode ni Bluetooth.
> Espera algún error de compilación menor; corrígelo en Xcode.

## Montaje en Xcode (≈10 min)
1. Xcode → *New Project* → iOS **App** (SwiftUI, iOS 17). Borra el `…App.swift` y `ContentView.swift` generados y añade `BLEProbe.swift` (ya contiene `@main`).
2. *Signing & Capabilities*: tu Apple ID como Team. Añade **Background Modes → Uses Bluetooth LE accessories** (`bluetooth-central`).
3. `Info.plist`:
   - `NSBluetoothAlwaysUsageDescription` = "Leer la frecuencia cardíaca de la Fitbit Air".
   - `NSAppTransportSecurity → NSAllowsLocalNetworking = YES` (para http a tu ordenador en la prueba 3.6).
   - `NSLocalNetworkUsageDescription` = "Enviar muestras al backend de pruebas".
   - (opcional) `UIFileSharingEnabled = YES` y `LSSupportsOpeningDocumentsInPlace = YES` para sacar los `.jsonl` desde la app Archivos.
4. Cambia `restoreID` por tu bundle id. Ejecuta en un **iPhone real**.

## Procedimiento
1. En **Google Health** → tu Fitbit Air → *Compartir frecuencia cardíaca* ON y *Siempre visible* ON. Cierra Strava y otras apps que puedan acaparar la conexión.
2. `python3 receiver.py` en tu ordenador (misma wifi); pon su IP en la sonda.
3. En la sonda: *Sin filtro* ON → *Scan*. Anota si la Air aparece (y con qué nombre) y si marca `0x180D`. Contrasta con nRF Connect/LightBlue.
4. Pulsa la Air → mira en el log **todos** los servicios y características. Si no aparece 0x180D/0x2A37, la vía estándar no existe.
5. Ver BPM. Mira `con RR`: si sube, la Air transmite intervalos RR (flag bit 4); si queda en 0 tras varios minutos, solo BPM.
6. Bloquea la pantalla 10 min; luego un entrenamiento de 30–45 min. Cuenta `desconexiones` y huecos en el `.jsonl`.
7. Activa *Send to backend* y revisa `lag` en el receptor.

## Qué registrar
Cada muestra queda en `Documents/ble-probe-*.jsonl` con `bpm`, `rr_ms`, `flags` y el payload crudo en hex. Con eso se responde a todas las filas de `docs/TEST_PLAN.md` §Prueba 3.
