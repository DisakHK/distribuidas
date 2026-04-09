-- ============================================================
--  07_explain_queries.sql
--  Consultas representativas con EXPLAIN ANALYZE.
--  Documenta planes de ejecución para el informe.
--
--  Ejecutar en el nodo correspondiente según el user_id buscado.
--  Copiar la salida en resultados/ para el análisis.
-- ============================================================


-- ════════════════════════════════════════════════════════════
--  BLOQUE 1: Consultas OLTP — acceso por clave primaria
-- ════════════════════════════════════════════════════════════

-- Q1: Obtener perfil de usuario (Index Scan esperado)
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT id, username, email, followers_count, following_count, created_at
FROM users
WHERE id = 1500;
-- Resultado esperado: Index Scan using users_pkey | ~0.1 ms

-- Q2: Feed de un usuario — posts recientes (Index Scan)
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT id, content, likes_count, created_at
FROM posts
WHERE user_id = 1500
ORDER BY created_at DESC
LIMIT 20;
-- Resultado esperado: Index Scan using idx_posts_user_created | ~0.5 ms

-- Q3: Verificar si dos usuarios se siguen (Index Scan en PK)
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT EXISTS (
    SELECT 1 FROM follows
    WHERE follower_id = 100 AND followed_id = 4500
) AS se_siguen;
-- Resultado esperado: Index Scan using follows_pkey | ~0.1 ms

-- Q4: Insertar un like (prueba de escritura)
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
INSERT INTO likes (user_id, post_id)
VALUES (999, 1)
ON CONFLICT DO NOTHING;


-- ════════════════════════════════════════════════════════════
--  BLOQUE 2: Consultas OLAP — análisis agregado
-- ════════════════════════════════════════════════════════════

-- Q5: Top 10 usuarios con más posts (Hash Agg + Seq Scan)
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT
    u.username,
    COUNT(p.id) AS total_posts,
    AVG(p.likes_count) AS avg_likes
FROM users u
JOIN posts p ON u.id = p.user_id
GROUP BY u.id, u.username
ORDER BY total_posts DESC
LIMIT 10;
-- NOTA: Con datos grandes aparece HashAggregate + Index Scan posts

-- Q6: Posts más populares (por likes) en la última semana
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT
    p.id,
    p.content,
    COUNT(l.user_id) AS real_likes,
    p.likes_count     AS cached_likes
FROM posts p
JOIN likes l ON p.id = l.post_id
WHERE p.created_at > NOW() - INTERVAL '7 days'
GROUP BY p.id, p.content, p.likes_count
ORDER BY real_likes DESC
LIMIT 10;
-- NOTA: Debería usar idx_posts_recent (índice parcial)

-- Q7: Distribución de posts por hora del día
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT
    EXTRACT(HOUR FROM created_at) AS hora,
    COUNT(*)                       AS cantidad_posts
FROM posts
GROUP BY hora
ORDER BY hora;

-- Q8: Usuarios que siguen pero no son seguidos (análisis de asimetría)
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT
    f1.follower_id,
    u.username,
    COUNT(DISTINCT f1.followed_id) AS siguiendo,
    COUNT(DISTINCT f2.follower_id) AS seguidores
FROM follows f1
JOIN users u ON f1.follower_id = u.id
LEFT JOIN follows f2 ON f1.follower_id = f2.followed_id
GROUP BY f1.follower_id, u.username
HAVING COUNT(DISTINCT f1.followed_id) > COUNT(DISTINCT f2.follower_id) * 2
ORDER BY siguiendo DESC
LIMIT 20;


-- ════════════════════════════════════════════════════════════
--  BLOQUE 3: Consultas cross-shard (join distribuido manual)
-- ════════════════════════════════════════════════════════════
-- NOTA: Estas consultas se ejecutan con dblink desde la capa
-- de aplicación. El impacto en latencia se debe a múltiples
-- round-trips de red entre nodos.

