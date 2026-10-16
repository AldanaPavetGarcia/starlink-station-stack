# Pantalla táctil oficial de 7" (DSI) en la RPi5

Runbook de la conexión de la pantalla a la RPi5 de la estación (LIT), hecha el
**16/10/2026**. La RPi5 es hardware compartido por los dos módulos, por eso vive en este
repo y no en uno individual.

## Resumen

| | |
|---|---|
| Pantalla | Raspberry Pi Touch Display 7" **v1** (oficial) |
| Cable | Flexible DSI de 160 mm (mini 22 pines del lado de la Pi 5 → 15 pines del lado de la pantalla) |
| Placa | Raspberry Pi 5 Model B Rev 1.1, kernel `6.12.75+rpt-rpi-2712` |
| Síntoma | La pantalla no mostraba imagen; no se sabía si era hardware o configuración |
| Causa | `display_auto_detect=1` **no reconocía** la pantalla, así que el kernel no creaba el conector DSI |
| Solución | Forzar `dtoverlay=vc4-kms-dsi-7inch` en `/boot/firmware/config.txt` y reiniciar |
| Estado | ✅ Imagen funcionando, touch registrado, pila de la estación levantada tras el reinicio |

**Cable y pantalla estaban sanos.** No hace falta reemplazar nada.

## Conexión a la RPi5

Desde la red del LIT, directo:

```bash
ssh leonode-rpi          # 172.18.147.143, usuario leonode
```

Desde afuera del LIT, por el túnel SSH inverso que pasa por la VM:

```bash
ssh rpi5-remoto
```

Las entradas de `~/.ssh/config` y las claves no están en este repo. Pedírselas a Aldana o a Fede.

## 1. Diagnóstico (solo lectura)

Ninguno de estos comandos cambia nada en la Pi.

```bash
# Identificar placa y kernel
hostname
cat /proc/device-tree/model
uname -r
```
→ `raspberrypi`, `Raspberry Pi 5 Model B Rev 1.1`, `6.12.75+rpt-rpi-2712`.

```bash
# Salidas de video que ve el kernel (DRM)
ls /sys/class/drm/
for f in /sys/class/drm/card*-*/status; do echo "$f: $(cat $f)"; done
```
→ Solo `card1-HDMI-A-1` (disconnected), `card1-HDMI-A-2` (connected) y dos `Writeback`.
**No había ningún conector DSI.**

```bash
# Retroiluminación (la pantalla oficial crea una entrada acá)
ls /sys/class/backlight/
```
→ Vacío.

```bash
# Configuración de arranque, sin comentarios ni líneas vacías
grep -vE "^\s*(#|$)" /boot/firmware/config.txt
```
→ `display_auto_detect=1` y `dtoverlay=vc4-kms-v3d,composite`, sin ningún overlay DSI.

```bash
# Mensajes del kernel sobre DSI, panel, touch, backlight e I2C
sudo dmesg | grep -iE "dsi|panel|7inch|ili9881|ft5|backlight|rpi_touch|attiny|i2c" | tail -40
```
→ Solo el registro de los controladores I2C. Ninguna mención de panel ni touch.

```bash
# Buses I2C disponibles
ls /dev/i2c-*
```
→ Solo `i2c-13` e `i2c-14`, que son los DDC de HDMI. El bus I2C del DSI no existe hasta
que se carga el overlay.

```bash
# Overlays de pantallas DSI instalados
ls /boot/firmware/overlays | grep -iE "dsi|7inch|ili9881|waveshare"
```
→ Están todos instalados (`vc4-kms-dsi-7inch`, `vc4-kms-dsi-ili9881-7inch`,
`vc4-kms-dsi-waveshare-panel`, …). No falta software.

**Lectura:** que no aparezca ningún DSI **no prueba que el flexible esté roto**. Si la
autodetección no reconoce el panel, el kernel no crea el conector ni su bus I2C, y el
síntoma es idéntico con flexible roto, pantalla muerta o falta de configuración. Para
saber cuál de los tres es, hay que forzar el overlay.

## 2. Cambio aplicado

Hace falta reiniciar la RPi5, y eso **corta la adquisición de la estación ~1-2 min**.
Avisar antes de hacerlo.

```bash
# Respaldo de la config original
sudo cp /boot/firmware/config.txt /boot/firmware/config.txt.bak-dsi

# Forzar el overlay de la pantalla oficial v1
echo -e "\n# Prueba pantalla DSI oficial 7in v1 (16/10/2026)\ndtoverlay=vc4-kms-dsi-7inch" \
  | sudo tee -a /boot/firmware/config.txt

# Estado de los contenedores antes de reiniciar (para comparar después)
docker ps --format "{{.Names}}: {{.Status}}"

sudo reboot
```

