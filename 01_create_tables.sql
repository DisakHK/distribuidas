-- ============================================================
--  01_create_tables.sql
--  Ejecutar en CADA nodo PostgreSQL (pgnode1, pgnode2, pgnode3)
--  Base de datos: socialdb
--  Dominio: red social simplificada
-- ============================================================

-- Extensiones útiles
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- ── Tabla: users ─────────────────────────────────────────────
-- En cada nodo viven los usuarios del rango correspondiente.
-- user_id 1–3000 en nodo1, 3001–6000 en nodo2, 6001–10000 en nodo3.
CREATE TABLE IF NOT EXISTS users (
    id              SERIAL PRIMARY KEY,
    username        VARCHAR(50)  NOT NULL,
    email           VARCHAR(100) NOT NULL,
    bio             TEXT,
    followers_count INT          NOT NULL DEFAULT 0,
    following_count INT          NOT NULL DEFAULT 0,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_username UNIQUE (username),
    CONSTRAINT uq_email    UNIQUE (email)
);

-- ── Tabla: posts ─────────────────────────────────────────────
-- Cada nodo almacena los posts de sus usuarios (data locality).
CREATE TABLE IF NOT EXISTS posts (
    id         BIGSERIAL   PRIMARY KEY,
    user_id    INT         NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    content    TEXT        NOT NULL ,
    likes_count INT        NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── Tabla: follows ───────────────────────────────────────────
-- Tabla cross-shard: ambos follower_id y followed_id pueden
-- pertenecer a nodos distintos. Cada nodo mantiene una copia
-- de TODOS los follows (denormalización para evitar joins remotos).
CREATE TABLE IF NOT EXISTS follows (
    follower_id INT         NOT NULL,
    followed_id INT         NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (follower_id, followed_id)
);

-- ── Tabla: likes ─────────────────────────────────────────────
-- Igual que follows: tabla global replicada en todos los nodos.
CREATE TABLE IF NOT EXISTS likes (
    user_id    INT         NOT NULL,
    post_id    BIGINT      NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, post_id)
);

-- ── Índices ──────────────────────────────────────────────────
-- Aceleran las consultas OLTP más frecuentes.
CREATE INDEX IF NOT EXISTS idx_posts_user_id     ON posts(user_id);
CREATE INDEX IF NOT EXISTS idx_posts_created_at  ON posts(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_follows_followed   ON follows(followed_id);
CREATE INDEX IF NOT EXISTS idx_likes_post_id      ON likes(post_id);
CREATE INDEX IF NOT EXISTS idx_users_created_at   ON users(created_at);

-- ── Comentarios de documentación ─────────────────────────────
COMMENT ON TABLE users   IS 'Usuarios de la red social. Sharding por rango de id.';
COMMENT ON TABLE posts   IS 'Publicaciones. Co-localizado con el nodo del autor (user_id).';
COMMENT ON TABLE follows IS 'Relaciones de seguimiento. Replicada en todos los nodos.';
COMMENT ON TABLE likes   IS 'Reacciones a posts. Replicada en todos los nodos.';
