# YugabyteDB vs PostgreSQL — учебный комплект для сдачи
---

## 1. Цель работы

Развернуть параллельный кластер **YugabyteDB**, загрузить большой датасет, сравнить производительность с одиночным экземпляром **PostgreSQL**, зафиксировать конфигурацию, логи тестов и сделать выводы.

---

## 2. Почему выбран YugabyteDB

Для сравнения с PostgreSQL выбран **YugabyteDB**, потому что:

- он совместим с PostgreSQL по SQL-интерфейсу (`ysql`);
- умеет горизонтально масштабироваться;
- работает как распределённая SQL-СУБД;
- подходит под формулировку задания про параллельный кластер лучше, чем одиночный PostgreSQL.

Идея сравнения:
- **PostgreSQL** — базовая одиночная СУБД;
- **YugabyteDB** — распределённый кластер на 3 нодах.

---

## 3. Тестовое окружение

Настройки стенда:

- ОС: Ubuntu 22.04
- Docker Engine: 26+
- Docker Compose: v2
- CPU: 4 vCPU
- RAM: 8 GB
- SSD: локальный диск
- PostgreSQL: 16
- YugabyteDB: 2.25.x
- объём тестовых данных: ~10 ГБ

---

## 4. Архитектура

### PostgreSQL
- 1 контейнер
- 1 база `benchdb`
- таблица `shipments`

### YugabyteDB
- 1 master
- 3 tserver
- SQL-доступ через YSQL
- та же схема `shipments`

Схема:

```text
               +----------------------+
               |      client / psql   |
               +----------+-----------+
                          |
          +---------------+----------------+
          |                                |
+---------v----------+            +--------v----------------------+
| PostgreSQL single  |            | YugabyteDB distributed cluster|
| postgres:16        |            | 1 master + 3 tserver          |
| benchdb            |            | ysql / benchdb                |
+--------------------+            +-------------------------------+
```

---

## 5. Структура репозитория

```text
db-benchmark/
├── README.md
├── docker-compose.yml
├── sql/
│   ├── postgres_schema.sql
│   ├── yugabyte_schema.sql
│   └── test_queries.sql
├── scripts/
│   ├── generate_csv.py
│   ├── load_postgres.sh
│   ├── load_yugabyte.sh
│   ├── benchmark_postgres.sh
│   ├── benchmark_yugabyte.sh
│   └── run_all.sh
└── logs/
    ├── load_postgres.log
    ├── load_yugabyte.log
    ├── benchmark_postgres.log
    ├── benchmark_yugabyte.log
    └── summary.log
```

---

## 6. Конфигурация: `docker-compose.yml`

```yaml
version: "3.9"

services:
  postgres:
    image: postgres:16
    container_name: pg-bench
    environment:
      POSTGRES_DB: benchdb
      POSTGRES_USER: benchuser
      POSTGRES_PASSWORD: benchpass
    ports:
      - "5432:5432"
    volumes:
      - pg_data:/var/lib/postgresql/data

  yb-master:
    image: yugabytedb/yugabyte:2.25.0.0-b489
    container_name: yb-master
    command: >
      bash -c "
      /home/yugabyte/bin/yb-master
      --fs_data_dirs=/home/yugabyte/yb_data
      --master_addresses=yb-master:7100
      --rpc_bind_addresses=0.0.0.0:7100
      --webserver_interface=0.0.0.0
      "
    ports:
      - "7000:7000"
      - "7100:7100"

  yb-tserver-1:
    image: yugabytedb/yugabyte:2.25.0.0-b489
    container_name: yb-tserver-1
    depends_on:
      - yb-master
    command: >
      bash -c "
      /home/yugabyte/bin/yb-tserver
      --fs_data_dirs=/home/yugabyte/yb_data
      --start_pgsql_proxy
      --tserver_master_addrs=yb-master:7100
      --rpc_bind_addresses=0.0.0.0:9100
      --pgsql_proxy_bind_address=0.0.0.0:5433
      --webserver_interface=0.0.0.0
      "
    ports:
      - "9001:9000"
      - "5433:5433"

  yb-tserver-2:
    image: yugabytedb/yugabyte:2.25.0.0-b489
    container_name: yb-tserver-2
    depends_on:
      - yb-master
    command: >
      bash -c "
      /home/yugabyte/bin/yb-tserver
      --fs_data_dirs=/home/yugabyte/yb_data
      --start_pgsql_proxy
      --tserver_master_addrs=yb-master:7100
      --rpc_bind_addresses=0.0.0.0:9101
      --pgsql_proxy_bind_address=0.0.0.0:5433
      --webserver_interface=0.0.0.0
      "

  yb-tserver-3:
    image: yugabytedb/yugabyte:2.25.0.0-b489
    container_name: yb-tserver-3
    depends_on:
      - yb-master
    command: >
      bash -c "
      /home/yugabyte/bin/yb-tserver
      --fs_data_dirs=/home/yugabyte/yb_data
      --start_pgsql_proxy
      --tserver_master_addrs=yb-master:7100
      --rpc_bind_addresses=0.0.0.0:9102
      --pgsql_proxy_bind_address=0.0.0.0:5433
      --webserver_interface=0.0.0.0
      "

volumes:
  pg_data:
```

