# Checklist de integración

Puntos compartidos entre los 2 módulos.

Última actualización: 26/10/2026.

| # | Punto | Dueño | Estado | Desbloquea |
| --- | --- | --- | --- | --- |
| 1 | Broker compartido en vez de instancias aisladas (`tesis-mosquitto` de Fede vs. `broker` de Aldana) | Ambos | ✅ Desplegado y verificado 19-20/8 (`infra/mosquitto-vm/`, puerto `5883`) | Que los mensajes de los 2 módulos lleguen al mismo lugar |
| 2 | Auth del broker de la VM (`allow_anonymous false` + `password_file`) | Ambos | ✅ Cerrado 19-20/8 — verificado que rechaza conexiones sin credenciales | Paso 5 de `docs/CONNECTING.md` |
| 2b | Apuntar la RPi5 al broker de la VM (bridge de Mosquitto, no cliente directo — ver ADR-19/20 de `starlink-measurement-station`) | Aldana | ✅ **Resuelto 20/8** — no era problema de red del LIT bloqueando la VM, era de *routing*: la RPi5 tiene un enlace Starlink propio (`eth0`) con salida libre por el que ahora sale el bridge. Verificado recibiendo `starlink/metrics/#` y `starlink/status/#` reales en la VM. | Que la RPi5 empiece a recibir datos de Fede también |
| 2c | Apuntar el mock/firmware de Fede al broker de la VM | Fede | 🔴 Sin empezar — necesita las credenciales (pedirlas a Aldana, no están en ningún repo). Su cliente Python usa `MQTTv311` (`tesis-sensor-node/mocks/bme280/src/mqtt_publisher.py`); el broker de la VM exige credenciales pero no fuerza versión de protocolo, así que no debería bloquear, a confirmar cuando lo intente. | Primer mensaje real de Fede llegando a la VM |
| 3 | ~~`MeteoDB` real en el consumer de Aldana~~ → **reemplazado por ADR-02**: `meteo_data` + `meteo_consumer` propios en el repo de Fede | Fede | 🟡 Implementado en `feature/meteo-persistence` y `feature/meteo-consumer` (24-25/10), **sin mergear a `development`**. El stub `MeteoDB` se eliminó del lado de Aldana. | Que las métricas ambientales persistan |
| 8 | Compose de integración en la RPi5 (`infra/rpi5-union/`) | Aldana | 🟡 Preparado y **validado de punta a punta en una PC** (26/10). Falta correrlo en la RPi5 con el ESP32 — ver `docs/E2E_RPI5.md`. | CA-01 del lado ambiental, CA-04 |
| 9 | Fede publica sus imágenes en GHCR (workflow de CI) | Fede | 🔴 Sin empezar — hoy el compose de integración construye desde un clon de su repo | Desplegar sin clonar su repo; versiones fijas |
| 10 | ESP32: el BME280 no se detecta en la placa probada (16/10) | Fede | 🔴 Abierto — WiFi/MQTT ya funcionan (`docs/ESP32_WIFI_MQTT.md`). Además, una presión fuera de 800-1100 hPa se rechaza en `meteo_data` (validado 26/10). | Mediciones reales del sensor |
| 11 | Quién implementa `GET /metrics/env*`, `POST /ingest/env` y `last_env_metric` de `/nodes` | Ambos | 🔴 Abierto (ADR-21) — backend de Aldana leyendo `meteo_data`, o servicio de Fede | Contrato REST ambiental |
| 7 | Pila pública en la VM (TimescaleDB + consumer + Grafana con acceso anónimo Viewer, QR pedido por el director) | Aldana | 🟡 Preparado, no ejecutado (`infra/vm-stack/`) — bloqueado por RAM de la VM (964MB total, ~500MB libres con el broker corriendo; sumar esto son ~450-650MB más, riesgo de OOM). Mensaje redactado para pedirle a Santiago más RAM, sin mandar todavía. | El QR público que pidió el director |
| 4 | Fede pushea/abre PR de los cambios locales post-prueba del 14/8 | Fede | 🟡 Pusheado en `feature/bme280-driver`, sin PR a `development` | Que el estado de su repo en GitHub sea el real |
| 5 | Confirmar con el profesor persistencia/recursos de la VM si se decide correr algo más ahí en el futuro | Ambos | ✅ Confirmado 19/8 (persistente, cuenta compartida a propósito) | — |
| 6 | Estación meteorológica externa a usar (`api_smn`/`api_open_meteo`/`api_owm`) | Fede | 🟡 3 candidatas investigadas, sin decisión final | Que Fede empiece el cliente de la API externa |

🔴 Sin empezar/bloqueado · 🟡 En progreso · ✅ Cerrado

## Bugs reales encontrados al desplegar el broker (corregidos)

Documentados con detalle en `docs/PROGRESS.md` de `starlink-measurement-station` —
resumen: el healthcheck no se autenticaba (loop infinito) y el `passwordfile` no era
legible por el UID del proceso Mosquitto dentro del contenedor (se resolvió con
permisos `644`, world-readable — funcional pero no ideal; candidato a mejorar
sacando el `:ro` de los mounts para que el propio entrypoint del contenedor pueda
hacer `chown` al UID correcto).

## Semántica `source`/`producer` de `env_metrics` — cerrada (26/10)

Decidido por Aldana y Fede (ADR-02 de este repo, ADR-21 de `starlink-measurement-station`):

- `source` ∈ {`real`, `mock`}: naturaleza del dato.
- `producer`: productor concreto (`bme280`, `open_meteo`, `ohmc`, …), a nivel de envelope.
- PK `(time, node_id, source, producer)`.

Reemplaza la propuesta del 19/8 (que invertía los campos). `source_module` queda descartado.
Esquema autoritativo: `tesis-sensor-node/infrastructure/meteo-db/init_meteo_data.sql`; los
documentos de `starlink-measurement-station` (DER, SRS, API, QA) ya lo reflejan.
