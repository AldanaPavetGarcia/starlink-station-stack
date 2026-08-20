-- ============================================================
-- init_starlink_health.sql — DB: starlink_health (ADR-10, ADR-11)
-- Idempotente: IF NOT EXISTS / if_not_exists en todo lo que soporta la opción,
-- para que Postgres pueda re-ejecutar este script sin fallar (reinicios,
-- docker-compose down/up de CA-03).
--
-- Fuente de verdad: docs/06_DER.md §3.1-§3.2. PRIMARY KEY (time, node_id)
-- agregada explícitamente en ambas hypertables: el bloque SQL de referencia del
-- DER no la declaraba pese a que la convención documentada en §"Convenciones"
-- la exige (PK compuesta, time primero por el particionado de TimescaleDB) y a
-- que RF-18/QoS 1 implica reentregas -> sin PK no hay forma de deduplicar.
--
-- schema_version 1.1 (ADR-16/17/18, agosto 2026): snr_db (float) reemplazado
-- por snr_low (bool, ADR-17) -- el firmware real no expone SNR numérico.
-- Agregadas handover_count/outage_duration_ms (ADR-16) y las columnas de
-- alignmentStats (ADR-18). Agregar columnas a una hypertable existente es
-- seguro (no requiere migración destructiva) -- en Etapa 0 (datos sintéticos)
-- se recrea el volumen en vez de hacer ALTER TABLE, ver docs/PROGRESS.md.
-- ============================================================

CREATE EXTENSION IF NOT EXISTS timescaledb;

-- ── Tabla base de telemetría de red ──────────────────────────
CREATE TABLE IF NOT EXISTS network_metrics (
    time                              TIMESTAMPTZ        NOT NULL,
    node_id                           VARCHAR(64)        NOT NULL,
    latency_ms                        FLOAT8,
    jitter_ms                         FLOAT8,
    packet_loss_pct                   FLOAT8,
    throughput_down_bps               BIGINT,
    throughput_up_bps                 BIGINT,
    snr_low                           BOOLEAN,
    is_obstructed                     BOOLEAN,
    satellite_count                   SMALLINT,
    handover_count                    SMALLINT,
    outage_duration_ms                FLOAT8,
    tilt_angle_deg                    FLOAT8,
    boresight_azimuth_deg             FLOAT8,
    boresight_elevation_deg           FLOAT8,
    desired_boresight_azimuth_deg     FLOAT8,
    desired_boresight_elevation_deg   FLOAT8,
    attitude_uncertainty_deg          FLOAT8,
    schema_version                    VARCHAR(16)        NOT NULL DEFAULT '1.1',
    PRIMARY KEY (time, node_id),
    CONSTRAINT chk_netmet_loss
        CHECK (packet_loss_pct IS NULL OR (packet_loss_pct >= 0 AND packet_loss_pct <= 100)),
    CONSTRAINT chk_netmet_down
        CHECK (throughput_down_bps IS NULL OR throughput_down_bps >= 0),
    CONSTRAINT chk_netmet_up
        CHECK (throughput_up_bps IS NULL OR throughput_up_bps >= 0),
    CONSTRAINT chk_netmet_handover_count
        CHECK (handover_count IS NULL OR handover_count >= 0),
    CONSTRAINT chk_netmet_outage_duration
        CHECK (outage_duration_ms IS NULL OR outage_duration_ms >= 0),
    CONSTRAINT chk_netmet_tilt
        CHECK (tilt_angle_deg IS NULL OR (tilt_angle_deg >= 0 AND tilt_angle_deg <= 90)),
    CONSTRAINT chk_netmet_boresight_azimuth
        CHECK (boresight_azimuth_deg IS NULL OR (boresight_azimuth_deg >= -180 AND boresight_azimuth_deg <= 180)),
    CONSTRAINT chk_netmet_boresight_elevation
        CHECK (boresight_elevation_deg IS NULL OR (boresight_elevation_deg >= 0 AND boresight_elevation_deg <= 90)),
    CONSTRAINT chk_netmet_desired_azimuth
        CHECK (desired_boresight_azimuth_deg IS NULL OR (desired_boresight_azimuth_deg >= -180 AND desired_boresight_azimuth_deg <= 180)),
    CONSTRAINT chk_netmet_desired_elevation
        CHECK (desired_boresight_elevation_deg IS NULL OR (desired_boresight_elevation_deg >= 0 AND desired_boresight_elevation_deg <= 90)),
    CONSTRAINT chk_netmet_attitude_uncertainty
        CHECK (attitude_uncertainty_deg IS NULL OR attitude_uncertainty_deg >= 0)
);

SELECT create_hypertable('network_metrics', 'time',
    chunk_time_interval => INTERVAL '1 day', if_not_exists => TRUE);

-- Índices secundarios
CREATE INDEX IF NOT EXISTS idx_netmet_node_time
    ON network_metrics (node_id, time DESC);
CREATE INDEX IF NOT EXISTS idx_netmet_loss
    ON network_metrics (packet_loss_pct)
    WHERE packet_loss_pct > 1.0;
CREATE INDEX IF NOT EXISTS idx_netmet_obstructed
    ON network_metrics (time DESC)
    WHERE is_obstructed = TRUE;

