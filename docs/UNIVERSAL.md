# HealthSpike universal: Google Health + Apple Salud

Estudio de 2026-10-23. Decide cómo abrir la app a más dispositivos y más público. No hay código hecho: es un plan para decidir.

## Respuesta corta

**Sí, el híbrido es la mejor forma.** Cada fuente se lee por su camino más directo y la app los junta:

| Dispositivo | Camino | Por qué |
|---|---|---|
| Fitbit Air y otros de Google/Fitbit | Google Health API (como ahora) | Es el dato original y completo, con el detalle que Apple Salud no guarda. |
| Apple Watch, iPhone | HealthKit | Lectura nativa, sin cuenta ni servidor. |
| Oura, WHOOP, Garmin, Withings, Polar… | HealthKit | Todos escriben en Apple Salud desde su app; se leen sin su API ni su aprobación. |

La app pide permiso a Apple Salud solo cuando el usuario añade esa fuente. Sigue sin haber servidor.

## Hechos comprobados y no comprobados

Comprobado por nosotros (2026-10-23, solo pasos):
- Google devuelve Apple Salud como fuente `HEALTH_KIT` (`formFactor` PHONE, `manufacturer` Apple Inc., `packageName` com.apple.health, sin `displayName`). **No distingue Apple Watch de iPhone.** Por tanto, para Apple hay que ir a HealthKit: `HKSource`/`HKDevice` sí lo distinguen.

Visto en fuentes públicas (sensai.fit, Sonar, Sahha, 9to5Mac, documentación de Apple), sin probar con dispositivos propios:
- Oura, WHOOP y Garmin escriben en Apple Salud desde su app. Las puntuaciones propias (readiness, recovery, strain, Body Battery) **no** se escriben; sí lo hacen las métricas base.
- La app de Google Health para iOS (v5.05, ~2026-08) ya **escribe** datos de Fitbit en Apple Salud, además de leerlos.
- La guía 5.1.3 de App Review permite leer HealthKit para mostrar datos de salud, con condiciones: sin publicidad, sin vender datos, sin guardar en iCloud datos de HealthKit.

Samsung, Withings, Polar, Amazfit, Coros y la lista concreta de Oura/WHOOP/Garmin: ver «Qué escribe cada fabricante». Nada de eso está probado con dispositivos propios.

## Qué escribe cada fabricante en Apple Salud

Investigado el 2026-10-23 solo con fuentes públicas. «Oficial» = página de soporte del fabricante; «foro» = comunidad de usuarios o terceros, puede estar desfasado.