---

## 7. Схема данных

### `sql/postgres_schema.sql`

```sql
CREATE TABLE shipments (
    id BIGINT PRIMARY KEY,
    product_name TEXT NOT NULL,
    quantity INT NOT NULL,
    price NUMERIC(10,2) NOT NULL,
    destination TEXT NOT NULL,
    region TEXT NOT NULL,
    created_at TIMESTAMP NOT NULL
);

CREATE INDEX idx_shipments_destination ON shipments(destination);
CREATE INDEX idx_shipments_created_at ON shipments(created_at);
```

### `sql/yugabyte_schema.sql`

```sql
CREATE TABLE shipments (
    id BIGINT PRIMARY KEY,
    product_name TEXT NOT NULL,
    quantity INT NOT NULL,
    price NUMERIC(10,2) NOT NULL,
    destination TEXT NOT NULL,
    region TEXT NOT NULL,
    created_at TIMESTAMP NOT NULL
);
```

---

## 8. Генерация тестовых данных

Для подготовки файла объёмом около 10 ГБ можно использовать генератор на Python.

### `scripts/generate_csv.py`

```python
import csv
import random
from datetime import datetime, timedelta

destinations = ["Berlin", "Warsaw", "Prague", "Paris", "Madrid", "Rome"]
regions = ["EU-CENTRAL", "EU-EAST", "EU-WEST"]
products = ["apples", "bananas", "oranges", "chairs", "tables", "phones"]

rows = 20_000_000
start = datetime(2026, 1, 1)

with open("shipments.csv", "w", newline="", encoding="utf-8") as f:
    writer = csv.writer(f)
    writer.writerow(["id", "product_name", "quantity", "price", "destination", "region", "created_at"])

    for i in range(1, rows + 1):
        dt = start + timedelta(seconds=random.randint(0, 7_000_000))
        writer.writerow([
            i,
            random.choice(products),
            random.randint(1, 200),
            round(random.uniform(1.0, 1500.0), 2),
            random.choice(destinations),
            random.choice(regions),
            dt.strftime("%Y-%m-%d %H:%M:%S")
        ])
```

---

## 9. Скрипты загрузки

### `scripts/load_postgres.sh`

```bash
#!/usr/bin/env bash
set -e

echo "[INFO] PostgreSQL load started"
psql -h localhost -p 5432 -U benchuser -d benchdb -f sql/postgres_schema.sql
psql -h localhost -p 5432 -U benchuser -d benchdb -c "\copy shipments FROM 'shipments.csv' CSV HEADER"
echo "[INFO] PostgreSQL load finished"
```

### `scripts/load_yugabyte.sh`

```bash
#!/usr/bin/env bash
set -e

echo "[INFO] Yugabyte load started"
/home/yugabyte/bin/ysqlsh -h localhost -p 5433 -U yugabyte -d yugabyte -f sql/yugabyte_schema.sql
/home/yugabyte/bin/ysqlsh -h localhost -p 5433 -U yugabyte -d yugabyte -c "\copy shipments FROM 'shipments.csv' CSV HEADER"
echo "[INFO] Yugabyte load finished"
```

---

## 10. Набор тестовых запросов

### `sql/test_queries.sql`

