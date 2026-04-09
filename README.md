# SI3009 — Proyecto 2: Arquitecturas Distribuidas

> **Curso:** Bases de Datos Avanzadas · 2026-1  
> **Dominio:** Red social simplificada (usuarios, posts, follows, likes)  
> **Motores evaluados:** PostgreSQL 15 (manual) · CockroachDB v23.2 · YugabyteDB 2.20

---

## Tabla de contenidos

1. [Estructura del repositorio](#1-estructura-del-repositorio)
2. [Dominio y modelo de datos](#2-dominio-y-modelo-de-datos)
3. [Fundamentos teóricos](#3-fundamentos-teóricos)
4. [Arquitectura del sistema](#4-arquitectura-del-sistema)
5. [Inicio rápido](#5-inicio-rápido)
6. [PostgreSQL: configuración distribuida manual](#6-postgresql-configuración-distribuida-manual)
7. [NewSQL: CockroachDB / YugabyteDB](#7-newsql-cockroachdb--yugabytedb)
8. [Experimentos y resultados](#8-experimentos-y-resultados)
9. [Análisis comparativo final](#9-análisis-comparativo-final)
10. [Análisis crítico](#10-análisis-crítico)
11. [Generador de datos sintéticos](#11-generador-de-datos-sintéticos)

---

## 1. Estructura del repositorio

```
/
├── infra/
│   ├── docker-compose.yml          # Red con latencia simulada entre nodos
│   ├── pg_hba.conf                 # Configuración de autenticación PostgreSQL
│   └── prometheus/                 # Métricas de monitoreo (opcional)
├── scripts/
│   ├── 01_create_tables.sql        # Esquema base (aplicar en cada nodo)
│   ├── 02_indexes.sql              # Índices adicionales y estadísticas
│   ├── 03_inserts.sql              # Datos de prueba mínimos
│   ├── 04_routing.sql              # Lógica de enrutamiento con funciones PL/pgSQL + dblink
│   ├── 05_2pc.sql                  # Transacciones distribuidas con PREPARE / COMMIT PREPARED
│   ├── 06_replication.sql          # Benchmark synchronous_commit + guía de failover
│   └── 07_explain_queries.sql      # Consultas con EXPLAIN ANALYZE documentadas
├── newsql/
│   ├── cockroachdb_setup.sh        # Inicialización y experimentos del cluster CockroachDB
│   └── yugabyte_setup.sh           # Inicialización y experimentos del cluster YugabyteDB
├── data/                           # Archivos SQL generados (git-ignored, producidos con generate_data.py)
├── resultados/
│   ├── latencia_escritura.csv      # Datos de benchmark de escritura
│   ├── latencia_lectura.csv        # Datos de benchmark de lectura
│   └── graficas/                   # Gráficas de los experimentos
├── docs/
│   └── analisis_critico.md         # Análisis crítico del equipo
├── generate_data.py                # Generador de datos sintéticos (Faker)
└── README.md
```

---

## 2. Dominio y modelo de datos

### Contexto

Se modela una **red social simplificada** donde los usuarios pueden publicar contenido, seguir a otros usuarios y reaccionar a publicaciones mediante likes. Este dominio es especialmente adecuado para experimentar con bases de datos distribuidas porque:

- Permite segmentar datos naturalmente por `user_id` (data locality).
- Genera patrones de acceso mixtos: OLTP frecuente (publicar, dar like, seguir) y OLAP analítico (usuarios más populares, posts virales).
- Tiene relaciones cross-shard reales (un usuario de un shard puede seguir a otro de un shard diferente), lo que fuerza a enfrentar el problema del join distribuido y las transacciones 2PC.

**Volúmenes estimados:**

| Tabla   | Registros | Tamaño aprox. |
|---------|-----------|---------------|
| users   | 10.000    | ~2 MB         |
| posts   | 50.000    | ~15 MB        |
| follows | 30.000    | ~5 MB         |
| likes   | 100.000   | ~12 MB        |

### Esquema SQL

```sql
CREATE TABLE users (
    id              SERIAL PRIMARY KEY,
    username        VARCHAR(50)  NOT NULL UNIQUE,
    email           VARCHAR(100) NOT NULL UNIQUE,
    bio             TEXT,
    followers_count INT          NOT NULL DEFAULT 0,
    following_count INT          NOT NULL DEFAULT 0,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE TABLE posts (
    id          BIGSERIAL   PRIMARY KEY,
    user_id     INT         NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    content     TEXT        NOT NULL CHECK (char_length(content) <= 280),
    likes_count INT         NOT NULL DEFAULT 0,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE follows (
    follower_id INT NOT NULL,
    followed_id INT NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (follower_id, followed_id)
);

CREATE TABLE likes (
    user_id    INT    NOT NULL,
    post_id    BIGINT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, post_id)
);
```

### Operaciones OLTP

```sql
-- Crear un post
INSERT INTO posts (user_id, content) VALUES ($1, $2);

-- Dar like
INSERT INTO likes (user_id, post_id) VALUES ($1, $2) ON CONFLICT DO NOTHING;

-- Seguir a otro usuario (cross-shard → requiere 2PC en PostgreSQL)
CALL follow_user_2pc($follower_id, $followed_id);

-- Feed de un usuario (posts recientes)
SELECT id, content, likes_count, created_at
FROM posts WHERE user_id = $1
ORDER BY created_at DESC LIMIT 20;
```

### Operaciones OLAP

```sql
-- Top 10 usuarios con más publicaciones
SELECT u.username, COUNT(p.id) AS total_posts
FROM users u JOIN posts p ON u.id = p.user_id
GROUP BY u.username ORDER BY total_posts DESC LIMIT 10;

-- Posts más populares por likes reales
SELECT p.id, p.content, COUNT(l.user_id) AS total_likes
FROM posts p JOIN likes l ON p.id = l.post_id
GROUP BY p.id, p.content ORDER BY total_likes DESC LIMIT 10;
```

---

## 3. Fundamentos teóricos

### 3.1 Teorema CAP

El teorema CAP establece que un sistema distribuido solo puede garantizar **dos de las tres** propiedades de forma simultánea:

- **Consistencia (C):** todos los nodos ven los mismos datos en el mismo instante.
- **Disponibilidad (A):** cada solicitud recibe una respuesta, aunque no sea la más reciente.
- **Tolerancia a particiones (P):** el sistema continúa operando aunque se pierda comunicación entre nodos.

En la práctica, las particiones de red son inevitables, por lo que el trade-off real es entre **CP** (consistencia fuerte, puede rechazar peticiones) y **AP** (alta disponibilidad, acepta datos desactualizados).

| Motor | Posición CAP |
|-------|-------------|
| PostgreSQL (nodo único) | CA |
| PostgreSQL (sync, multi-nodo) | CP |
| PostgreSQL (async, multi-nodo) | AP |
| CockroachDB / YugabyteDB | CP |

### 3.2 Modelo PACELC

PACELC extiende CAP para incluir el comportamiento **sin partición** (operación normal):

- **P → A o C:** en caso de partición, ¿el sistema elige disponibilidad o consistencia?
- **E → L o C:** en operación normal, ¿el sistema elige menor latencia o mayor consistencia?

| Motor | Configuración | En partición | En operación normal |
|-------|---------------|--------------|---------------------|
| PostgreSQL | `synchronous_commit=off` | PA | EL |
| PostgreSQL | `synchronous_commit=on` | PC | EC |
| CockroachDB / YugabyteDB | default | PC | EC |

### 3.3 ACID vs Consistencia eventual

**ACID** garantiza que las transacciones son completamente atómicas, consistentes, aisladas y durables. PostgreSQL implementa ACID de forma nativa en un único nodo. En configuración distribuida requiere 2PC explícito.

La **consistencia eventual** acepta lecturas desactualizadas (stale reads) a cambio de mayor disponibilidad y menor latencia. Los sistemas NewSQL ofrecen ACID distribuido sin sacrificar la escalabilidad horizontal.

### 3.4 Particionamiento horizontal (Sharding)

| Estrategia | Descripción | Pros | Contras |
|------------|-------------|------|---------|
| Por rango | Rangos continuos de la clave | Simple, preserva orden | Propenso a hot spots |
| Por hash | Distribución uniforme | Sin hot spots | Pierde orden natural |
| Por lista | Asignación explícita por valor | Control total | Rígido |

Este proyecto implementa **sharding por rango de `user_id`** para mantener todos los datos de un usuario en el mismo nodo (data locality), optimizando el acceso al feed individual.

### 3.5 Two-Phase Commit (2PC)

Protocolo para garantizar consistencia en transacciones multi-nodo:

1. **Fase Prepare:** el coordinador solicita a todos los participantes que preparen la transacción.
2. **Fase Commit/Abort:** si todos confirman, el coordinador emite commit. Si alguno falla, emite abort.

**Riesgo crítico:** si el coordinador falla entre fases, los participantes quedan bloqueados en estado `PREPARED` indefinidamente. Se detecta con:

```sql
SELECT gid, prepared, owner,
       EXTRACT(EPOCH FROM (NOW() - prepared)) AS segundos_bloqueada
FROM pg_prepared_xacts;
```

---

## 4. Arquitectura del sistema

```
                    ┌──────────────────────────────┐
                    │     Aplicación / API Layer    │
                    │   Lógica de enrutamiento      │
                    │   get_node_dsn(user_id)        │
                    └────────────┬─────────────────┘
                                 │
              ┌──────────────────┼──────────────────┐
         u≤3000               u≤6000              u≤10000
              │                  │                   │
   ┌──────────▼──────┐  ┌────────▼──────┐  ┌────────▼──────┐
   │   pgnode1:5432   │  │  pgnode2:5432 │  │  pgnode3:5432 │
   │   Primary        │  │  Primary      │  │  Primary      │
   │   shard 1–3000   │  │  shard 3–6k   │  │  shard 6–10k  │
   └──────┬───────────┘  └──────┬────────┘  └──────┬────────┘
          │ sync replic.         │ sync replic.       │ sync replic.
   ┌──────▼───────────┐  ┌──────▼────────┐  ┌──────▼────────┐
   │   pgnode1r:5432  │  │  pgnode2r     │  │  pgnode3r     │
   │   Réplica (RO)   │  │  Réplica (RO) │  │  Réplica (RO) │
   └──────────────────┘  └───────────────┘  └───────────────┘
         ←──────── 2PC (PREPARE / COMMIT PREPARED) ────────→

   ┌─────────────────────────────────────────────────────────┐
   │       CockroachDB / YugabyteDB — cluster 3 nodos        │
   │                                                          │
   │  ┌──────────┐     ┌──────────┐     ┌──────────┐         │
   │  │  crdb1   │◄───►│  crdb2   │◄───►│  crdb3   │         │
   │  │ :26257   │     │ :26258   │     │ :26259   │         │
   │  └──────────┘     └──────────┘     └──────────┘         │
   │    Auto-sharding · Raft consensus · failover automático  │
   └─────────────────────────────────────────────────────────┘
```

---

## 5. Inicio rápido

### Prerrequisitos

- Docker ≥ 24 y Docker Compose v2
- Python 3.10+ con `faker` instalado
- `psql` disponible en el PATH (cliente PostgreSQL)

### Paso 1: Generar datos sintéticos

```bash
pip install faker
python generate_data.py \
  --users 10000 \
  --posts 50000 \
  --follows 30000 \
  --likes 100000 \
  --out ./data
```

### Paso 2: Levantar la infraestructura PostgreSQL

```bash
cd infra
docker compose up -d pgnode1 pgnode2 pgnode3 pgnode1r pgnode2r pgnode3r
docker compose logs -f pgnode1   # Verificar que está listo
```

### Paso 3: Inicializar esquema en cada nodo

```bash
# Nodo 1 (puerto 5432)
psql -h localhost -p 5432 -U postgres -d socialdb -f scripts/01_create_tables.sql
psql -h localhost -p 5432 -U postgres -d socialdb -f scripts/02_indexes.sql
psql -h localhost -p 5432 -U postgres -d socialdb -f scripts/04_routing.sql
psql -h localhost -p 5432 -U postgres -d socialdb -f data/users_nodo1.sql
psql -h localhost -p 5432 -U postgres -d socialdb -f data/posts_nodo1.sql
psql -h localhost -p 5432 -U postgres -d socialdb -f data/follows_all.sql
psql -h localhost -p 5432 -U postgres -d socialdb -f data/likes_all.sql

# Nodo 2 (puerto 5434)
psql -h localhost -p 5434 -U postgres -d socialdb -f scripts/01_create_tables.sql
psql -h localhost -p 5434 -U postgres -d socialdb -f scripts/02_indexes.sql
psql -h localhost -p 5434 -U postgres -d socialdb -f data/users_nodo2.sql
psql -h localhost -p 5434 -U postgres -d socialdb -f data/posts_nodo2.sql
psql -h localhost -p 5434 -U postgres -d socialdb -f data/follows_all.sql
psql -h localhost -p 5434 -U postgres -d socialdb -f data/likes_all.sql

# Nodo 3 (puerto 5436)
psql -h localhost -p 5436 -U postgres -d socialdb -f scripts/01_create_tables.sql
psql -h localhost -p 5436 -U postgres -d socialdb -f scripts/02_indexes.sql
psql -h localhost -p 5436 -U postgres -d socialdb -f data/users_nodo3.sql
psql -h localhost -p 5436 -U postgres -d socialdb -f data/posts_nodo3.sql
psql -h localhost -p 5436 -U postgres -d socialdb -f data/follows_all.sql
psql -h localhost -p 5436 -U postgres -d socialdb -f data/likes_all.sql
```

### Paso 4: Levantar el cluster CockroachDB

```bash
cd infra
docker compose up -d crdb1 crdb2 crdb3 crdb-init
# Esperar ~30 segundos para que el cluster se inicialice
bash ../newsql/cockroachdb_setup.sh
```

---

## 6. PostgreSQL: configuración distribuida manual

### 6.1 Estrategia de sharding por rango

| Nodo     | Rango `user_id` | Puerto host |
|----------|----------------|-------------|
| pgnode1  | 1 – 3000       | 5432        |
| pgnode2  | 3001 – 6000    | 5434        |
| pgnode3  | 6001 – 10000   | 5436        |

### 6.2 Lógica de enrutamiento (PL/pgSQL + dblink)

```sql
-- La aplicación determina el nodo antes de ejecutar cada operación
SELECT get_node_dsn(1500);  -- → host=pgnode1 port=5432 ...
SELECT get_node_dsn(4000);  -- → host=pgnode2 port=5432 ...
SELECT get_node_dsn(8000);  -- → host=pgnode3 port=5432 ...
```

La función `get_node_dsn()` implementa las reglas de enrutamiento. En un sistema NewSQL esta lógica es transparente para el desarrollador.

### 6.3 Experimento: `synchronous_commit`

Ejecutar `scripts/06_replication.sql` para comparar las tres configuraciones:

| Configuración | Latencia p99 | Riesgo de pérdida |
|---------------|-------------|-------------------|
| `off` (asincrónico) | ~3 ms | Hasta las últimas transacciones no replicadas |
| `on` (sincrónico)   | ~14 ms | Ninguno |
| `remote_apply`      | ~28 ms | Ninguno + réplica ya aplicó el cambio |

### 6.4 Transacciones 2PC

Ver `scripts/05_2pc.sql` para los tres escenarios documentados:
- Escenario 1: 2PC exitoso cross-shard
- Escenario 2: 2PC con ROLLBACK por fallo simulado
- Escenario 3: Bloqueo por falla del coordinador (y cómo detectarlo)

### 6.5 Proceso de failover

```bash
# 1. Simular caída del Primary de Nodo 1
docker stop pgnode1

# 2. Promover la réplica
docker exec -it pgnode1r pg_ctl promote -D /var/lib/postgresql/data

# 3. Verificar nueva Primary
psql -h localhost -p 5433 -U postgres -c "SELECT pg_is_in_recovery();"
# → f (es Primary ahora)

# 4. Actualizar enrutamiento de la aplicación para apuntar al puerto 5433
```

---

## 7. NewSQL: CockroachDB / YugabyteDB

### 7.1 Inicialización

```bash
# CockroachDB (automatizado)
bash newsql/cockroachdb_setup.sh

# YugabyteDB (alternativa)
bash newsql/yugabyte_setup.sh
```

### 7.2 Auto-sharding: diferencia clave

En CockroachDB/YugabyteDB no se definen particiones. El motor divide los datos en **rangos de claves** (~512 MB por defecto) y los redistribuye automáticamente:

```sql
-- Ver distribución actual de rangos
SHOW RANGES FROM TABLE posts;

-- Ver qué nodo tiene el leaseholder de cada rango
SELECT range_id, lease_holder, replicas
FROM crdb_internal.ranges
WHERE table_name = 'posts';
```

### 7.3 Transacciones distribuidas sin 2PC manual

```sql
-- En NewSQL las transacciones cross-shard son transparentes:
BEGIN;
INSERT INTO follows (follower_id, followed_id) VALUES (100, 4500);
UPDATE users SET following_count = following_count + 1 WHERE id = 100;
UPDATE users SET followers_count = followers_count + 1 WHERE id = 4500;
COMMIT;
-- El motor gestiona el consenso Raft internamente
```

### 7.4 Experimento de failover automático

```bash
# Detener un nodo
docker stop crdb2

# El cluster sigue operando (2/3 nodos = quórum mantenido)
cockroach sql --insecure --host=localhost:26257 \
  --database=socialdb \
  --execute="SELECT COUNT(*) FROM posts;"

# Reincorporar el nodo
docker start crdb2
# El nodo sincroniza automáticamente via Raft en ~30 segundos
```

---

## 8. Experimentos y resultados

### 8.1 Latencia de escritura

| Escenario | Motor | Configuración | p50 (ms) | p99 (ms) |
|-----------|-------|---------------|----------|----------|
| INSERT post (shard local) | PostgreSQL | async | ~1.5 | ~3 |
| INSERT post (shard local) | PostgreSQL | sync | ~6 | ~14 |
| INSERT post | CockroachDB | default | ~4 | ~12 |
| Transacción 2PC cross-shard | PostgreSQL | manual | ~25 | ~60 |
| Transacción cross-shard | CockroachDB | default | ~8 | ~20 |

### 8.2 Latencia de lectura

| Escenario | Motor | p50 (ms) | p99 (ms) |
|-----------|-------|----------|----------|
| SELECT posts por user_id (shard local) | PostgreSQL | ~0.8 | ~2 |
| SELECT posts por user_id | CockroachDB | ~2 | ~6 |
| Consulta analítica GROUP BY (un nodo) | PostgreSQL | ~40 | ~90 |
| Consulta analítica GROUP BY | CockroachDB | ~30 | ~70 |
| Join cross-shard (vía dblink) | PostgreSQL | ~80 | ~200 |
| Join cross-shard (nativo) | CockroachDB | ~35 | ~90 |

### 8.3 Impacto del número de réplicas sincrónicas en PostgreSQL

| Réplicas sincrónicas | Latencia escritura p99 | Disponibilidad ante 1 fallo |
|---------------------|----------------------|-------------------------------|
| 0 (async) | ~3 ms | Alta (posible pérdida de datos) |
| 1 (sync) | ~14 ms | Alta |
| 2 (sync) | ~28 ms | Alta |

### 8.4 Planes de ejecución representativos

```sql
-- Q1: Acceso por clave (nodo local) — resultado esperado: Index Scan
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM posts WHERE user_id = 1500
ORDER BY created_at DESC LIMIT 20;
-- → Index Scan using idx_posts_user_created | Execution Time: ~0.8 ms

-- Q2: Consulta analítica — resultado esperado: Hash Aggregate
EXPLAIN (ANALYZE, BUFFERS)
SELECT u.username, COUNT(p.id) AS total_posts
FROM users u JOIN posts p ON u.id = p.user_id
GROUP BY u.username ORDER BY total_posts DESC LIMIT 10;
-- → HashAggregate + Index Scan posts | Execution Time: ~42 ms

-- Q3: Detección de transacciones 2PC bloqueadas
SELECT gid, prepared, EXTRACT(EPOCH FROM (NOW()-prepared)) AS seg
FROM pg_prepared_xacts ORDER BY prepared;
```

---

## 9. Análisis comparativo final

| Dimensión | PostgreSQL (manual) | CockroachDB / YugabyteDB |
|-----------|--------------------|-----------------------------|
| **Particionamiento** | Manual por rango/hash/lista. Enrutamiento en la aplicación | Automático (auto-sharding). Transparente para el desarrollador |
| **Replicación** | Líder-seguidor, configuración manual vía `postgresql.conf` | Protocolo Raft, automático y continuo |
| **Consistencia** | ACID en un nodo. Distribuida requiere 2PC manual | Consistencia serializable global por defecto |
| **Modelo CAP** | CA (nodo único) → CP o AP según `synchronous_commit` | CP siempre |
| **PACELC** | PA/EL (async) o PC/EC (sync) | PC/EC |
| **Transacciones distribuidas** | No nativas. 2PC manual: `PREPARE` + `COMMIT PREPARED` | Nativas y transparentes. `BEGIN` / `COMMIT` estándar |
| **Failover** | Manual o semi-automático (Patroni). Riesgo de split-brain | Automático en ~6 segundos via Raft |
| **Tolerancia a fallos** | Depende de `synchronous_standby_names` | Quórum Raft: 3 nodos toleran 1 fallo |
| **Latencia escritura** | Muy baja async (~2 ms). Mayor sync (~15 ms) | Moderada (~4–12 ms) por overhead de consenso |
| **Latencia lectura** | Muy baja local (~0.8 ms) | Levemente mayor (~2 ms) |
| **Joins distribuidos** | Costosos. Combinación en la aplicación (~80 ms p50) | Optimización interna (~35 ms p50) |
| **Complejidad operativa** | Muy alta. Múltiples herramientas externas | Baja a media. El motor gestiona la distribución |
| **Complejidad de desarrollo** | Alta. El desarrollador gestiona topología y 2PC | Baja. SQL estándar, distribución transparente |
| **Compatibilidad SQL** | SQL estándar completo + extensiones PostgreSQL | Dialecto PostgreSQL (algunas extensiones no disponibles) |
| **Costo infraestructura** | Bajo en instancias propias. Alto en mantenimiento | Mayor en recursos. Menor costo operativo |
| **Madurez** | Muy madura (30+ años) | Relativamente joven (desde 2015–2017) |

---

## 10. Análisis crítico

Ver el documento completo en [`docs/analisis_critico.md`](docs/analisis_critico.md).

**Puntos clave:**

**Complejidad operativa real.** Configurar `synchronous_commit = on` toma diez segundos. Entender cuándo ese trade-off de latencia/consistencia vale la pena en producción, y comunicarlo al equipo de negocio, toma meses. El 2PC bloquea recursos cuando el coordinador falla — un riesgo que los benchmarks no capturan.

**CockroachDB: promesa y realidad.** El auto-sharding es genuinamente impresionante. El overhead de Raft (~4-12 ms vs ~1.5 ms de PostgreSQL async) es irrelevante para una red social pero podría ser prohibitivo para trading de alta frecuencia.

**Impacto en costos.** La misma arquitectura del proyecto en producción (3× EC2 m5.xlarge + 1 DBA senior + monitoreo) supera $1.000 USD/mes. Amazon RDS Multi-AZ cuesta ~$400-800/mes e incluye failover automático, backups y soporte. El punto de equilibrio económico depende del tamaño del equipo y del nivel de control requerido.

**Contexto colombiano.** La adopción de bases de datos distribuidas en Colombia está liderada por fintechs (Nequi, Addi) y delivery (Rappi). La mayoría de empresas medianas prefieren PostgreSQL con RDS administrado. El conocimiento de CockroachDB aparece en menos del 5% de las ofertas de trabajo relacionadas con bases de datos, lo que representa una ventaja competitiva real para quien lo domina.

---

## 11. Generador de datos sintéticos

### Instalación

```bash
pip install faker
```

### Uso

```bash
python generate_data.py \
  --users 10000 \
  --posts 50000 \
  --follows 30000 \
  --likes 100000 \
  --out ./data
```

### Archivos generados

| Archivo | Contenido |
|---------|-----------|
| `data/users_nodo1.sql` | Usuarios con `id` 1–3000 |
| `data/users_nodo2.sql` | Usuarios con `id` 3001–6000 |
| `data/users_nodo3.sql` | Usuarios con `id` 6001–10000 |
| `data/posts_nodo{1,2,3}.sql` | Posts según el nodo del autor |
| `data/follows_all.sql` | Todos los follows (cross-shard) |
| `data/likes_all.sql` | Todos los likes (cross-shard) |

---

*Proyecto desarrollado para SI3009 Bases de Datos Avanzadas · Universidad · 2026-1*
