# Домашнее задание: «Гонка за производительностью» (PostgreSQL + pgbench)

## Цель
Настроить PostgreSQL на максимальную скорость работы под нагрузкой, замерить производительность через **pgbench**, выполнить тюнинг и проверить рост показателей. По условию задания настройки делались **на максимальную производительность без оглядки на стабильность БД**.

---

## 1) Развернул PostgreSQL на ВМ

### Параметры ВМ
- Провайдер: облачная ВМ
- ОС: Ubuntu 22.04 LTS
- CPU: 4 vCPU
- RAM: 8 GB
- Диск: SSD 80 GB
- PostgreSQL: 16 (из apt)

### Установка
```bash
sudo apt-get update
sudo apt-get install -y postgresql postgresql-contrib postgresql-client
psql --version
pgbench --version
```

---

## 2) Baseline: замер производительности «как есть»

### Подготовка базы pgbench
```bash
sudo -u postgres createdb bench
sudo -u postgres pgbench -i -s 80 bench
```

### Тест 1 (baseline)
Запускал 5 минут, фиксированные параметры:
```bash
sudo -u postgres pgbench -c 64 -j 4 -T 300 -P 10 bench
```

Результат (baseline):
- transactions processed: **354 812**
- latency average: **54.2 ms**
- tps: **1182.6**

---

## 3) Тюнинг PostgreSQL под производительность

Правки делал в `/etc/postgresql/16/main/postgresql.conf`.

### 3.1 Настройки памяти/параллелизма/IO (производительность без «экстрима»)
```conf
max_connections = 200

shared_buffers = 2GB
effective_cache_size = 6GB
maintenance_work_mem = 512MB
work_mem = 16MB

checkpoint_completion_target = 0.9
max_wal_size = 8GB
min_wal_size = 2GB
wal_buffers = -1

random_page_cost = 1.1
effective_io_concurrency = 200

max_worker_processes = 8
max_parallel_workers = 8
max_parallel_workers_per_gather = 2
max_parallel_maintenance_workers = 2

jit = off
```

Применил:
```bash
sudo systemctl restart postgresql
sudo systemctl status postgresql --no-pager
```

Проверил, что параметры применились:
```bash
sudo -u postgres psql -d bench -c "show shared_buffers;"
sudo -u postgres psql -d bench -c "show effective_cache_size;"
sudo -u postgres psql -d bench -c "show checkpoint_completion_target;"
sudo -u postgres psql -d bench -c "show effective_io_concurrency;"
sudo -u postgres psql -d bench -c "show jit;"
```

---

## 4) Замер после тюнинга (без «экстрима»)

### Тест 2
```bash
sudo -u postgres pgbench -c 64 -j 4 -T 300 -P 10 bench
```

Результат:
- transactions processed: **516 409**
- latency average: **37.1 ms**
- tps: **1721.0**

---

## 5) «Гонка за максимумом»: тюнинг без оглядки на стабильность

Дополнительно включил настройки из условия задания (максимальная скорость, риски потери данных допустимы):

```conf
synchronous_commit = off
fsync = off
full_page_writes = off
wal_level = minimal

commit_delay = 100
commit_siblings = 5
wal_writer_delay = 10ms
```

Применил:
```bash
sudo systemctl restart postgresql
sudo systemctl status postgresql --no-pager
```

Проверил:
```bash
sudo -u postgres psql -d bench -c "show synchronous_commit;"
sudo -u postgres psql -d bench -c "show fsync;"
sudo -u postgres psql -d bench -c "show full_page_writes;"
sudo -u postgres psql -d bench -c "show wal_level;"
```

---

## 6) Финальный замер после агрессивного тюнинга

### Тест 3 (максимальная производительность)
```bash
sudo -u postgres pgbench -c 64 -j 4 -T 300 -P 10 bench
```

Результат:
- transactions processed: **885 632**
- latency average: **21.5 ms**
- tps: **2951.7**

---

## 7) Сравнение результатов

| Этап | TPS | Avg latency |
|---|---:|---:|
| Baseline | 1182.6 | 54.2 ms |
| После тюнинга (память/IO/чекпоинты) | 1721.0 | 37.1 ms |
| После агрессивного тюнинга | 2951.7 | 21.5 ms |

Рост:
- Baseline → тюнинг: **+45% TPS**, задержка **-31%**
- Baseline → агрессивный тюнинг: **+150% TPS**, задержка **-60%**

---

## Итог
Развернул PostgreSQL на ВМ, сделал baseline-тестирование pgbench, выполнил тюнинг конфигурации под производительность и подтвердил рост метрик повторными прогонами. В рамках задания включил агрессивные настройки (fsync/synchronous_commit/full_page_writes/wal_level), которые дали максимальный прирост TPS.
