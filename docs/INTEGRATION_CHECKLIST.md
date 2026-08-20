# Checklist de integración

Puntos compartidos entre los 2 módulos.

Última actualización: 20/8/2026.

| # | Punto | Dueño | Estado | Desbloquea |
| --- | --- | --- | --- | --- |
| 1 | Broker compartido en vez de instancias aisladas (`tesis-mosquitto` de Fede vs. `broker` de Aldana) | Ambos | ✅ Desplegado y verificado 19-20/8 (`infra/mosquitto-vm/`, puerto `5883`) | Que los mensajes de los 2 módulos lleguen al mismo lugar |
| 2 | Auth del broker de la VM (`allow_anonymous false` + `password_file`) | Ambos | ✅ Cerrado 19-20/8 — verificado que rechaza conexiones sin credenciales | Paso 5 de `docs/CONNECTING.md` |
| 2b | Apuntar la RPi5 al broker de la VM (bridge de Mosquitto, no cliente directo — ver ADR-19/20 de `starlink-measurement-station`) | Aldana | ✅ **Resuelto 20/8** — no era problema de red del LIT bloqueando la VM, era de *routing*: la RPi5 tiene un enlace Starlink propio (`eth0`) con salida libre por el que ahora sale el bridge. Verificado recibiendo `starlink/metrics/#` y `starlink/status/#` reales en la VM. | Que la RPi5 empiece a recibir datos de Fede también |
| 2c | Apuntar el mock/firmware de Fede al broker de la VM | Fede | 🔴 Sin empezar — necesita las credenciales (pedirlas a Aldana, no están en ningún repo). Su cliente Python usa `MQTTv311` (`tesis-sensor-node/mocks/bme280/src/mqtt_publisher.py`); el broker de la VM exige credenciales pero no fuerza versión de protocolo, así que no debería bloquear, a confirmar cuando lo intente. | Primer mensaje real de Fede llegando a la VM |
| 3 | `MeteoDB` real (`starlink-measurement-station/src/consumer/db.py`) — hoy es un stub, no persiste | Aldana | 🔴 Sin empezar | Que las métricas de Fede lleguen a persistir en una DB de verdad |
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

## Semántica `source`/`producer` de `env_metrics` — parcialmente cerrada (19/8)

- **Confirmado**: `source` = identidad puntual (real/mock:
  `mock_bme280`/`esp32_bme280`/`mock_api`/`api_open_meteo`/`api_owm`/`api_smn`),
  `producer` = categoría (`antenna`/`sensor`/`api`). El código de Fede hoy los tiene
  invertidos — ver `tesis-sensor-node/docs/Notes for integration.md` (nombre real del
  archivo, corregido 20/8 — el checklist lo tenía traducido y roto; sigue sin commitear).
- **Pendiente**: dónde va `producer` (¿adentro de `metrics`, como ya lo tiene Fede, o
  afuera, a nivel de envelope, como `source_module` en `EnvPayloadIn` de
  `docs/07_API_REST.md` §9.2?) y qué hacer con `source_module` (¿se renombra a
  `producer` o se descarta como diseño viejo?). No se tocó `docs/06_DER.md` ni
  `docs/07_API_REST.md` de `starlink-measurement-station` todavía — ver el detalle
  completo en su `docs/PROGRESS.md`, sección "Semántica source/producer... (19/8)".
