# Prueba de punta a punta en la RPi5 (unión Starlink + meteo)

Runbook para levantar la pila meteo de Fede junto a la pila Starlink de Aldana en la RPi5
del LIT y verificar el recorrido completo:

```
ESP32 (o mock) ──MQTT──▶ broker (RPi5) ──▶ meteo_consumer ──▶ meteo_data ─┐
antena Starlink ──gRPC──▶ acquisition ──▶ broker ──▶ consumer ──▶ starlink_health_db ─┤
                                                                          └─▶ Grafana "Correlación Red-Clima"
```

Decisión de diseño: ADR-02 de este repo y ADR-21 de `starlink-measurement-station`.

## Qué se validó antes (PC, 26/10/2026)

Las dos pilas levantadas en una PC con `mock_starlink` y los mocks de Fede:

| Verificación | Resultado |
| --- | --- |
| `meteo_consumer` se conecta al broker de Aldana y se suscribe a `meteo/sensor/+` y `meteo/external/+` | ✅ |
| Payload con el formato exacto del firmware del ESP32 (`source=real`, `producer=bme280`) | ✅ Guardado en `env_metrics` |
| Mock BME280 (`source=mock`) y dato real en el mismo nodo | ✅ Conviven, sin choque de PK |
| Payload con `pressure_hpa=667.95` (lo que leía el sketch de prueba del 16/10) | ⚠️ **Rechazado** por la validación (rango 800-1100). Es correcto, pero confirma que hay que revisar el sensor |
| El consumer de Aldana no procesa nada de `meteo/*` | ✅ Cero menciones en sus logs |
| `GET /api/v1/health` → `db_meteo_data` | ✅ `up`, con `last_write` |
| Datasources `starlink_health_db` y `meteo_data` en Grafana | ✅ "Database Connection OK" |
| Las 10 consultas del dashboard "Correlación Red-Clima" | ✅ Devuelven datos |

## 0. Antes de ir al LIT

Ramas a usar:

| Repo | Rama |
| --- | --- |
| `starlink-measurement-station` | `main` (ADR-21 mergeado el 26/10) |
| `starlink-station-stack` | `main` |
| `tesis-sensor-node` | `feature/meteo-consumer` (o `development` si Fede ya la mergeó) |

## 1. Conectarse y ubicar la pila actual

```bash
ssh leonode-rpi          # desde el LIT (o ssh rpi5-remoto desde afuera)

# Carpeta desde donde corre hoy la pila Starlink:
docker inspect starlink-consumer \
  --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}'
docker ps --format '{{.Names}}\t{{.Status}}'     # deberían ser los 7 contenedores
```

En los comandos que siguen, `$STARLINK` es esa carpeta, y los otros dos repos se clonan al
lado de ella.

## 2. Actualizar la pila Starlink (repo de Aldana)

```bash
cd $STARLINK
git status                           # que no haya cambios locales sin commitear
git checkout main && git pull
```

Agregar al `.env` (copiar los valores de `.env.example` si falta alguno):

```bash
METEO_DB_HOST=meteo_db
METEO_DB_PORT=5432
METEO_DB_NAME=meteo_data
METEO_DB_USER=meteo_app
METEO_DB_PASSWORD=meteo_dev_password
STARLINK_NETWORK_NAME=starlink-station-net
```

Levantar **los mismos 7 servicios de siempre**. Nombrar los servicios explícitamente activa
sus perfiles, así `mock_starlink` no arranca junto a `acquisition`:

```bash
docker compose up -d --build broker acquisition starlink_db station_config_db consumer backend grafana
```

Como la red ahora tiene nombre fijo, este `up` **recrea los contenedores** sobre
`starlink-station-net`. Los volúmenes (datos de las bases, Grafana y Mosquitto) se
conservan. El ESP32 y el bridge a la VM se reconectan solos tras el corte de unos segundos.

```bash
docker network inspect starlink-station-net --format '{{range .Containers}}{{.Name}} {{end}}'
```

## 3. Levantar la pila meteo (repo de Fede + este repo)

