# SI3009 — Proyecto 2 — Setup completo
# Ejecutar desde PowerShell en la carpeta del proyecto

$ErrorActionPreference = "Continue"
$carpeta = $PSScriptRoot
if (-not $carpeta) { $carpeta = Get-Location }

Write-Host ""
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "   SI3009 - Proyecto 2: Arquitecturas Distribuidas" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host ""

# ── PASO 1: Generar datos sintéticos ─────────────────────────
Write-Host "[1/6] Generando datos sinteticos..." -ForegroundColor Yellow
pip install faker -q
if (-not (Test-Path ".\data")) { New-Item -ItemType Directory -Name "data" | Out-Null }
python generate_data.py --users 10000 --posts 50000 --follows 30000 --likes 100000 --out ./data
Write-Host "      OK - Datos generados en ./data/" -ForegroundColor Green

# ── PASO 2: Levantar PostgreSQL 3 nodos ──────────────────────
Write-Host ""
Write-Host "[2/6] Levantando 3 nodos PostgreSQL con Docker..." -ForegroundColor Yellow
Write-Host "      (Primera vez puede tardar 2-3 min descargando imagenes)" -ForegroundColor Gray

# docker-compose mínimo embebido directamente aquí
$compose = @"
version: "3.9"
services:
  pgnode1:
    image: postgres:15-alpine
    container_name: pgnode1
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: socialdb
    command: postgres -c max_prepared_transactions=20 -c wal_level=replica -c max_wal_senders=3 -c synchronous_commit=on
    ports: ["5432:5432"]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres -d socialdb"]
      interval: 5s
      timeout: 5s
      retries: 10

  pgnode2:
    image: postgres:15-alpine
    container_name: pgnode2
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: socialdb
    command: postgres -c max_prepared_transactions=20 -c wal_level=replica -c max_wal_senders=3 -c synchronous_commit=on
    ports: ["5434:5432"]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres -d socialdb"]
      interval: 5s
      timeout: 5s
      retries: 10

  pgnode3:
    image: postgres:15-alpine
    container_name: pgnode3
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: socialdb
    command: postgres -c max_prepared_transactions=20 -c wal_level=replica -c max_wal_senders=3 -c synchronous_commit=on
    ports: ["5436:5432"]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres -d socialdb"]
      interval: 5s
      timeout: 5s
      retries: 10

  crdb1:
    image: cockroachdb/cockroach:v23.2.0
    container_name: crdb1
    command: start --insecure --store=/cockroach/cockroach-data --listen-addr=crdb1:26257 --advertise-addr=crdb1:26257 --http-addr=0.0.0.0:8080 --join=crdb1:26257,crdb2:26257,crdb3:26257
    ports: ["26257:26257", "8080:8080"]

  crdb2:
    image: cockroachdb/cockroach:v23.2.0
    container_name: crdb2
    command: start --insecure --store=/cockroach/cockroach-data --listen-addr=crdb2:26257 --advertise-addr=crdb2:26257 --http-addr=0.0.0.0:8081 --join=crdb1:26257,crdb2:26257,crdb3:26257
    ports: ["26258:26257", "8081:8081"]

  crdb3:
    image: cockroachdb/cockroach:v23.2.0
    container_name: crdb3
    command: start --insecure --store=/cockroach/cockroach-data --listen-addr=crdb3:26257 --advertise-addr=crdb3:26257 --http-addr=0.0.0.0:8082 --join=crdb1:26257,crdb2:26257,crdb3:26257
    ports: ["26259:26257", "8082:8082"]
"@

$compose | Out-File -FilePath "docker-compose-proyecto.yml" -Encoding utf8
docker compose -f docker-compose-proyecto.yml up -d
Write-Host "      OK - Contenedores iniciados." -ForegroundColor Green

# ── PASO 3: Esperar a que los nodos estén listos ─────────────
Write-Host ""
Write-Host "[3/6] Esperando que PostgreSQL este listo..." -ForegroundColor Yellow
$nodos = @(
    @{nombre="pgnode1"; contenedor="pgnode1"},
    @{nombre="pgnode2"; contenedor="pgnode2"},
    @{nombre="pgnode3"; contenedor="pgnode3"}
)
foreach ($nodo in $nodos) {
    $listo = $false
    $intentos = 0
    while (-not $listo -and $intentos -lt 30) {
        $result = docker exec $nodo.contenedor pg_isready -U postgres -d socialdb 2>&1
        if ($LASTEXITCODE -eq 0) {
            $listo = $true
            Write-Host "      $($nodo.nombre) listo." -ForegroundColor Green
        } else {
            $intentos++
            Write-Host "      Esperando $($nodo.nombre)... ($intentos/30)" -ForegroundColor Gray
            Start-Sleep -Seconds 4
        }
    }
}

# ── PASO 4: Crear tablas en los 3 nodos ──────────────────────
Write-Host ""
Write-Host "[4/6] Creando tablas e indices en los 3 nodos..." -ForegroundColor Yellow

$sql_tablas = Get-Content "01_create_tables.sql" -Raw

foreach ($cfg in @(
    @{nombre="pgnode1"; contenedor="pgnode1"},
    @{nombre="pgnode2"; contenedor="pgnode2"},
    @{nombre="pgnode3"; contenedor="pgnode3"}
)) {
    Write-Host "      $($cfg.nombre)..." -ForegroundColor Gray
    $sql_tablas | docker exec -i $cfg.contenedor psql -U postgres -d socialdb | Out-Null
}
Write-Host "      OK - Tablas creadas en los 3 nodos." -ForegroundColor Green

# ── PASO 5: Cargar datos en cada nodo ────────────────────────
Write-Host ""
Write-Host "[5/6] Cargando datos (puede tardar 2-3 minutos)..." -ForegroundColor Yellow

