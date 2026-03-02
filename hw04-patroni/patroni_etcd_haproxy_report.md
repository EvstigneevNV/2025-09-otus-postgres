# Мини‑отчёт: отказоустойчивый кластер PostgreSQL (Patroni + etcd) + HAProxy

## Цель
Развернуть отказоустойчивый кластер PostgreSQL на **Patroni** с DCS на **etcd** и проксированием через **HAProxy**:
- порт **write** ведёт на текущий **primary**
- порт **read** ведёт на **replica**
- проверить failover, имитировав падение одного узла  
Дополнительно: настроить бэкапы через **WAL‑G**.

---

## 0) Стенд и схема

### ВМ и адресация (пример из моего стенда)
**etcd:**
- `etcd1` — `10.10.10.11`
- `etcd2` — `10.10.10.12`
- `etcd3` — `10.10.10.13`

**PostgreSQL + Patroni:**
- `pg1` — `10.10.20.21`
- `pg2` — `10.10.20.22`
- `pg3` — `10.10.20.23`

**HAProxy:**
- `haproxy` — `10.10.30.31`

### Порты
- etcd: `2379` (client), `2380` (peer)
- Patroni REST API: `8008`
- PostgreSQL: `5432`
- HAProxy: `5000` (write), `5001` (read), `7000` (stats)

---

## 1) Поднял 6 виртуальных машин

Сделал 3 ВМ под etcd и 3 ВМ под Patroni/PostgreSQL.  
На всех узлах настроил статические IP, проверил связность:

```bash
ping -c 2 10.10.10.11
ping -c 2 10.10.20.21
```

**Проблема:** одна ВМ не пинговалась.  
**Решение:** выяснилось, что был закрыт трафик (ufw). Открыл нужные порты и проверил маршруты.

---

## 2) Развернул etcd‑кластер (3 узла)

### 2.1 Установка etcd (на каждом etcd‑узле)
```bash
sudo apt-get update
sudo apt-get install -y etcd
```

Если включён `ufw`, открыл порты:
```bash
sudo ufw allow 2379/tcp
sudo ufw allow 2380/tcp
```

### 2.2 Конфигурация etcd (пример для `etcd1`)
Файл: `/etc/default/etcd` (на моём образе Ubuntu пакетный etcd использует этот файл)

```bash
sudo tee /etc/default/etcd > /dev/null <<'EOF'
ETCD_NAME="etcd1"
ETCD_DATA_DIR="/var/lib/etcd"
ETCD_LISTEN_PEER_URLS="http://10.10.10.11:2380"
ETCD_LISTEN_CLIENT_URLS="http://10.10.10.11:2379,http://127.0.0.1:2379"
ETCD_INITIAL_ADVERTISE_PEER_URLS="http://10.10.10.11:2380"
ETCD_ADVERTISE_CLIENT_URLS="http://10.10.10.11:2379"
ETCD_INITIAL_CLUSTER="etcd1=http://10.10.10.11:2380,etcd2=http://10.10.10.12:2380,etcd3=http://10.10.10.13:2380"
ETCD_INITIAL_CLUSTER_STATE="new"
ETCD_INITIAL_CLUSTER_TOKEN="pg-etcd-cluster"
EOF
```

На `etcd2/etcd3` поменял `ETCD_NAME` и IP.

### 2.3 Запуск и проверка кластера
```bash
sudo systemctl enable --now etcd
sudo systemctl status etcd --no-pager
```

Проверил здоровье и статус:
```bash
ETCDCTL_API=3 etcdctl --endpoints=http://10.10.10.11:2379,http://10.10.10.12:2379,http://10.10.10.13:2379 endpoint health -w table
ETCDCTL_API=3 etcdctl --endpoints=http://10.10.10.11:2379,http://10.10.10.12:2379,http://10.10.10.13:2379 endpoint status -w table
```

**Проблема:** на одном из узлов ловил «уже инициализирован/bootstrapped».  
**Решение:** удалил старые данные `/var/lib/etcd` на проблемном узле, после чего кластер стартанул корректно.

---

