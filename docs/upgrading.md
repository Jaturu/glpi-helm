# Upgrading and uninstalling

Examples assume release `desk` in namespace `glpi`.

## Before any upgrade

1. Back up the database and the data volume. See
   [Database > Backup and restore](database.md#backup-and-restore).
   GLPI schema updates are one-way. Restoring from backup is the only way to
   roll back a version.
2. Read the release notes for every GLPI version you are crossing. Many GLPI
   releases include security fixes, and major versions change requirements.
3. Check your plugins. A plugin written for one GLPI major version generally
   does not load on the next. Update or remove plugins as their own release
   notes direct before a major upgrade.
4. Preview the change:

```console
   helm diff upgrade desk glpi/glpi -n glpi -f my-values.yaml   # helm-diff plugin
   # or
   helm template desk glpi/glpi -n glpi -f my-values.yaml > new.yaml
```

## Upgrading GLPI

Each chart release pins a GLPI version (`appVersion`) and an image built for
it. Upgrading the chart upgrades GLPI:

```console
helm repo update
helm upgrade desk glpi/glpi -n glpi -f my-values.yaml
```

What happens:

1. The Deployment's `Recreate` strategy stops the old pod. Expect an outage
   for the length of the update: under a minute when the schema is unchanged,
   several minutes for a major version on a large database.
2. The new pod's `wait-for-database` init container confirms the database
   accepts a login, then `migrate` runs `bin/console database:update` against
   the existing database.
3. php-fpm, nginx and cron start, and the pod becomes Ready.

The built-in MariaDB restarts only when something about it changes: its
image, its settings or its configuration. Its pod template carries no chart
or GLPI version labels, so an upgrade that changes neither leaves the database
running.

Watch it:

```console
kubectl -n glpi get pods -w
kubectl -n glpi logs deploy/desk-glpi -c wait-for-database
kubectl -n glpi logs deploy/desk-glpi -c migrate
```

### Pinning or overriding the version

`image.tag` defaults to the chart's `appVersion`. Setting it explicitly pins
GLPI independently of the chart, for example to stay on a version while
taking chart fixes:

```yaml
image:
  tag: 12.0.2
```

For a fully reproducible deployment, set `image.digest` instead. It takes
precedence over the tag.

Only use image tags built from this repository. The chart relies on the
image's layout: non-root user, the `/var/glpi` data paths, the
`/etc/glpi/php.d` scan directory, and php-fpm on loopback.

GLPI does not support downgrading. Do not move `image.tag` to a version older
than the database schema without restoring the matching backup.

### If the database wait fails

`wait-for-database` exits non-zero in two cases, and its log says which:

- Access denied or unknown database. It fails on the first attempt: the
  password Secret, username or database name does not match the server.
  Waiting would not help.
- Not ready after the timeout. The server never accepted a connection: check
  the MariaDB pod (`kubectl -n glpi get pods`) or, for an external database,
  its host, port and network policy.

### If the update fails

The `migrate` init container exits non-zero and the pod stays in
`Init:CrashLoopBackOff`. The previous version is already stopped, so GLPI is
down until this is resolved.

1. Read the error: `kubectl -n glpi logs deploy/desk-glpi -c migrate`.
2. If it's transient (database not reachable), the pod recovers by itself
   once the database is back.
3. If GLPI reports that the schema differs from what it expects, the database
   was changed outside GLPI's own updates, often by a plugin or a manual
   edit. `bin/console database:check_schema_integrity` lists the differences.
   Resolve them, or restore the backup.
4. Otherwise, roll back the release and restore the database backup taken
   before the upgrade. `helm rollback` alone restores the old image but not
   the old schema.

## Plugins

Plugins installed from the marketplace live on the data volume
(`/var/glpi/marketplace`), so they survive pod restarts and image upgrades.
The `plugins/` directory inside the image is read-only and empty.

Plugins can also be managed from the CLI:

```console
kubectl -n glpi exec deploy/desk-glpi -c glpi -- php bin/console plugin:list
kubectl -n glpi exec deploy/desk-glpi -c glpi -- php bin/console marketplace:download <plugin>
```

The image runs opcache without timestamp checks. After updating a plugin in
place, restart the pod so PHP loads the new files:
`kubectl -n glpi rollout restart deploy/desk-glpi`.

## Upgrading MariaDB (built-in)

### Within a series (patch and minor)

`mariadb.image.tag` is a series tag (`11.8`), so new patch releases arrive
whenever the pod is recreated and pulls the image. `MARIADB_AUTO_UPGRADE=1`
runs `mariadb-upgrade` on start. No manual steps are needed.

To control exactly when this happens, pin a full version or a digest:

```yaml
mariadb:
  image:
    tag: "11.8.6"   # example
```

### To a new series

Moving to a newer LTS series is a deliberate change:

1. Back up the database.
2. Set `mariadb.image.tag` to the new series and `helm upgrade`.
3. The StatefulSet restarts MariaDB on the new version and
   `MARIADB_AUTO_UPGRADE` upgrades the system tables. Confirm with
   `kubectl -n glpi logs statefulset/desk-glpi-mariadb`.

MariaDB does not support downgrading a data directory. To go back, restore
the dump into a fresh volume on the old version.

## Changing values

Configuration changes (GLPI constants, PHP settings, nginx settings) change
checksum annotations on the pod, so `helm upgrade` rolls it automatically.
Secrets referenced through `existingSecret` are not checksummed. After
rotating one, restart the pod:

```console
kubectl -n glpi rollout restart deploy/desk-glpi
```

Some values must not change on an existing release:

| Value | Why |
|-------|-----|
| `mariadb.auth.database` / `username` | Only applied when MariaDB initialises an empty volume |
| `mariadb.auth.existingSecret` (different passwords) | MariaDB keeps the passwords it was initialised with. Change them in SQL first |
| `persistence.*` / `mariadb.persistence.*` size class or name | PVC specs are mostly immutable. Resize only where the StorageClass allows expansion |
| `persistence.enabled: false` | Moves GLPI to an empty emptyDir: a new encryption key, and no documents |
| `glpi.defaultLanguage` | Only applied when the database is first installed |

## Uninstalling

```console
helm uninstall desk -n glpi
```

To protect data, this leaves behind:

| Resource | Name | Why it's kept |
|----------|------|---------------|
| Secret | `desk-glpi-mariadb` | Database passwords matching the data volume |
| PVC | `desk-glpi-data` | Documents, plugins, `config_db.php` and `glpicrypt.key` |
| PVC | `data-desk-glpi-mariadb-0` | The database |

Re-installing with the same release name and namespace picks all of them up
again, so GLPI comes back as it was.

To remove everything permanently:

```console
kubectl -n glpi delete secret desk-glpi-mariadb
kubectl -n glpi delete pvc desk-glpi-data data-desk-glpi-mariadb-0
```

Whether deleting a PVC also deletes the underlying storage depends on the
StorageClass's reclaim policy (`Delete` removes it, `Retain` keeps the
PersistentVolume for manual cleanup).
