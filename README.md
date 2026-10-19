# HealthSpike

App de iPhone (SwiftUI) que lee una **Fitbit Air** a través de la **Google Health API v4** y la enseña en cinco pestañas, con widgets y un Coach
con IA local. Es un proyecto personal: una sola cuenta de Google, sin servidor propio, todo se queda en el dispositivo.

Nació como un estudio de viabilidad (¿deja Google leer los datos de la Air desde una app propia?) y acabó siendo la app completa.
Este repo reúne la app, el estudio de viabilidad con sus pruebas, las sondas de Python y Bluetooth con las que se hizo y la web legal que exige Google.

## Qué hay en el repo
| Ruta | Contenido |
|---|---|
| `Sources/`, `Widgets/`, `Shared/`, `Config/`, `Resources/`, `project.yml` | La app iOS y sus widgets (proyecto generado con XcodeGen) |
| [`docs/FEASIBILITY.md`](docs/FEASIBILITY.md) | Veredicto de viabilidad, qué permite y qué bloquea Google, datos por API frente a Bluetooth |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | Arquitectura planteada: backend, modelo de datos, puntuaciones, app iOS |
| [`docs/TEST_PLAN.md`](docs/TEST_PLAN.md) | Pruebas mínimas con criterios de paso/fallo y sus resultados |
| [`spikes/oauth_read/`](spikes/oauth_read/probe.py) | Sonda OAuth + lectura de la API y dashboard local (Python, solo librería estándar) |
| [`spikes/ble_probe/`](spikes/ble_probe/README.md) | Sonda Core Bluetooth del pulso en directo y receptor de pruebas |
| [`legal/`](legal/) | Página principal y política de privacidad (GitHub Pages), con el archivo de verificación de Google |

> Los documentos de `docs/` conservan el estado de cada momento (octubre de 2026): el estudio se escribió antes de construir la app.

## La app
La Air es siempre la fuente: Google mezcla Apple Health en las mismas listas, así que se filtra por
`dataSource.platform == FITBIT` (Ajustes → *Fuente de los datos* permite pasar a *Todas*).

| Pestaña | Contenido |
|---|---|
| **Hoy** | Pasos, sueño, pulso, carga cardio, recuperación, resiliencia, peso y ánimo. Sueño muestra noche + siestas del día. |
| **Sueño** | Última noche con fases, puntuación y desglose, siestas, consejos, hora de acostarte y periodos (semana a año). |
| **Corazón** | Pulso de hoy y en directo (Bluetooth), reposo, constantes vitales (VFC, SpO₂, respiración, temperatura) y carga cardio. |
| **Actividad** | Pasos, distancia, calorías, minutos en zona activa, entrenos y carga cardio por día, semana, mes, 3 meses y año. |
| **Coach** | Resúmenes del sueño, los entrenos y el día redactados por IA local, en formato log y chat. |

- **Puntuaciones calculadas en local** (`Scores.swift`): Google no publica sus fórmulas ni las devuelve la API. Se reproducen los factores que
  enseña su app (sueño, recuperación, resiliencia) con umbrales estimados: las cifras no tienen por qué coincidir con las de Google.
- **Carga cardio** (`CardioLoad.swift`): estimada con la FC media por minuto (`heart-rate:rollUp`, ventanas de 60 s) y tu reserva
  cardíaca; calibrada con días reales de Google (~16 % de error). Edad y objetivo, en Ajustes.
- **IA local** (`LocalAI.swift`): el modelo del sistema de Apple (Foundation Models, iOS 26+), sin pesos en la app ni descarga. La app calcula las cifras
  y el modelo solo las redacta. Gemma 4 con MLX Swift (`GemmaEngine.swift`) se probó y se descartó: más peso, peor formato y peor redacción.
- **Peso y ánimo**: se anotan a mano y se guardan en un JSON local (`manual-logs.json`); no se borran al cerrar sesión.
- **Widgets** (`Widgets/`): resumen pequeño, trío mediano y de pantalla de bloqueo. Comparten datos con la app por el grupo
  `group.dev.cosmichomeless.healthspike` y se refrescan en segundo plano (`BackgroundRefresh.swift`; iOS decide cuándo, no hay intervalo fijo).
- **Cachés** en *Application Support* (histórico 365 días, hoy, ayer, FC por minuto, zonas, vitales) para abrir al instante y pedir solo lo que falta.
  Cerrar sesión (Ajustes → Cuenta) las borra.
- **Ajustes**: fuente, objetivos (pasos, sueño, calorías, carga cardio), edad, cuenta (actualizar, borrar histórico, cerrar sesión) y, para depurar, *Datos de la API* (cobertura de cada dataType y datos en bruto) y *Bluetooth de la pulsera*.

## Requisitos
- Xcode con iOS 17+, [XcodeGen](https://github.com/yonaskolb/XcodeGen) y un iPhone (solo vertical). La IA local necesita iOS 26+.
- Haber vinculado Google Health en la app móvil de Google **antes** de dar el consentimiento OAuth.
- Un cliente OAuth de Google Cloud (ver *Credenciales*).

## Compilar y ejecutar
El `.xcodeproj` no se versiona: se genera desde `project.yml`.
```bash
xcodegen generate
xcodebuild -scheme HealthSpike -destination 'generic/platform=iOS' -configuration Debug build CODE_SIGNING_ALLOWED=NO   # solo compilar
```
Para instalar en el iPhone, abre `HealthSpike.xcodeproj` y elige tu equipo en *Signing & Capabilities* (app y widgets). Con Personal Team
(gratis) la app caduca a los 7 días. `DEVELOPMENT_TEAM` y el bundle `dev.cosmichomeless.healthspike` están en `project.yml`: cámbialos por los tuyos.

## Credenciales
Nada de secretos en el repo.
- **iPhone (lo normal):** cliente OAuth de tipo **iOS** (esquema inverso, sin secreto). El `client_id` va en `Resources/GoogleClient.plist`,
  que descarga Cloud Console y no se versiona. Login con Google (code + PKCE) y vuelta a la app.
- **Simulador (solo desarrollo):** cliente Web (el de [`spikes/oauth_read/probe.py`](spikes/oauth_read/probe.py)) con redirect loopback `http://127.0.0.1:8765/callback`.
  Las credenciales se pasan por entorno y quedan en el Keychain del simulador:
  ```bash
  set -a; . ~/.fitbit-probe.env; set +a
  SIMCTL_CHILD_GH_CLIENT_ID=$GH_CLIENT_ID SIMCTL_CHILD_GH_CLIENT_SECRET=$GH_CLIENT_SECRET \
    xcrun simctl launch booted dev.cosmichomeless.healthspike
  ```
  `SIMCTL_CHILD_GH_REFRESH_TOKEN=…` salta el login interactivo.

## Qué NO está probado
- Fusión con el Apple Watch (regla propuesta en [`docs/FEASIBILITY.md`](docs/FEASIBILITY.md) §3).
- La cadencia real de la actualización en segundo plano de los widgets.
