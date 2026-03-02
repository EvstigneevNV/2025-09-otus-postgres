# Мини-отчёт: бэкапы и восстановление PostgreSQL (pg_probackup)

## Цель
Настроить **надёжное резервное копирование** и **восстановление** PostgreSQL для БД **«Лояльность оптовиков»** так, чтобы:
1) бэкапы делались регулярно и не «убивали» прод по ресурсам;  
2) можно было восстановиться на **другом кластере/сервере** и убедиться, что бэкапы реально рабочие;  
3) восстановленные данные проверялись на корректность;  
4) дополнительно — снять бэкап **под нагрузкой с реплики**.

В качестве инструмента использовал **pg_probackup** (поддерживает режимы FULL/DELTA/PAGE + WAL delivery ARCHIVE/STREAM и бэкапы со standby при корректной настройке).

---

## 0) Входные данные и стенд

### Узлы (пример из моего стенда)
- `pg-primary` — основной кластер/primary (PostgreSQL 16)
- `pg-replica` — реплика (hot standby)
- `backup-host` — отдельная ВМ/хост под каталог бэкапов (диск + место), чтобы бэкап не лежал рядом с базой
- `pg-restore` — отдельная ВМ/хост для тестового восстановления

### Порты/доступы
- открыт доступ от `backup-host` к PostgreSQL на `pg-primary`/`pg-replica`
- настроены SSH-ключи (если используется remote mode)

---

## 1) Настроил бэкапы PostgreSQL через pg_probackup

### 1.1 Установка pg_probackup
Поставил pg_probackup **на backup-host и на postgres-узлы** (важно держать одинаковую версию, если делаю remote-операции).

### 1.2 Создал роль для бэкапов
На primary создал роль `backup` с правами репликации:

```sql
CREATE ROLE backup WITH LOGIN REPLICATION PASSWORD 'backup_pass';
```

В `pg_hba.conf` добавил доступ для `backup` (пример — разрешил с подсети backup-host/репликации):
```conf
host  replication  backup  10.10.30.0/24  md5
host  all          backup  10.10.30.0/24  md5
```

Перечитал конфиг:
```bash
sudo systemctl reload postgresql
```

### 1.3 Параметры для бэкапа с реплики
Проверил/включил:
- на **реплике** `hot_standby=on`
- на **primary** `full_page_writes=on`

Проверка на primary:
```sql
SHOW full_page_writes;
```

### 1.4 Инициализировал каталог бэкапов и добавил инстанс
Каталог на `backup-host` (на отдельном диске):
```bash
sudo mkdir -p /mnt/backups/pg_probackup
sudo chown -R backup_user:backup_user /mnt/backups/pg_probackup
```

Инициализация:
```bash
pg_probackup init -B /mnt/backups/pg_probackup
```

Добавил инстанс (логическое имя — `loyalty`):
```bash
pg_probackup add-instance -B /mnt/backups/pg_probackup -D /var/lib/postgresql/16/main --instance=loyalty
```

### 1.5 Настроил сжатие/ретеншн/таймауты
Сделал конфиг:
```bash
pg_probackup set-config -B /mnt/backups/pg_probackup --instance=loyalty   --compress-algorithm=zlib --compress-level=1   --retention-redundancy=2 --retention-window=7   --archive-timeout=600
```

Почему так:
- `compress-level=1` — чтобы сжатие не сжирало CPU;
- `retention` — чтобы не раздувать хранилище;
- `archive-timeout` — чтобы бэкап не падал, если доставка WAL идёт медленно.

### 1.6 Включил непрерывное архивирование WAL
На primary включил WAL-архивацию через `archive_command` → `pg_probackup archive-push`.

Пример (path адаптировал под свою установку):
```conf
archive_mode = on
archive_command = '/usr/bin/pg_probackup archive-push -B /mnt/backups/pg_probackup --instance=loyalty --wal-file-name=%f --wal-file-path=%p'
archive_timeout = 300s
```

**Проблема:** `archive_command` не стартовал из-за кавычек/пути.  
**Решение:** проверил полный путь до `pg_probackup`, убрал лишние кавычки, протестировал команду вручную.

---

## 2) Снял бэкап так, чтобы он не влиял на производительность

### 2.1 Базовый FULL бэкап (STREAM + temp-slot)
Снял FULL (первый базовый) в STREAM-режиме:
```bash
pg_probackup backup -B /mnt/backups/pg_probackup --instance=loyalty -b FULL --stream --temp-slot -j 4 --smooth-checkpoint
```