| Fabricante | Escribe en Apple Salud | No escribe / límites | Fuente |
|---|---|---|---|
| Oura | Sueño (duración, inicio, fin y fases), pulso cada minuto, pasos, energía activa, respiración nocturna media, altura, peso, minutos de atención plena, rutas de entreno, entrenos añadidos a mano. Requiere Gen2, o Gen3 y posteriores con membresía activa | Readiness y demás puntuaciones. HRV y temperatura **no aparecen** en la lista oficial | Oficial: [Oura](https://support.ouraring.com/hc/en-us/articles/360025438734) |
| Polar | Energía activa, energía en reposo, sueño (duración y horas), pasos, peso, entrenos (tipo, duración, distancia, inicio/fin, energía y pulso medio), pulso **solo durante entrenos** | El pulso continuo no se sincroniza. Hay que poner Polar Flow el primero en «Fuentes de datos» de Salud o Apple puede no usar sus datos | Oficial: [Polar](https://support.polar.com/en/support/connecting_polar_flow_with_apple_health) |
| Coros | Pulso, sueño, pasos, distancia andando/corriendo, ciclismo y natación | Sin comprobar fases de sueño ni HRV: lo que dicen blogs es de baja calidad | Oficial (leído en el resultado de búsqueda; la página dio 403): [Coros](https://support.coros.com/hc/en-us/articles/360041549551-Connecting-Apple-Health-with-COROS-App) |
| WHOOP | Energía activa, SpO₂, pulso, respiración, pulso en reposo, sueño, entrenos | Pulso solo en actividades, no todo el día. Sueño sin fases según usuarios y algunos dicen que se corta tras actualizaciones. **Sin HRV.** Recovery/Strain no se escriben | Foro: [WHOOP community](https://www.community.whoop.com/t/apple-health-missing-sleep-stage-data-from-whoop/8192), [DC Rainmaker](https://dcrainmaker.com/2022/04/exporting-health-actually.html) |
| Garmin | Sueño, pulso de todo el día, pasos, pisos, distancia, energía activa y en reposo, métricas corporales, agua, entrenos | En actividades cronometradas solo pulso máximo/mínimo; entrenos sin ruta GPS. Algunos usuarios reportan que los pasos dejan de llegar tras actualizaciones. No lee de Apple Salud | Foro citando a Garmin: [Apple Discussions](https://discussions-cn-prz.apple.com/thread/251525307). La página oficial dio 403 |
| Amazfit / Zepp | Pasos, sueño y peso (ejemplos de Xiaomi); la ficha de Zepp dice que también lee pulso y SpO₂ | Lista incompleta y el camino de configuración cambia según modelo | Oficial parcial: [Xiaomi](https://www.mi.com/global/support/article/KA-12890/) |
| Withings | No confirmado. La ayuda oficial empieza por glucosa, SpO₂ y tensión; la ficha de la app menciona pasos, pulso, sueño y peso | Falta la lista completa y qué hace ScanWatch | Página de soporte con 403: [Withings](https://support.withings.com/hc/en-us/articles/203934573) |
| Samsung | Casi nada útil en iPhone: usuarios reportan solo pasos y distancia andando | Los Galaxy Watch con Wear OS no se soportan en iPhone; Samsung Health en iOS lista relojes antiguos (Gear, Fit2, Watch Active2) | Foro y ficha de App Store; sin fuente oficial actual |

Sin verificar todavía: lista completa de Withings, modelos actuales de Samsung, tipos exactos de Amazfit, si Oura escribe HRV/temperatura en versiones nuevas y la lista vigente de Garmin. Se cierra probando con un dispositivo real o con el spike de la fase 0.

Conclusiones para el producto:
- **La disponibilidad cambia por fuente y por métrica.** El selector no puede asumir que toda fuente da todo: debe ocultar o desactivar las métricas que esa fuente no escribe y decirlo («Oura no envía VFC a Apple Salud»).
- **Sueño con fases**: Oura sí; WHOOP y Polar parece que no, Coros sin confirmar. La puntuación de sueño estimada tendrá que funcionar solo con horas dormidas cuando no haya fases.
- **VFC**: WHOOP no la escribe y Oura no la lista. Con Apple Watch y Fitbit sí. No prometer VFC universal.
- **Polar, Coros y Garmin** son sobre todo de entrenos y actividad; encajan en la pestaña Actividad antes que en Sueño o Corazón.
- **Samsung** queda fuera del alcance en iPhone.
- **Prioridad de fuentes**: Polar exige estar primero en Salud; es probable que otros fabricantes tengan el mismo problema. La app debe explicarlo si ve datos sin llegar.

## Arquitectura propuesta

Hoy el modelo asume la Air (`isAir`, `airOnly`). Pasaría a ser:

- `HealthSource` (protocolo): `fetch(metric, range) -> [Sample]`, `availableMetrics`, `authorization`.
- Adaptadores: `GoogleHealthSource` (el código actual) y `HealthKitSource` (nuevo).
- `SourceID { provider, origin }`: `provider` = google | healthkit; `origin` = nombre legible del dispositivo (Fitbit Air, Apple Watch de David, Oura…). En HealthKit sale de `HKSource.name` + `HKDevice.name`; en Google, de `dataSource`.
- Selector por métrica, como el de Google: chips «Todas las fuentes / Fitbit Air / Apple Watch / Oura». La elección se guarda por métrica.
- Textos neutros: «Tu Fitbit Air» → nombre real de la fuente elegida.
- Se elimina `isAir`/`airOnly`.

El código de pantallas, widgets y Coach no debería tocar el origen: solo recibe muestras normalizadas.

## Duplicados (el riesgo principal)

Si Google Health escribe en Apple Salud y HealthSpike lee de las dos, el mismo paso sale dos veces.

1. **De Google**: pedir solo datos con origen `FITBIT` (o dispositivos de Google), nunca `HEALTH_KIT`.
2. **De HealthKit**: excluir las fuentes cuya app sea Google Health/Fitbit. El bundle id exacto hay que sacarlo con el spike (fase 0); no lo damos por sabido.
3. **Por métrica**: en «Todas las fuentes», usar `HKStatisticsCollectionQuery` (suma con deduplicación de HealthKit) para acumulados, y para pulso/sueño elegir una fuente por intervalo (la de mayor prioridad con datos).
4. **Sin bucles**: HealthSpike no escribe nunca en Apple Salud. Se mantiene solo lectura.

## Métricas (orientativo; verificar con cada dispositivo)

| Métrica | Google (Fitbit) | HealthKit |
|---|---|---|
| Pasos, calorías activas, distancia | Sí | Sí, de cualquier fuente |
| Pulso y reposo | Sí, muy denso | Sí; la densidad depende de la fuente |
| VFC (HRV) | Sí | Sí (SDNN; Oura/WHOOP pueden usar RMSSD, no son comparables) |
| Sueño por fases | Sí | Sí si la fuente escribe fases; el nivel de detalle varía |
| SpO₂, respiración, temperatura | Sí | Sí, según dispositivo |
| Entrenos | Sí | Sí (`HKWorkout`) |
| Puntuaciones propias (readiness, recovery…) | No aplica | **No disponibles** |

Consecuencia de producto: la «puntuación de sueño» de HealthSpike es propia (estimada) y puede calcularse con cualquier fuente que dé fases; las puntuaciones de Oura o WHOOP no se podrán mostrar.

## Permisos

- HealthKit **oculta** si el usuario denegó una lectura: la consulta devuelve vacío, igual que sin datos. La UI debe decir «Sin datos o sin permiso: revisa Ajustes → Salud → Acceso a datos» en vez de dar por roto el dispositivo.
- Pedir solo los tipos de la métrica que se activa, no todos de golpe.
- Añadir `NSHealthShareUsageDescription` y el entitlement `com.apple.developer.healthkit` (la app aún no los tiene).

## Segundo plano y widgets

- `HKObserverQuery` + `enableBackgroundDelivery` despierta la app con datos nuevos; se guarda una caché en el App Group para los widgets.
- Con el iPhone bloqueado, HealthKit no entrega datos (están cifrados): el widget enseña la última caché, no un dato nuevo.
- Hoy el refresco usa `BGAppRefresh` de Google; ambos conviven.

## Privacidad, App Store y web

- Ficha y etiquetas de privacidad: añadir «Salud y forma física» leídos, sin vincular a la identidad ni rastreo. Seguir `Guias/Ficha-App-Store.md`.
- La IA del Coach recibe datos de HealthKit: sigue siendo local (Foundation Models/Gemma), lo que encaja con 5.1.3. Mantener que ningún dato de HealthKit sale del móvil.
- `PrivacyInfo.xcprivacy`: HealthKit no es una API de razón obligatoria, no cambia el manifiesto, pero la política debe citarlo.
- Política y web: ahora dicen «solo lectura de Google Health» y «Necesitas una Fitbit Air». Habría que reescribir hero, camino de datos (Fitbit Air → Google Health → iPhone) y avisos. Bonus: sin la Air como requisito, la app deja de ser nicho.
- **Google (CASA)**: seguiría siendo necesario solo si se usa la API de Google. Un usuario que solo use Apple Salud no necesita pasar por Google. Es la gran ventaja del híbrido: la app es útil el día 1 aunque la verificación siga pendiente.

## Competencia

Vora, Onedash, fitMetrics, Context y Open Wearables ya agregan varios wearables. Casi todos van con servidor o suscripción. Diferenciales de HealthSpike: sin servidor, IA 100 % local, lectura directa de la API de Google (detalle que Apple Salud pierde) y estética propia por pestañas.

## Público

No hay cifras fiables que citar. Razonamiento cualitativo: solo Air = muy poca gente; cualquier iPhone con Apple Watch, Oura o WHOOP = mucho más grande y ya en Apple Salud. No se han inventado números de mercado.

## Plan por fases

0. **Spike de fuentes (½ día)**: pantalla de depuración que liste `HKSource`/`HKDevice` por tipo de dato en tu iPhone (Apple Watch + lo que escribe Google Health). Resultado: bundle id de Google/Fitbit en Apple Salud y qué métricas llegan duplicadas.
1. **Modelo de fuentes**: `HealthSource`, `SourceID`, quitar `isAir`; sin cambios visibles.
2. **Conector HealthKit**: pasos, calorías, pulso, reposo, sueño y entrenos; permisos por métrica.
3. **Selector por métrica** y regla anti-duplicados en «Todas».
4. **Permisos, privacidad, ficha y web**: reescribir textos; política; etiquetas de App Store.
5. **Más métricas** (VFC, SpO₂, respiración, temperatura) y entrenos detallados.

## Riesgos

- Duplicados si falla el filtro de fuentes (mitigado por fase 0 y por pruebas con tus dos relojes).
- Datos de Oura/WHOOP incompletos en Apple Salud: depende de lo que escriba cada app, no de nosotros.
- Sin dispositivos Oura/WHOOP/Garmin a mano, solo se puede probar con datos de terceros o con voluntarios.
- Reescribir web, política y ficha antes de publicar; no mezclar con el envío 1.0 si se quiere salir pronto.

## Decisiones tomadas (2026-10-23)

1. **Universal ya, no en 1.1**: se publica la 1.0 con Google + Apple Salud. Fase 0 (spike de fuentes) se hace ahora.
2. **Selector global en Ajustes: «Google Health» | «Apple Salud»**. Ventajas: evita duplicados (las dos fuentes nunca se mezclan), cubre al usuario de un solo wearable, reutiliza el panel «Datos de la API» que ya existe en Ajustes. Dentro de Apple Salud, un subselector de dispositivo (Todos / Apple Watch / Oura / WHOOP…). Override por métrica se deja para 1.1.
3. **Puntuaciones propias**: no se prometen. Se admite que Readiness/Recovery/Strain/Body Battery no llegan a Apple Salud; la app calcula su propia puntuación de sueño donde haya fases.
4. **Web, política y ficha**: reescritas para ser universales (ver `Portfolio/src/app/healthspike/`, sin commitear ni desplegar hasta que la app lea Apple Salud).
