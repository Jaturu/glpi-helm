# Database and secrets

GLPI needs MySQL 8.0+ or MariaDB 10.11+. The chart either runs MariaDB itself
or connects to one you provide. Exactly one is used, chosen by
`mariadb.enabled`.

Examples on this page assume release `desk` in namespace `glpi`, so resources
are named `desk-glpi*`.

## Built-in MariaDB (default)

`mariadb.enabled: true` deploys a single-replica StatefulSet from the official
`mariadb` image, pinned to the `11.8` LTS series.

- The database and user named in `mariadb.auth` are created on first start.
- `MARIADB_AUTO_UPGRADE=1` runs `mariadb-upgrade` after an image change, so
  patch and minor updates within a series apply without manual steps.
- Server settings come from `mariadb.config`, mounted as
  `/etc/mysql/conf.d/zz-chart.cnf`. The default sets utf8mb4, disables reverse
  DNS lookups and uses a 256 MB InnoDB buffer pool. Keep
  `mariadb.resources.limits.memory` comfortably above the buffer pool. A GLPI
  with a large inventory benefits from a bigger pool.
- The data volume comes from a `volumeClaimTemplate` with
  `persistentVolumeClaimRetentionPolicy: Retain`. Deleting or scaling the
  StatefulSet never deletes the data.

The application connects to the headless Service `desk-glpi-mariadb`.
You don't need to set `externalDatabase` at all.

## External database

```yaml
mariadb:
  enabled: false
externalDatabase:
  host: mariadb.databases.svc
  port: 3306
  database: glpi
  username: glpi
  existingSecret: glpi-db
  passwordKey: password
```

Create the database and user first, with full privileges on that database.
GLPI installs and updates its own schema:

```sql
CREATE DATABASE glpi CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'glpi'@'%' IDENTIFIED BY '<password>';
GRANT ALL PRIVILEGES ON glpi.* TO 'glpi'@'%';
```

and the Secret:

```console
kubectl -n glpi create secret generic glpi-db \
  --from-literal=password='<password>'
```

The chart fails to render if `externalDatabase.host` or
`externalDatabase.existingSecret` is empty while `mariadb.enabled` is false.

An external database that already holds GLPI tables is updated, not
reinstalled. The `migrate` step only installs into a database with no
`glpi_*` tables.

## How GLPI gets its connection settings

GLPI does not read the database connection from the environment. It reads
`config/config_db.php`, which on this chart is `/var/glpi/config/config_db.php`
on the data volume. The `migrate` init container writes that file on every pod
start from the chart's database values and the password Secret, using GLPI's
own `database:install` or `database:configure` command.

Two consequences:

- Changing `externalDatabase.*`, or rotating the password in the Secret, takes
  effect at the next pod start. Secrets are not checksummed, so restart the
  pod after rotating one:
  `kubectl -n glpi rollout restart deploy/desk-glpi`.
- With `migrations.enabled: false` nothing writes the file. Use that only if
  you manage `config_db.php` on the volume yourself.

## Secrets and keys

| What | Where | Created when |
|------|-------|--------------|
| `mariadb-password`, `mariadb-root-password` | Secret `desk-glpi-mariadb` | built-in MariaDB, `mariadb.auth.existingSecret` empty |
| `glpicrypt.key` | file in `/var/glpi/config` on the data volume | first install, by GLPI |
| `oauth.pem`, `oauth.pub` | files in `/var/glpi/config` on the data volume | first install, by GLPI |

The Secret's values are generated on first install. On every later
`helm upgrade` the chart reads the existing Secret from the cluster and reuses
it, so they never change. It carries `helm.sh/resource-policy: keep`, so
`helm uninstall` leaves it in place.

> `helm template` and `--dry-run` without cluster access generate new
> passwords each time. That is expected. Only an install or upgrade against
> the cluster reuses the stored ones. Don't apply rendered output from a
> disconnected `helm template` over a running release.

