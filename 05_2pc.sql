-- ============================================================
--  05_2pc.sql
--  Transacciones distribuidas con 2PC (Two-Phase Commit)
--  en PostgreSQL.
--
--  PRERREQUISITO: max_prepared_transactions > 0 en postgresql.conf
--  (ya configurado en el docker-compose: -c max_prepared_transactions=20)
--
--  ESCENARIO: Operación "follow" entre usuarios en shards distintos.
--    - follower_id = 100  → Nodo 1 (rango 1–3000)
--    - followed_id = 4500 → Nodo 2 (rango 3001–6000)
--
--  La aplicación actúa como coordinador 2PC.
--  Este script simula manualmente las fases.
-- ============================================================

-- ════════════════════════════════════════════════════════════
--  ESCENARIO 1: Follow cross-shard con 2PC exitoso
-- ════════════════════════════════════════════════════════════

-- ── Fase 1 — PREPARE en Nodo 1 ──────────────────────────────
-- Ejecutar conectado a pgnode1:
BEGIN;
INSERT INTO follows (follower_id, followed_id)
VALUES (100, 4500)
ON CONFLICT DO NOTHING;

UPDATE users
SET following_count = following_count + 1
WHERE id = 100;

PREPARE TRANSACTION 'follow_100_4500_n1';

-- ── Fase 1 — PREPARE en Nodo 2 ──────────────────────────────
-- Ejecutar conectado a pgnode2:
BEGIN;
UPDATE users
SET followers_count = followers_count + 1
WHERE id = 4500;

PREPARE TRANSACTION 'follow_100_4500_n2';

-- ── Fase 2 — COMMIT PREPARED (ambas fases OK) ────────────────
-- Si ambos PREPARE retornaron éxito, el coordinador emite COMMIT:

-- En Nodo 1:
COMMIT PREPARED 'follow_100_4500_n1';

-- En Nodo 2:
COMMIT PREPARED 'follow_100_4500_n2';

-- Verificación:
SELECT id, username, followers_count, following_count
FROM users
WHERE id IN (100, 4500);


-- ════════════════════════════════════════════════════════════
--  ESCENARIO 2: 2PC con ROLLBACK (fallo simulado en nodo 2)
-- ════════════════════════════════════════════════════════════

-- ── Fase 1 — PREPARE en Nodo 1 ──────────────────────────────
BEGIN;
INSERT INTO follows (follower_id, followed_id)
VALUES (200, 5000)
ON CONFLICT DO NOTHING;
UPDATE users SET following_count = following_count + 1 WHERE id = 200;
PREPARE TRANSACTION 'follow_200_5000_n1';

-- ── Nodo 2 FALLA antes de responder ──────────────────────────
-- Simulación: no ejecutamos el PREPARE en nodo 2.
-- El coordinador detecta el fallo y emite ROLLBACK a nodo 1:
ROLLBACK PREPARED 'follow_200_5000_n1';

-- Verificación: los contadores NO deben haber cambiado
SELECT id, username, following_count FROM users WHERE id = 200;


-- ════════════════════════════════════════════════════════════
--  ESCENARIO 3: Bloqueo por falla del coordinador
--  (situación crítica de 2PC)
-- ════════════════════════════════════════════════════════════

-- Simular: el coordinador falla DESPUÉS del PREPARE pero ANTES del COMMIT.
-- Las transacciones quedan en estado PREPARED indefinidamente.

-- En Nodo 1 (preparar y "olvidar"):
BEGIN;
INSERT INTO follows (follower_id, followed_id) VALUES (300, 5500)
ON CONFLICT DO NOTHING;
PREPARE TRANSACTION 'follow_300_5500_BLOQUEADA';

-- En Nodo 2 (preparar y "olvidar"):
-- (ejecutar en pgnode2)
BEGIN;
UPDATE users SET followers_count = followers_count + 1 WHERE id = 5500;
PREPARE TRANSACTION 'follow_300_5500_BLOQUEADA_n2';

-- Detectar transacciones bloqueadas:
SELECT
    gid,
    prepared,
    owner,
    database,
    EXTRACT(EPOCH FROM (NOW() - prepared)) AS segundos_bloqueada
