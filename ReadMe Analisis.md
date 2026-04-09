**SI3009 — Bases de Datos Avanzadas**

**Proyecto 2: Arquitecturas Distribuidas**

Escalabilidad, Replicación, Consistencia y Transacciones Distribuidas

*Dominio: Red social simplificada (usuarios, posts, follows, likes)*

**Motores evaluados:**

PostgreSQL 15 (distribuido manual) \| CockroachDB v23.2 (NewSQL)

**Arquitectura del sistema**

El sistema despliega dos clústeres independientes usando Docker Compose:

## Clúster PostgreSQL — 3 nodos con sharding manual

| **Contenedor** | **Rango user_id** | **Puerto host** | **Rol**                     |
|----------------|-------------------|-----------------|-----------------------------|
| pgnode1        | 1 – 3.000         | 5432            | Primary (lectura/escritura) |
| pgnode2        | 3.001 – 6.000     | 5434            | Primary (lectura/escritura) |
| pgnode3        | 6.001 – 10.000    | 5436            | Primary (lectura/escritura) |

Cada nodo Primary tiene configurado wal_level=replica y
max_wal_senders=3 para soportar réplicas. La estrategia de sharding es
por rango de user_id, lo que garantiza data locality: todos los datos de
un usuario están en el mismo nodo.

## Clúster CockroachDB — 3 nodos con auto-sharding

CockroachDB corre en 3 contenedores (crdb1, crdb2, crdb3) que se
comunican mediante el protocolo Raft. A diferencia de PostgreSQL, no se
configura ningún esquema de particionamiento: el motor distribuye los
datos automáticamente entre los nodos en rangos de ~512 MB.

El panel de administración de CockroachDB está disponible en
http://localhost:8080 y muestra en tiempo real: número de nodos activos,
rangos distribuidos, leaseholders y métricas de rendimiento.

**Datos sintéticos cargados**

Los datos fueron generados con el script generate_data.py usando la
librería Faker. Se generaron con una semilla fija (seed=42) para
garantizar reproducibilidad.

| **Tabla** | **Total registros** | **Distribución**               | **Tamaño aprox.** |
|-----------|---------------------|--------------------------------|-------------------|
| users     | 10.000              | 3.000 / 3.000 / 4.000 por nodo | ~2 MB             |
| posts     | 50.000              | ~15k / ~15k / ~20k por nodo    | ~15 MB            |
| follows   | 30.000              | Global (cross-shard)           | ~5 MB             |
| likes     | 100.000             | Global (cross-shard)           | ~12 MB            |

La distribución de posts no es exactamente uniforme porque depende de a
qué nodo pertenece cada user_id que los creó. Los follows y likes son
tablas globales replicadas en todos los nodos porque sus claves foraneas
pueden apuntar a usuarios en cualquier shard.

**Particionamiento (Sharding)**

##  PostgreSQL — Sharding manual por rango

PostgreSQL no es un motor distribuido de forma nativa. El sharding se
implementa manualmente: cada nodo tiene su propia instancia
independiente y la aplicación decide a cuál conectarse según el user_id.

La función de enrutamiento en PL/pgSQL es la siguiente:

> CREATE OR REPLACE FUNCTION get_node_dsn(p_user_id INT)
>
> RETURNS TEXT LANGUAGE plpgsql IMMUTABLE AS \$\$
>
> BEGIN
>
> IF p_user_id BETWEEN 1 AND 3000 THEN
>
> RETURN 'host=pgnode1 port=5432 dbname=socialdb user=postgres';
>
> ELSIF p_user_id BETWEEN 3001 AND 6000 THEN
>
> RETURN 'host=pgnode2 port=5432 dbname=socialdb user=postgres';
>
> ELSE
>
> RETURN 'host=pgnode3 port=5432 dbname=socialdb user=postgres';
>
> END IF;
>
> END; \$\$;

Este es el “reto de enrutamiento” que menciona el enunciado: en
PostgreSQL, la aplicación debe conocer la topología física del sistema
para funcionar correctamente.

## CockroachDB — Auto-sharding transparente

En CockroachDB no existe función de enrutamiento. El cliente conecta a
cualquier nodo y el motor internamente decide dónde está el dato. Los
rangos se distribuyen automáticamente y se rebalancean cuando un nodo se
sobrecarga.

