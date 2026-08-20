# Cómo conectarse

> Este repo es **público**. Ninguna clave privada ni password real va en ningún
> archivo de acá, ni en un commit, ni en un ejemplo con el valor real — solo
> placeholders. Las credenciales reales se piden a Aldana o Fede por otro canal.

## 1. Topología

La VM (`35.224.141.221`, IP pública, provista por la cátedra) aloja únicamente el
broker MQTT compartido. La RPi5 de Aldana sigue alojando las bases de datos, el
consumer, el backend y Grafana — ver `docs/01_ADR.md` para el porqué (la VM tiene
~1GB de RAM, no entra la pila completa).

```
mock_bme280 / firmware ESP32 (Fede)  ─┐
                                       ├─▶ Mosquitto en la VM (35.224.141.221:5883)
mock_starlink / acquisition (Aldana) ─┘         │
                                                 ▼
                                    consumer (en la RPi5, LIT)
                                                 │
                                                 ▼
                          starlink_db / meteo_db / station_config_db (RPi5)
                                                 │
                                                 ▼
                                    backend + grafana (RPi5)
```

## 2. Acceso SSH a la VM

Usuario: `federico.isaia.soria` (creado por la cátedra, pensado para que lo usen los
2). Clave privada compartida por fuera de este repo — pedirla a Aldana o Fede si no
la tenés.

```bash
ssh -i <tu-copia-local-de-la-clave> federico.isaia.soria@35.224.141.221
```

## 3. Puertos

| Servicio | Puerto interno | Puerto externo en la VM |
| --- | --- | --- |
| Mosquitto (broker) | 1883 | `5883` |

La VM solo tiene habilitados `5000-6000/tcp`, `8080` y `443` — por eso el broker no
usa el default `1883` hacia afuera. `8080`/`443` quedan libres para el día que se
agregue algo más ahí (ver `docs/01_ADR.md`, "Consecuencias").

## 4. Apuntar tu productor/consumer al broker compartido

En el `.env` de tu repo individual (`starlink-measurement-station` o
`tesis-sensor-node`), no en código:

```bash
MQTT_HOST=35.224.141.221
MQTT_PORT=5883
MQTT_USERNAME=<pedir a Aldana/Fede>
MQTT_PASSWORD=<pedir a Aldana/Fede>
```

Consistente con `CLAUDE.md` §11 de `starlink-measurement-station`: config de conexión
siempre en `.env`, nunca hardcodeada — así el mismo código sigue sirviendo para
desarrollo local (broker propio) y para integración (broker de la VM) sin tocar una
línea.

## 5. Levantar el broker en la VM (ya hecho una vez, 19-20/8 — esto es referencia
   para la próxima vez que haga falta recrearlo desde cero)

La VM es Debian 13 (trixie) — el paquete se llama `docker-compose` (no
`docker-compose-plugin`, no existe en sus repos), pero instala Compose v2.26.1 igual
(`docker compose ...` funciona). El usuario `federico.isaia.soria` no está en el
grupo `docker`, así que todo va con `sudo` por ahora.

```bash
ssh -i <clave> federico.isaia.soria@35.224.141.221
# (en la VM, primera vez únicamente)
sudo apt-get update && sudo apt-get install -y docker.io docker-compose
git clone https://github.com/AldanaPavetGarcia/starlink-station-stack.git
cd starlink-station-stack/infra/mosquitto-vm

# generar el archivo de passwords (no se versiona, ver .gitignore)
sudo docker run --rm -v "$(pwd)":/mosquitto/config eclipse-mosquitto:2.0.18 \
    mosquitto_passwd -c -b /mosquitto/config/passwordfile <usuario> <password>

# OJO: no usar 600 acá -- el mount es de solo archivo (:ro) y el proceso
# Mosquitto adentro del contenedor corre con un UID distinto al del host, así
# que un 600 (dueño = tu usuario del host) lo deja ilegible para el contenedor
# ("Unable to open pwfile", encontrado en el despliegue real del 19-20/8).
# 644 (world-readable) es el workaround funcional hasta que se saque el :ro
# de los mounts y se deje que el propio entrypoint haga el chown correcto.
sudo chmod 644 passwordfile

# .env local (no versionado, ver .env.example) -- mismas credenciales de arriba,
# las usa el healthcheck del broker para autenticarse igual que cualquier cliente
cp .env.example .env   # y completar MQTT_HEALTHCHECK_PASSWORD

sudo docker compose up -d
sudo docker compose ps    # confirmar "healthy", no solo "Up"
sudo docker compose logs -f   # si algo no cierra
```

## 6. Verificar que llega

Desde tu máquina, con `mosquitto_sub`/`mosquitto_pub` instalado local (o el mismo
contenedor):

```bash
mosquitto_sub -h 35.224.141.221 -p 5883 -u <usuario> -P <password> -t '#' -v
```
