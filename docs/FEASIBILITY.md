# Viabilidad: app iOS privada con Fitbit Air + Google Health API

Fecha de la investigación: 2026-10-08. Documentación oficial verificada ese mismo día desde sesión local (§3 y §2 actualizados). Pruebas 1 y 2 ejecutadas con la cuenta real el 2026-10-09; lo marcado ⚠️ restante sigue sin confirmar.

> **Cómo se obtuvo esto.** El análisis previo (2026-10-08) salió de la documentación oficial y de
> terceros (Validic, Open Wearables, reseñas de la Air). Desde el 2026-10-09 la parte de la API
> está **contrastada contra la cuenta real** (Pruebas 1 y 2, `TEST_PLAN.md`). La parte de Bluetooth
> y los webhooks **siguen sin probarse**. Cada punto lleva su nivel de certeza.

## 1. Veredicto

**Veredicto a 2026-10-09: la vía Google Health API es viable para tu uso (una cuenta, uso personal).** Pruebas 1 y 2 superadas con la cuenta real: la API se habilitó sin bloqueo, el OAuth en modo Testing concedió los 3 scopes y se leyeron datos reales de la Air (FC, sueño con fases, pasos, distancia, HRV, temperatura nocturna, SpO₂, respiración, ejercicios, minutos activos, natación; detalle en `TEST_PLAN.md`).

**Recomendación: (a) construir backend + app iOS sobre Google Health API**, con estas condiciones, todas por verificar o por diseñar:
1. **Filtrar por fuente (`dataSource`) en el backend.** La API mezcla en las mismas listas lo que la Air registra y lo que Apple Health aporta (ver §3, "Fuentes mezcladas"). Sin filtro, los pasos y la distancia se duplican.
2. **Diseñar para que el refresh token muera.** En modo Testing caduca a los 7 días (emitido 2026-10-09 09:40:49 UTC; comprobar ~2026-10-16). Hace falta aviso de reautorización o publicar en Production (no confirmado que se pueda sin verificación).
3. **Webhooks (Prueba 2b) y latencia real: sin medir.** Hasta entonces, el diseño debe funcionar solo con sondeo periódico.
4. **Bluetooth (Prueba 3): probado el 2026-10-13.** Pulso en vivo por el perfil estándar 0x180D (1 muestra/s); sin RR, sin contacto y sin batería estándar (§4). Segundo plano sin probar.
5. **Fusión con el Apple Watch: sin probar.** La regla propuesta está en §3, pero no hay ningún entreno del Watch visible en la API todavía.

No hace falta el Plan B (Health Connect/Android) mientras el acceso siga abierto. Riesgo residual: Google dice que "no incorpora proyectos nuevos"; a nosotros no nos bloqueó, pero la política puede cambiar.

### Análisis previo (2026-10-08, anterior a las pruebas)

**Viable sobre el papel, no confirmado en la práctica.** Había un único bloqueo que decidía todo y
solo se resolvía intentándolo: **¿puede tu proyecto de Google Cloud habilitar y usar Google Health API hoy?** (Respuesta: sí, ver arriba.)