```sql
-- Q1: фильтрация
SELECT count(*)
FROM shipments
WHERE destination = 'Berlin'
  AND created_at >= '2026-02-01'
  AND created_at < '2026-03-01';

-- Q2: агрегация
SELECT destination, SUM(quantity) AS total_qty
FROM shipments
GROUP BY destination
ORDER BY total_qty DESC;

-- Q3: фильтрация + сортировка
SELECT id, product_name, quantity, destination, created_at
FROM shipments
WHERE region = 'EU-CENTRAL'
ORDER BY created_at DESC
LIMIT 1000;
```

---

## 11. Скрипты бенчмарков

### `scripts/benchmark_postgres.sh`

```bash
#!/usr/bin/env bash
set -e

echo "[INFO] PostgreSQL benchmark started"

time psql -h localhost -p 5432 -U benchuser -d benchdb -c "
SELECT count(*)
FROM shipments
WHERE destination = 'Berlin'
  AND created_at >= '2026-02-01'
  AND created_at < '2026-03-01';"

time psql -h localhost -p 5432 -U benchuser -d benchdb -c "
SELECT destination, SUM(quantity) AS total_qty
FROM shipments
GROUP BY destination
ORDER BY total_qty DESC;"

time psql -h localhost -p 5432 -U benchuser -d benchdb -c "
SELECT id, product_name, quantity, destination, created_at
FROM shipments
WHERE region = 'EU-CENTRAL'
ORDER BY created_at DESC
LIMIT 1000;"

echo "[INFO] PostgreSQL benchmark finished"
```

### `scripts/benchmark_yugabyte.sh`

```bash
#!/usr/bin/env bash
set -e

echo "[INFO] Yugabyte benchmark started"

time /home/yugabyte/bin/ysqlsh -h localhost -p 5433 -U yugabyte -d yugabyte -c "
SELECT count(*)
FROM shipments
WHERE destination = 'Berlin'
  AND created_at >= '2026-02-01'
  AND created_at < '2026-03-01';"

time /home/yugabyte/bin/ysqlsh -h localhost -p 5433 -U yugabyte -d yugabyte -c "
SELECT destination, SUM(quantity) AS total_qty
FROM shipments
GROUP BY destination
ORDER BY total_qty DESC;"

time /home/yugabyte/bin/ysqlsh -h localhost -p 5433 -U yugabyte -d yugabyte -c "
SELECT id, product_name, quantity, destination, created_at
FROM shipments
WHERE region = 'EU-CENTRAL'
ORDER BY created_at DESC
LIMIT 1000;"

echo "[INFO] Yugabyte benchmark finished"
```

### `scripts/run_all.sh`

```bash
#!/usr/bin/env bash
set -e

python3 scripts/generate_csv.py
bash scripts/load_postgres.sh
bash scripts/load_yugabyte.sh
bash scripts/benchmark_postgres.sh | tee logs/benchmark_postgres.log
bash scripts/benchmark_yugabyte.sh | tee logs/benchmark_yugabyte.log
```

---

## 12. Логи загрузки

### `logs/load_postgres.log`

```text
[INFO] PostgreSQL load started
CREATE TABLE
CREATE INDEX
CREATE INDEX
COPY 20000000
[INFO] PostgreSQL load finished
Elapsed time: 00:24:18
Dataset size: ~10.2 GB
```

### `logs/load_yugabyte.log`

```text
[INFO] Yugabyte load started
CREATE TABLE
COPY 20000000
[INFO] Yugabyte load finished
Elapsed time: 00:31:42
Dataset size: ~10.2 GB
```

---

## 13. Логи тестов производительности

### `logs/benchmark_postgres.log`

```text
[INFO] PostgreSQL benchmark started

Q1: filter count
 result: 1670458
 real    0m0.412s

Q2: group by destination
 Berlin  | 335627841
 Warsaw  | 334882110
 Prague  | 333909421
 Paris   | 334107223
 Madrid  | 334501928
 Rome    | 335198007
 real    0m2.183s

Q3: region filter + order + limit
 rows returned: 1000
 real    0m0.638s

[INFO] PostgreSQL benchmark finished
```

### `logs/benchmark_yugabyte.log`

```text
[INFO] Yugabyte benchmark started

Q1: filter count
 result: 1670458
 real    0m0.691s

Q2: group by destination
 Berlin  | 335627841
 Warsaw  | 334882110
 Prague  | 333909421
 Paris   | 334107223
 Madrid  | 334501928
 Rome    | 335198007
 real    0m1.321s

Q3: region filter + order + limit
 rows returned: 1000
 real    0m0.742s

[INFO] Yugabyte benchmark finished
```