## 3) Установил PostgreSQL + Patroni на 3 узла

На `pg1/pg2/pg3`:
```bash
sudo apt-get update
sudo apt-get install -y postgresql postgresql-contrib python3-pip
sudo pip3 install -U patroni[etcd] psycopg2-binary
```

Чтобы PostgreSQL контролировал Patroni, остановил стандартный сервис:
```bash
sudo systemctl stop postgresql
sudo systemctl disable postgresql
```

Подготовил директории и права:
```bash
sudo mkdir -p /etc/patroni
sudo chown -R postgres:postgres /etc/patroni

sudo mkdir -p /var/lib/postgresql/16/main
sudo chown -R postgres:postgres /var/lib/postgresql
```

**Проблема:** Patroni падал из‑за прав на `data_dir`.  
**Решение:** сделал `chown` на `postgres:postgres` (см. выше).

---

## 4) Настроил Patroni‑кластер

### 4.1 Конфиг `patroni.yml` (пример `pg1`)
Файл: `/etc/patroni/patroni.yml`

```yaml
scope: banana
namespace: /service/
name: pg1

restapi:
  listen: 10.10.20.21:8008
  connect_address: 10.10.20.21:8008

etcd:
  hosts: 10.10.10.11:2379,10.10.10.12:2379,10.10.10.13:2379

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
    postgresql:
      use_pg_rewind: true
      use_slots: true
      parameters:
        wal_level: replica
        hot_standby: "on"
        max_wal_senders: 10
        max_replication_slots: 10
        wal_keep_size: 512MB
        synchronous_commit: "on"
  initdb:
    - encoding: UTF8
    - data-checksums
  pg_hba:
    - host all all 0.0.0.0/0 md5
    - host replication replicator 10.10.20.0/24 md5

postgresql:
  listen: 10.10.20.21:5432
  connect_address: 10.10.20.21:5432
  data_dir: /var/lib/postgresql/16/main
  bin_dir: /usr/lib/postgresql/16/bin
  authentication:
    superuser:
      username: postgres
      password: postgres_pass
    replication:
      username: replicator
      password: repl_pass
  pgpass: /tmp/pgpass

tags:
  nofailover: false
  noloadbalance: false
  clonefrom: false
  nosync: false
```

На `pg2` и `pg3` поменял только:
- `name: pg2/pg3`
- `restapi.listen/connect_address` → IP своего узла
- `postgresql.listen/connect_address` → IP своего узла

### 4.2 Сервис systemd для Patroni
Создал `/etc/systemd/system/patroni.service`:

```ini
[Unit]
Description=Patroni PostgreSQL HA Cluster Node
After=network-online.target
Wants=network-online.target

[Service]
User=postgres
Group=postgres
Type=simple
ExecStart=/usr/local/bin/patroni /etc/patroni/patroni.yml
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
```

Запустил на каждом узле:
```bash
sudo systemctl daemon-reload
sudo systemctl enable --now patroni
sudo systemctl status patroni --no-pager
```

### 4.3 Проверил состояние кластера
```bash
patronictl -c /etc/patroni/patroni.yml list
```

Ожидаемый результат: 1 лидер (Leader) + 2 реплики (Replica).

**Проблема:** один раз Patroni не видел etcd.  
**Решение:** проверил доступность `10.10.10.x:2379` и открыл firewall — после этого Patroni поднялся и зарегистрировался в DCS.

---

## 5) Настроил HAProxy для write/read

### 5.1 Установка на `haproxy`
```bash
sudo apt-get update
sudo apt-get install -y haproxy
```

### 5.2 Конфиг `/etc/haproxy/haproxy.cfg`
Сделал 2 listener’а:
- `pg_write` на `:5000` — healthcheck на `/master`
- `pg_read` на `:5001` — healthcheck на `/replica`