-- Q9: Join entre posts de nodo1 y usuario de nodo2 (via dblink)
-- Ejecutar en pgnode1 con dblink a pgnode2:
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT *
FROM dblink(
    'host=pgnode2 port=5432 dbname=socialdb user=postgres password=postgres',
    'SELECT id, username FROM users WHERE id = 4500'
) AS remote_user(id INT, username TEXT);
-- NOTA: EXPLAIN no puede ver el plan interno de la query remota.
-- El costo principal es la latencia de red (~10 ms en docker-compose).

-- Q10: Demostrar ausencia de partition pruning en tabla no particionada
-- (PostgreSQL nativo no hace auto-sharding — la aplicación debe enrutar)
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT * FROM posts WHERE user_id BETWEEN 1 AND 3000;
-- Resultado: Seq Scan o Index Scan dependiendo de la selectividad.
-- En un NewSQL, esta query se ejecutaría en el nodo correcto automáticamente.


-- ════════════════════════════════════════════════════════════
--  BLOQUE 4: Comparativa CockroachDB (ejecutar en crdb1)
-- ════════════════════════════════════════════════════════════

-- Q11: Ver distribución de rangos
-- SHOW RANGES FROM TABLE posts;

-- Q12: Misma consulta analítica en CockroachDB
-- EXPLAIN ANALYZE SELECT u.username, COUNT(p.id) AS total_posts
-- FROM users u JOIN posts p ON u.id = p.user_id
-- GROUP BY u.username ORDER BY total_posts DESC LIMIT 10;

-- Q13: Ver leaseholders (líderes de rango)
-- SELECT range_id, start_key, end_key, lease_holder, replicas
-- FROM crdb_internal.ranges
-- WHERE table_name = 'posts'
-- LIMIT 10;


-- ════════════════════════════════════════════════════════════
--  BLOQUE 5: Script de benchmark automatizado
-- ════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS bench_results (
    id          SERIAL PRIMARY KEY,
    query_name  TEXT,
    motor       TEXT,
    config      TEXT,
    exec_ms     NUMERIC(10,3),
    rows_ret    BIGINT,
    ts          TIMESTAMPTZ DEFAULT NOW()
);

-- Función de benchmark genérica
CREATE OR REPLACE FUNCTION run_bench(
    p_name   TEXT,
    p_motor  TEXT,
    p_config TEXT,
    p_sql    TEXT,
    p_iters  INT DEFAULT 10
)
RETURNS TABLE(avg_ms NUMERIC, min_ms NUMERIC, max_ms NUMERIC, p99_ms NUMERIC)
LANGUAGE plpgsql AS $$
DECLARE
    v_start TIMESTAMPTZ;
    v_ms    NUMERIC;
    v_i     INT;
BEGIN
    FOR v_i IN 1..p_iters LOOP
        v_start := clock_timestamp();
        EXECUTE p_sql;
        v_ms := EXTRACT(EPOCH FROM (clock_timestamp() - v_start)) * 1000;

        INSERT INTO bench_results (query_name, motor, config, exec_ms)
        VALUES (p_name, p_motor, p_config, v_ms);
    END LOOP;

    RETURN QUERY
    SELECT
        ROUND(AVG(exec_ms), 3)                                     AS avg_ms,
        ROUND(MIN(exec_ms), 3)                                     AS min_ms,
        ROUND(MAX(exec_ms), 3)                                     AS max_ms,
        ROUND(PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY exec_ms), 3) AS p99_ms
    FROM bench_results
    WHERE query_name = p_name AND motor = p_motor AND config = p_config;
END;
$$;

-- Ejemplo de uso:
-- SELECT * FROM run_bench(
--     'feed_query',
--     'postgresql',
--     'sync_on',
--     'SELECT * FROM posts WHERE user_id = 1500 ORDER BY created_at DESC LIMIT 20',
--     50
-- );