### glpicrypt.key

GLPI encrypts the passwords it stores in the database (LDAP bind, SMTP, mail
receivers, API tokens) with `glpicrypt.key`. If the file is lost or replaced,
those values cannot be decrypted and each one has to be entered again in the
UI. The key lives on the data volume, not in a Kubernetes Secret, because GLPI
creates and rotates it itself. Back it up with the rest of the volume, and
restore the database and the key from the same backup.

To rotate it, use GLPI's own command, which re-encrypts the stored values:

```console
kubectl -n glpi exec deploy/desk-glpi -c glpi -- php bin/console security:change_key
```

## Backup and restore

A complete backup has two parts, taken together:

1. the database,
2. the data volume: `config/` (the keys), `files/` (documents and pictures)
   and `marketplace/` (installed plugins).

Storage-level tools (Velero, CSI snapshots) cover both if they snapshot both
PVCs together. The commands below are a tool-free alternative.

### Back up

```console
# 1. Database (built-in MariaDB)
kubectl -n glpi exec statefulset/desk-glpi-mariadb -- \
  sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" mariadb-dump -uroot \
         --single-transaction --routines --triggers glpi' \
  > glpi-$(date +%F).sql

# 2. Data volume, without sessions, cache and temporary files
kubectl -n glpi exec deploy/desk-glpi -c glpi -- \
  tar -C /var/glpi -czf - \
      --exclude files/_sessions --exclude files/_cache --exclude files/_tmp \
      config files marketplace \
  > glpi-data-$(date +%F).tar.gz
```

`--single-transaction` gives a consistent dump without locking GLPI out.
The two archives contain everything needed to rebuild the instance, including
the encryption key and the database password in `config_db.php`. Store them
encrypted.

### Restore

Into a fresh release of the same chart version. The new release installs an
empty GLPI first, and the restore then replaces it:

```console
helm install desk glpi/glpi -n glpi -f my-values.yaml --wait --timeout 15m

# Database: replace the freshly installed one
kubectl -n glpi exec statefulset/desk-glpi-mariadb -- \
  sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" mariadb -uroot \
         -e "DROP DATABASE glpi; CREATE DATABASE glpi CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"'
kubectl -n glpi exec -i statefulset/desk-glpi-mariadb -- \
  sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" mariadb -uroot glpi' \
  < glpi-<date>.sql

# Data volume, including glpicrypt.key
kubectl -n glpi exec -i deploy/desk-glpi -c glpi -- \
  tar -C /var/glpi -xzf - < glpi-data-<date>.tar.gz

# Restart: migrate rewrites config_db.php for this release's database and
# updates the schema if the backup came from an older GLPI
kubectl -n glpi rollout restart deploy/desk-glpi
kubectl -n glpi rollout status deploy/desk-glpi

kubectl -n glpi exec deploy/desk-glpi -c glpi -- php bin/console cache:clear
```

The restored `config_db.php` carries the old release's database password.
The restart matters for that reason: `migrate` rewrites the file with the new
release's password before GLPI starts.

## Timezones

GLPI can store dates with timezone support when the database user can read
MariaDB's timezone tables. The built-in MariaDB loads those tables on first
start and the install enables the feature. For an external database, grant
the GLPI user `SELECT` on `mysql.time_zone_name`, load the timezone tables on
the server, then run:

```console
kubectl -n glpi exec deploy/desk-glpi -c glpi -- php bin/console database:enable_timezones
```

## Moving between built-in and external

1. Back up the database and the data volume as above.
2. Load the dump into the external server and create its Secret.
3. `helm upgrade` with `mariadb.enabled: false` and `externalDatabase` set.
   The data volume, and with it `glpicrypt.key`, is unchanged. `migrate`
   points `config_db.php` at the new server.
4. Once verified, delete the retained MariaDB PVC (`data-desk-glpi-mariadb-0`)
   and Secret, which the chart leaves behind on purpose.