```cfg
global
  maxconn 20000

defaults
  mode tcp
  timeout connect 5s
  timeout client  1m
  timeout server  1m

listen stats
  bind *:7000
  mode http
  stats enable
  stats uri /

listen pg_write
  bind *:5000
  option httpchk GET /master
  http-check expect status 200
  default-server inter 2s fall 3 rise 2 on-marked-down shutdown-sessions
  server pg1 10.10.20.21:5432 check port 8008
  server pg2 10.10.20.22:5432 check port 8008
  server pg3 10.10.20.23:5432 check port 8008

listen pg_read
  bind *:5001
  balance roundrobin
  option httpchk GET /replica
  http-check expect status 200
  default-server inter 2s fall 3 rise 2
  server pg1 10.10.20.21:5432 check port 8008
  server pg2 10.10.20.22:5432 check port 8008
  server pg3 10.10.20.23:5432 check port 8008
```

Проверил конфиг и перезапустил:
```bash
sudo haproxy -c -f /etc/haproxy/haproxy.cfg
sudo systemctl restart haproxy
sudo systemctl status haproxy --no-pager
```

**Проблема:** HAProxy сначала показывал все backend’ы down.  
**Решение:** понял, что закрыт порт `8008` между haproxy и pg‑узлами. Открыл и перепроверил healthchecks.

---

## 6) Проверка отказоустойчивости (имитация сбоя)

### 6.1 Проверил write через HAProxy
```bash
psql "host=10.10.30.31 port=5000 user=postgres password=postgres_pass dbname=postgres" -c "select 1;"
psql "host=10.10.30.31 port=5000 user=postgres password=postgres_pass dbname=postgres" -c "create table if not exists t(i int); insert into t values (1);"
```

### 6.2 Проверил read через HAProxy
```bash
psql "host=10.10.30.31 port=5001 user=postgres password=postgres_pass dbname=postgres" -c "select count(*) from t;"
```

### 6.3 Уронил лидера
Сначала посмотрел лидера:
```bash
patronictl -c /etc/patroni/patroni.yml list
```

На лидере остановил Patroni:
```bash
sudo systemctl stop patroni
```

Через ~10–30 секунд Patroni выбрал нового лидера. HAProxy автоматически переключил write‑трафик на новый primary.

Проверил запись после failover:
```bash
psql "host=10.10.30.31 port=5000 user=postgres password=postgres_pass dbname=postgres" -c "insert into t values (2);"
psql "host=10.10.30.31 port=5001 user=postgres password=postgres_pass dbname=postgres" -c "select * from t order by i;"
```

**Результат:** сервис остался доступным, запись/чтение продолжились, данные сохранились.

---

## 7) Дополнительно: бэкапы через WAL‑G (опционально)

Я сделал базовую настройку WAL‑архивации и basebackup через WAL‑G (сначала в локальное хранилище на диске, чтобы проверить механику).

### 7.1 Подготовил хранилище
```bash
sudo mkdir -p /var/backups/walg
sudo chown -R postgres:postgres /var/backups/walg
```

### 7.2 Переменные окружения WAL‑G
Пример для локального storage (file):
- `WALG_FILE_PREFIX=file:///var/backups/walg`

### 7.3 Включил архивацию в Patroni
В `patroni.yml` добавил:
```yaml
postgresql:
  parameters:
    archive_mode: "on"
    archive_timeout: 60s
    archive_command: "wal-g wal-push %p"
    restore_command: "wal-g wal-fetch %f %p"
```

### 7.4 Проверил backup‑push и список бэкапов
```bash
sudo -u postgres wal-g backup-push /var/lib/postgresql/16/main
sudo -u postgres wal-g backup-list
```

**Проблема:** один раз `archive_command failed`.  
**Решение:** исправил путь к `wal-g` и проверил, что env доступен пользователю `postgres`.

---

## Итог
- Поднял **etcd‑кластер из 3 узлов** и убедился, что есть кворум.
- Развернул **Patroni/PostgreSQL кластер из 3 узлов**, получил 1 primary + 2 replica.
- Настроил **HAProxy** на write/read порты с проверкой роли по Patroni REST.
- Протестировал **failover** остановкой лидера — кластер автоматически выбрал нового primary, доступность сохранилась.
- Дополнительно подключил **WAL‑G** и проверил создание basebackup и WAL‑архивацию (в базовом виде).
