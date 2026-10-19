# Plan de prueba mínimo

Orden estricto. **Si una prueba falla, se para y se replantea; no se avanza a la siguiente.**
Marca resultados en la columna *Resultado* y guarda salidas en `spikes/**/logs/` (ignorado por git).

## Prerrequisitos
- Fitbit Air emparejada con **Google Health** y sincronizando (≥ 7 días de datos, incluida ≥ 1 noche de sueño).
- Cuenta Google personal que usa la Air, con **Google Health vinculado en la app móvil** (requisito oficial antes del consentimiento OAuth). Proyecto de Cloud **único** (el tope de usuarios es vitalicio).
- Para la Prueba 3: iPhone físico (el simulador no tiene Bluetooth), Mac con Xcode, Apple ID.

## Prueba 1 — ¿Google deja habilitar y autorizar? (30–60 min)
1. Cloud Console → proyecto nuevo → *APIs & Services* → habilitar **Google Health API**.
   - Anota el mensaje exacto si hay bloqueo, cuota 0, "request access", o si el API no aparece.
2. *Google Auth Platform*: tipo **External**, estado **Testing**, añadir tu cuenta como *test user*.
3. Añadir scopes: `activity_and_fitness.readonly`, `health_metrics_and_measurements.readonly`, `sleep.readonly` (prefijo `https://www.googleapis.com/auth/googlehealth.`). Anota si el selector los muestra o hay que teclearlos.
4. Crear cliente OAuth. La guía oficial indica **Web Server**; añadir redirect `http://127.0.0.1:8765/callback` y anotar si Google lo acepta.
5. Opcional antes de nada: el [OAuth Playground codelab](https://developers.google.com/health/codelabs/make-your-first-api-call-using-oauth2-playground) para una llamada sin código.

| Criterio de éxito | Resultado |
|---|---|
| API habilitada sin petición de acceso | **SÍ** (2026-10-09). Solo el aviso estándar "puede que debas crear credenciales" |
| Pantalla de consentimiento muestra los 3 scopes (con aviso "no verificada") | **SÍ**: los 3 se concedieron (`scope` devuelto con los tres). Clasificación sensible/restringido: no anotada |
| Se obtiene `refresh_token` | **SÍ**. `users.getIdentity` → HTTP 200 |

**Resultado Prueba 1: PASA** (2026-10-09). Notas: usuario de prueba añadido (un reintento dio "cuentas no aptas" aunque ya estaba en la lista, sin consecuencias). Cliente tipo **Web** con redirect `http://127.0.0.1:8765/callback` aceptado. Los *Orígenes JavaScript autorizados* no admiten ruta: dejarlos vacíos.

**Si falla en el paso 1**: ese es el bloqueo de "no onboarding". Captura pantalla + texto, no sigas, vuelve a FEASIBILITY §6.

## Prueba 2 — Lectura real de datos (1–2 h)
```bash
cd spikes/oauth_read
export GH_CLIENT_ID=… GH_CLIENT_SECRET=…
python3 probe.py auth              # abre navegador, guarda token local
python3 probe.py read heart-rate --days 1   # --days se traduce al parámetro `filter`
python3 probe.py matrix --days 14  # prueba todos los dataTypes y resume
```
`matrix` imprime por tipo: HTTP status, nº de puntos, páginas, campos del primer punto. Rellena:

Resultados reales del 2026-10-09 (`matrix --days 14`; tope de la sonda: 5 páginas × 100, por eso 500 = "al menos 500"). **Los recuentos son orientativos y mezclan fuentes** (ver "Hallazgo: fuentes mezcladas" más abajo); los totales completos, separados Air / otras fuentes, están en la tabla de cobertura del dashboard.

| dataType | HTTP | Puntos (14 d) | Observaciones |
|---|---|---|---|
| steps / distance | 200 | 201 / 202 | |
| total-calories | 200 vía **`dailyRollUp` (POST)**; `list` da 400 | 1 valor/día | `totalCalories.kcalSum`; rollup máx. 14 días |
| active-minutes / active-zone-minutes | 200 | 199 / 216 | |
| heart-rate (intradía) | 200 | ≥ 500 | muestras cada pocos segundos (09:30:52, 09:30:54…), `PASSIVELY_MEASURED`, dispositivo "Google Fitbit Air" |
| daily-resting-heart-rate | 200 | 16 | |
| heart-rate-variability | 200 | ≥ 500 | **SÍ hay HRV**: RMSSD en ms + `highFrequencyPower`/`lowFrequencyPower`, muestras cada ~5 min, `DERIVED` |
| daily-heart-rate-variability | 200 | 17 | media diaria, `nonRemHeartRateBeatsPerMinute`, `entropy`, RMSSD en sueño profundo |
| sleep | 200 | 20 | **Fases** (AWAKE/LIGHT/…), resumen (minutos dormido, despertares, `mainSleep`). `sleep.readonly` basta. Con `pageSize=2` devolvió 1 punto |
| daily-sleep-temperature-derivations | 200 | 14 | **SÍ hay temperatura nocturna de la Air**: `nightlyTemperatureCelsius`, `baselineTemperatureCelsius`, desviación 30 d |
| oxygen-saturation / daily-oxygen-saturation | 200 | 394 / 17 | |
| daily-respiratory-rate / respiratory-rate-sleep-summary | 200 | 14 / 15 | |
| exercise | 200 con filtro **civil**; `start_time`/`end_time` → 400 | ≥ 10 | tipo, distancia, pasos, kcal, FC media, zonas de FC |
| run-vo2-max / vo2-max | 200 | 0 / 0 | sin datos en 14 d (¿requiere carreras?) |
| daily-vo2-max | 200 | 15 | |
| sedentary-period / swim-lengths-data | 200 | 214 / 266 | |
| nutrición | no probado | | fuera de los 3 scopes |

Además comprobar:
- **Paginación**: **funciona** (`nextPageToken` presente en heart-rate, HRV, exercise, sleep…; la sonda siguió páginas hasta su tope).
- **Latencia** (pendiente de medir bien): dato orientativo, a las 09:41 UTC la última muestra de FC era de las 09:30:54 UTC (~10 min de retraso en ese momento). Medir forzando sincronización: sincroniza la Air, anota cuánto tarda en aparecer un dato nuevo (esperado ~15 min bajo ciertas condiciones).
- **Token**: `refresh_token` emitido **2026-10-09 09:40:49 UTC** (en Testing caduca ~2026-10-16; comprobarlo). `access_token` dura 3599 s. El `access_token` se renueva con el refresh token. Repetir tras 7 días para confirmar la caducidad en Testing (**guardar fecha de emisión**).
- **Fallos esperables**: nombres de `dataType` o parámetros de rango que difieran de los candidatos del script ⇒ ajustar `probe.py` mirando el cuerpo del error.

**Resultado Prueba 2: PASA** (2026-10-09): FC, sueño y pasos con datos reales, además de HRV y temperatura. Pendiente: latencia medida, caducidad a 7 días y refresh tras 1 h.

**Criterio de paso**: al menos FC, sueño y pasos con datos reales. HRV y temperatura son un *bonus* que se registra como sí/no; no bloquean el proyecto, pero cambian los scores posibles.

### Hallazgo: fuentes mezcladas (2026-10-09)
Los pasos y la distancia de la API no coincidían con la app (unos 4400 pasos frente a 2425 en la app, en la comparación durante el día). Causa: Google Health mezcla en la misma lista los puntos de la Air (`dataSource.platform = FITBIT`) y los de Apple Health (`HEALTH_KIT`). Filtrando por `FITBIT`: 2425 pasos / 1,76 km, igual que la app.
- Afecta a `steps`, `distance`, `heart-rate`, `heart-rate-variability`, `daily-resting-heart-rate`, `daily-heart-rate-variability`, `daily-oxygen-saturation` y `vo2-max` (este último, solo Apple).
- Los ejercicios (10) y el sueño (20) de 14 días son de la Air (el sueño incluye 1 `MANUAL`).
- Aplicado en `spikes/oauth_read/dashboard.py` y en `probe.py` (`--source air|all`, por defecto `air`; `probe.py today` muestra pasos y distancia de hoy por fuente). Los recuentos de la tabla de arriba son anteriores al filtro y mezclan fuentes.
- App iOS mínima en el simulador (la app de este repo, en su raíz): lee pasos, distancia, FC y sueño con el filtro solo-Air y coincide con la app de Google (2425 pasos / 1,76 km, FC en reposo 62, sueño 7 h 16 min). Sesión persistida en el Keychain. El **login interactivo con Google también funciona en el simulador** (code + PKCE con redirect loopback). **Probada también en un iPhone 14 real** con un cliente OAuth tipo iOS (sin secreto, redirect por esquema inverso): login y datos solo-Air correctos. Los scopes de Google Health se aceptan con cliente iOS en modo Testing.
- Regla de fusión con el Apple Watch y requisitos para el backend: `FEASIBILITY.md` §3 y `ARCHITECTURE.md`.

### Inventario y dashboard (2026-10-09)
Se leyeron 14 días de los 20 tipos con datos y se generó un dashboard local (`dashboard.py`, ignorado por git) que dibuja FC, sueño con hipnograma, actividad, SpO₂, VO₂ y ejercicios, más una tabla de cobertura con puntos por fuente. Revisado visualmente en captura completa: sin `NaN` ni gráficas vacías; los huecos (FC diaria desde el 03/10, noche del 04/10 `CLASSIC`) son de los datos.

## Prueba 2b — Webhook (después de la 2, 1–2 h)
1. Exponer un endpoint HTTPS (Cloud Run / túnel tipo cloudflared) que devuelva 204 y registre cabeceras y cuerpo.
2. Crear el *subscriber* (`projects.subscribers`) para `heart-rate`, `sleep`, `steps`; superar el desafío de verificación.
3. Sincronizar la Air. Registrar: ¿llega la notificación?, ¿cuánto tarda?, ¿firma válida?, forma del cuerpo.

## Prueba 3 — Bluetooth con la pulsera física (1–2 h)
Código: `spikes/ble_probe/` (ver su README). Pasos:

| # | Pregunta | Cómo | Resultado |
|---|---|---|---|
| 3.0 | Activar *Compartir FC* + *Siempre visible* en Google Health | Manual; cerrar Strava/otras apps | |
| 3.1 | ¿Aparece en el escaneo? ¿con 0x180D en la publicidad? | Pestaña *Scan* (modo "todos" y modo "solo 0x180D"). Contrastar con nRF Connect/LightBlue | |
| 3.2 | ¿Conecta una app propia? | *Connect* → descubrir servicios | |
| 3.3 | ¿Solo BPM o también RR? | Ver `flags` y `rr` en el log; ≥ 5 min en reposo y caminando | |
| 3.4 | ¿Sigue en segundo plano? | Bloquear pantalla 10 min; ver huecos en el log | |
| 3.5 | ¿Aguanta un entrenamiento? | 30–45 min de actividad con teléfono en bolsillo; contar desconexiones | |
| 3.6 | ¿Llega al backend en tiempo real? | Activar *Send to backend* hacia `receiver.py`; medir latencia y pérdidas | |
| 3.7 | ¿Convive con Google Health? | Con la app de Google abierta/cerrada, ¿se puede conectar? | |

**Criterio de paso (mínimo)**: 3.1–3.3 positivos. 3.4–3.6 deciden si LiveHR merece construirse.
Si la Air no expone 0x180D en iOS (la reseña de DCRainmaker sugiere un enlace propietario), la función Bluetooth se descarta y se documenta.

## Decisión tras las pruebas
| Escenario | Acción |
|---|---|
| P1 y P2 OK | Construir backend + iOS según ARCHITECTURE.md · **ESTE ES NUESTRO CASO (2026-10-09)** |
| P1 falla | Plan B (FEASIBILITY §6) o esperar apertura |
| P2 sin HRV/temperatura | Scores de recuperación solo con RHR/sueño/respiración |
| P3 positiva con RR | Fase 2: LiveHR + HRV propio durante entrenos |
| P3 negativa | Eliminar LiveHR |

**Estado a 2026-10-09:** P1 y P2 superadas → recomendación (a): construir backend + iOS. Pendientes sin ejecutar: 2b (webhook), 3 (Bluetooth), latencia real, caducidad del refresh token (~2026-10-16) y fusión con el Apple Watch. Ninguna de ellas bloquea empezar el backend con sondeo y filtro por fuente.