Para ver la distribución de rangos en CockroachDB:

> SHOW RANGES FROM TABLE posts;

Esta es la diferencia fundamental entre un motor clásico y un NewSQL: en
PostgreSQL la distribución es responsabilidad del desarrollador; en
CockroachDB es responsabilidad del motor.

**Replicación Líder-Seguidor**

## Configuración en PostgreSQL

Cada nodo Primary tiene configurado en postgresql.conf:

> wal_level = replica -- habilita streaming de WAL
>
> max_wal_senders = 3 -- máximo de réplicas por nodo
>
> synchronous_commit = on -- escritura espera confirmación de la réplica

##  Experimento: impacto de synchronous_commit en latencia

El parámetro synchronous_commit controla el trade-off entre latencia y
durabilidad:

| **Configuración** | **Latencia escritura p99** | **Riesgo de pérdida**  | **Cuándo usarlo**           |
|-------------------|----------------------------|------------------------|-----------------------------|
| off (asíncrono)   | ~3 ms                      | Sí (hasta últimas txn) | Caché, logs, métricas       |
| on (síncrono)     | ~14 ms                     | No                     | Transacciones financieras   |
| remote_apply      | ~28 ms                     | No + réplica aplicó    | Alta disponibilidad crítica |

## Replicación en CockroachDB — Protocolo Raft

CockroachDB no usa líder-seguidor clásico sino el protocolo Raft. Cada
rango de datos tiene un leaseholder (equivalente al líder) y dos
réplicas. Una escritura se confirma cuando la mayoría de réplicas
(quorum) la acepta. Esto hace que el failover sea automático y que no
haya riesgo de split-brain.

**Transacciones distribuidas (2PC)**

Una operación de follow entre dos usuarios en shards distintos requiere
actualizar dos nodos diferentes de forma atómica. PostgreSQL implementa
esto con Two-Phase Commit (2PC):

## Fase 1: PREPARE

> -- En Nodo 1 (follower_id=100, shard 1-3000)
>
> BEGIN;
>
> UPDATE users SET following_count = following_count + 1 WHERE id = 100;
>
> PREPARE TRANSACTION 'follow_100_4500_n1';
>
> -- En Nodo 2 (followed_id=4500, shard 3001-6000)
>
> BEGIN;
>
> UPDATE users SET followers_count = followers_count + 1 WHERE id =
> 4500;
>
> PREPARE TRANSACTION 'follow_100_4500_n2';

## Fase 2: COMMIT o ROLLBACK

> -- Si ambos PREPARE fueron exitosos:
>
> COMMIT PREPARED 'follow_100_4500_n1'; -- en Nodo 1
>
> COMMIT PREPARED 'follow_100_4500_n2'; -- en Nodo 2
>
> -- Si algún nodo falló:
>
> ROLLBACK PREPARED 'follow_100_4500_n1';
>
> ROLLBACK PREPARED 'follow_100_4500_n2';

## Riesgo crítico: bloqueo por falla del coordinador

Si el coordinador (la aplicación) falla después del PREPARE pero antes
del COMMIT, las transacciones quedan bloqueadas indefinidamente en
estado PREPARED. Se detectan con:

> SELECT gid, prepared, EXTRACT(EPOCH FROM (NOW()-prepared)) AS segundos
>
> FROM pg_prepared_xacts ORDER BY prepared;

En CockroachDB este problema no existe: las transacciones distribuidas
son transparentes y el motor maneja internamente el protocolo de
consenso. El desarrollador solo escribe BEGIN / COMMIT.

**Failover y split-brain**

## PostgreSQL — Failover manual

Para simular la caída del Primary de Nodo 1:

> docker stop pgnode1

Para promover la réplica a Primary:

> docker exec -it pgnode1r pg_ctl promote -D /var/lib/postgresql/data

Verificar que ya es Primary:

> docker exec pgnode1r psql -U postgres -c "SELECT pg_is_in_recovery();"
>
> -- Resultado: f (false = es Primary)

Prevención de split-brain: si el nodo caído se recupera y cree que sigue
siendo Primary, dos nodos aceptaráan escrituras simultáneamente
(split-brain). Se previene con synchronous_standby_names: el Primary no
acepta escrituras si no tiene una réplica disponible.

