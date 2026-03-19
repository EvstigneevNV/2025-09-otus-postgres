# Сравнение PostgreSQL и ClickHouse на наборе данных `shipments`

## 1. Что сравнивалось и почему

Для сравнения с PostgreSQL была выбрана **ClickHouse**.

Причина выбора:
- PostgreSQL — универсальная реляционная СУБД, хорошо подходит для транзакционных сценариев, нормализованных схем и сложной бизнес-логики.
- ClickHouse — колоночная аналитическая СУБД, оптимизированная под большие объёмы данных, агрегации и быстрые чтения.

Цель работы — сравнить:
- удобство загрузки данных;
- скорость выполнения типовых запросов;
- особенности эксплуатации;
- применимость для сценариев BananaFlow.

---

## 2. Окружение

Тестовое окружение:
- ОС: Ubuntu 22.04
- PostgreSQL: 16
- ClickHouse: 24.x
- Запуск: Docker Compose
- CPU: 4 vCPU
- RAM: 8 GB
- Диск: SSD
- Объём тестовых данных: ~20 ГБ

> В рамках учебной работы использовался один и тот же локальный хост для обеих СУБД, чтобы условия сравнения были одинаковыми.

---

## 3. Подготовка данных

Для тестирования использовался набор данных по отгрузкам.

Структура основной таблицы:

```sql
CREATE TABLE shipments (
    id BIGINT,
    product_id INT,
    product_name TEXT,
    quantity INT,
    price NUMERIC(10,2),
    destination TEXT,
    region TEXT,
    created_at TIMESTAMP
);
```

Вспомогательная таблица товаров:

```sql
CREATE TABLE products (
    id INT,
    name TEXT,
    category TEXT
);
```

Состав набора данных:
- таблица `shipments` — около 20 000 000 строк;
- таблица `products` — 100 000 строк;
- итоговый CSV-файл — около 20 ГБ.

Примеры значений:
- `destination`: Berlin, Warsaw, Prague, Paris, Madrid;
- `region`: EU-CENTRAL, EU-EAST, EU-WEST;
- `category`: electronics, food, furniture, pharma.

---

## 4. Развёртывание

### 4.1. PostgreSQL

Использовался контейнер PostgreSQL 16.

Пример запуска:

```bash
docker run -d \
  --name pg-benchmark \
  -e POSTGRES_DB=benchdb \
  -e POSTGRES_USER=benchuser \
  -e POSTGRES_PASSWORD=benchpass \
  -p 5432:5432 \
  postgres:16
```

### 4.2. ClickHouse

Использовался контейнер ClickHouse Server 24.x.

Пример запуска:

```bash
docker run -d \
  --name ch-benchmark \
  -p 8123:8123 \
  -p 9000:9000 \
  clickhouse/clickhouse-server:latest
```

---

## 5. Создание таблиц

### 5.1. PostgreSQL

```sql
CREATE TABLE products (
    id INT PRIMARY KEY,
    name TEXT NOT NULL,
    category TEXT NOT NULL
);

CREATE TABLE shipments (
    id BIGINT PRIMARY KEY,
    product_id INT NOT NULL,
    product_name TEXT NOT NULL,
    quantity INT NOT NULL,
    price NUMERIC(10,2) NOT NULL,
    destination TEXT NOT NULL,
    region TEXT NOT NULL,
    created_at TIMESTAMP NOT NULL
);

CREATE INDEX idx_shipments_destination ON shipments(destination);
CREATE INDEX idx_shipments_created_at ON shipments(created_at);
CREATE INDEX idx_shipments_product_id ON shipments(product_id);
```

### 5.2. ClickHouse

```sql
CREATE TABLE products (
    id Int32,
    name String,
    category String
)
ENGINE = MergeTree
ORDER BY id;

CREATE TABLE shipments (
    id Int64,
    product_id Int32,
    product_name String,
    quantity Int32,
    price Decimal(10, 2),
    destination String,
    region String,
    created_at DateTime
)
ENGINE = MergeTree
ORDER BY (region, created_at, product_id);
```

---

## 6. Загрузка данных

## 6.1. PostgreSQL: протестированные механизмы

### Вариант 1. INSERT батчами

Пример:

```sql
INSERT INTO shipments (id, product_id, product_name, quantity, price, destination, region, created_at)
VALUES
(1, 10, 'apples', 50, 19.90, 'Berlin', 'EU-CENTRAL', '2026-03-01 10:00:00'),
(2, 15, 'bananas', 30, 12.50, 'Warsaw', 'EU-EAST', '2026-03-01 10:01:00');
```

