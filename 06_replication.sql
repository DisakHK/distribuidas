-- ============================================================
--  06_replication.sql
--  Configuración, monitoreo y experimentos de replicación
--  líder-seguidor en PostgreSQL.
--  Ejecutar en el nodo PRIMARY (pgnode1, pgnode2 o pgnode3).
-- ============================================================


-- ════════════════════════════════════════════════════════════
--  SECCIÓN 1: Monitoreo del estado de replicación
-- ════════════════════════════════════════════════════════════

-- Ver réplicas conectadas y su estado
SELECT
    client_addr,
    state,
    sent_lsn,
    write_lsn,
    flush_lsn,
    replay_lsn,
    (sent_lsn - replay_lsn) AS replication_lag_bytes,
    sync_state,
    sync_priority
FROM pg_stat_replication;

-- Calcular lag en tiempo (requiere track_commit_timestamp = on)
SELECT
    application_name,
    client_addr,
    state,
    sync_state,
    ROUND((EXTRACT(EPOCH FROM (NOW() - pg_last_xact_replay_timestamp()))) * 1000) AS lag_ms
FROM pg_stat_replication;

-- Ver si este nodo es primary o standby
SELECT pg_is_in_recovery() AS es_replica;

-- Ver posición actual del WAL (en primary)
SELECT pg_current_wal_lsn() AS current_wal_lsn;

-- En réplica: ver último LSN recibido
-- SELECT pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn();


-- ════════════════════════════════════════════════════════════
--  SECCIÓN 2: Experimento synchronous_commit
--  Medir impacto en latencia de escritura
-- ════════════════════════════════════════════════════════════

-- Crear tabla de benchmarking temporal
CREATE TABLE IF NOT EXISTS bench_writes (
    id         SERIAL PRIMARY KEY,
    payload    TEXT,
    ts         TIMESTAMPTZ DEFAULT NOW(),
    config     TEXT
);

-- ── Experimento A: synchronous_commit = OFF (asincrónico) ────
SET synchronous_commit = off;

DO $$
DECLARE
    v_start  TIMESTAMPTZ;
    v_end    TIMESTAMPTZ;
    v_iter   INT := 1000;
    v_i      INT;
BEGIN
    v_start := clock_timestamp();
    FOR v_i IN 1..v_iter LOOP
        INSERT INTO bench_writes (payload, config)
        VALUES (md5(random()::TEXT), 'async_off');
    END LOOP;
    v_end := clock_timestamp();
    RAISE NOTICE 'ASYNC (off): % escrituras en % ms → %.2f ms/op',
        v_iter,
        EXTRACT(EPOCH FROM (v_end - v_start)) * 1000,
        EXTRACT(EPOCH FROM (v_end - v_start)) * 1000 / v_iter;
END;
$$;

-- ── Experimento B: synchronous_commit = ON (sincrónico) ──────
SET synchronous_commit = on;

DO $$
DECLARE
    v_start  TIMESTAMPTZ;
    v_end    TIMESTAMPTZ;
    v_iter   INT := 1000;
    v_i      INT;
BEGIN
    v_start := clock_timestamp();
    FOR v_i IN 1..v_iter LOOP
        INSERT INTO bench_writes (payload, config)
        VALUES (md5(random()::TEXT), 'sync_on');
    END LOOP;
    v_end := clock_timestamp();
    RAISE NOTICE 'SYNC (on): % escrituras en % ms → %.2f ms/op',
        v_iter,
        EXTRACT(EPOCH FROM (v_end - v_start)) * 1000,
        EXTRACT(EPOCH FROM (v_end - v_start)) * 1000 / v_iter;
END;
$$;

-- ── Experimento C: synchronous_commit = REMOTE_APPLY ─────────
SET synchronous_commit = remote_apply;

DO $$
DECLARE
    v_start  TIMESTAMPTZ;
    v_end    TIMESTAMPTZ;
    v_iter   INT := 200;  -- menos iteraciones: es el más lento
    v_i      INT;
BEGIN
    v_start := clock_timestamp();
    FOR v_i IN 1..v_iter LOOP
        INSERT INTO bench_writes (payload, config)
        VALUES (md5(random()::TEXT), 'remote_apply');
    END LOOP;
    v_end := clock_timestamp();
    RAISE NOTICE 'REMOTE_APPLY: % escrituras en % ms → %.2f ms/op',
        v_iter,
        EXTRACT(EPOCH FROM (v_end - v_start)) * 1000,
        EXTRACT(EPOCH FROM (v_end - v_start)) * 1000 / v_iter;
END;
$$;

-- Restaurar valor por defecto del docker-compose
SET synchronous_commit = on;

-- Resumen de resultados
SELECT
    config,
    COUNT(*) AS total_escrituras,
    AVG(EXTRACT(EPOCH FROM (ts - LAG(ts) OVER (PARTITION BY config ORDER BY id)))) * 1000 AS avg_lag_ms
FROM bench_writes
GROUP BY config
ORDER BY avg_lag_ms;


-- ════════════════════════════════════════════════════════════
--  SECCIÓN 3: Proceso de Failover (promotion)
-- ════════════════════════════════════════════════════════════
-- NOTA: estos comandos se ejecutan en la TERMINAL del sistema,
-- no directamente en psql. Se documentan aquí como referencia.

/*
── Paso 1: Detectar caída del Primary ──────────────────────
$ pg_isready -h pgnode1 -p 5432
pgnode1:5432 - no response   ← Primary caído

── Paso 2: Verificar lag antes de promotion ────────────────
$ psql -h pgnode1r -U postgres -c "SELECT pg_last_wal_replay_lsn();"

── Paso 3: Promover la réplica a Primary ───────────────────
# Opción A: pg_ctl promote (en el contenedor de la réplica)
$ docker exec -it pgnode1r pg_ctl promote -D /var/lib/postgresql/data

# Opción B: touch trigger file (si standby_mode usa trigger_file)
$ touch /var/lib/postgresql/data/failover.trigger

── Paso 4: Verificar que ya es Primary ─────────────────────
$ psql -h pgnode1r -U postgres -c "SELECT pg_is_in_recovery();"
-- Debe retornar: f (false = es Primary ahora)

── Paso 5: Actualizar enrutamiento de la aplicación ────────
# Actualizar get_node_dsn() para apuntar pgnode1r como Primary:
$ psql -h pgnode1r -U postgres -d socialdb

-- En pgnode1r (ahora Primary):
CREATE OR REPLACE FUNCTION get_node_dsn(p_user_id INT)
RETURNS TEXT LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p_user_id BETWEEN 1 AND 3000 THEN
        RETURN 'host=pgnode1r port=5432 dbname=socialdb user=postgres password=postgres';
    ...

── Paso 6: Prevención de split-brain ───────────────────────
# Evitar que el antiguo Primary (si se recupera) vuelva como Primary:
# - Usar pg_rewind para sincronizarlo como réplica del nuevo Primary
$ pg_rewind --target-pgdata=/var/lib/postgresql/data \
            --source-server="host=pgnode1r user=postgres"

# - Luego configurarlo como standby del nuevo Primary y reiniciar.
*/


-- ════════════════════════════════════════════════════════════
--  SECCIÓN 4: Verificar consistencia post-failover
-- ════════════════════════════════════════════════════════════

-- Comparar filas entre Primary y réplica (ejecutar en ambos)
SELECT COUNT(*) AS total_posts FROM posts;
SELECT COUNT(*) AS total_users FROM users;
SELECT MAX(id)  AS ultimo_post_id FROM posts;
