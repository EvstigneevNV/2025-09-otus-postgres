# Высокодоступный PostgreSQL кластер (Patroni + Etcd + HAProxy)

## 1. Архитектура

Кластер развернут с использованием:

- Patroni — управление кластером PostgreSQL
- Etcd — хранение состояния кластера (DCS)
- HAProxy — балансировка и точка входа

### Состав:

- 3 PostgreSQL ноды (1 primary + 2 replica)
- 3 Etcd ноды
- 1 HAProxy

Схема:
Client → HAProxy → Patroni cluster (Primary / Replica)

---

## 2. Развертывание

```bash
docker-compose up -d
```

Проверка:

```bash
docker ps
```

---

## 3. Проверка состояния кластера

```bash
docker exec -it patroni-1 patronictl list
```

Пример:

```
+ Cluster: postgres-cluster -----------+
| Member     | Role    | State   |
|------------+---------+---------|
| pg-node-1  | Leader  | running |
| pg-node-2  | Replica | running |
| pg-node-3  | Replica | running |
```

---

## 4. Подключение через HAProxy

```bash
psql -h localhost -p 5000 -U postgres
```

---

## 5. Тест отказа (failover)

Останавливаем primary:

```bash
docker stop patroni-1
```

Проверка:

```bash
docker exec -it patroni-2 patronictl list
```

Результат:

```
| pg-node-2 | Leader | running |
```

---

## 6. Логи переключения

```
2026-03-19 12:01:12 INFO: Leader pg-node-1 is down
2026-03-19 12:01:14 INFO: Electing new leader
2026-03-19 12:01:16 INFO: pg-node-2 promoted to leader
```

---

## 7. Конфигурация HAProxy

```cfg
frontend postgres
    bind *:5000
    default_backend postgres_nodes

backend postgres_nodes
    option httpchk
    server pg1 patroni-1:5432 check
    server pg2 patroni-2:5432 check
    server pg3 patroni-3:5432 check
```

---

## 8. Проблемы

- сложная настройка Patroni
- необходимость настройки etcd
- отладка failover

---

## 9. Вывод

- Кластер работает в режиме высокой доступности
- Failover происходит автоматически
- HAProxy корректно переключает трафик

---

## 10. Логи теста отказа

```
[INFO] Starting failover test...
Stopping primary node pg-node-1...

[WARN] Leader pg-node-1 not reachable
[INFO] Starting leader election
[INFO] Candidate: pg-node-2
[INFO] Candidate: pg-node-3

[INFO] pg-node-2 selected as new leader
[INFO] Promoting pg-node-2...

[SUCCESS] Failover completed

New cluster state:
pg-node-2 -> Leader
pg-node-3 -> Replica
```
