#!/usr/bin/env python3
"""
generate_data.py
================
Generador de datos sintéticos para el Proyecto 2 — SI3009.
Dominio: Red social simplificada (usuarios, posts, follows, likes).

Uso:
    pip install faker
    python generate_data.py --users 10000 --posts 50000 --follows 30000 --likes 100000 --out ./data

Archivos generados:
    data/users_nodo{1,2,3}.sql   — usuarios particionados por rango de id
    data/posts_nodo{1,2,3}.sql   — posts particionados según su user_id
    data/follows_all.sql          — todos los follows (cross-shard)
    data/likes_all.sql            — todos los likes (cross-shard)
"""

import argparse
import os
import random
import sys
from datetime import datetime, timedelta, timezone

try:
    from faker import Faker
except ImportError:
    print("ERROR: Instala faker antes de ejecutar: pip install faker")
    sys.exit(1)

fake = Faker("es_CO")
Faker.seed(42)
random.seed(42)

# ── Rangos de sharding por nodo ──────────────────────────────
SHARD_RANGES = [
    (1, 3000),       # Nodo 1
    (3001, 6000),    # Nodo 2
    (6001, 10000),   # Nodo 3
]


def get_node(user_id: int) -> int:
    for i, (lo, hi) in enumerate(SHARD_RANGES, start=1):
        if lo <= user_id <= hi:
            return i
    raise ValueError(f"user_id {user_id} fuera de rango")


def random_dt(days_back: int = 365) -> str:
    """Genera un timestamp aleatorio en los últimos 'days_back' días."""
    delta = timedelta(seconds=random.randint(0, days_back * 86400))
    dt = datetime.now(tz=timezone.utc) - delta
    return dt.strftime("%Y-%m-%d %H:%M:%S+00")


def escape_str(s: str) -> str:
    """Escapa comillas simples para SQL."""
    return s.replace("'", "''")


def generate_users(n: int) -> list[dict]:
    """Genera n usuarios con ids de 1 a n."""
    print(f"  Generando {n} usuarios...", end="", flush=True)
    used_usernames = set()
    used_emails = set()
    users = []

    for uid in range(1, n + 1):
        # Generar username único
        while True:
            username = fake.user_name()[:49]
            if username not in used_usernames:
                used_usernames.add(username)
                break

        # Generar email único
        while True:
            email = fake.email()[:99]
            if email not in used_emails:
                used_emails.add(email)
                break

        bio = escape_str(fake.sentence(nb_words=10)[:200]) if random.random() > 0.3 else None

        users.append({
            "id": uid,
            "username": escape_str(username),
            "email": escape_str(email),
            "bio": bio,
            "followers_count": 0,
            "following_count": 0,
            "created_at": random_dt(730),
        })

        if uid % 1000 == 0:
            print(f"\r  Generando usuarios... {uid}/{n}", end="", flush=True)

    print(f"\r  ✓ {n} usuarios generados           ")
    return users


def generate_posts(user_ids: list[int], n: int) -> list[dict]:
    """Genera n posts distribuidos entre los usuarios."""
    print(f"  Generando {n} posts...", end="", flush=True)
    posts = []
    for i in range(1, n + 1):
        user_id = random.choice(user_ids)
        content = escape_str(fake.text(max_nb_chars=280))
        posts.append({
            "id": i,
            "user_id": user_id,
            "content": content,
            "likes_count": random.randint(0, 500),
            "created_at": random_dt(365),
        })
        if i % 5000 == 0:
            print(f"\r  Generando posts... {i}/{n}", end="", flush=True)
    print(f"\r  ✓ {n} posts generados              ")
    return posts


def generate_follows(user_ids: list[int], n: int) -> list[dict]:
    """Genera n relaciones de follow únicas."""
    print(f"  Generando {n} follows...", end="", flush=True)
    pairs = set()
    follows = []
    max_attempts = n * 10

    attempts = 0
    while len(follows) < n and attempts < max_attempts:
        attempts += 1
        follower = random.choice(user_ids)
        followed = random.choice(user_ids)
        if follower == followed:
            continue
        pair = (follower, followed)
        if pair in pairs:
            continue
        pairs.add(pair)
        follows.append({
            "follower_id": follower,
            "followed_id": followed,
            "created_at": random_dt(365),
        })

    print(f"\r  ✓ {len(follows)} follows generados             ")
    return follows


def generate_likes(user_ids: list[int], post_ids: list[int], n: int) -> list[dict]:
    """Genera n likes únicos (user, post)."""
    print(f"  Generando {n} likes...", end="", flush=True)
    pairs = set()
    likes = []
    max_attempts = n * 10

    attempts = 0
    while len(likes) < n and attempts < max_attempts:
        attempts += 1
        user_id = random.choice(user_ids)
        post_id = random.choice(post_ids)
        pair = (user_id, post_id)
        if pair in pairs:
            continue
        pairs.add(pair)
        likes.append({
            "user_id": user_id,
            "post_id": post_id,
            "created_at": random_dt(365),
        })

    print(f"\r  ✓ {len(likes)} likes generados              ")
    return likes