```bash
cd $STARLINK/..
git clone https://github.com/BlastNeos/tesis-sensor-node.git        # si no está
git -C tesis-sensor-node fetch && git -C tesis-sensor-node checkout feature/meteo-consumer
git clone https://github.com/AldanaPavetGarcia/starlink-station-stack.git   # si no está
git -C starlink-station-stack checkout main && git -C starlink-station-stack pull

cd starlink-station-stack/infra/rpi5-union
cp .env.example .env      # TESIS_SENSOR_NODE_DIR=../../../tesis-sensor-node ya apunta al clon de al lado
```

Elegir según el estado del BME280:

```bash
# A) Con el ESP32 real midiendo:
docker compose up -d --build

# B) Si el BME280 sigue sin detectarse: sumar los mocks de Fede (source=mock)
docker compose --profile meteo-mocks up -d --build
```

La primera vez construye las imágenes en la RPi5 (unos minutos).

## 4. Verificar

```bash
# 4.1 Llegan mensajes meteo al broker
docker exec mosquitto-broker mosquitto_sub -h localhost -t 'meteo/#' -v -C 3

# 4.2 El consumer de Fede los procesa (sin "Payload meteorológico inválido")
docker logs --tail 20 meteo-consumer

# 4.3 Filas en meteo_data, por productor
docker exec meteo-db psql -U meteo_app -d meteo_data -c \
  "SELECT source, producer, COUNT(*), MAX(time) FROM env_metrics GROUP BY 1,2 ORDER BY 1,2"

# 4.4 La telemetría Starlink real sigue entrando
docker exec starlink-health-db psql -U starlink_app -d starlink_health -c \
  "SELECT COUNT(*), MAX(time) FROM network_metrics WHERE time > now() - interval '10 minutes'"

# 4.5 El backend ve las dos bases
curl -s localhost:8000/api/v1/health | python3 -m json.tool
```

**4.6 Grafana** (`http://<IP de la RPi5>:3000`): dashboard **Correlación Red-Clima**. Las
series ambientales aparecen como `bme280 (real)`, `bme280 (mock)` u `open_meteo (mock)`.
**Sacar captura**: es la evidencia del ítem 9 del Plan de QA (CA-04).

### Criterio de éxito

- [ ] 4.3 muestra filas con `source=real, producer=bme280` (ESP32) o, en el plan B, `source=mock`.
- [ ] 4.4 muestra telemetría de los últimos 10 minutos.
- [ ] 4.5: `db_starlink_health`, `mqtt_broker` y `db_meteo_data` en `up`.
- [ ] El dashboard muestra la serie de red y la ambiental en el mismo panel.

## Problemas posibles

| Síntoma | Causa probable | Qué hacer |
| --- | --- | --- |
| `network starlink-station-net declared as external, but could not be found` | La pila de Aldana no se recreó con la red nueva | Repetir el paso 2 |
| `meteo-consumer` en loop de reinicio | No resuelve `broker` o `meteo_db` | `docker network inspect starlink-station-net`: tienen que estar `mosquitto-broker` y `meteo-db` |
| "Payload meteorológico inválido … pressure_hpa" | El sensor lee fuera de rango (ver 16/10) | Revisar el BME280; mientras tanto, plan B |
| `db_meteo_data: not_configured` en `/health` | Falta `METEO_DB_HOST` en el `.env` de Aldana | Agregarlo y repetir el `up` del paso 2 (solo `backend grafana`) |
| Panel ambiental vacío y 4.3 con datos | Rango de tiempo o variable `Nodo` | Rango "Last 1 hour", Nodo = `lit-cordoba-01` |
| El ESP32 no publica | Ver `docs/ESP32_WIFI_MQTT.md` | IP de la RPi5 en `Secrets.h`, monitor serie |

## Volver atrás

```bash
cd $STARLINK/../starlink-station-stack/infra/rpi5-union
docker compose --profile meteo-mocks down          # sin -v: conserva meteo_data

```

La pila Starlink puede quedar como está: sin la pila meteo, `/health` reporta
`db_meteo_data: down` y los paneles de correlación quedan vacíos. Para volver al
estado anterior a ADR-21 (red por defecto, mismos volúmenes):

```bash
cd $STARLINK
git checkout 80ca0d4
docker compose up -d --build broker acquisition starlink_db station_config_db consumer backend grafana
```