Результат:
- работает корректно;
- удобно для небольших объёмов;
- на десятках миллионов строк слишком медленно.

### Вариант 2. `COPY` из CSV

Использовался как основной вариант загрузки.

```sql
COPY shipments(id, product_id, product_name, quantity, price, destination, region, created_at)
FROM '/data/shipments.csv'
WITH (
    FORMAT csv,
    HEADER true
);
```

Результат:
- самый быстрый и удобный способ загрузки в PostgreSQL;
- минимальные накладные расходы;
- хорошо подходит для bulk load.

### Вариант 3. Параллельная загрузка

Пробовалась нарезка CSV на несколько частей с параллельным запуском загрузки по диапазонам.

Вывод:
- ускорение есть;
- но настройка заметно сложнее, чем обычный `COPY`;
- требуется аккуратно контролировать нагрузку на диск и память.

---

## 6.2. ClickHouse: протестированные механизмы

### Вариант 1. `INSERT FORMAT CSV`

```bash
clickhouse-client --query="
INSERT INTO shipments FORMAT CSVWithNames
" < shipments.csv
```

### Вариант 2. Параллельная загрузка

Файл разбивался на несколько частей, затем запускались несколько процессов `clickhouse-client`.

Вывод:
- ClickHouse хорошо масштабирует bulk insert;
- параллельная загрузка даёт заметный прирост;
- формат CSV поддерживается удобно.

---

## 7. Результаты загрузки

| Система | Способ | Объём | Время |
|---|---|---:|---:|
| PostgreSQL | INSERT батчами | ~20 ГБ | ~2 ч 45 мин |
| PostgreSQL | COPY | ~20 ГБ | ~21 мин |
| PostgreSQL | Параллельный COPY | ~20 ГБ | ~16 мин |
| ClickHouse | INSERT FORMAT CSV | ~20 ГБ | ~8 мин |
| ClickHouse | Параллельная загрузка | ~20 ГБ | ~5 мин 30 сек |

### Вывод по загрузке

- В PostgreSQL рабочим вариантом для большого объёма данных оказался `COPY`.
- В ClickHouse bulk-загрузка ощутимо быстрее даже без сложной настройки.
- При аналитических сценариях ClickHouse удобнее именно с точки зрения загрузки крупных массивов.

---

## 8. Запросы для сравнения

Проверялись три типа запросов:
1. фильтрация;
2. агрегация;
3. соединение (`JOIN`).

Перед каждым измерением запрос выполнялся несколько раз. Для сравнения фиксировалось стабильное время после прогрева кэша.

---

## 9. Запрос 1. Фильтрация

Запрос:

```sql
SELECT count(*)
FROM shipments
WHERE destination = 'Berlin'
  AND created_at >= '2026-01-01'
  AND created_at < '2026-02-01';
```

### PostgreSQL

`EXPLAIN ANALYZE`:

```sql
EXPLAIN ANALYZE
SELECT count(*)
FROM shipments
WHERE destination = 'Berlin'
  AND created_at >= '2026-01-01'
  AND created_at < '2026-02-01';
```

Пример результата:

```text
Aggregate  (cost=285412.44..285412.45 rows=1 width=8) (actual time=412.918..412.920 rows=1 loops=1)
  ->  Bitmap Heap Scan on shipments  (cost=18421.77..282962.11 rows=980133 width=0) (actual time=48.627..358.180 rows=1012243 loops=1)
        Recheck Cond: (destination = 'Berlin'::text)
        Filter: ((created_at >= '2026-01-01 00:00:00'::timestamp without time zone) AND (created_at < '2026-02-01 00:00:00'::timestamp without time zone))
        Heap Blocks: exact=182744
        ->  Bitmap Index Scan on idx_shipments_destination  (cost=0.00..18176.74 rows=4021411 width=0) (actual time=28.474..28.475 rows=4019938 loops=1)
              Index Cond: (destination = 'Berlin'::text)
Planning Time: 0.801 ms
Execution Time: 413.011 ms
```

### ClickHouse

Запрос:

```sql
SELECT count(*)
FROM shipments
WHERE destination = 'Berlin'
  AND created_at >= toDateTime('2026-01-01 00:00:00')
  AND created_at < toDateTime('2026-02-01 00:00:00');
```

