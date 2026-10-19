# Arquitectura propuesta

**Pruebas 1 y 2 superadas (2026-10-09): se puede empezar con backend + iOS por sondeo y filtro por fuente.** Webhooks (2b) y Bluetooth (3) siguen sin probarse: no construir esas partes hasta pasar sus pruebas de `TEST_PLAN.md`. Esto es el diseño objetivo.

```
Fitbit Air ──BLE──► Google Health (app móvil) ──► nube Google ──► Google Health API
                                                                      │  ▲ REST (dataPoints.list, paginado)
                                                              webhook │  │
                                                                      ▼  │
                                                              ┌── Backend ──────────┐
                                                              │ OAuth + token vault │
                                                              │ Sync incremental    │
                                                              │ Normalización       │
                                                              │ Scores (propios)    │
                                                              │ API propia (REST)   │
                                                              └─────┬───────────────┘
                                                                    │ HTTPS + token propio
                                                              App iOS (SwiftUI)
Fitbit Air ──BLE HR (0x180D)──► App iOS (Core Bluetooth) ──WebSocket/HTTP──► Backend   [opcional, fase 2]
```

## Backend

Una sola persona, un solo usuario ⇒ **monolito pequeño**. Propuesta: Python (FastAPI) o TypeScript (Fastify), Postgres, un único contenedor en Cloud Run / Fly / VPS. Lo importante son los contratos, no el framework.

### Módulos
1. **auth_google**: flujo OAuth (code + PKCE, `access_type=offline`, `prompt=consent`). Refresh token **cifrado** en reposo (AES-GCM con clave en Secret Manager/KMS, nunca en la BD en claro). Renovación de `access_token` bajo demanda. Detecta `invalid_grant` ⇒ marca la conexión como `needs_reauth` y te avisa (por el límite de 7 días en modo Testing).
2. **sync**:
   - *Backfill*: ventanas de N días por `dataType`, paginando con `pageToken` hasta agotar.
   - *Incremental*: por `dataType` guarda `last_synced_end`; en cada ejecución pide `[last_synced_end − solape, ahora]` y hace upsert idempotente (clave natural = id del punto de Google o `(type, start, end, source)`). El solape (p. ej. 48 h) cubre datos que llegan tarde o se reconcilian.
   - *Disparo*: webhook → encola `sync(dataType, intervalo)`; además un cron de seguridad cada hora/día (los webhooks pueden perderse).
3. **webhook**: HTTPS público; verifica cabecera `GOOGLE-HEALTH-API-SIGNATURE` (ECDSA P-256) y el bearer secret; responde rápido (204) y procesa en cola. Notificación = "cambió X en este intervalo", no trae los valores.
4. **normalize**: tabla de mapeo `dataType` → esquema interno; unidades SI; marcas de tiempo en UTC + `tz_offset`.
   - **Filtro por fuente (obligatorio):** Google Health mezcla en las mismas listas los datos de la Air (`dataSource.platform = FITBIT`) y los de Apple Health (`HEALTH_KIT`). Se guarda siempre el `dataSource` en `raw_event` y `metric_point.source`, y las agregaciones solo usan la Air (`FITBIT`, `device.displayName = "Google Fitbit Air"`). Sin esto, pasos y distancia se duplican (hallazgo del 2026-10-09).
   - **Fusión con el Apple Watch (diseño, sin verificar):** Air base; dentro de una sesión de ejercicio del Watch manda Apple y se descarta lo de la Air en esa ventana; las sesiones de la Air solapadas se descartan; sueño y métricas diarias siempre de la Air. Detalle y salvedades en `FEASIBILITY.md` §3. Implementar tras ver un entreno real del Watch en la API.
5. **scores**: funciones puras sobre las series normalizadas (ver abajo), versionadas (`score_version`) para recalcular el histórico.
6. **api**: REST propia para iOS.

### Modelo de datos (Postgres)

```
google_connection(id, scopes[], refresh_token_enc, status, last_refresh_at, needs_reauth_at)
raw_event(id, data_type, source_id, start_ts, end_ts, payload jsonb, fetched_at)   -- inmutable, para reprocesar
sync_state(data_type PK, last_synced_end, page_token, last_error)
metric_point(ts, metric, value, unit, source)                    -- series (HR, SpO2…)  [Timescale opcional]
sleep_session(id, start, end, efficiency, stages jsonb)
exercise(id, start, end, type, calories, avg_hr, zones jsonb)
daily_summary(date PK, steps, distance_m, kcal, azm, rhr, hrv_rmssd, spo2, resp_rate, temp_delta_c, vo2max)
score_daily(date, score_version, sleep, recovery, activity, strain, inputs jsonb)
```
Guardar `raw_event` permite cambiar la normalización o los scores sin volver a llamar a Google.

### API propia (v1, autenticada con un token estático largo o Sign in with Apple limitado a tu ID)
```
GET /v1/today
GET /v1/daily?from=&to=
GET /v1/sleep?date=            GET /v1/sleep/sessions?from=&to=
GET /v1/heart-rate?from=&to=&resolution=
GET /v1/workouts?from=&to=     GET /v1/trends?metric=&window=
GET /v1/scores?from=&to=
GET /v1/health/sync            -- estado de sincronización, needs_reauth, última muestra
POST /v1/live/hr               -- fase 2: lotes de BPM/RR desde BLE
```

### Puntuaciones propias (primer borrador, a calibrar con tus datos)
- **Sueño** (0–100): duración vs. objetivo, eficiencia, % profundo+REM, latencia/despertares, consistencia de hora de dormir.
- **Recuperación** (0–100): z-score de HRV (RMSSD) y pulso en reposo frente a tu línea base móvil de 14–30 días, + frecuencia respiratoria y desviación de temperatura como penalización; requiere ≥ 14 días de historia.
- **Actividad** (0–100): pasos, minutos activos/AZM y sedentarismo vs. objetivos.
- **Strain** (carga): TRIMP/zonas de FC del día.
Todo con líneas base personales; sin comparar contra poblaciones.

## App iOS (SwiftUI, iOS 17+)

- MVVM + `async/await`; cliente HTTP tipado generado a mano o con OpenAPI.
- Pantallas: **Hoy** (3 anillos + scores), **Sueño** (hipnograma, fases, tendencias), **Corazón** (FC intradía, reposo, HRV), **Actividad** (pasos, AZM, entrenos), **Tendencias** (7/30/90 d con línea base), **Ajustes** (objetivos, estado de sincronización, reautorizar).
- Gráficos con Swift Charts. Caché local (SwiftData) para abrir sin red.
- Módulo opcional **LiveHR** (Core Bluetooth) aislado, activado solo si la Prueba 3 es positiva.
- Distribución: instalación directa con tu Apple ID (7 días de firma gratis) o cuenta de desarrollador (TestFlight) — decisión pendiente.

## Seguridad
- Secretos fuera del repo (`.env`, Secret Manager). `*.token.json` está en `.gitignore`.
- El backend solo expone tus datos a un token tuyo; HTTPS obligatorio; sin analytics de terceros.
- Cumplir la [política de datos de usuario de Google Health API](https://developers.google.com/health/policies/health-api-developer-user-data-policy) (uso limitado; no ceder datos a terceros).
