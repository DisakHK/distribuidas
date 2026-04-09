#!/usr/bin/env bash
# ============================================================
#  newsql/cockroachdb_setup.sh
#  Inicialización y configuración del cluster CockroachDB
#  para el Proyecto 2 — SI3009
#
#  Prerrequisito: docker-compose up crdb1 crdb2 crdb3 crdb-init
# ============================================================

set -euo pipefail

CRDB_HOST="localhost"
CRDB_PORT="26257"
CRDB_DB="socialdb"
SQL="cockroach sql --insecure --host=${CRDB_HOST}:${CRDB_PORT}"

echo "=============================================="
echo "  CockroachDB Setup — Proyecto 2 SI3009"
echo "=============================================="

# ── 1. Verificar que el cluster esté activo ──────────────────
echo "[1/8] Verificando estado del cluster..."
cockroach node status --insecure --host="${CRDB_HOST}:${CRDB_PORT}" || {
    echo "ERROR: El cluster no está disponible. Ejecuta primero:"
    echo "  docker-compose up -d crdb1 crdb2 crdb3 crdb-init"
    exit 1
}

# ── 2. Crear base de datos ───────────────────────────────────
echo "[2/8] Creando base de datos ${CRDB_DB}..."
${SQL} --execute="CREATE DATABASE IF NOT EXISTS ${CRDB_DB};"

