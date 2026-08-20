# ADR Log — starlink-station-stack

Este repo es la integración entre `starlink-measurement-station` (Aldana) y
`tesis-sensor-node` (Fede) — polyrepo + docker-compose, decidido el 11/8/2026 (ver
`docs/PROGRESS.md` de `starlink-measurement-station`). Sus propios ADR/SRS/DER
completos viven en cada repo de origen, no acá (ver README.md, sección
"Documentación" — se enlazan, no se copian). Este log es solo para decisiones propias
de *este* repo, la integración en sí.

## ADR-01 — Topología de despliegue: la VM de la cátedra aloja solo el broker MQTT

| **Atributo** | **Valor** |
| --- | --- |
| **ID** | ADR-01 (station-stack) |
| **Estado** | Propuesto |
| **Fecha** | 19 ago 2026 |

### Contexto

La cátedra ofreció una VM (`35.224.141.221`, IP pública, GCP) para que ambos módulos
se puedan conectar sin depender de estar en la misma red — problema real: la RPi5 de
Aldana está en la red del LIT, la PC/ESP32 de Fede en otra red, ninguna de las dos
tiene IP pública. Verificado por SSH el 19/8: la VM tiene ~1GB RAM (964Mi total, 518Mi
disponibles) y 9.7GB de disco, sin Docker instalado, sudo sin password, persistente
entre sesiones.

### Decisión

**La VM aloja únicamente el broker Mosquitto compartido.** El resto de la pila
(`starlink_db`, `station_config_db`, `meteo_db`, `consumer`, `backend`, `grafana`)
sigue viviendo en el `docker-compose.yml` de `starlink-measurement-station`, corriendo
en la RPi5 de Aldana — que ya tiene la pila completa validada con datos reales de la
antena (semana 10, 14/8) y muchísima más RAM disponible (RPi5 típica: 4-8GB) que la
VM. La RPi5 y el mock/firmware de Fede apuntan ambos a `MQTT_HOST=35.224.141.221` en
su `.env` — nadie necesita compartir red WiFi, cada máquina solo necesita salida a
internet hacia esa IP.

### Alternativas consideradas

| Alternativa | Por qué se descartó |
| --- | --- |
| Pila completa (3× TimescaleDB + Grafana + backend + broker + 2 mocks) en la VM | Cada instancia Postgres/TimescaleDB tiene overhead base de ~50-100MB solo por existir; con 518MB disponibles verificados por SSH, riesgo real de OOM apenas arranca el primer servicio de base de datos. No se probó bajo esta carga y la ventana de 72h de CA-01/CA-02 (`starlink-measurement-station`) es demasiado importante para arriesgarla a una VM sin validar. |
| Cada quién con su propio broker aislado (estado actual antes de este ADR) | Es literalmente el problema que este repo existe para resolver — los mensajes de un lado nunca llegan al consumer del otro. |
| VPN/túnel (Tailscale, WireGuard) entre las 2 redes sin usar la VM como broker | Más complejo de configurar para este alcance, y la VM ofrecida por la cátedra ya resuelve el problema de forma más simple — se deja como alternativa futura si la VM deja de estar disponible. |

### Consecuencias

- El broker de la VM se expone con IP pública real — a diferencia del broker de
  `starlink-measurement-station` (solo red Docker/LAN, sin auth por diseño), este
  **sí necesita autenticación** (`allow_anonymous false` + `password_file`, ver
  `infra/mosquitto-vm/mosquitto.conf`).
- Puertos: la VM solo tiene abiertos `5000-6000/tcp`, `8080` y `443` — el broker se
  remapea a `5883` externo (interno sigue en `1883`). Backend y Grafana no se mudan a
  la VM, siguen expuestos como ya lo estaban en la RPi5.
- Si en el futuro la VM crece de recursos (o la cátedra da una más grande), este ADR
  se revisita — no es una decisión permanente, es la mejor opción con los ~1GB
  verificados hoy.

### Actualización 20/8/2026 — pedido explícito del director de ampliar el alcance

El director (Santiago) pidió expresamente un front público con QR ("Lo ideal sería que
ahí tengas el mqtt sí, y ponele que el front estaría ideal […] que cualquiera pueda
escanear y entrar a ver algunas métricas"), lo que requiere que los datos vivan en algo
con IP pública — hoy solo la VM la tiene.

Se preparó `infra/vm-stack/` (TimescaleDB tuneada para RAM baja + consumer + Grafana con
acceso anónimo Viewer, sin buildear nada en la VM, todo desde imágenes ya publicadas en
GHCR) **pero no se desplegó todavía** — la RAM sigue siendo la misma restricción de
cuando se escribió este ADR (964MB total, ~500MB libres con el broker corriendo), y
sumar esto son otros ~450-650MB, con riesgo real de OOM. Queda pendiente de que Santiago
confirme si puede darle más recursos a la VM antes de arriesgar el broker que ya está
funcionando (bridge desde la RPi5 verificado el mismo día, ver `starlink-measurement-station`
ADR-20). La decisión de fondo de este ADR (**solo el broker corre hoy**) sigue vigente —
esto es una ampliación de alcance en evaluación, no un cambio ya aplicado.