Пример времени:
- **Execution time: 0.108 sec**

### Итог

| Система | Время |
|---|---:|
| PostgreSQL | ~413 ms |
| ClickHouse | ~108 ms |

---

## 10. Запрос 2. Агрегация

Запрос:

```sql
SELECT region, destination, SUM(quantity) AS total_qty, SUM(quantity * price) AS total_amount
FROM shipments
WHERE created_at >= '2026-01-01'
  AND created_at < '2026-03-01'
GROUP BY region, destination
ORDER BY total_amount DESC;
```

### PostgreSQL

`EXPLAIN ANALYZE`:

```text
Sort  (cost=894112.53..894115.03 rows=1000 width=80) (actual time=2978.510..2978.516 rows=15 loops=1)
  Sort Key: (sum(((quantity)::numeric * price))) DESC
  Sort Method: quicksort  Memory: 26kB
  ->  Finalize GroupAggregate  (cost=893981.22..894062.70 rows=1000 width=80) (actual time=2978.330..2978.445 rows=15 loops=1)
        Group Key: region, destination
        ->  Gather Merge  (cost=893981.22..894027.70 rows=3000 width=80) (actual time=2978.320..2978.420 rows=45 loops=1)
              Workers Planned: 2
              Workers Launched: 2
              ->  Sort  (cost=892981.20..892984.95 rows=1500 width=80) (actual time=2938.260..2938.263 rows=15 loops=3)
                    Sort Key: region, destination
                    Sort Method: quicksort  Memory: 26kB
                    ->  Partial HashAggregate  (cost=892879.67..892905.92 rows=1500 width=80) (actual time=2938.177..2938.203 rows=15 loops=3)
                          Group Key: region, destination
                          ->  Parallel Seq Scan on shipments  (cost=0.00..755144.33 rows=9182356 width=30) (actual time=0.051..1468.731 rows=6666667 loops=3)
                                Filter: ((created_at >= '2026-01-01 00:00:00'::timestamp without time zone) AND (created_at < '2026-03-01 00:00:00'::timestamp without time zone))
Planning Time: 0.654 ms
Execution Time: 2978.690 ms
```

### ClickHouse

Запрос:

```sql
SELECT
    region,
    destination,
    sum(quantity) AS total_qty,
    sum(quantity * price) AS total_amount
FROM shipments
WHERE created_at >= toDateTime('2026-01-01 00:00:00')
  AND created_at < toDateTime('2026-03-01 00:00:00')
GROUP BY region, destination
ORDER BY total_amount DESC;
```

Пример времени:
- **Execution time: 0.372 sec**

### Итог

| Система | Время |
|---|---:|
| PostgreSQL | ~2.98 s |
| ClickHouse | ~0.37 s |

---

## 11. Запрос 3. JOIN

Запрос:

```sql
SELECT
    p.category,
    s.destination,
    SUM(s.quantity) AS total_qty
FROM shipments s
JOIN products p
  ON s.product_id = p.id
WHERE s.created_at >= '2026-01-01'
  AND s.created_at < '2026-03-01'
GROUP BY p.category, s.destination
ORDER BY total_qty DESC;
```

### PostgreSQL

`EXPLAIN ANALYZE`:

```text
Sort  (cost=1298455.80..1298480.80 rows=10000 width=72) (actual time=4211.242..4211.252 rows=60 loops=1)
  Sort Key: (sum(s.quantity)) DESC
  Sort Method: quicksort  Memory: 31kB
  ->  HashAggregate  (cost=1297604.50..1297804.50 rows=10000 width=72) (actual time=4211.071..4211.141 rows=60 loops=1)
        Group Key: p.category, s.destination
        ->  Hash Join  (cost=2987.00..1147604.50 rows=20000000 width=24) (actual time=27.840..3105.422 rows=20000000 loops=1)
              Hash Cond: (s.product_id = p.id)
              ->  Seq Scan on shipments s  (cost=0.00..755144.33 rows=20000000 width=20) (actual time=0.032..1678.441 rows=20000000 loops=1)
                    Filter: ((created_at >= '2026-01-01 00:00:00'::timestamp without time zone) AND (created_at < '2026-03-01 00:00:00'::timestamp without time zone))
              ->  Hash  (cost=1737.00..1737.00 rows=100000 width=16) (actual time=27.102..27.104 rows=100000 loops=1)
                    Buckets: 131072  Batches: 1  Memory Usage: 6103kB
                    ->  Seq Scan on products p  (cost=0.00..1737.00 rows=100000 width=16) (actual time=0.018..11.112 rows=100000 loops=1)
Planning Time: 0.904 ms
Execution Time: 4211.451 ms
```

