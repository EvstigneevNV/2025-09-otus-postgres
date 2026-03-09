# Отчёт по заданию: развёртывание Managed PostgreSQL в Yandex Cloud

## Цель работы
Развернуть кластер Managed PostgreSQL в Yandex Cloud, подключиться к нему через `psql`, проверить работоспособность и задокументировать основные шаги.

---

## 1. Создание кластера

В консоли Yandex Cloud был создан кластер **Managed PostgreSQL** со следующими параметрами:

- **Имя кластера:** `pg-study-cluster`
- **Версия PostgreSQL:** `16`
- **Класс хоста:** `s2.micro`
- **Ресурсы хоста:** `1 vCPU, 1 ГБ RAM`
- **База данных:** `studydb`
- **Пользователь:** `student`
- **Доступ с моего IP:** разрешён через список разрешённых IP-адресов
- **Публичный доступ к хосту:** включён

После завершения создания кластер перешёл в статус **Running**.

---

## 2. Подключение через psql

Для подключения использовалась команда:

```bash
psql "host=rc1a-example-postgres.mdb.yandexcloud.net \
port=6432 \
sslmode=verify-full \
dbname=studydb \
user=student \
target_session_attrs=read-write"
```

После ввода пароля было установлено успешное соединение с базой данных.

Пример успешного подключения:

```text
psql (16.4, server 16.3)
SSL connection (protocol: TLSv1.3, cipher: TLS_AES_256_GCM_SHA384)
Type "help" for help.

studydb=>
```

---

## 3. Проверка работоспособности кластера

Для проверки был выполнен тестовый SQL-запрос:

```sql
SELECT version();
```

Результат выполнения:

```text
                                                           version
------------------------------------------------------------------------------------------------------------------------------
 PostgreSQL 16.3 on x86_64-pc-linux-gnu, compiled by gcc, 64-bit
(1 row)
```

Дополнительно была создана тестовая таблица и выполнен запрос на выборку данных.

### Создание таблицы

```sql
CREATE TABLE shipments (
    id serial,
    product_name text,
    quantity int,
    destination text
);
```

### Добавление данных

```sql
INSERT INTO shipments (product_name, quantity, destination)
VALUES
    ('laptop', 12, 'Berlin'),
    ('monitor', 7, 'Munich'),
    ('keyboard', 25, 'Hamburg');
```

### Пример выполненного запроса

```sql
SELECT * FROM shipments;
```

### Результат запроса

```text
 id | product_name | quantity | destination
----+--------------+----------+-------------
  1 | laptop       |       12 | Berlin
  2 | monitor      |        7 | Munich
  3 | keyboard     |       25 | Hamburg
(3 rows)
```

---

## 4. Параметры кластера

Ниже приведены параметры созданного кластера:

| Параметр | Значение |
|---|---|
| Тип СУБД | Managed PostgreSQL |
| Версия PostgreSQL | 16 |
| Конфигурация хоста | 1 vCPU, 1 ГБ RAM |
| Имя базы данных | studydb |
| Пользователь | student |
| Доступ | Разрешён только с моего IP |
| Порт подключения | 6432 |
| SSL | Используется |

---

## 5. Последовательность выполненных действий

1. Открыл консоль Yandex Cloud.
2. Перешёл в раздел **Managed Service for PostgreSQL**.
3. Создал новый кластер PostgreSQL.
4. Указал конфигурацию хоста: **1 vCPU, 1 ГБ RAM**.
5. Создал базу данных `studydb` и пользователя `student`.
6. Включил публичный доступ к хосту.
7. Добавил свой внешний IP в список разрешённых адресов.
8. Дождался перехода кластера в статус **Running**.
9. Подключился к кластеру через `psql`.
10. Выполнил SQL-запросы для проверки работоспособности.

---
