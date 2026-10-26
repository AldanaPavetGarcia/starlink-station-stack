# starlink-station-stack

Estación de medición para Starlink (LEO) con sensado ambiental integrado — telemetría de red vía gRPC, correlación con clima, y nodo Córdoba del testbed internacional.

Este repo **no contiene código de aplicación** — es solo la integración entre los dos
módulos individuales, cada uno evaluable por separado (modelo polyrepo, decidido
11/8/2026):

- **[`starlink-measurement-station`](https://github.com/AldanaPavetGarcia/starlink-measurement-station)** (Aldana) — telemetría de red Starlink: extractor gRPC, mock stateful, broker, consumer, backend, Grafana.
- **[`tesis-sensor-node`](https://github.com/BlastNeos/tesis-sensor-node)** (Fede) — sensado ambiental: firmware ESP32 + BME280, mocks, DB `meteo_data` y `meteo_consumer`.

## Qué hay acá

- `infra/mosquitto-vm/` — el broker MQTT compartido, pensado para correr en la VM
  provista por la cátedra (no en la RPi5 ni en ninguna PC local).
- `docs/CONNECTING.md` — cómo conectarse a la VM y apuntar tu productor/consumer al
  broker compartido.
- `docs/01_ADR.md` — decisiones de arquitectura propias de *este* repo (la
  integración en sí, no los módulos individuales).
- `docs/INTEGRATION_CHECKLIST.md` — estado de los puntos de coordinación entre los 2
  módulos.
- `infra/rpi5-union/` — compose de integración en la RPi5: suma la pila meteo de Fede
  (`meteo_data`, `meteo_consumer`, mocks) a la red de la pila Starlink de Aldana (ADR-02).
- `docs/E2E_RPI5.md` — runbook de la prueba de punta a punta en la RPi5.
- `docs/ESP32_WIFI_MQTT.md` — cómo se conectó el ESP32 al broker de la RPi5 (WiFi/MQTT),
  con los errores encontrados y los comandos usados.

## Documentación de cada módulo

Los documentos autoritativos completos (ADR, SRS, DER, API REST, Plan de QA) viven en
cada repo de origen, **no se copian acá** — para evitar que se desincronicen (ver
razonamiento en `docs/01_ADR.md` y en el propio `docs/PROGRESS.md` de
`starlink-measurement-station`, que ya documenta este tipo de drift como el riesgo
principal del proyecto):

- Starlink: [`docs/05_ADR.md`](https://github.com/AldanaPavetGarcia/starlink-measurement-station/blob/main/docs/05_ADR.md), [`docs/03_SRS.md`](https://github.com/AldanaPavetGarcia/starlink-measurement-station/blob/main/docs/03_SRS.md), [`docs/06_DER.md`](https://github.com/AldanaPavetGarcia/starlink-measurement-station/blob/main/docs/06_DER.md), [`docs/07_API_REST.md`](https://github.com/AldanaPavetGarcia/starlink-measurement-station/blob/main/docs/07_API_REST.md), [`docs/08_Plan_QA.md`](https://github.com/AldanaPavetGarcia/starlink-measurement-station/blob/main/docs/08_Plan_QA.md).
- Ambiental: `tesis-sensor-node` todavía no tiene ADR/SRS/DER propios. El contrato de
  `env_metrics` (`source` ∈ {`real`, `mock`}, `producer`, PK `(time, node_id, source, producer)`)
  está cerrado desde el 26/10/2026: SQL autoritativo en
  `tesis-sensor-node/infrastructure/meteo-db/init_meteo_data.sql`, decisión en ADR-02 de
  este repo y ADR-21 de `starlink-measurement-station`.

## Quickstart: levantar todo en la RPi5 (o en una PC)

Los tres repos clonados lado a lado. Un solo broker: el de la pila Starlink, al que
publica también el ESP32. El detalle (verificación, problemas posibles y vuelta atrás)
está en `docs/E2E_RPI5.md`.

```bash
git clone https://github.com/AldanaPavetGarcia/starlink-measurement-station.git
git clone https://github.com/BlastNeos/tesis-sensor-node.git
git clone https://github.com/AldanaPavetGarcia/starlink-station-stack.git
```

**1. Pila Starlink** (crea la red Docker `starlink-station-net`):

```bash
cd starlink-measurement-station
cp .env.example .env        # completar METEO_DB_* (ver comentarios en el archivo)

# RPi5, con la antena real:
docker compose up -d --build broker acquisition starlink_db station_config_db consumer backend grafana
# PC, sin hardware:
docker compose --profile mocks up -d --build
```

**2. Pila meteo de Fede** (se une a esa red):

```bash
cd ../starlink-station-stack/infra/rpi5-union
cp .env.example .env        # TESIS_SENSOR_NODE_DIR ya apunta a ../../../tesis-sensor-node

docker compose up -d --build                         # con el ESP32 real
docker compose --profile meteo-mocks up -d --build   # o con los mocks de Fede
```

**3. Verificar:** `curl -s localhost:8000/api/v1/health` (las tres conexiones en `up`) y
el dashboard **Correlación Red-Clima** en Grafana (`http://<host>:3000`).

Mientras las ramas de Fede no estén en `development`, hacer
`git -C tesis-sensor-node checkout feature/meteo-consumer` antes del paso 2.

## Broker en la VM (copia pública)

Ver `docs/CONNECTING.md` para el detalle completo. Resumen:

1. Conseguir la clave SSH de la VM (pedir a Aldana o Fede — nunca está en este repo).
2. Levantar el broker en la VM (`infra/mosquitto-vm/`, instrucciones en `docs/CONNECTING.md`).
3. En tu repo individual, apuntar `.env` (`MQTT_HOST`, `MQTT_PORT`, credenciales) al
   broker de la VM en vez de a tu broker local — sin tocar código.

## Estado

En construcción — arrancado 19/8/2026. Ver `docs/INTEGRATION_CHECKLIST.md` para el
detalle de qué falta de cada lado antes de que la integración esté funcionando
end-to-end.