# ── 3. Crear esquema ─────────────────────────────────────────
echo "[3/8] Creando tablas en ${CRDB_DB}..."
${SQL} --database="${CRDB_DB}" << 'EOF'
-- Tabla users con clave primaria UUID para distribución uniforme
CREATE TABLE IF NOT EXISTS users (
    id              INT          PRIMARY KEY DEFAULT unique_rowid(),
    username        VARCHAR(50)  NOT NULL UNIQUE,
    email           VARCHAR(100) NOT NULL UNIQUE,
    bio             TEXT,
    followers_count INT          NOT NULL DEFAULT 0,
    following_count INT          NOT NULL DEFAULT 0,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- posts: co-localizado con users por user_id usando INTERLEAVE (deprecated en v22+)
-- En v22+ se usa locality-optimized search y table locality
CREATE TABLE IF NOT EXISTS posts (
    id          INT         PRIMARY KEY DEFAULT unique_rowid(),
    user_id     INT         NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    content     STRING      NOT NULL CHECK (length(content) <= 280),
    likes_count INT         NOT NULL DEFAULT 0,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    INDEX idx_posts_user_created (user_id, created_at DESC)
);

CREATE TABLE IF NOT EXISTS follows (
    follower_id INT         NOT NULL REFERENCES users(id),
    followed_id INT         NOT NULL REFERENCES users(id),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (follower_id, followed_id),
    INDEX idx_follows_followed (followed_id)
);

CREATE TABLE IF NOT EXISTS likes (
    user_id    INT         NOT NULL REFERENCES users(id),
    post_id    INT         NOT NULL REFERENCES posts(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, post_id),
    INDEX idx_likes_post (post_id)
);

-- Tabla para resultados de benchmark
CREATE TABLE IF NOT EXISTS bench_results (
    id         INT         PRIMARY KEY DEFAULT unique_rowid(),
    query_name STRING,
    motor      STRING,
    config     STRING,
    exec_ms    DECIMAL(10,3),
    ts         TIMESTAMPTZ DEFAULT NOW()
);
EOF
echo "✓ Tablas creadas"

# ── 4. Configurar cluster settings ───────────────────────────
echo "[4/8] Configurando cluster settings..."
${SQL} --database="${CRDB_DB}" << 'EOF'
-- Habilitar merge de rangos pequeños
SET CLUSTER SETTING kv.range_merge.queue_enabled = true;

-- Tiempo antes de declarar un nodo como muerto
SET CLUSTER SETTING server.time_until_store_dead = '1m30s';

-- Rebalanceo agresivo para experimentos
SET CLUSTER SETTING kv.allocator.load_based_rebalancing = 'leases and replicas';

-- Habilitar statements statistics
SET CLUSTER SETTING sql.metrics.statement_details.enabled = true;

-- Factor de replicación por defecto (3 para nuestro cluster)
ALTER RANGE default CONFIGURE ZONE USING num_replicas = 3;
EOF
echo "✓ Cluster settings configurados"

# ── 5. Ver distribución de rangos ─────────────────────────────
echo "[5/8] Verificando distribución de rangos inicial..."
${SQL} --database="${CRDB_DB}" --execute="SHOW RANGES FROM TABLE users;"
${SQL} --database="${CRDB_DB}" --execute="SHOW RANGES FROM TABLE posts;"

# ── 6. Cargar datos sintéticos ────────────────────────────────
echo "[6/8] Cargando datos sintéticos..."
if [ -f "../data/users_nodo1.sql" ]; then
    for f in ../data/users_nodo*.sql; do
        echo "  Cargando $f..."
        ${SQL} --database="${CRDB_DB}" < "$f"
    done
    for f in ../data/posts_nodo*.sql; do
        echo "  Cargando $f..."
        ${SQL} --database="${CRDB_DB}" < "$f"
    done
    ${SQL} --database="${CRDB_DB}" < "../data/follows_all.sql"
    ${SQL} --database="${CRDB_DB}" < "../data/likes_all.sql"
    echo "✓ Datos cargados"
else
    echo "  Datos sintéticos no encontrados. Ejecuta primero: python generate_data.py"
fi

# ── 7. Experimento: observar auto-sharding ────────────────────
echo "[7/8] Observando distribución de rangos post-carga..."
${SQL} --database="${CRDB_DB}" << 'EOF'
-- Ver cuántos rangos tiene cada tabla
SELECT
    descriptor_name AS tabla,
    COUNT(*)        AS num_rangos
FROM crdb_internal.ranges
WHERE descriptor_name IN ('users', 'posts', 'follows', 'likes')
GROUP BY descriptor_name
ORDER BY num_rangos DESC;

-- Ver leaseholders por nodo
SELECT
    lease_holder_locality,
    COUNT(*) AS rangos_asignados
FROM crdb_internal.ranges
WHERE descriptor_name IN ('users', 'posts', 'follows', 'likes')
GROUP BY lease_holder_locality;
EOF

# ── 8. Experimento: failover ──────────────────────────────────
echo "[8/8] Script de experimento de failover listo."
cat << 'FAILOVER_INSTRUCTIONS'

═══════════════════════════════════════════════════════════════
  EXPERIMENTO DE FAILOVER — Instrucciones
═══════════════════════════════════════════════════════════════

1. Verificar estado inicial del cluster:
   $ cockroach node status --insecure --host=localhost:26257

2. Detener un nodo (simular fallo):
   $ docker stop crdb2

3. Observar que el cluster sigue funcionando (2/3 nodos = quórum):
   $ cockroach sql --insecure --host=localhost:26257 \
     --database=socialdb \
     --execute="SELECT COUNT(*) FROM posts;"

4. Verificar que CockroachDB movió los leaseholders automáticamente:
   $ cockroach sql --insecure --host=localhost:26257 \
     --database=socialdb \
     --execute="SELECT lease_holder, COUNT(*) FROM crdb_internal.ranges GROUP BY 1;"

5. Reincorporar el nodo caído:
   $ docker start crdb2

6. Observar rebalanceo automático (puede tardar ~30 segundos):
   $ watch -n 2 "cockroach node status --insecure --host=localhost:26257"

7. Verificar datos íntegros tras el failover:
   $ cockroach sql --insecure --host=localhost:26257 \
     --database=socialdb \
     --execute="SELECT COUNT(*) FROM users; SELECT COUNT(*) FROM posts;"

FAILOVER_INSTRUCTIONS

echo ""
echo "✓ Setup de CockroachDB completado."
echo "  UI Admin: http://localhost:8080"
echo "  Conexión: cockroach sql --insecure --host=localhost:26257 --database=socialdb"
