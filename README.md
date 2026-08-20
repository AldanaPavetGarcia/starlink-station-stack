# starlink-station-stack

Estación de medición para Starlink (LEO) con sensado ambiental integrado — telemetría de red vía gRPC, correlación con clima, y nodo Córdoba del testbed internacional.

Este repo **no contiene código de aplicación** — es solo la integración entre los dos
módulos individuales, cada uno evaluable por separado (modelo polyrepo, decidido
11/8/2026):

- **[`starlink-measurement-station`](https://github.com/AldanaPavetGarcia/starlink-measurement-station)** (Aldana) — telemetría de red Starlink: extractor gRPC, mock stateful, broker, consumer, backend, Grafana.
- **[`tesis-sensor-node`](https://github.com/BlastNeos/tesis-sensor-node)** (Fede) — sensado ambiental: firmware ESP32 + BME280, mock, broker propio.

## Qué hay acá

- `infra/mosquitto-vm/` — el broker MQTT compartido, pensado para correr en la VM
  provista por la cátedra (no en la RPi5 ni en ninguna PC local).
- `docs/CONNECTING.md` — cómo conectarse a la VM y apuntar tu productor/consumer al
  broker compartido.
- `docs/01_ADR.md` — decisiones de arquitectura propias de *este* repo (la
  integración en sí, no los módulos individuales).
- `docs/INTEGRATION_CHECKLIST.md` — estado de los puntos de coordinación entre los 2
  módulos.

## Documentación de cada módulo

Los documentos autoritativos completos (ADR, SRS, DER, API REST, Plan de QA) viven en
cada repo de origen, **no se copian acá** — para evitar que se desincronicen (ver
razonamiento en `docs/01_ADR.md` y en el propio `docs/PROGRESS.md` de
`starlink-measurement-station`, que ya documenta este tipo de drift como el riesgo
principal del proyecto):

- Starlink: [`docs/05_ADR.md`](https://github.com/AldanaPavetGarcia/starlink-measurement-station/blob/main/docs/05_ADR.md), [`docs/03_SRS.md`](https://github.com/AldanaPavetGarcia/starlink-measurement-station/blob/main/docs/03_SRS.md), [`docs/06_DER.md`](https://github.com/AldanaPavetGarcia/starlink-measurement-station/blob/main/docs/06_DER.md), [`docs/07_API_REST.md`](https://github.com/AldanaPavetGarcia/starlink-measurement-station/blob/main/docs/07_API_REST.md), [`docs/08_Plan_QA.md`](https://github.com/AldanaPavetGarcia/starlink-measurement-station/blob/main/docs/08_Plan_QA.md).
- Ambiental: `tesis-sensor-node` todavía no tiene ADR/SRS/DER propios — solo
  `README.md` (sección "Contrato pendiente").

## Quickstart

Ver `docs/CONNECTING.md` para el detalle completo. Resumen:

1. Conseguir la clave SSH de la VM (pedir a Aldana o Fede — nunca está en este repo).
2. Levantar el broker en la VM (`infra/mosquitto-vm/`, instrucciones en `docs/CONNECTING.md`).
3. En tu repo individual, apuntar `.env` (`MQTT_HOST`, `MQTT_PORT`, credenciales) al
   broker de la VM en vez de a tu broker local — sin tocar código.

## Estado

En construcción — arrancado 19/8/2026. Ver `docs/INTEGRATION_CHECKLIST.md` para el
detalle de qué falta de cada lado antes de que la integración esté funcionando
end-to-end.
