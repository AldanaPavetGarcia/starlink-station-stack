# ESP32 → RPi5 por WiFi/MQTT (nodo ambiental)

Runbook del diagnóstico y arreglo de la conexión del ESP32 del nodo ambiental al broker
Mosquitto de la RPi5, hecho el **16/10/2026** en el LIT. El firmware es del módulo de Fede
(`tesis-sensor-node`), pero el problema cruzaba ESP32, red del LIT y broker de la RPi5, que
es hardware compartido; por eso vive en este repo.

## Resumen

| | |
|---|---|
| Placa | ESP32 DevKit (USB-serie CP210x, `/dev/ttyUSB0`) |
| Firmware | `tesis-sensor-node/firmware/esp32-bme280`, rama `development` (`62f3e77`) |
| Librería MQTT | `256dpi/MQTT@2.5.3` (lwmqtt) |
| Red | WiFi `LCD` del LIT (2.4 GHz) |
| Broker | Mosquitto de la RPi5, `172.18.147.143:1883`, sin auth |
| Síntoma | El ESP32 entraba al WiFi pero nunca conectaba al broker: `[MQTT] Conexión fallida. Error=-1, retorno=6` |
| Causa | **Bug de firmware**: buffer de escritura del cliente MQTT de 128 bytes, más chico que el paquete CONNECT (~154 bytes con el LWT) |
| Solución | `MQTTClient mqttClient_{512, 128};` → `{512, 512};` en `include/MqttService.h` |
| Estado | ✅ WiFi + NTP + MQTT funcionando, el estado `online` llega a la RPi5 cada 30 s. ❌ **El BME280 no se detecta** — todavía no llegan mediciones (ver [Pendientes](#pendientes)) |

**No era un problema de red.** No hizo falta convertir la RPi5 en access point ni montar un
servidor NTP propio.

## 1. Primer intento: el ESP32 tenía otro programa cargado

La primera salida del monitor serie fue:

```
Temperatura: 22.72 °C
Humedad: 78.63 %
Presion: 667.95 hPa
--------------------
```

Ese formato **no existe en el firmware del repo** (se buscó con
`git grep -E "Temperatura|Presion|-----" origin/development -- firmware/`, sin resultados). El
firmware real arranca con `=== Nodo ambiental ESP32 + BME280 ===` y loguea `[WiFi]`,
`[Tiempo]` y `[MQTT]`. Lo que estaba cargado era un sketch de prueba del sensor, sin WiFi ni
MQTT: por eso "no transmitía".

> La presión de **667,95 hPa** de ese sketch es sospechosa: en Córdoba debería rondar
> 950–970 hPa (668 hPa equivale a ~3300 m de altura), y las tres lecturas eran idénticas
> hasta el último decimal. Queda pendiente verificarla con el firmware real.

## 2. Diagnóstico con el firmware real

Con el firmware del repo cargado (por Fede, en su ThinkPad):

```
=== Nodo ambiental ESP32 + BME280 ===
[BME280] Sensor detectado en 0x76.
[WiFi] Intentando conectar a LCD...
[WiFi] Conectado. IP del ESP32: 172.18.147.163
[Tiempo] Sincronización NTP iniciada.
[MQTT] Conectando a 172.18.147.143:1883...
[MQTT] Conexión fallida. Error=-1, retorno=6
```

Interpretación, contra el código fuente de `256dpi/MQTT@2.5.3`:

- **WiFi OK**: el ESP32 entra a `LCD` y recibe IP.
- **TCP al broker OK**: `MQTTClient::connect()` (`src/MQTTClient.cpp:335-341`) abre primero el
  socket TCP y, si falla, devuelve `LWMQTT_NETWORK_FAILED_CONNECT` (`-3`). No fue `-3`, así que
  la IP era correcta y la red no aísla clientes.
- **`Error=-1` = `LWMQTT_BUFFER_TOO_SHORT`** (enum `lwmqtt_err_t` en `src/lwmqtt/lwmqtt.h`): el
  paquete CONNECT no entra en el buffer de escritura.
- **`retorno=6` = `LWMQTT_UNKNOWN_RETURN_CODE`**: el broker nunca respondió, porque el CONNECT
  ni siquiera se llegó a enviar.

La causa está en `include/MqttService.h`:

```cpp
MQTTClient mqttClient_{512, 128};   // (readBufSize, writeBufSize)
```

El buffer de **escritura** es de 128 bytes, pero el CONNECT lleva:

| Parte | Bytes aprox. |
|---|---|
| Header fijo + variable | 12 |
| Client ID `esp32-bme280-lit-cordoba-01` | 29 |
| Tópico del LWT `meteo/status/lit-cordoba-01` | 29 |
| Payload del LWT (`{"node_id":…,"status":"offline"}`) | ~84 |
| **Total** | **~154 > 128** |

Aunque hubiera conectado, cada medición (~250 bytes de JSON + tópico) tampoco habría entrado
en el buffer al publicar.

### Hipótesis descartadas

| Hipótesis | Por qué se descartó |
|---|---|
| IP del broker equivocada | El TCP conectaba (no hubo `-3`). Además, `nc`/`/dev/tcp` desde una laptop en `LCD` a `172.18.147.143:1883` responde |
| Red `LCD` en 5 GHz o WPA2-Enterprise | El ESP32 entra a `LCD` sin problema |
| Aislamiento de clientes en `LCD` | Una laptop en `LCD` llega al broker de la RPi5 |
| NTP bloqueado (la red del LIT solo deja salir por 80/443, ver `PROGRESS.md` 20/8) | Una consulta SNTP a `pool.ntp.org` desde `LCD` respondió bien, y el ESP32 sincroniza la hora. **En `LCD` el NTP sí sale** |

La IA de Fede había propuesto convertir `wlan0` de la RPi5 en access point (`TesisSensor`,
`10.42.0.1`) para esquivar la red del LIT. **No hace falta**: la red no era el problema.

## 3. Arreglo

En `firmware/esp32-bme280/include/MqttService.h`:

```diff
-  MQTTClient mqttClient_{512, 128};
+  MQTTClient mqttClient_{512, 512};
```

Configuración local para el LIT (no es parte del arreglo):

- `include/AppConfig.h`: `MQTT_HOST[] = "172.18.147.143";` (la IP de la RPi5 en `LCD`; en el
  repo figura el placeholder `192.168.1.10`).
- `include/Secrets.h` (copiado de `Secrets.example.h`, **ignorado por git**): `WIFI_SSID` =
  `LCD` y su contraseña. Las credenciales MQTT quedan vacías: el broker local es anónimo.

## 4. Cómo se reprodujo y verificó (desde la laptop de Aldana, en `LCD`)

### Preparación de la laptop

```bash
# PlatformIO en un venv propio, sin tocar el sistema ni el .venv del proyecto
python3 -m venv ~/.platformio/penv
~/.platformio/penv/bin/pip install platformio        # quedó PlatformIO Core 6.2.0

# Permiso para el puerto serie (pide cerrar sesión para aplicarse)
sudo usermod -aG dialout $USER
```

Si todavía no se cerró la sesión gráfica, el grupo no está activo en la terminal; se puede
usar igual con `sg dialout -c "<comando>"`.

### Copia del firmware sin tocar otras ramas

```bash
cd tesis-sensor-node
git fetch
git worktree add -b fix/mqtt-write-buffer ../tesis-sensor-node-esp32 origin/development
cd ../tesis-sensor-node-esp32/firmware/esp32-bme280
cp include/Secrets.example.h include/Secrets.h      # completar WiFi
# aplicar el arreglo y el MQTT_HOST de la sección 3
```

### Chequeos de red previos (desde la laptop en `LCD`)

```bash
timeout 5 bash -c '</dev/tcp/172.18.147.143/1883' && echo "broker abierto"
```
→ `broker abierto`. Además, una consulta SNTP a `pool.ntp.org` y `ar.pool.ntp.org` (UDP 123)
devolvió la hora correcta.

### Compilar, flashear y leer

```bash
pio run                                              # 1ª vez descarga la toolchain (~3 min)
sg dialout -c "pio run -t upload --upload-port /dev/ttyUSB0"
sg dialout -c "pio device monitor -b 115200"         # y apretar EN/RST
```

En paralelo, escuchando el broker de la RPi5 desde la laptop (sin instalar
`mosquitto-clients`, con la misma imagen que usa la pila):

```bash
docker run --rm --network host eclipse-mosquitto:2.0.18 \
  mosquitto_sub -h 172.18.147.143 -t 'meteo/#' -v -F '%I %t %p'
```

### Resultado

Monitor serie:

```
=== Nodo ambiental ESP32 + BME280 ===
[WiFi] Conectado. IP del ESP32: 172.18.147.163
[Tiempo] Sincronización NTP iniciada.
[MQTT] Conectando a 172.18.147.143:1883...
[MQTT] Conectado al broker Mosquitto.
```

Broker de la RPi5 (heartbeat cada 30 s, sin cortes durante 4 minutos):

```
2026-10-16T21:28:51+0000 meteo/status/lit-cordoba-01 {"node_id":"lit-cordoba-01","source":"real","producer":"bme280","status":"online"}
2026-10-16T21:29:22+0000 meteo/status/lit-cordoba-01 {"node_id":"lit-cordoba-01","source":"real","producer":"bme280","status":"online"}
2026-10-16T21:29:52+0000 meteo/status/lit-cordoba-01 {"node_id":"lit-cordoba-01","source":"real","producer":"bme280","status":"online"}
```

## 5. Errores encontrados (todos, en orden)

| # | Dónde | Error / síntoma | Causa | Cómo se resolvió |
|---|---|---|---|---|
| 1 | Serie del ESP32 (ThinkPad de Fede) | Solo `Temperatura: / Humedad: / Presion:`, ningún log `[WiFi]`/`[MQTT]` | Estaba cargado un sketch de prueba del sensor, no el firmware del repo | Flashear `tesis-sensor-node/firmware/esp32-bme280` |
| 2 | Serie del ESP32 | `Presion: 667.95 hPa`, lecturas idénticas | Desconocida (conversión del sketch, sensor o lectura congelada) | **Pendiente** |
| 3 | Serie del ESP32 | `[MQTT] Conexión fallida. Error=-1, retorno=6` | Buffer de escritura MQTT de 128 bytes < CONNECT (~154) → `LWMQTT_BUFFER_TOO_SHORT` | `mqttClient_{512, 512}` |
| 4 | Laptop de Aldana → RPi5 | `ssh rpi5-remoto` → `Permission denied (publickey)` / `ssh_askpass: … No such file` | La clave de la VM tiene passphrase y no estaba cargada en el agente | No se usó; la verificación se hizo por la LAN (`LCD`). Para usarla: `ssh-add` antes |
| 5 | Laptop de Aldana | Sin `pio` ni `pyserial`; usuario fuera del grupo `dialout` | Máquina sin preparar para el ESP32 | venv de PlatformIO + `usermod -aG dialout` |
| 6 | Laptop de Aldana | Tras reiniciar Claude Code, `id -nG` seguía sin `dialout` | El grupo se aplica al cerrar la **sesión gráfica**, no al reabrir una terminal | `sg dialout -c "<comando>"` |
| 7 | Serie del ESP32 (laptop de Aldana) | `[BME280] No se encontró el sensor en 0x76 ni 0x77.` → `Sensor no inicializado; se omite la medición.` | No determinada (cableado/sensor) | **Pendiente**, persiste tras revisar el cableado |

Los `exit code 124` de los `mosquitto_sub` no son errores: es el `timeout` puesto a propósito
para que la escucha terminara sola.

## 6. Comandos usados (en orden)

### Revisión del firmware (solo lectura)

```bash
cd tesis-sensor-node
git fetch
git log --oneline --all -8
git show 62f3e77:firmware/esp32-bme280/include/AppConfig.h      # y WifiService.cpp, MqttService.cpp, main.cpp, TimeService.cpp
git show origin/development:firmware/esp32-bme280/include/MqttService.h
git show origin/development:firmware/esp32-bme280/src/PayloadBuilder.cpp
git grep -n -E "Temperatura|Presion|-----" origin/development -- firmware/   # confirma que el sketch no es del repo
```

### Códigos de error de la librería MQTT

```bash
curl -s https://raw.githubusercontent.com/256dpi/arduino-mqtt/v2.5.3/src/lwmqtt/lwmqtt.h | grep -n -A16 "typedef enum {"
curl -s https://raw.githubusercontent.com/256dpi/arduino-mqtt/v2.5.3/src/MQTTClient.h  | grep -n "bufSize\|MQTTClient("
curl -s https://raw.githubusercontent.com/256dpi/arduino-mqtt/v2.5.3/src/MQTTClient.cpp | grep -n -A30 "bool MQTTClient::connect(const char clientID"
```

### Preparación de la laptop

```bash
python3 -m venv ~/.platformio/penv
~/.platformio/penv/bin/pip install platformio
sudo usermod -aG dialout $USER
getent group dialout                                 # dialout:x:20:aldanapavet
ls -l /dev/ttyUSB0 && lsusb | grep -i cp210          # Silicon Labs CP210x UART Bridge
```

### Worktree, arreglo y configuración

```bash
cd tesis-sensor-node
git worktree add -b fix/mqtt-write-buffer ../tesis-sensor-node-esp32 origin/development
cd ../tesis-sensor-node-esp32/firmware/esp32-bme280
sed -i 's/MQTTClient mqttClient_{512, 128};/MQTTClient mqttClient_{512, 512};/' include/MqttService.h
sed -i 's/MQTT_HOST\[\] = "192.168.1.10";/MQTT_HOST[] = "172.18.147.143";/' include/AppConfig.h
cp include/Secrets.example.h include/Secrets.h       # y completar WIFI_SSID / WIFI_PASSWORD
git check-ignore -v include/Secrets.h                # confirma que no se commitea
```

### Chequeos de red desde `LCD`

```bash
ip -4 -br addr                                       # laptop en 172.18.147.244/25
timeout 5 bash -c '</dev/tcp/172.18.147.143/1883' && echo "broker abierto"
```

Consulta SNTP mínima (UDP 123), en Python sin dependencias:

```python
import socket, struct, time
for host in ("pool.ntp.org", "ar.pool.ntp.org"):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(4)
    s.sendto(b'\x1b' + 47*b'\0', (host, 123)); d, _ = s.recvfrom(48)
    t = struct.unpack('!I', d[40:44])[0] - 2208988800
    print(host, time.strftime('%Y-%m-%d %H:%M:%S UTC', time.gmtime(t)))
```

### Compilar y flashear

```bash
cd tesis-sensor-node-esp32/firmware/esp32-bme280
~/.platformio/penv/bin/pio run
sg dialout -c "$HOME/.platformio/penv/bin/pio run -t upload --upload-port /dev/ttyUSB0"
```

### Escuchar el broker de la RPi5

```bash
timeout 240 docker run --rm --network host eclipse-mosquitto:2.0.18 \
  mosquitto_sub -h 172.18.147.143 -t 'meteo/#' -v -F '%I %t %p'
```

### Leer el serie con reset automático

En vez de `pio device monitor` (interactivo), un script que resetea la placa por RTS y lee
durante N segundos; se corre con el Python del venv de PlatformIO, que ya trae `pyserial`:

```python
# serial_read.py
import serial, sys, time
s = serial.Serial("/dev/ttyUSB0", 115200, timeout=0.5)
s.dtr = False; s.rts = True; time.sleep(0.2); s.rts = False   # reset por EN
end = time.time() + float(sys.argv[1])
while time.time() < end:
    line = s.readline()
    if line:
        print(time.strftime("%H:%M:%S"), line.decode(errors="replace").rstrip(), flush=True)
```

```bash
sg dialout -c "$HOME/.platformio/penv/bin/python -I serial_read.py 100"
```

## Pendientes

1. **BME280 no detectado.** Con la placa en la laptop de Aldana el firmware imprime
   `[BME280] No se encontró el sensor en 0x76 ni 0x77.` y omite las mediciones (solo se
   publica el estado). Se revisó el cableado y se repitió con el mismo resultado. Conexión
   esperada:

   | BME280 | ESP32 |
   |---|---|
   | VCC | 3V3 (no 5V) |
   | GND | GND |
   | SCL | GPIO22 |
   | SDA | GPIO21 |
   | SDO | GND (dirección 0x76) |

   Siguiente paso: cargar un escáner I2C para ver si hay algún dispositivo respondiendo en el
   bus, y probar el sensor que en la ThinkPad de Fede sí se detectaba en `0x76`.
2. **Validar la presión** con el firmware real (el sketch de prueba daba 668 hPa).
3. **Subir el arreglo al repo de Fede.** Está commiteado (`1818c11`) en la rama local `fix/mqtt-write-buffer` (worktree
   `tesis-sensor-node-esp32`), sin pushear ni PR. El commit tiene solo el cambio de
   `MqttService.h`; si `MQTT_HOST` se commitea o no lo decide Fede.
4. **IP de la RPi5 por DHCP.** `172.18.147.143` está fija en el firmware; si el DHCP del LIT
   se la cambia, el ESP32 deja de llegar al broker. Conviene una reserva DHCP o IP fija.
