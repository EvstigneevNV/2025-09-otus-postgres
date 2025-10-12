## Что сделал

### 1. Завёл ВМ
Поднял Ubuntu 20.04 в Yandex.Cloud, открыл SSH и порт `5432` в SG.

### 2. Поставил Docker
Я добавил официальный репозиторий и установил движок:
```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu focal stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io
sudo usermod -aG docker $USER
```
Проверил `docker version` — установился.

### 3. Подготовил директорию под данные
Создал каталог для постоянного хранения и сразу выставил владельца (uid 999 у postgres в образе):
```bash
sudo mkdir -p /var/lib/postgres
sudo chown 999:999 /var/lib/postgres
```

### 4. Запустил контейнер PostgreSQL 14 с volume
```bash
docker run -d --name pg14 \
  -e POSTGRES_USER=app -e POSTGRES_PASSWORD=app -e POSTGRES_DB=appdb \
  -v /var/lib/postgres:/var/lib/postgresql/data \
  -p 5432:5432 postgres:14
```

### 5. Зашёл psql из отдельного контейнера
```bash
docker run -it --rm --network host postgres:14 psql "postgres://app:app@127.0.0.1:5432/appdb"
```
Создал таблицу и залил строки:
```sql
create table shipments(
  id serial primary key,
  product_name text, quantity int, destination text
);
insert into shipments(product_name, quantity, destination) values
('bananas',1000,'Europe'),('bananas',1500,'Asia'),('bananas',2000,'Africa'),
('coffee',500,'USA'),('coffee',700,'Canada'),('coffee',300,'Japan'),
('sugar',1000,'Europe'),('sugar',800,'Asia'),('sugar',600,'Africa'),('sugar',400,'USA');
select count(*) from shipments; -- получил 10
```

### 6. Проверил доступ с ноутбука
Подключился по публичному IP:
```bash
psql "postgres://app:app@<PUBLIC_IP>:5432/appdb" -c "select count(*) from shipments;"
```
Увидел 10 — значит сеть ок.

### 7. Убедился, что данные переживают пересоздание контейнера
Удалил контейнер и поднял заново **с тем же volume**:
```bash
docker rm -f pg14
docker run -d --name pg14 \
  -e POSTGRES_USER=app -e POSTGRES_PASSWORD=app -e POSTGRES_DB=appdb \
  -v /var/lib/postgres:/var/lib/postgresql/data \
  -p 5432:5432 postgres:14
```
Снова зашёл и попросил количество строк — осталось 10.

## Проблемы и как решал
- Контейнер ругнулся на права каталога. Исправил `sudo chown 999:999 /var/lib/postgres` и перезапустил.
- Снаружи не подключался psql. Открыл порт `5432` в SG и проверил проброс `-p 5432:5432`.
- После пересоздания контейнера данных не было, когда забывал volume. Вернул флаг `-v /var/lib/postgres:/var/lib/postgresql/data` — данные вернулись.