- Google dice en su referencia que *"no está incorporando nuevos proyectos por ahora"* y que está
  trabajando en abrir el acceso; no hay fecha. (Fuente: [referencia REST v4](https://developers.google.com/health/reference/rest/v4/users), cita recogida por búsqueda.)
- A la vez, la guía de [configuración](https://developers.google.com/health/setup) y los codelabs
  describen un alta autoservicio: crear proyecto → habilitar API → cliente OAuth. No hay lista de espera
  ni formulario de "uso personal" visible. (Validic menciona un proceso de credenciales, pero es de
  su integración como partner, no de Google.)
- Ambas cosas pueden ser ciertas: la API se puede *habilitar* pero el *consent/credenciales* puede
  rechazarse o quedar en cola. **Eso solo lo dirá el intento (Prueba 1 del plan).**

Si el intento falla, la ruta alternativa honesta es **Health Connect en Android** o dejar de depender de la nube
de Google (ver §6). No hay una vía oficial para iOS sin la API.

## 2. Qué está permitido y qué está bloqueado

| Tema | Estado | Certeza |
|---|---|---|
| Habilitar Google Health API en un proyecto nuevo | **Permitido en la práctica (2026-10-09)**: el aviso *"While we are not onboarding new projects at this time"* sigue en /health/setup, pero no bloqueó nada | Alta (probado) |
| OAuth 2.0 para tu propia cuenta | **Probado**: modo *Testing*, 3 scopes concedidos, cliente Web con redirect loopback | Alta (probado) |
| Scopes `…/auth/googlehealth.<x>.readonly` (`activity_and_fitness`, `health_metrics_and_measurements`, `sleep`) | Existen y están documentados | Alta |
| `nutrition.readonly` | Existe (verificado 2026-10-08) | Alta |
| Clasificación sensible/restringida | La página de scopes no los clasifica; **se sabrá en la pantalla de consentimiento** | Media |
| Verificación OAuth + auditoría CASA | Solo para lanzamiento público; no para uso personal < 100 usuarios (pantalla "app no verificada") | Media |
| **Refresh token en modo Testing** | **Caduca a los 7 días** (documentado en la guía de setup) | Alta |
| Refresh token en *In production* | No caduca salvo revocación o 6 meses sin uso | Alta |
| Publicar a *Production* sin verificar con scopes restringidos | ⚠️ No confirmado que Google lo permita | Baja |
| Rate limit sin verificar | 250 QPS totales, 2,5 QPS/usuario | Media |
| API antigua Fitbit Web API | Soporte terminó 30-sep-2026; apagado 30-oct-2026. **No usar.** | Alta |
| Webhooks | Existen (notify-only, firmados, HTTPS público) | Alta |

### Dos correcciones a lo que dabas por supuesto
1. **"Menos de 100 usuarios ⇒ no hace falta verificación" es cierto solo para *uso*, y con la
   consecuencia del token de 7 días.** En *Testing* te toca reautorizar cada semana; para evitarlo hay que publicar
   en *Production*, y no está confirmado que se pueda con scopes restringidos sin verificar.
   El backend debe diseñarse asumiendo que el refresh token **puede morir** y avisarte (push/email) para reautorizar.
2. **"El tope de 100 usuarios no se puede resetear"**: usa **un único proyecto** y no lo quemes en pruebas.

## 3. Datos disponibles por la API (Fitbit Air)

**Verificado contra la documentación oficial el 2026-10-08** (matriz de compatibilidad,
`deviceId: air`, y lista de data types). "Listada" = la Air figura en la matriz oficial; **no**
significa que haya datos reales: eso lo dirá la Prueba 2.

| Dato | dataType | Tipo de registro | Air listada |
|---|---|---|---|
| Pasos | `steps` | Interval | Sí |
| Distancia | `distance` | Interval | Sí |
| Calorías totales | `total-calories` | Interval | Sí (`calories-in-heart-rate-zone` y `active-energy-burned` **no** listados) |
| Minutos activos / zona | `active-minutes`, `active-zone-minutes` | Interval | Sí |
| Frecuencia cardíaca | `heart-rate` | Sample | Sí |
| Pulso en reposo | `daily-resting-heart-rate` | Daily | Sí |
| **HRV** | `heart-rate-variability`, `daily-heart-rate-variability` | Sample / Daily | **Sí** |
| Sueño y fases | `sleep` | Session (scope `sleep`) | Sí |
| **Temperatura nocturna vs. línea base** | `daily-sleep-temperature-derivations` | Daily | **Sí** (`skin-temperature-sensors`, v4beta, solo Pixel Watch 4/5) |
| SpO₂ | `daily-oxygen-saturation`, `oxygen-saturation` | Daily / Sample | Sí |
| Frecuencia respiratoria | `daily-respiratory-rate`, `respiratory-rate-sleep-summary` | Daily / Sample | Sí |
| Entrenamientos | `exercise` | Session | Sí |
| VO₂ máx. | `run-vo2-max`, `vo2-max`, `daily-vo2-max` | Sample / Daily | Sí |
| Periodos sedentarios | `sedentary-period` | Interval | Sí |
| Natación | `swim-lengths-data` | Interval | Sí |
| Nutrición | `nutrition-log`, `food-measurement-unit` | Session / Food | Sí, pero scope `nutrition` (fuera de nuestros 3 scopes) |
| Pisos subidos | `floors` | Solo `rollup`/`dailyRollUp`/`reconcile` (`list` da 400) | Existe en la API, pero **no es de la Air**: no tiene altímetro y los pisos salen del teléfono |
| ECG, IRN, altitud, zonas de FC diarias | — | — | **No** listados para la Air |

### Hallazgos reales (2026-10-09)
- La Air entrega **HRV** (RMSSD cada ~5 min + diario) y **temperatura nocturna con línea base**. Se pueden construir scores de recuperación con HRV, RHR, respiración y temperatura.
- `total-calories` **no admite `list`**: solo `dataPoints:dailyRollUp` (POST, máx. 14 días).
- `exercise` solo se filtra con `interval.civil_start_time`.
- **`heart-rate:rollUp` con `windowSize` de 60 s funciona** y es la base de la carga cardio de la app. `POST /v4/users/me/dataTypes/heart-rate/dataPoints:rollUp` con `{"range": {"startTime": …, "endTime": …}, "windowSize": "60s"}` (instantes ISO 8601 en UTC) devuelve `rollupDataPoints[]`, cada uno con `startTime`, `endTime` y `heartRate.beatsPerMinuteAvg`: la FC media de cada minuto, sin bajar las ~14 000 muestras diarias (199 738 en 14 días). La app pide un día civil por petición y suma los minutos que pasó a cada pulso para estimar la carga (`HealthAPI.heartMinutes(day:)`, `CardioLoad.swift`). Con `dailyRollUp` (ventana de días) la FC solo da un punto diario, que no sirve para esto. Con 9 días reales de la app de Google (3–11 oct 2026) la estimación sale con ~16 % de error por día; el modelo y la calibración están en la cabecera de `CardioLoad.swift`.
- `run-vo2-max` y `vo2-max` devolvieron 0 puntos en 14 días.
- El aviso "no onboarding de proyectos nuevos" **no bloqueó** habilitar la API ni autorizar una cuenta propia en modo Testing.
- Los 10 ejercicios de los últimos 14 días son todos de la Air (`FITNESS_BAND`, `PASSIVELY_MEASURED`); el sueño es de la Air (`DERIVED`) más 1 registro `MANUAL`.
- Huecos observados, propios de los datos: la FC intradía de la Air solo aparece desde 2026-10-03 15:07 en el volcado; la noche del 04/10 se registró como `CLASSIC` (sin fases) y sin temperatura ni SpO₂.
- Con un dashboard local (`spikes/oauth_read/dashboard.py`) se verificó visualmente que todos los tipos con datos se pueden representar sin huecos inesperados.

### Fuentes mezcladas (hallazgo 2026-10-09)

**Google Health agrega en las mismas listas los datos de la Air y los de Apple Health (HealthKit del iPhone).** Cada punto trae `dataSource` con `platform` (`FITBIT` o `HEALTH_KIT`), `device.displayName` ("Google Fitbit Air"), `formFactor`, `manufacturer`, `application.packageName` y `recordingMethod`.

- Síntoma: en una comparación durante el día, la app de Google mostraba 2425 pasos / 1,76 km y la suma sin filtrar de la API era bastante mayor (el dashboard marcaba ~4400 pasos y ~3,2 km). Con solo `FITBIT` coincidía con la app (2425 / 1,76 km); lo demás era Apple Health. Ejemplo reproducible con el volcado del 2026-10-09 (días en UTC): el 2026-10-08 hay 14 516 pasos de la Air frente a 12 521 de Apple Health; sumarlos daría 27 037.
- Tipos con puntos de Apple: `steps`, `distance`, `heart-rate`, `heart-rate-variability`, `daily-resting-heart-rate`, `daily-heart-rate-variability`, `daily-oxygen-saturation` y `vo2-max` (5 puntos en 90 días, todos Apple). `run-vo2-max` vacío; `daily-vo2-max` es de Fitbit.
- Cobertura a 14 días (Air / otras fuentes): steps 3612 / 807, distance 3618 / 951, heart-rate 199 738 / 235, HRV 1112 / 11.
- **Requisito de diseño:** si la fuente debe ser siempre la Air, el backend filtra por `dataSource.platform == "FITBIT"` (y por dispositivo) antes de agregar, y guarda la fuente en `metric_point.source`. `dashboard.py` lo hace por defecto (`--source air`; `--source all` para mezclar).

**Regla de fusión propuesta ("Air base, el Watch manda en sus ejercicios")**, para cuando entrenes con el Apple Watch y quieras que se mezcle sin perder el criterio de que la Air es la fuente:
1. Fuera de las sesiones del Watch, todo viene de la Air.
2. Dentro de una sesión del Watch, manda Apple y se descarta lo de la Air en esa ventana.
3. Las sesiones de la Air que se solapen con una del Watch se descartan.
4. Totales del día = Air fuera de sesiones + Watch dentro de ellas.
5. Sueño y métricas diarias (HRV, reposo, SpO₂, respiración, temperatura, VO₂ diario): siempre de la Air.

⚠️ **Sin verificar:** no se sabe si las sesiones del Apple Watch llegan a Google Health ni cómo aparecen (los 10 ejercicios actuales son todos de la Air). Sin sesión habría que inferir los límites desde las muestras de FC/pasos. Implementar tras un entreno real.

### Detalles de la API (verificados)
- Host y ruta: `GET https://health.googleapis.com/v4/users/me/dataTypes/{dataType}/dataPoints`. Respuesta: array `dataPoints` + `nextPageToken`.
- **Rango de fechas = parámetro `filter`** (AIP-160), no `startTime/endTime`:
  - Interval/Session: `steps.interval.start_time >= "2026-10-01T00:00:00Z"` (también `civil_start_time`).
  - Sample: `heart_rate.sample_time.physical_time` / `.civil_time`.
  - Daily: `daily_resting_heart_rate.date` con `YYYY-MM-DD`.
  - Sleep: solo `sleep.interval.end_time` (u `civil_end_time`).
  - El nombre en el filtro usa guiones bajos; resultados ordenados por inicio descendente.
- `pageSize`: por defecto 1440, máx. 10000; **25 para `exercise` y `sleep`**.
- `dataSourceFamily` no aplica a `sleep` (usar `dataPoints.reconcile`).
- Scopes `https://www.googleapis.com/auth/googlehealth.{activity_and_fitness,health_metrics_and_measurements,sleep}.readonly` ✓. La página de scopes **no** los clasifica como sensibles/restringidos (corrige la sospecha de §2).
- `users.getIdentity` (`GET /v4/users/me/identity`) devuelve `healthUserId` y `legacyUserId`.
- **Requisito nuevo**: el usuario debe haber vinculado Google Health en la app móvil *antes* del consentimiento OAuth.
- La guía de setup indica cliente OAuth de tipo **Web Server** (redirect de ejemplo `https://www.google.com`); `probe.py` usa loopback `http://127.0.0.1:8765/callback`: comprobar en la Prueba 1 que Google lo acepta para ese tipo de cliente.

## 4. Datos por Bluetooth (probado con la pulsera el 2026-10-13)

Prueba hecha con la pantalla «Bluetooth de la pulsera» de la app (iPhone 17 Pro, issue #18), con *Compartir frecuencia cardíaca* activado. **Resultado: la Air usa el perfil estándar de frecuencia cardíaca y solo entrega el pulso en vivo.**

| Dato | Resultado |
|---|---|
| Aparece como periférico | **Sí.** Nombre «Google Fitbit Air». El anuncio llevó el servicio 0xFD62 en una prueba y 0x180D en otra |
| BPM | **Sí**, servicio estándar 0x180D, característica 0x2A37 por *notify*, una muestra por segundo, formato de 16 bits |
| Intervalos RR | **No.** El flag de RR (bit 4) viene a 0 en todas las muestras |
| Contacto del sensor | **No informa** (flags de contacto a 0) |
| Energía, ubicación del sensor (0x2A38) | **No** |
| Batería | **No se ve.** No hay servicio estándar 0x180F y ninguna característica propietaria en claro la sigue: con la app de Google marcando 25 %, el único valor que parecía encajar (`ABBAFD01`) resultó cambiar entre conexiones (24, 120, 12…) y encaja mejor con parámetros de conexión. Probablemente viaja por el canal cifrado. **Por la API sí existe:** `GET /v4/users/{user}/pairedDevices` devuelve `batteryLevel`, `batteryStatus` (High/Medium/Low/Empty) y `lastSyncTime`, con el scope `googlehealth.settings.readonly` (distinto de los 3 iniciales); la app ya la muestra en Hoy (2026-10-13) |
| Device Information (0x180A) | Fabricante «Fitbit», modelo «67» y firmware 67.20001.253.2. El «número de serie» **cambia en cada conexión**, así que no es un identificador estable. Hardware y software vacíos |
| Servicios propietarios | Cuatro, sin documentar: `ABBAFD00-…`, `ABBAFF00-…`, `AC2F0045-…` y `4EEE1C00-…`, con características de lectura, *notify*, *indicate* y escritura. Al suscribirse a `ABBAFF02` llegan ~100 bytes por segundo con pinta de IPv4/UDP al puerto 5684 (CoAP sobre DTLS 1.2, registros `17 FE FD`), es decir, **cifrado**. Es el canal de sincronización y órdenes de la app de Google; no se puede leer sin las claves y no se ha escrito en él |
| Segundo plano en iOS | **Sin probar** (la pantalla no tiene modo `bluetooth-central`) |
| Historial, sueño, HRV, temperatura | **No hay base para esperarlos** por el perfil estándar. Solo podrían estar en los canales propietarios, cifrados o con un protocolo no documentado |

Conclusiones:
- Se resuelve la contradicción de las fuentes: el enlace estándar existe y funciona; no hace falta nada propietario para el pulso en directo.
- El Bluetooth sirve para un pulso en tiempo real (por ejemplo, durante un entreno), no para sustituir la API de Google. RR/HRV en directo no está disponible por esta vía.
- La parte propietaria queda sin explorar a propósito: escribir en características desconocidas de la pulsera puede estropear su estado o el emparejamiento con Google Health.

## 5. Datos no documentados / no esperables

- Acelerómetro, PPG óptico en bruto, señales internas del sensor.
- Puntuaciones propietarias de Google (sueño, readiness, etc.) → las calcularemos nosotros.
- Frecuencia de muestreo real del PPG (Google no la publica; el "2 s" de algunas reseñas vino de un bug del export TCX).
- Datos antes de la sincronización Air → Google Health. La API no los ve hasta entonces.

## 6. Plan B si Google no te da acceso

1. Esperar la apertura de onboarding (sin fecha).
2. Usar Health Connect en un móvil Android solo como puente (los datos leídos en dispositivo evitan el scope restringido de Google), reenviando a tu backend. Contradice "solo iPhone", pero mantiene la Air como fuente.
3. Quedarse solo con Bluetooth HR en directo (muy limitado: sin sueño, HRV nocturno ni historial).

## 7. Lo que NO hemos hecho

Hecho (2026-10-09): proyecto de Cloud único, API habilitada, OAuth con los 3 scopes, lectura real de todos los tipos con datos (spike `oauth_read`), refresh del access token y dashboard local.

**Pendiente (sin probar):**
- Webhooks (Prueba 2b): suscriptor, handshake, firma, latencia.
- Latencia real tras sincronizar la Air (solo hay una medición orientativa de ~10 min).
- Caducidad del refresh token a 7 días en Testing (comprobar ~2026-10-16) y opción de pasar a Production.
- Bluetooth en segundo plano (`bluetooth-central` + state restoration): sin probar. El resto de datos (sueño, HRV, temperatura) no viaja por el perfil estándar.
- Apple Watch en Google Health: visibilidad de sus sesiones y regla de fusión.
- Clasificación sensible/restringida de los scopes (no se anotó en la pantalla de consentimiento).

## Fuentes
- [Google Health API – setup](https://developers.google.com/health/setup)
- [Scopes](https://developers.google.com/health/scopes)
- [App verification](https://developers.google.com/health/app-verification)
- [Webhooks](https://developers.google.com/health/webhooks)
- [Data types](https://developers.google.com/health/data-types) · [Vitals](https://developers.google.com/health/data-types/vitals)
- [Release notes](https://developers.google.com/health/release-notes)
- [Quotas](https://developers.google.com/health/rate-limits)
- [Compatibilidad de dispositivos](https://developers.google.com/health/data-types/device-compatibility) (no pude abrirla; citada por tu enunciado)
- [Compartir FC por Bluetooth](https://support.google.com/googlehealth/answer/14236705) (no pude abrirla)
- [DCRainmaker – Fitbit Air review](https://www.dcrainmaker.com/2026/05/fitbit-review-vs-whoop.html) · [ZonePoints](https://zonepoints.app/articles/fitbit-air-live-heart-rate/) · [FITIV](https://www.fitiv.com/blog/live-hr-and-workout-tracking-on-ios-how-to-maximize-your-fitbit-air-experience)
- [Open Wearables – Google Health API setup](https://openwearables.io/blog/google-health-api-practical-guide-getting-started)