Посмотрел список бэкапов:
```bash
pg_probackup show -B /mnt/backups/pg_probackup --instance=loyalty
```

### 2.2 Инкрементальные (DELTA) после FULL
```bash
pg_probackup backup -B /mnt/backups/pg_probackup --instance=loyalty -b DELTA --stream --temp-slot -j 4
```

### 2.3 Что сделал для снижения влияния
- FULL бэкапы планировал на ночное окно;
- запускал с пониженным приоритетом:
```bash
nice -n 10 ionice -c2 -n7 pg_probackup backup -B /mnt/backups/pg_probackup --instance=loyalty -b FULL --stream --temp-slot -j 4 --smooth-checkpoint
```
- параллелизм держал умеренным (`-j 4`), чтобы не «положить» диск.

---

## 3) Восстановил данные на другом кластере/сервере (проверка бэкапов)

### 3.1 Подготовил отдельный сервер/кластер для восстановления
На `pg-restore` поднял чистый PostgreSQL той же major-версии (16), остановил сервис:
```bash
sudo systemctl stop postgresql
```

Старый `PGDATA` убрал в сторону:
```bash
sudo mv /var/lib/postgresql/16/main /var/lib/postgresql/16/main.bak.$(date +%F_%H%M%S)
sudo mkdir -p /var/lib/postgresql/16/main
sudo chown -R postgres:postgres /var/lib/postgresql/16/main
```

### 3.2 Восстановление из последнего FULL
Нашёл нужный backup ID:
```bash
pg_probackup show -B /mnt/backups/pg_probackup --instance=loyalty
```

Восстановил (пример с конкретным ID):
```bash
pg_probackup restore -B /mnt/backups/pg_probackup --instance=loyalty -i <BACKUP_ID> -D /var/lib/postgresql/16/main
```

Запустил PostgreSQL:
```bash
sudo systemctl start postgresql
```

**Проблема:** первый старт упал из-за прав на каталог.  
**Решение:** `chown -R postgres:postgres` на `PGDATA` и повторный старт.

---

## 4) Проверил корректность восстановленных данных

### 4.1 Проверка целостности бэкапа средствами pg_probackup
Перед/после restore прогнал валидацию:
```bash
pg_probackup validate -B /mnt/backups/pg_probackup --instance=loyalty
```

### 4.2 Функциональная проверка на уровне данных
Перед бэкапом на боевой базе создал контрольные данные:
```sql
CREATE TABLE IF NOT EXISTS loyalty_check(
  id bigserial primary key,
  v text,
  created_at timestamptz default now()
);

INSERT INTO loyalty_check(v) VALUES ('backup_test_1'), ('backup_test_2');
SELECT count(*) FROM loyalty_check;
```

После восстановления на `pg-restore` проверил:
```sql
SELECT count(*) FROM loyalty_check;
SELECT * FROM loyalty_check ORDER BY id DESC LIMIT 5;
```

Результат: контрольные записи на месте, запросы выполняются, схема поднялась корректно.

---

## 5) Дополнительно: снял бэкап под нагрузкой с реплики

### 5.1 Создал нагрузку на primary
На primary запустил `pgbench`:
```bash
pgbench -i -s 10 postgres
pgbench -c 30 -j 6 -T 300 postgres
```

### 5.2 На реплике сделал FULL бэкап во время нагрузки
На `pg-replica` запустил FULL бэкап (процесс — с пониженным приоритетом):
```bash
nice -n 10 ionice -c2 -n7 pg_probackup backup -B /mnt/backups/pg_probackup --instance=loyalty -b FULL --stream --temp-slot -j 4 --smooth-checkpoint
```

Контроль:
- на primary следил за лагом репликации (чтобы не улететь в минуты/часы);
- по итогу `pg_probackup show` — backup в статусе `OK`.

**Нюанс:** если реплика промоутнется в primary во время бэкапа — бэкап падает (ограничение standby backup).

---

## Итог
1) Настроил бэкапы PostgreSQL для **«Лояльность оптовиков»** через **pg_probackup**: каталог, инстанс, права, сжатие и ретеншн.  
2) Включил WAL-архивацию через `archive_command` + `archive-push`.  
3) Снял FULL + DELTA бэкапы в STREAM режиме с `--temp-slot` и контролем нагрузки.  
4) Восстановил данные на отдельном сервере и проверил корректность восстановленных данных SQL-проверками.  
5) Дополнительно снял FULL бэкап **с реплики под нагрузкой** и убедился, что primary продолжает обслуживать запросы без критической деградации.