## 3. Verificación después del reinicio

```bash
ls /sys/class/drm/
cat /sys/class/drm/card*-DSI*/status
```
→ Aparecen `card2-DSI-1` y `card3-DSI-2`, los dos `connected`. En la Pi 5 el overlay crea
un panel en cada uno de los dos puertos `CAM/DISP`.

```bash
ls /sys/class/backlight/
for b in /sys/class/backlight/*; do
  echo "$b: brightness=$(cat $b/brightness) max=$(cat $b/max_brightness) bl_power=$(cat $b/bl_power)"
done
```
→ `10-0045` con `brightness=255`, `bl_power=0`. Es la retroiluminación de la pantalla,
encendida al máximo.

```bash
sudo dmesg | grep -iE "dsi|panel|7inch|ft5|backlight|rpi_touch|attiny|i2c|regulator" | tail -40
```
→ `rp1dsi_bind succeeded` en los dos puertos, y el touch registrado:
`input: 10-0038 generic ft5x06 (79) as .../i2c-10/10-0038/input/input21`.

```bash
sudo i2cdetect -y 10
```
→ `UU` en `0x38` (controlador táctil `edt_ft5x06`) y en `0x45` (microcontrolador de la
pantalla y retroiluminación). `UU` significa que el chip responde y que su driver lo tomó.
**Que los dos chips respondan por I2C a través del flexible confirma que el cable y la
pantalla funcionan.**

```bash
docker ps --format "{{.Names}}: {{.Status}}"
```
→ Los 7 contenedores (`starlink-acquisition`, `mosquitto-broker`, `starlink-consumer`,
`starlink-backend`, `starlink-grafana`, `starlink-health-db`, `station-config-db`) volvieron
a levantar solos.

✅ **La pantalla muestra imagen** (confirmado físicamente en el laboratorio).

### Errores esperables (inofensivos)

`dmesg` muestra estos errores:

```
edt_ft5x06 11-0038: touchscreen probe failed
panel-simple 100000001.panel_disp: [drm:drm_panel_enable [drm]] failed to enable backlight: -121
```

Son del **otro puerto DSI (bus I2C 11), que está vacío**. El `-121` (`EREMOTEIO`) significa
que nadie respondió en ese bus. Si molestan, se puede dejar solo el puerto en uso; ver
"Notas" más abajo.

## 4. Revertir

```bash
sudo cp /boot/firmware/config.txt.bak-dsi /boot/firmware/config.txt && sudo reboot
```

## Notas y troubleshooting

- **Conector de la Pi 5:** la Pi 5 usa conectores DSI **mini de 22 pines (0.5 mm)**,
  rotulados `CAM/DISP 0` y `CAM/DISP 1`. La pantalla v1 trae uno de 15 pines (1 mm), así
  que hace falta el cable adaptador 22→15. Un cable de 15 pines en las dos puntas (el de la
  Pi 3/4) **no sirve** en la Pi 5.
- **Overlay según el modelo de pantalla:**

  | Pantalla | Overlay |
  |---|---|
  | Oficial 7" v1 (la del LIT) | `dtoverlay=vc4-kms-dsi-7inch` |
  | Touch Display 2 (7") | `dtoverlay=vc4-kms-dsi-ili9881-7inch` |
  | Waveshare u otra genérica | el overlay del fabricante (ej. `vc4-kms-dsi-waveshare-panel,7_0_inchC`) |

  Si la pantalla está en el puerto `DISP 0`, agregar `,dsi0` (ej.
  `dtoverlay=vc4-kms-dsi-7inch,dsi0`).
- **Alimentación:** la pantalla se alimenta aparte por GPIO, 5V en el pin 2 o 4 y GND en el
  pin 6.
  - Si **no prende ni la retroiluminación**, es alimentación o pantalla, no configuración.
  - Si **se ilumina pero queda en negro**, es la señal de video (flexible o puerto).
- **Cómo aislar el hardware sin repuestos:** forzar el overlay (paso 2) y ver
  `i2cdetect` en el bus del DSI.
  - Si `0x38`/`0x45` responden, cable y pantalla están vivos.
  - Si no responden, probar el otro puerto, volver a enchufar el flexible (traba abierta,
    derecho hasta el fondo) o probar la pantalla en una Pi 3/4.
- **Monitor HDMI:** durante la prueba también había un monitor conectado en `HDMI-A-2`. No
  interfiere con la pantalla DSI.