FROM pg_prepared_xacts
ORDER BY prepared;

-- Resolución manual (DBA interviene tras recuperar el coordinador):
-- COMMIT PREPARED 'follow_300_5500_BLOQUEADA';       -- en Nodo 1
-- COMMIT PREPARED 'follow_300_5500_BLOQUEADA_n2';    -- en Nodo 2
-- O si se decide abortar:
-- ROLLBACK PREPARED 'follow_300_5500_BLOQUEADA';
-- ROLLBACK PREPARED 'follow_300_5500_BLOQUEADA_n2';


-- ════════════════════════════════════════════════════════════
--  Procedimiento almacenado: follow_user_2pc
--  Automatiza el protocolo 2PC usando dblink
-- ════════════════════════════════════════════════════════════
CREATE OR REPLACE PROCEDURE follow_user_2pc(
    p_follower_id INT,
    p_followed_id INT
)
LANGUAGE plpgsql AS $$
DECLARE
    v_dsn_follower  TEXT;
    v_dsn_followed  TEXT;
    v_txn_id        TEXT;
    v_same_node     BOOLEAN;
BEGIN
    v_txn_id       := format('follow_%s_%s_%s', p_follower_id, p_followed_id, EXTRACT(EPOCH FROM NOW())::BIGINT);
    v_dsn_follower := get_node_dsn(p_follower_id);
    v_dsn_followed := get_node_dsn(p_followed_id);
    v_same_node    := (get_node_number(p_follower_id) = get_node_number(p_followed_id));

    IF v_same_node THEN
        -- Mismo nodo: transacción local normal (sin 2PC)
        INSERT INTO follows (follower_id, followed_id) VALUES (p_follower_id, p_followed_id)
            ON CONFLICT DO NOTHING;
        UPDATE users SET following_count = following_count + 1 WHERE id = p_follower_id;
        UPDATE users SET followers_count = followers_count + 1 WHERE id = p_followed_id;
        RAISE NOTICE 'Follow local (mismo nodo) completado.';
        RETURN;
    END IF;

    -- Nodos distintos: usar 2PC vía dblink
    RAISE NOTICE 'Iniciando 2PC para follow % → %', p_follower_id, p_followed_id;

    -- FASE 1: PREPARE en ambos nodos
    PERFORM dblink_exec(v_dsn_follower, format(
        'BEGIN; INSERT INTO follows (follower_id, followed_id) VALUES (%s, %s) ON CONFLICT DO NOTHING; UPDATE users SET following_count = following_count + 1 WHERE id = %s; PREPARE TRANSACTION ''%s_n1'';',
        p_follower_id, p_followed_id, p_follower_id, v_txn_id
    ));

    PERFORM dblink_exec(v_dsn_followed, format(
        'BEGIN; UPDATE users SET followers_count = followers_count + 1 WHERE id = %s; PREPARE TRANSACTION ''%s_n2'';',
        p_followed_id, v_txn_id
    ));

    -- FASE 2: COMMIT en ambos nodos
    PERFORM dblink_exec(v_dsn_follower, format('COMMIT PREPARED ''%s_n1'';', v_txn_id));
    PERFORM dblink_exec(v_dsn_followed, format('COMMIT PREPARED ''%s_n2'';', v_txn_id));

    RAISE NOTICE '2PC completado exitosamente: txn_id=%', v_txn_id;

EXCEPTION WHEN OTHERS THEN
    -- Intentar rollback de ambos nodos en caso de fallo
    BEGIN
        PERFORM dblink_exec(v_dsn_follower, format('ROLLBACK PREPARED ''%s_n1'';', v_txn_id));
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    BEGIN
        PERFORM dblink_exec(v_dsn_followed, format('ROLLBACK PREPARED ''%s_n2'';', v_txn_id));
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    RAISE EXCEPTION '2PC abortado: %', SQLERRM;
END;
$$;

-- ── Uso del procedimiento ────────────────────────────────────
-- CALL follow_user_2pc(100, 4500);   -- cross-shard
-- CALL follow_user_2pc(100, 200);    -- mismo nodo (más rápido)