$cargas = @(
    @{contenedor="pgnode1"; archivos=@("data\users_nodo1.sql","data\posts_nodo1.sql","data\follows_all.sql","data\likes_all.sql")},
    @{contenedor="pgnode2"; archivos=@("data\users_nodo2.sql","data\posts_nodo2.sql","data\follows_all.sql","data\likes_all.sql")},
    @{contenedor="pgnode3"; archivos=@("data\users_nodo3.sql","data\posts_nodo3.sql","data\follows_all.sql","data\likes_all.sql")}
)

foreach ($carga in $cargas) {
    Write-Host "      Cargando en $($carga.contenedor)..." -ForegroundColor Gray
    foreach ($archivo in $carga.archivos) {
        if (Test-Path $archivo) {
            Get-Content $archivo -Raw | docker exec -i $carga.contenedor psql -U postgres -d socialdb | Out-Null
        }
    }
    Write-Host "      $($carga.contenedor) OK" -ForegroundColor Green
}

# ── PASO 6: Inicializar CockroachDB y cargar datos ────────────
Write-Host ""
Write-Host "[6/6] Inicializando CockroachDB..." -ForegroundColor Yellow
Start-Sleep -Seconds 15

docker exec crdb1 cockroach init --insecure --host=crdb1:26257 2>&1 | Out-Null
Start-Sleep -Seconds 5

$sql_crdb = @"
CREATE DATABASE IF NOT EXISTS socialdb;
USE socialdb;
CREATE TABLE IF NOT EXISTS users (
    id INT PRIMARY KEY DEFAULT unique_rowid(),
    username VARCHAR(50) NOT NULL UNIQUE,
    email VARCHAR(100) NOT NULL UNIQUE,
    bio TEXT,
    followers_count INT NOT NULL DEFAULT 0,
    following_count INT NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE TABLE IF NOT EXISTS posts (
    id BIGINT PRIMARY KEY DEFAULT unique_rowid(),
    user_id INT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    content STRING NOT NULL,
    likes_count INT NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_posts_user ON posts(user_id, created_at DESC);
CREATE TABLE IF NOT EXISTS follows (
    follower_id INT NOT NULL REFERENCES users(id),
    followed_id INT NOT NULL REFERENCES users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (follower_id, followed_id)
);
CREATE TABLE IF NOT EXISTS likes (
    user_id INT NOT NULL REFERENCES users(id),
    post_id BIGINT NOT NULL REFERENCES posts(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, post_id)
);
"@

$sql_crdb | docker exec -i crdb1 cockroach sql --insecure --host=crdb1:26257
Write-Host "      Esquema CockroachDB creado." -ForegroundColor Green

Write-Host "      Cargando datos en CockroachDB..." -ForegroundColor Gray
foreach ($archivo in @("data\users_nodo1.sql","data\users_nodo2.sql","data\users_nodo3.sql",
                        "data\posts_nodo1.sql","data\posts_nodo2.sql","data\posts_nodo3.sql",
                        "data\follows_all.sql","data\likes_all.sql")) {
    if (Test-Path $archivo) {
        Get-Content $archivo -Raw | docker exec -i crdb1 cockroach sql --insecure --host=crdb1:26257 --database=socialdb 2>&1 | Out-Null
        Write-Host "      $archivo cargado" -ForegroundColor Gray
    }
}

# ── Verificación final ────────────────────────────────────────
Write-Host ""
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "   VERIFICACION FINAL" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan

if (-not (Test-Path "resultados")) { New-Item -ItemType Directory -Name "resultados" | Out-Null }

Write-Host ""
Write-Host "  Conteo PostgreSQL Nodo 1:" -ForegroundColor White
docker exec pgnode1 psql -U postgres -d socialdb -c "SELECT 'users' AS tabla, COUNT(*) FROM users UNION ALL SELECT 'posts', COUNT(*) FROM posts UNION ALL SELECT 'follows', COUNT(*) FROM follows UNION ALL SELECT 'likes', COUNT(*) FROM likes;"

Write-Host ""
Write-Host "  Conteo CockroachDB:" -ForegroundColor White
docker exec crdb1 cockroach sql --insecure --host=crdb1:26257 --database=socialdb -e "SELECT 'users' AS tabla, COUNT(*)::INT FROM users UNION ALL SELECT 'posts', COUNT(*)::INT FROM posts UNION ALL SELECT 'follows', COUNT(*)::INT FROM follows UNION ALL SELECT 'likes', COUNT(*)::INT FROM likes;" 2>&1

# Guardar resultados de experimentos
Write-Host ""
Write-Host "  Guardando resultados de experimentos..." -ForegroundColor Gray
Get-Content "07_explain_queries.sql" -Raw | docker exec -i pgnode1 psql -U postgres -d socialdb 2>&1 | Out-File "resultados\explain_analyze.txt"
docker exec crdb1 cockroach sql --insecure --host=crdb1:26257 --database=socialdb -e "SHOW RANGES FROM TABLE posts;" 2>&1 | Out-File "resultados\crdb_ranges.txt"
docker exec crdb1 cockroach node status --insecure --host=crdb1:26257 2>&1 | Out-File "resultados\crdb_nodes.txt"

Write-Host ""
Write-Host "=========================================================" -ForegroundColor Green
Write-Host "   TODO LISTO" -ForegroundColor Green
Write-Host "=========================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Panel CockroachDB:  http://localhost:8080" -ForegroundColor Cyan
Write-Host "  Resultados en:      .\resultados\" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Para apagar todo cuando termines:" -ForegroundColor White
Write-Host "  docker compose -f docker-compose-proyecto.yml down" -ForegroundColor Yellow
Write-Host ""
Read-Host "Presiona Enter para cerrar"