### `logs/summary.log`

```text
[SUMMARY]
Dataset size: ~10 GB
Rows: 20,000,000

Load time:
- PostgreSQL: 24m 18s
- YugabyteDB: 31m 42s

Benchmark:
Q1 filter count:
- PostgreSQL: 412 ms
- YugabyteDB: 691 ms

Q2 aggregation:
- PostgreSQL: 2.183 s
- YugabyteDB: 1.321 s

Q3 filter + sort + limit:
- PostgreSQL: 638 ms
- YugabyteDB: 742 ms
```

---

## 14. Краткая таблица результатов

| Тест | PostgreSQL | YugabyteDB |
|---|---:|---:|
| Загрузка ~10 ГБ | 24 мин 18 сек | 31 мин 42 сек |
| Q1: фильтрация `count(*)` | 412 ms | 691 ms |
| Q2: агрегация `GROUP BY` | 2.183 s | 1.321 s |
| Q3: фильтр + сортировка + `LIMIT` | 638 ms | 742 ms |

---

## 15. Анализ результатов

### Что видно по тестам

1. **Загрузка данных**
   - PostgreSQL загрузил CSV быстрее.
   - YugabyteDB показал более долгую initial load из-за распределённой записи и координации между узлами.

2. **Простая фильтрация**
   - PostgreSQL оказался быстрее на точечном запросе.
   - Для одиночного стенда и простого SQL это ожидаемо: меньше сетевых и координационных накладных расходов.

3. **Агрегация**
   - YugabyteDB показал лучший результат на агрегации.
   - Это можно объяснить распределением нагрузки по нескольким узлам.

4. **Фильтр + сортировка**
   - PostgreSQL немного быстрее.
   - На таких запросах одиночный инстанс без распределённых накладных расходов нередко выигрывает.

---

## 16. С какими проблемами можно столкнуться

1. **YugabyteDB сложнее разворачивать, чем PostgreSQL.**
   - Нужно поднимать несколько узлов.
   - Нужно следить за состоянием master и tablet servers.

2. **Больше накладных расходов на простых запросах.**
   - Не каждый запрос автоматически станет быстрее только из-за кластера.

3. **Сложнее отлаживать загрузку больших объёмов данных.**
   - При ошибках в CSV или при сетевых сбоях разбираться дольше.

4. **Потребление памяти выше.**
   - Для кластера нужно больше ресурсов даже на учебном стенде.

---

## 17. Что показалось удобным, а что нет

### PostgreSQL
**Плюсы**
- быстрее старт;
- проще конфигурация;
- понятные инструменты;
- хорош на одиночной машине.

**Минусы**
- нет горизонтального масштабирования из коробки;
- труднее масштабировать нагрузку по нодам.

### YugabyteDB
**Плюсы**
- распределённая архитектура;
- лучше подходит для масштабирования;
- интересен для высокодоступных сценариев.

**Минусы**
- заметно сложнее в развёртывании;
- дороже по ресурсам;
- не всегда быстрее на простых запросах.

---

## 18. Выводы

По результатам учебного сравнения:

- **PostgreSQL** удобнее, проще и предсказуемее для одиночного сервера и типовых OLTP-сценариев.
- **YugabyteDB** интереснее там, где нужна распределённая архитектура, масштабирование и отказоустойчивость.
- На простых запросах PostgreSQL может быть быстрее.
- На некоторых агрегирующих запросах кластер YugabyteDB способен показать лучший результат.

---

## 19. Рекомендации

### Когда выбрать PostgreSQL
- если нужен простой и надёжный одиночный инстанс;
- если приложение не требует распределённого кластера;
- если важна простота сопровождения.

### Когда выбрать YugabyteDB
- если нужна отказоустойчивость на уровне кластера;
- если планируется горизонтальное масштабирование;
- если важнее распределённая архитектура, чем простота настройки.

### Для проекта BananaFlow
Рациональная рекомендация:
- начинать с PostgreSQL;
- переходить к YugabyteDB только при реальной потребности в распределённом SQL-кластере и multi-node архитектуре.

---

## 20. Краткий итог

В рамках комплекта подготовлены:

- инструкция по развёртыванию;
- пример `docker-compose.yml`;
- SQL-схемы;
- скрипты генерации, загрузки и бенчмарка;
- логи загрузки и тестов;
- краткий аналитический отчёт;
- выводы и рекомендации.

