#!/usr/bin/env bash
# ============================================================
#  newsql/yugabyte_setup.sh
#  Inicialización y configuración del cluster YugabyteDB
#  para el Proyecto 2 — SI3009
#
#  Prerrequisito: Docker con imagen yugabytedb/yugabyte
# ============================================================

set -euo pipefail

YB_HOST="localhost"
YSQL_PORT="5433"      # YugabyteDB expone YSQL en 5433 por defecto
YCQL_PORT="9042"
YB_DB="socialdb"
YSQL="psql -h ${YB_HOST} -p ${YSQL_PORT} -U yugabyte"

echo "=============================================="
echo "  YugabyteDB Setup — Proyecto 2 SI3009"
echo "=============================================="

# ── docker-compose para YugabyteDB ───────────────────────────
# Si prefieres usar YugabyteDB en lugar de CockroachDB,
# primero ejecuta este bloque para levantar el cluster:

cat << 'DOCKER_NOTE'
Para levantar el cluster YugabyteDB con Docker:

  docker network create yb-net

  docker run -d --name yb-node1 --network yb-net \
    -p 7000:7000 -p 9000:9000 -p 5433:5433 -p 9042:9042 \
    yugabytedb/yugabyte:2.20.0.0 \
    bin/yugabyted start \
    --advertise_address=yb-node1 \
    --join=yb-node1,yb-node2,yb-node3

  docker run -d --name yb-node2 --network yb-net \
    yugabytedb/yugabyte:2.20.0.0 \
    bin/yugabyted start \
    --advertise_address=yb-node2 \
    --join=yb-node1,yb-node2,yb-node3

  docker run -d --name yb-node3 --network yb-net \
    yugabytedb/yugabyte:2.20.0.0 \
    bin/yugabyted start \
    --advertise_address=yb-node3 \
    --join=yb-node1,yb-node2,yb-node3

  # Verificar estado
  docker exec -it yb-node1 bin/yugabyted status

DOCKER_NOTE

# ── 1. Crear base de datos ───────────────────────────────────
echo "[1/7] Creando base de datos ${YB_DB}..."
${YSQL} -c "CREATE DATABASE IF NOT EXISTS ${YB_DB};" 2>/dev/null || \
${YSQL} << EOF
SELECT 'CREATE DATABASE ${YB_DB}' WHERE NOT EXISTS (
    SELECT FROM pg_database WHERE datname = '${YB_DB}'
)\gexec
EOF

# ── 2. Crear tablas (dialecto PostgreSQL compatible) ──────────
echo "[2/7] Creando esquema en ${YB_DB}..."
${YSQL} -d "${YB_DB}" << 'EOF'
-- YugabyteDB soporta SQL compatible con PostgreSQL
-- El sharding es automático por la clave primaria (DocDB)

CREATE TABLE IF NOT EXISTS users (
    id              BIGSERIAL    PRIMARY KEY,
    username        VARCHAR(50)  NOT NULL,
    email           VARCHAR(100) NOT NULL,
    bio             TEXT,
    followers_count INT          NOT NULL DEFAULT 0,
    following_count INT          NOT NULL DEFAULT 0,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    UNIQUE (username),
    UNIQUE (email)
) SPLIT INTO 3 TABLETS;
-- SPLIT INTO 3 TABLETS: distribuye la tabla en 3 tablets desde el inicio

CREATE TABLE IF NOT EXISTS posts (
    id          BIGSERIAL   PRIMARY KEY,
    user_id     BIGINT      NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    content     TEXT        NOT NULL CHECK (char_length(content) <= 280),
    likes_count INT         NOT NULL DEFAULT 0,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
) SPLIT INTO 3 TABLETS;

CREATE INDEX IF NOT EXISTS idx_posts_user_created
    ON posts(user_id, created_at DESC);

CREATE TABLE IF NOT EXISTS follows (
    follower_id BIGINT      NOT NULL REFERENCES users(id),
    followed_id BIGINT      NOT NULL REFERENCES users(id),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (follower_id, followed_id)
) SPLIT INTO 3 TABLETS;

