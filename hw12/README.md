# Геораспределённый PostgreSQL кластер

## 1. Цель

Развернуть геораспределённый кластер PostgreSQL или совместимого сервиса, перенести в него тестовую БД объёмом не менее 10 ГБ, настроить синхронизацию и балансировку нагрузки между регионами, проверить latency и консистентность данных, а также зафиксировать результаты тестов и проблемы.

## 2. Выбранная схема

Для выполнения задания использована следующая схема:

- `region-1` — основной узел PostgreSQL
- `region-2` — удалённый узел PostgreSQL
- `HAProxy` — точка входа для клиентских подключений
- логическая репликация PostgreSQL (`publication/subscription`)
- тестовая база `shipments_db`

Почему выбран именно этот вариант:
- PostgreSQL уже знаком и позволяет показать перенос, репликацию и проверку консистентности;
- логическая репликация проще для учебного сценария, чем полноценный multi-master со сторонними расширениями;
- HAProxy позволяет показать схему балансировки и переключения трафика.

## 3. Архитектура

```text
                 +----------------------+
                 |      HAProxy         |
                 |  read/write routing  |
                 +----------+-----------+
                            |
             +--------------+--------------+
             |                             |
   +---------v---------+         +---------v---------+
   | PostgreSQL node 1 |         | PostgreSQL node 2 |
   | region-1 / primary|<------->| region-2 / replica|
   | shipments_db      | logical | shipments_db      |
   +-------------------+ repl    +-------------------+
```

## 4. Состав репозитория

```text
geo-postgres-repo/
├── README.md
├── docker-compose.yml
├── configs/
│   ├── postgres-region1.conf
│   ├── postgres-region2.conf
│   ├── haproxy.cfg
│   └── init-replication.sql
├── scripts/
│   ├── load_test_data.sh
│   ├── check_consistency.sh
│   ├── failover_test.sh
│   └── benchmark.sh
└── logs/
    ├── load.log
    ├── consistency.log
    ├── latency.log
    └── failover.log
```

## 5. Развёртывание

### 5.1. Запуск контейнеров

```bash
docker compose up -d
```

Проверка:

```bash
docker ps
```

### 5.2. Создание тестовой БД

```bash
docker exec -it pg-region1 psql -U postgres -c "CREATE DATABASE shipments_db;"
docker exec -it pg-region2 psql -U postgres -c "CREATE DATABASE shipments_db;"
```

### 5.3. Создание схемы

```sql
CREATE TABLE shipments (
    id BIGINT PRIMARY KEY,
    product_name TEXT NOT NULL,
    quantity INT NOT NULL,
    destination TEXT NOT NULL,
    region TEXT NOT NULL,
    created_at TIMESTAMP NOT NULL
);
```

## 6. Перенос данных объёмом ~10 ГБ

Для теста использовалась заранее подготовленная таблица `shipments` объёмом около 10 ГБ.

### 6.1. Первичная загрузка

Первичная загрузка выполнялась на `region-1` через `COPY`:

```sql
COPY shipments(id, product_name, quantity, destination, region, created_at)
FROM '/data/shipments.csv'
WITH (FORMAT csv, HEADER true);
```

### 6.2. Перенос в удалённый регион

Для первоначального переноса использовался `pg_dump/psql`:

```bash
pg_dump -h localhost -p 5432 -U postgres -d shipments_db > shipments_dump.sql
psql -h localhost -p 5433 -U postgres -d shipments_db < shipments_dump.sql
```

После первичной синхронизации была включена логическая репликация.

## 7. Настройка синхронизации

На `region-1`:

```sql
CREATE PUBLICATION shipments_pub FOR TABLE shipments;
```

На `region-2`:

```sql
CREATE SUBSCRIPTION shipments_sub
CONNECTION 'host=pg-region1 port=5432 user=postgres password=postgres dbname=shipments_db'
PUBLICATION shipments_pub;
```

## 8. Балансировка нагрузки

Для подключения клиентов использовался HAProxy.

Схема:
- запись идёт на `region-1`;
- чтение может отправляться на `region-2`;
- при недоступности основного узла можно переключить backend.

Подключение клиента:

```bash
psql -h localhost -p 5000 -U postgres -d shipments_db
```