-- Compresión columnar (chunks > 7 días)
ALTER TABLE network_metrics SET (
    timescaledb.compress,
    timescaledb.compress_segmentby = 'node_id',
    timescaledb.compress_orderby   = 'time DESC'
);
SELECT add_compression_policy('network_metrics',
    INTERVAL '7 days', if_not_exists => TRUE);

-- Retención de datos crudos (RF-23: al menos 6 meses)
SELECT add_retention_policy('network_metrics',
    INTERVAL '6 months', if_not_exists => TRUE);

-- ── Tabla de tests detallados (iperf3/speedtest/traceroute/etc.) ──
-- Fuera del alcance actual del extractor (solo telemetría pasiva vía gRPC,
-- ver CLAUDE.md §1.1 "Alcance técnico"), pero forma parte del esquema
-- starlink_health de docs/06_DER.md §3.2 y no cuesta nada dejarla creada.
CREATE TABLE IF NOT EXISTS network_tests (
    time              TIMESTAMPTZ  NOT NULL,
    node_id           VARCHAR(64)  NOT NULL,
    test_type         VARCHAR(32)  NOT NULL,
    target_host       VARCHAR(256) NOT NULL,
    result_primary    FLOAT8,
    result_secondary  FLOAT8,
    samples           INTEGER,
    raw_output        TEXT,
    tool_version      VARCHAR(16),
    PRIMARY KEY (time, node_id),
    CONSTRAINT chk_nettest_type
        CHECK (test_type IN ('ping', 'iperf3_tcp', 'iperf3_udp', 'speedtest', 'traceroute', 'dns_lookup'))
);

SELECT create_hypertable('network_tests', 'time',
    chunk_time_interval => INTERVAL '1 day', if_not_exists => TRUE);

-- ── Continuous Aggregates ─────────────────────────────────────
CREATE MATERIALIZED VIEW IF NOT EXISTS net_hourly
WITH (timescaledb.continuous) AS
SELECT
    time_bucket('1 hour', time)                                AS bucket,
    node_id,
    AVG(latency_ms)                                            AS avg_latency_ms,
    MAX(latency_ms)                                            AS max_latency_ms,
    MIN(latency_ms)                                            AS min_latency_ms,
    percentile_cont(0.95) WITHIN GROUP (ORDER BY latency_ms)   AS p95_latency_ms,
    AVG(jitter_ms)                                             AS avg_jitter_ms,
    AVG(packet_loss_pct)                                       AS avg_packet_loss_pct,
    AVG(throughput_down_bps)                                   AS avg_throughput_down_bps,
    AVG(throughput_up_bps)                                     AS avg_throughput_up_bps,
    SUM(handover_count)                                        AS sum_handover_count,
    SUM(outage_duration_ms)                                    AS sum_outage_duration_ms,
    AVG(tilt_angle_deg)                                        AS avg_tilt_angle_deg,
    COUNT(*)                                                   AS sample_count
FROM network_metrics
GROUP BY bucket, node_id
WITH NO DATA;

SELECT add_continuous_aggregate_policy('net_hourly',
    start_offset      => INTERVAL '3 hours',
    end_offset         => INTERVAL '1 hour',
    schedule_interval  => INTERVAL '1 hour',
    if_not_exists      => TRUE);

CREATE MATERIALIZED VIEW IF NOT EXISTS net_daily
WITH (timescaledb.continuous) AS
SELECT
    time_bucket('1 day', time)                                 AS bucket,
    node_id,
    AVG(latency_ms)                                            AS avg_latency_ms,
    MAX(latency_ms)                                            AS max_latency_ms,
    percentile_cont(0.95) WITHIN GROUP (ORDER BY latency_ms)   AS p95_latency_ms,
    AVG(packet_loss_pct)                                       AS avg_packet_loss_pct,
    100.0 * SUM(CASE WHEN packet_loss_pct < 5 THEN 1 ELSE 0 END)::float / COUNT(*) AS availability_pct,
    AVG(throughput_down_bps)                                   AS avg_throughput_down_bps,
    AVG(throughput_up_bps)                                     AS avg_throughput_up_bps,
    SUM(handover_count)                                        AS sum_handover_count,
    SUM(outage_duration_ms)                                    AS sum_outage_duration_ms,
    AVG(tilt_angle_deg)                                        AS avg_tilt_angle_deg,
    COUNT(*)                                                   AS sample_count
FROM network_metrics
GROUP BY bucket, node_id
WITH NO DATA;

-- start_offset - end_offset debe cubrir al menos 2 buckets ('1 day' cada uno):
-- '2 days' - '1 day' = 1 bucket, TimescaleDB lo rechaza ("policy refresh
-- window too small"). '3 days' - '1 day' = 2 buckets, misma proporción que
-- net_hourly (3h - 1h = 2 buckets de 1h) -- verificado contra un servidor real.
SELECT add_continuous_aggregate_policy('net_daily',
    start_offset      => INTERVAL '3 days',
    end_offset         => INTERVAL '1 day',
    schedule_interval  => INTERVAL '1 day',
    if_not_exists      => TRUE);