def write_sql_file(filepath: str, table: str, rows: list[dict], columns: list[str], chunk_size: int = 500):
    """Escribe los datos en un archivo SQL con INSERTs por lotes."""
    if not rows:
        return
    os.makedirs(os.path.dirname(filepath), exist_ok=True)

    with open(filepath, "w", encoding="utf-8") as f:
        f.write(f"-- Generado automáticamente por generate_data.py\n")
        f.write(f"-- {datetime.now().strftime('%Y-%m-%d %H:%M:%S')} | {len(rows)} registros\n\n")
        f.write("BEGIN;\n\n")

        for i in range(0, len(rows), chunk_size):
            chunk = rows[i : i + chunk_size]
            col_list = ", ".join(columns)
            f.write(f"INSERT INTO {table} ({col_list}) VALUES\n")

            values_list = []
            for row in chunk:
                vals = []
                for col in columns:
                    v = row.get(col)
                    if v is None:
                        vals.append("NULL")
                    elif isinstance(v, str):
                        vals.append(f"'{v}'")
                    elif isinstance(v, bool):
                        vals.append("TRUE" if v else "FALSE")
                    else:
                        vals.append(str(v))
                values_list.append(f"  ({', '.join(vals)})")

            f.write(",\n".join(values_list))
            f.write("\nON CONFLICT DO NOTHING;\n\n")

        f.write("COMMIT;\n")


def main():
    parser = argparse.ArgumentParser(
        description="Generador de datos sintéticos para la red social distribuida"
    )
    parser.add_argument("--users",   type=int, default=10000, help="Número de usuarios (default: 10000)")
    parser.add_argument("--posts",   type=int, default=50000, help="Número de posts (default: 50000)")
    parser.add_argument("--follows", type=int, default=30000, help="Número de follows (default: 30000)")
    parser.add_argument("--likes",   type=int, default=100000, help="Número de likes (default: 100000)")
    parser.add_argument("--out",     type=str, default="./data", help="Directorio de salida (default: ./data)")
    args = parser.parse_args()

    print(f"\n{'='*55}")
    print(f"  Generador de datos sintéticos — SI3009 Proyecto 2")
    print(f"{'='*55}")
    print(f"  Usuarios : {args.users:,}")
    print(f"  Posts    : {args.posts:,}")
    print(f"  Follows  : {args.follows:,}")
    print(f"  Likes    : {args.likes:,}")
    print(f"  Salida   : {args.out}")
    print(f"{'='*55}\n")

    os.makedirs(args.out, exist_ok=True)

    # ── 1. Generar usuarios ──────────────────────────────────
    users = generate_users(args.users)
    user_ids = [u["id"] for u in users]

    # Escribir usuarios particionados por nodo
    for nodo in range(1, 4):
        lo, hi = SHARD_RANGES[nodo - 1]
        nodo_users = [u for u in users if lo <= u["id"] <= hi]
        filepath = os.path.join(args.out, f"users_nodo{nodo}.sql")
        write_sql_file(
            filepath, "users", nodo_users,
            ["id", "username", "email", "bio", "followers_count", "following_count", "created_at"]
        )
        print(f"  → {filepath}  ({len(nodo_users)} usuarios)")

    # ── 2. Generar posts ─────────────────────────────────────
    posts = generate_posts(user_ids, args.posts)
    post_ids = [p["id"] for p in posts]

    for nodo in range(1, 4):
        lo, hi = SHARD_RANGES[nodo - 1]
        nodo_posts = [p for p in posts if lo <= p["user_id"] <= hi]
        filepath = os.path.join(args.out, f"posts_nodo{nodo}.sql")
        write_sql_file(
            filepath, "posts", nodo_posts,
            ["id", "user_id", "content", "likes_count", "created_at"]
        )
        print(f"  → {filepath}  ({len(nodo_posts)} posts)")

    # ── 3. Generar follows ────────────────────────────────────
    follows = generate_follows(user_ids, args.follows)
    filepath = os.path.join(args.out, "follows_all.sql")
    write_sql_file(
        filepath, "follows", follows,
        ["follower_id", "followed_id", "created_at"]
    )
    print(f"  → {filepath}  ({len(follows)} follows)")

    # ── 4. Generar likes ──────────────────────────────────────
    likes = generate_likes(user_ids, post_ids, args.likes)
    filepath = os.path.join(args.out, "likes_all.sql")
    write_sql_file(
        filepath, "likes", likes,
        ["user_id", "post_id", "created_at"]
    )
    print(f"  → {filepath}  ({len(likes)} likes)")

    # ── Resumen ───────────────────────────────────────────────
    print(f"\n{'='*55}")
    print(f"  ✓ Archivos SQL generados en: {args.out}/")
    print(f"{'='*55}")
    print(f"""
  Cargar en PostgreSQL (por nodo):
    psql -h localhost -p 5432 -U postgres -d socialdb -f {args.out}/users_nodo1.sql
    psql -h localhost -p 5432 -U postgres -d socialdb -f {args.out}/posts_nodo1.sql
    psql -h localhost -p 5432 -U postgres -d socialdb -f {args.out}/follows_all.sql
    psql -h localhost -p 5432 -U postgres -d socialdb -f {args.out}/likes_all.sql

    (Cambiar puerto 5432/5434/5436 para nodo 1/2/3)

  Cargar en CockroachDB (un solo endpoint):
    cockroach sql --insecure --host=localhost:26257 --database=socialdb \\
      < {args.out}/users_nodo1.sql
    # ... (repetir para cada archivo)
""")


if __name__ == "__main__":
    main()