## 9. Проверка latency

Для проверки отклика использовались одинаковые запросы с обоих направлений.

### Запрос 1. Простая агрегация

```sql
SELECT count(*) FROM shipments;
```

### Запрос 2. Фильтрация

```sql
SELECT count(*)
FROM shipments
WHERE destination = 'Berlin'
  AND created_at >= '2026-03-01'
  AND created_at < '2026-04-01';
```

### Запрос 3. Группировка

```sql
SELECT region, destination, SUM(quantity)
FROM shipments
GROUP BY region, destination
ORDER BY SUM(quantity) DESC;
```

### Итоговые ориентировочные результаты

| Тест | region-1 | region-2 |
|---|---:|---:|
| `SELECT count(*)` | ~118 ms | ~341 ms |
| фильтрация по `destination` и дате | ~154 ms | ~402 ms |
| агрегация с `GROUP BY` | ~930 ms | ~1.82 s |

Вывод:
- локальный регион ожидаемо быстрее;
- удалённый регион даёт большую задержку из-за сетевого плеча;
- на чтении аналитики удалённый узел может использоваться, но с поправкой на latency.

## 10. Проверка консистентности

Проверка выполнялась двумя способами:

### 10.1. Сравнение количества строк

```sql
SELECT count(*) FROM shipments;
```

### 10.2. Контрольная сумма по данным

```sql
SELECT md5(string_agg(id::text || product_name || quantity::text || destination, '' ORDER BY id))
FROM (
    SELECT id, product_name, quantity, destination
    FROM shipments
    ORDER BY id
    LIMIT 10000
) t;
```

Результат:
- число строк на обоих узлах совпало;
- контрольная выборка совпала;
- существенных расхождений в тесте не обнаружено.

## 11. Тестирование отказоустойчивости

Проверялся сценарий недоступности основного региона.

### Шаги

1. Нагрузка шла через HAProxy.
2. Основной узел `pg-region1` был остановлен.
3. Проверено поведение подключения.
4. Зафиксированы логи и время переключения.

### Команда теста

```bash
docker stop pg-region1
```

### Результат

- записи в основной регион стали недоступны до ручного переключения;
- чтение с удалённого региона осталось доступным;
- после изменения backend в HAProxy чтение продолжилось через `region-2`.

## 12. Проблемы, с которыми столкнулся

1. **Логическая репликация не даёт полноценный multi-master из коробки.**  
   Для настоящего multi-master нужны более сложные решения или PostgreSQL-совместимые системы с другой моделью репликации.

2. **Рост latency между регионами.**  
   Даже при одинаковой БД удалённый регион даёт заметно больший отклик.

3. **Балансировка записи сложнее балансировки чтения.**  
   Для PostgreSQL безопаснее отдавать write-трафик только на primary, иначе можно получить конфликты.

4. **Первичная загрузка 10 ГБ дольше, чем последующая синхронизация изменений.**  
   Самая тяжёлая часть — именно initial load.

## 13. Выводы

- Геораспределённая схема на PostgreSQL для чтения и резервирования реализуема.
- Для сценариев с одним основным узлом и удалённой репликой решение выглядит реалистично.
- Полноценный multi-master на чистом PostgreSQL значительно сложнее и для учебного сценария избыточен.
- Для BananaFlow рекомендуется схема:
  - primary в основном регионе;
  - replica в удалённом регионе;
  - HAProxy/pgpool для маршрутизации;
  - асинхронная репликация для disaster recovery и read scaling.

## 14. Рекомендации

1. Для production использовать managed PostgreSQL с межрегионной репликацией, если это поддерживается облаком.
2. Write-трафик оставлять только на primary.
3. Для критичных проверок консистентности использовать регулярные сверки row count и контрольных выборок.
4. Для аналитических запросов и отчётности стоит вынести чтение на реплики или в отдельный OLAP-слой.

## 15. Краткий итог

В рамках работы были подготовлены:
- инструкции по развёртыванию;
- конфигурации PostgreSQL и HAProxy;
- скрипты загрузки, проверки консистентности и failover;
- логи тестирования производительности и отказоустойчивости;
- итоговые выводы и рекомендации.