## CockroachDB — Failover automático

Al detener un nodo de CockroachDB, Raft elige automáticamente un nuevo
leaseholder en ~6 segundos. El cluster sigue operando mientras haya
quorum (2 de 3 nodos activos):

> docker stop crdb2
>
> -- El cluster sigue funcionando con 2/3 nodos
>
> docker start crdb2
>
> -- El nodo se reincorpora y sincroniza automáticamente

No hay riesgo de split-brain en CockroachDB porque Raft garantiza que
solo un nodo puede ser leaseholder de cada rango en un momento dado.

# Experimentos y resultados

##  Latencia de escritura

| **Escenario**                    | **Motor**   | **p50 (ms)** | **p99 (ms)** |
|----------------------------------|-------------|--------------|--------------|
| INSERT post (shard local, async) | PostgreSQL  | ~1.5         | ~3           |
| INSERT post (shard local, sync)  | PostgreSQL  | ~6           | ~14          |
| INSERT post                      | CockroachDB | ~4           | ~12          |
| Transacción 2PC cross-shard      | PostgreSQL  | ~25          | ~60          |
| Transacción cross-shard (nativa) | CockroachDB | ~8           | ~20          |

##  Latencia de lectura

| **Escenario**                    | **Motor**   | **p50 (ms)** | **p99 (ms)** |
|----------------------------------|-------------|--------------|--------------|
| SELECT posts por user_id (local) | PostgreSQL  | ~0.8         | ~2           |
| SELECT posts por user_id         | CockroachDB | ~2           | ~6           |
| Consulta analítica GROUP BY      | PostgreSQL  | ~40          | ~90          |
| Consulta analítica GROUP BY      | CockroachDB | ~30          | ~70          |
| Join cross-shard (vía dblink)    | PostgreSQL  | ~80          | ~200         |
| Join cross-shard (nativo)        | CockroachDB | ~35          | ~90          |

**Análisis comparativo final**

| **Dimensión**          | **PostgreSQL (manual)**                                 | **CockroachDB (NewSQL)**                         |
|------------------------|---------------------------------------------------------|--------------------------------------------------|
| Particionamiento       | Manual. La app enruta según user_id                     | Automático. El motor distribuye sin intervención |
| Replicación            | Líder-seguidor. Configuración manual en postgresql.conf | Protocolo Raft. Automático y continuo            |
| Consistencia           | ACID en un nodo. Distribuida requiere 2PC manual        | Consistencia serializable global por defecto     |
| Modelo CAP             | CA (nodo único) → CP o AP según synchronous_commit      | CP siempre                                       |
| PACELC                 | PA/EL (async) o PC/EC (sync)                            | PC/EC siempre                                    |
| Txn distribuidas       | No nativas. PREPARE + COMMIT PREPARED manual            | Nativas. BEGIN / COMMIT estándar                 |
| Failover               | Manual. Riesgo de split-brain                           | Automático en ~6 segundos. Sin split-brain       |
| Latencia escritura     | Muy baja async (~2ms). Mayor sync (~15ms)               | Moderada (~4-12ms) por overhead Raft             |
| Latencia lectura       | Muy baja local (~0.8ms)                                 | Levemente mayor (~2ms)                           |
| Complejidad operativa  | Muy alta. Múltiples herramientas externas               | Baja. El motor gestiona la distribución          |
| Complejidad desarrollo | Alta. Dev gestiona topología y 2PC                      | Baja. SQL estándar, distribución transparente    |
| Costo infraestructura  | Bajo en instancias propias. Alto en DBA                 | Mayor en recursos. Menor costo operativo         |
| Madurez                | Muy madura (30+ años)                                   | Joven (desde 2015)                               |

**Modelos CAP y PACELC**

## Teorema CAP

El teorema CAP establece que un sistema distribuido solo puede
garantizar dos de las tres propiedades simultáneamente:

- Consistencia (C): todos los nodos ven los mismos datos en el mismo
  instante.

- Disponibilidad (A): cada solicitud recibe una respuesta, aunque no sea
  la más reciente.

- Tolerancia a particiones (P): el sistema funciona aunque se pierda
  comunicación entre nodos.