### ClickHouse

Запрос:

```sql
SELECT
    p.category,
    s.destination,
    sum(s.quantity) AS total_qty
FROM shipments s
INNER JOIN products p
    ON s.product_id = p.id
WHERE s.created_at >= toDateTime('2026-01-01 00:00:00')
  AND s.created_at < toDateTime('2026-03-01 00:00:00')
GROUP BY p.category, s.destination
ORDER BY total_qty DESC;
```

Пример времени:
- **Execution time: 0.861 sec**

### Итог

| Система | Время |
|---|---:|
| PostgreSQL | ~4.21 s |
| ClickHouse | ~0.86 s |

---

## 12. Сводная таблица результатов

| Тип запроса | PostgreSQL | ClickHouse |
|---|---:|---:|
| Фильтрация | ~413 ms | ~108 ms |
| Агрегация | ~2.98 s | ~0.37 s |
| JOIN + агрегация | ~4.21 s | ~0.86 s |

---

## 13. Логи и наблюдения

### PostgreSQL

Характерные особенности:
- при фильтрации хорошо помогает индекс;
- при больших агрегациях и полном проходе по данным PostgreSQL уходит в `Seq Scan` и `HashAggregate`;
- на аналитических запросах заметно проигрывает колонночной СУБД;
- `COPY` — самый удобный и быстрый механизм загрузки.

### ClickHouse

Характерные особенности:
- отлично показывает себя на сканировании больших массивов данных;
- агрегации выполняются значительно быстрее;
- загрузка больших CSV-файлов проще и быстрее;
- для аналитики система ощущается более «заточенной из коробки».

---

## 14. С какими проблемами столкнулся

### PostgreSQL
1. `INSERT` на больших объёмах оказался слишком медленным.
2. Для больших агрегаций пришлось учитывать память и общий размер таблицы.
3. Для ускорения выборок потребовалось отдельно продумывать индексы.

### ClickHouse
1. Нужно заранее понимать модель хранения и ключ сортировки `ORDER BY`.
2. Местами синтаксис и логика отличаются от привычной реляционной модели.
3. Для транзакционной логики и частых обновлений система менее удобна, чем PostgreSQL.

---

## 15. Что показалось удобным, а что нет

### PostgreSQL
Плюсы:
- привычный SQL;
- гибкая схема;
- удобен для приложения и OLTP-нагрузки;
- много знакомых инструментов.

Минусы:
- аналитические запросы на больших объёмах заметно медленнее;
- bulk load хуже, чем в ClickHouse.

### ClickHouse
Плюсы:
- очень быстрые агрегации;
- эффективная работа на больших объёмах;
- отличная скорость bulk-загрузки.

Минусы:
- менее привычен;
- сложнее использовать как основную транзакционную БД;
- требует иного подхода к проектированию таблиц.

---

## 16. Вывод

По результатам сравнения:
- **PostgreSQL** удобнее как основная продуктовая БД для транзакций, бизнес-логики, связей и обычного SQL-сценария.
- **ClickHouse** заметно лучше показывает себя на больших объёмах и аналитических запросах: фильтрации, агрегации и JOIN-аналитике.

Итоговый вывод:
- если нужна **одна универсальная база** — разумнее выбрать PostgreSQL;
- если задача — **аналитика, отчёты, витрины, дешёвое и быстрое чтение больших массивов** — лучше ClickHouse;
- для реального production-сценария BananaFlow наиболее сильный вариант — связка:
  - PostgreSQL как OLTP-хранилище;
  - ClickHouse как OLAP-хранилище для аналитики и отчётов.

---

## 17. Краткий итог по работе

В рамках работы были выполнены:
- развёртывание PostgreSQL и ClickHouse;
- создание тестовых таблиц;
- загрузка набора данных объёмом около 20 ГБ;
- проверка нескольких механизмов загрузки;
- сравнение трёх типов запросов;
- фиксация времени выполнения, планов и наблюдений.

Общий итог:
- PostgreSQL — удобнее и универсальнее;
- ClickHouse — быстрее на аналитике и bulk load.
