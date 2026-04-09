l

la distancia entre entender el teorema CAP y operar un sistema distribuido en producción no es lineal. Es exponencial.

Configurar `synchronous_commit = on` en PostgreSQL toma diez segundos. Entender por qué la latencia de escritura se triplicó, cuándo ese costo vale la pena y cuándo no, y cómo comunicarle ese trade-off a un equipo de negocio, es una habilidad que tarda meses en desarrollarse.

---

## El 2PC en producción: el problema que nadie menciona en los benchmarks

La documentación de PostgreSQL describe el `PREPARE TRANSACTION` como una herramienta poderosa. Lo que no aparece en los primeros párrafos es el riesgo del coordinador muerto.

En el experimento del Escenario 3 de `05_2pc.sql`, simulamos exactamente ese caso: el coordinador falla entre la fase Prepare y la fase Commit. El resultado es una transacción en estado `PREPARED` que bloquea recursos indefinidamente. En un entorno de producción de alto tráfico, esto puede traducirse en locks que se acumulan hasta provocar un deadlock en cascada.

Twitter documentó públicamente que una de las razones por las que migró de MySQL a una arquitectura más distribuida fue precisamente la fragilidad del 2PC bajo fallos de red frecuentes. En Colombia, equipos de fintech como Nequi han publicado en sus blogs técnicos (2022-2023) la complejidad de manejar transacciones distribuidas en sistemas de pagos donde la atomicidad no es negociable.

La alternativa moderna —el patrón SAGA implementado en CockroachDB o sobre Kafka— no elimina la complejidad: la desplaza. En lugar de bloquear recursos hasta que el coordinador se recupere, SAGA divide la transacción en pasos compensables. El sistema puede avanzar, pero el desarrollador ahora debe implementar la lógica de compensación. El costo de la distribucion se paga siempre; solo cambia quién lo paga y cuándo.

---

## CockroachDB: la promesa y la realidad

El auto-sharding de CockroachDB es genuinamente impresionante. Cargar 50.000 posts y ver cómo el motor los distribuye automáticamente entre tres nodos, sin que el desarrollador escriba una línea de lógica de enrutamiento, es una experiencia que cambia la perspectiva.

Pero el panel de administración en `localhost:8080` también muestra algo incómodo: el overhead de Raft. Cada escritura requiere que un quórum de nodos confirme el log antes de responder. En nuestros experimentos, eso significa que una inserción simple en CockroachDB tiene una latencia de ~4-12 ms, frente a ~1.5 ms en PostgreSQL con `synchronous_commit = off`.

Para una red social donde el usuario espera que su post aparezca en menos de 500 ms, esos 10 ms adicionales son insignificantes. Para un sistema de trading de alta frecuencia donde cada microsegundo tiene costo financiero, esa latencia podría ser prohibitiva.

La lección no es que CockroachDB sea peor. Es que **ningún motor es universalmente superior**. La elección siempre depende del dominio, el patrón de acceso, y las garantías que el negocio necesita.

---

## El costo real: lo que el presupuesto del proyecto no captura

El docker-compose de este proyecto corre en una laptop. En producción, la misma arquitectura implica:

- **3 instancias EC2 m5.xlarge** (~$140/mes cada una) más almacenamiento EBS (~$50/instancia) = ~$570/mes solo en infraestructura PostgreSQL.
- **Un DBA** con experiencia en replicación, failover y optimización de PostgreSQL: en el mercado colombiano, ese perfil cuesta entre $8 y $15 millones COP/mes.
- **Monitoreo**: Prometheus + Grafana + alertas en PagerDuty: ~$200/mes para un equipo pequeño.
- **Gestión de incidentes**: cada episodio de split-brain o transacción PREPARED bloqueada puede implicar horas de ingeniería y potencial pérdida de transacciones. El costo de un incidente de este tipo en una plataforma financiera rara vez baja de los $10.000 USD.

Frente a esto, un servicio administrado como **Amazon RDS Multi-AZ** para PostgreSQL cuesta ~$400-800/mes para el mismo volumen de datos, pero incluye failover automático, backups, parches de seguridad y soporte. La ecuación económica favorece el servicio administrado hasta que el equipo de ingeniería supera cierto tamaño y la necesidad de control granular justifica el costo operativo adicional.

---

## Lo que el mercado colombiano no enseña

En Colombia, la adopción de bases de datos distribuidas está acelerada principalmente por el sector fintech (Nequi, Bancolombia Digital, Addi) y el sector de entretenimiento/delivery (Rappi, Picap). Sin embargo, la transparencia técnica sobre las decisiones de arquitectura es escasa.

Lo que se puede inferir de ofertas de trabajo y publicaciones en LinkedIn Engineering Colombia:
- La mayoría de las empresas medianas operan PostgreSQL centralizado con RDS, no distribuido.
- La complejidad del sharding manual es conocida y evitada: prefieren escalar verticalmente o migrar a servicios administrados.
- El conocimiento de CockroachDB o YugabyteDB es considerado "avanzado" y aparece en menos del 5% de las ofertas de trabajo relacionadas con bases de datos.

Esto no significa que el conocimiento de este proyecto sea irrelevante. Significa que quien lo domina tiene una ventaja competitiva real en equipos que sí necesitan este nivel de control.

---

## Bases de datos distribuidas vs centralizadas vs servicio administrado

La decisión no es técnica. Es de negocio.

Una startup en etapa seed no debería operar PostgreSQL distribuido manual. El tiempo de ingeniería que gastaría en configurar Patroni, gestionar failovers y monitorear el lag de replicación es tiempo que no está construyendo producto.

Una empresa que procesa millones de transacciones diarias y necesita garantías de durabilidad regional (por regulación, como las entidades vigiladas por la SFC en Colombia) tampoco puede depender de un servicio administrado que almacena datos fuera del país.

El punto de inflexión es diferente para cada organización. Este proyecto proporciona el marco técnico para identificarlo cuando llegue.

---

*Documento preparado como parte del análisis crítico del Proyecto 2, SI3009 — Bases de Datos Avanzadas, 2026-1.*