En la práctica las particiones de red son inevitables, por lo que el
trade-off real es entre CP (consistencia fuerte, puede rechazar
peticiones) y AP (alta disponibilidad, acepta datos desactualizados).

## Modelo PACELC

PACELC extiende CAP para incluir el comportamiento sin partición: si no
hay fallo de red, el sistema debe elegir entre menor latencia (L) o
mayor consistencia (C).

| **Motor y configuración** | **En partición**            | **En operación normal**                            |
|---------------------------|-----------------------------|----------------------------------------------------|
| PostgreSQL (async)        | PA: prefiere disponibilidad | EL: baja latencia, riesgo de datos desactualizados |
| PostgreSQL (sync)         | PC: prefiere consistencia   | EC: mayor latencia, datos siempre actualizados     |
| CockroachDB               | PC: siempre consistente     | EC: latencia moderada por consenso Raft            |

**Análisis crítico**

## La brecha entre teoría y producción

Este proyecto reveló algo que los cursos de bases de datos suelen
omitir: la distancia entre entender el teorema CAP y operar un sistema
distribuido en producción no es lineal, es exponencial. Configurar
synchronous_commit = on toma diez segundos. Entender por qué la latencia
de escritura se triplicó, cuándo ese costo vale la pena y cónmo
comunicarle ese trade-off a un equipo de negocio, es una habilidad que
tarda meses en desarrollarse.

## El 2PC en producción

El riesgo del coordinador muerto es real y grave. En el experimento del
escenario 3 de 05_2pc.sql, simulamos exactamente ese caso: el
coordinador falla después del PREPARE pero antes del COMMIT. Las
transacciones quedan bloqueadas indefinidamente. En un entorno de
producción de alto tráfico, esto puede traducirse en locks que se
acumulan hasta provocar un deadlock en cascada. Twitter documentó
públicamente que una de las razones por las que migró su arquitectura
fue precisamente la fragilidad del 2PC bajo fallos de red frecuentes.

## Contexto colombiano

En Colombia, la adopción de bases de datos distribuidas está liderada
por fintechs (Nequi, Addi) y delivery (Rappi). La mayoría de empresas
medianas operan PostgreSQL centralizado con RDS administrado, no
distribuido manualmente. El conocimiento de CockroachDB o YugabyteDB
aparece en menos del 5% de las ofertas de trabajo relacionadas con bases
de datos, lo que representa una ventaja competitiva real para quien lo
domina.

## Impacto en costos

La misma arquitectura de este proyecto en producción real implicaría: 3
instancias EC2 m5.xlarge (~\$140/mes cada una) + almacenamiento EBS
(~\$50/instancia) + un DBA con experiencia en PostgreSQL distribuido
(~\$8-15 millones COP/mes en Colombia) + monitoreo (~\$200/mes). Total:
más de \$1.000 USD/mes solo en infraestructura y personal.

Amazon RDS Multi-AZ cuesta ~\$400-800/mes e incluye failover automático,
backups y soporte. El punto de equilibrio económico entre administrar la
infraestructura propia vs usar un servicio administrado depende del
tamaño del equipo y del nivel de control requerido

**Conclusiones**

- El sharding manual en PostgreSQL es funcional pero complejo: la
  aplicación debe conocer la topología física, gestionar el enrutamiento
  y manejar explícitamente el 2PC. En CockroachDB todo esto es
  transparente.

- El parámetro synchronous_commit es el control más importante para el
  trade-off latencia/consistencia en PostgreSQL. En modo síncrono la
  latencia se quintuplica pero se garantiza durabilidad.

- El protocolo Raft de CockroachDB elimina el problema del split-brain y
  hace el failover automático, a cambio de un overhead de ~2-10 ms en
  cada escritura por el consenso de quorum.

- Ningún motor es universalmente superior. PostgreSQL tiene menor
  latencia en lecturas locales y es más maduro. CockroachDB tiene menor
  complejidad operativa y escala horizontalmente sin intervención del
  desarrollador.

- Docker es una alternativa válida a EC2 para experimentar con
  arquitecturas distribuidas. Los conceptos, comandos SQL y
  comportamientos son idénticos; solo cambia el sustrato de
  infraestructura.
