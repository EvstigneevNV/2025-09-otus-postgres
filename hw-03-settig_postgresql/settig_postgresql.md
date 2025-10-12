# Отчёт (пошагово, от первого лица): PostgreSQL 15 на внешнем диске

## Что сделал

### 1. Установил PostgreSQL 15
На Ubuntu 20.04 добавил PGDG и поставил 15-ю версию:
```bash
curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo apt-key add -
echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" | \
  sudo tee /etc/apt/sources.list.d/pgdg.list
sudo apt-get update && sudo apt-get -y install postgresql-15
sudo -u postgres psql -c "select version();"
```

### 2. Создал таблицу и данные
```bash
sudo -u postgres psql <<'SQL'
create table if not exists shipments(
  id serial primary key,
  product_name text, quantity int, destination text
);
insert into shipments(product_name, quantity, destination) values
('bananas',1000,'Europe'),('bananas',1500,'Asia'),('bananas',2000,'Africa'),
('coffee',500,'USA'),('coffee',700,'Canada'),('coffee',300,'Japan'),
('sugar',1000,'Europe'),('sugar',800,'Asia'),('sugar',600,'Africa'),('sugar',400,'USA')
on conflict do nothing;
select count(*) from shipments; -- увидел 10
SQL
```

### 3. Подключил внешний диск и смонтировал
Нашёл диск `/dev/sdb`, разметил и смонтировал в `/mnt/pgdata`:
```bash
sudo parted -s /dev/sdb mklabel gpt
sudo parted -s /dev/sdb mkpart primary ext4 0% 100%
sudo mkfs.ext4 -F /dev/sdb1
sudo mkdir -p /mnt/pgdata && sudo mount /dev/sdb1 /mnt/pgdata
UUID=$(sudo blkid -s UUID -o value /dev/sdb1)
echo "UUID=$UUID /mnt/pgdata ext4 defaults,nofail 0 2" | sudo tee -a /etc/fstab
```

### 4. Перенёс кластер данных на новый диск
Остановил Postgres и скопировал данные:
```bash
sudo systemctl stop postgresql
sudo rsync -aHAX --numeric-ids /var/lib/postgresql/15/main/ /mnt/pgdata/main/
sudo chown -R postgres:postgres /mnt/pgdata/main
sudo chmod 700 /mnt/pgdata/main
```
Поменял `data_directory`:
```bash
sudo sed -i "s|^[# ]*data_directory *=.*|data_directory = '/mnt/pgdata/main'|" \
  /etc/postgresql/15/main/postgresql.conf
```

### 5. Разрешил доступ AppArmor и запустил
Разрешил новый путь профилю Postgres и перезагрузил профиль:
```bash
echo "/mnt/pgdata/main/** r,"  | sudo tee -a /etc/apparmor.d/local/usr.sbin.postgres
echo "/mnt/pgdata/main/** rwk," | sudo tee -a /etc/apparmor.d/local/usr.sbin.postgres
sudo apparmor_parser -r /etc/apparmor.d/usr.sbin.postgres
sudo systemctl start postgresql
```
Проверил, что Postgres читает новый каталог и что данные на месте:
```bash
sudo -u postgres psql -c "select current_setting('data_directory');"
sudo -u postgres psql -c "select count(*) from shipments;"  # 10
```

### 6. Проверил после перезагрузки
Сделал `sudo reboot`. После загрузки убедился, что диск смонтировался, сервис активен, строки на месте.

## Проблемы и как решал
- При первом запуске Postgres не стартовал: AppArmor блокировал доступ к `/mnt/pgdata`. Добавил правила в `usr.sbin.postgres` и перезагрузил профиль — сервис поднялся.
- Поймал ошибку прав на каталоге. Исправил владельца и режим: `chown -R postgres:postgres` и `chmod 700`.
- fstab забыл — после перезагрузки диск не примонтировался. Прописал `UUID=... /mnt/pgdata ext4 defaults,nofail 0 2` и повторил проверку.