CREATE INDEX IF NOT EXISTS idx_follows_followed ON follows(followed_id);

CREATE TABLE IF NOT EXISTS likes (
    user_id    BIGINT      NOT NULL REFERENCES users(id),
    post_id    BIGINT      NOT NULL REFERENCES posts(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, post_id)
) SPLIT INTO 3 TABLETS;

CREATE INDEX IF NOT EXISTS idx_likes_post ON likes(post_id);
EOF
echo "✓ Tablas creadas"

# ── 3. Ver distribución de tablets ──────────────────────────
echo "[3/7] Distribución de tablets..."
${YSQL} -d "${YB_DB}" << 'EOF'
-- Ver tablets de cada tabla
SELECT
    table_name,
    COUNT(*) AS num_tablets,
    SUM(sst_size) / 1024 / 1024 AS size_mb
FROM yb_table_properties('users')
UNION ALL
SELECT table_name, COUNT(*), SUM(sst_size)/1024/1024
FROM yb_table_properties('posts')
GROUP BY table_name;
EOF

# ── 4. Transacciones distribuidas (YSQL) ─────────────────────
echo "[4/7] Probando transacción distribuida..."
${YSQL} -d "${YB_DB}" << 'EOF'
-- En YugabyteDB las transacciones distribuidas son transparentes
-- No requiere PREPARE TRANSACTION ni 2PC manual
BEGIN;
INSERT INTO follows (follower_id, followed_id) VALUES (100, 4500)
ON CONFLICT DO NOTHING;
UPDATE users SET following_count = following_count + 1 WHERE id = 100;
UPDATE users SET followers_count = followers_count + 1 WHERE id = 4500;
COMMIT;
EOF

# ── 5. EXPLAIN ANALYZE (compatible PostgreSQL) ───────────────
echo "[5/7] Planes de ejecución..."
${YSQL} -d "${YB_DB}" << 'EOF'
-- YugabyteDB soporta EXPLAIN ANALYZE
EXPLAIN (ANALYZE, DIST, FORMAT TEXT)
SELECT id, content, likes_count, created_at
FROM posts
WHERE user_id = 1500
ORDER BY created_at DESC
LIMIT 20;
-- DIST: muestra información de distribución entre tablets
EOF

# ── 6. Simular fallo de nodo ─────────────────────────────────
echo "[6/7] Instrucciones para experimento de failover:"
cat << 'FAILOVER'

══════════════════════════════════════════════════════════
  EXPERIMENTO DE FAILOVER — YugabyteDB
══════════════════════════════════════════════════════════

1. Estado inicial:
   $ docker exec yb-node1 bin/yugabyted status

2. Detener un nodo:
   $ docker stop yb-node2

3. YugabyteDB requiere quórum de mayoría (2/3 nodos activos).
   El sistema sigue funcionando:
   $ psql -h localhost -p 5433 -U yugabyte -d socialdb \
     -c "SELECT COUNT(*) FROM posts;"

4. Ver reelección de líder de tablet:
   Abrir: http://localhost:7000/tablet-servers

5. Reincorporar el nodo:
   $ docker start yb-node2

6. El nodo sincroniza automáticamente via Raft.
   Estado después de ~30s: todos los tablets deben tener 3 réplicas.

FAILOVER

# ── 7. Comparativa PACELC ────────────────────────────────────
echo "[7/7] Configuración PACELC de YugabyteDB:"
${YSQL} -d "${YB_DB}" << 'EOF'
-- Ver nivel de aislamiento por defecto
SHOW transaction_isolation;

-- Ver configuración de replicación
SELECT * FROM yb_local_tablets LIMIT 5;
EOF

echo ""
echo "✓ Setup de YugabyteDB completado."
echo "  UI Admin: http://localhost:7000"
echo "  Conexión: psql -h localhost -p 5433 -U yugabyte -d socialdb"
