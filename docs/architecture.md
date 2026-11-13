# Architecture

This page explains what the chart deploys and why it is laid out the way it is.
For every configurable value see the
[values reference](../charts/glpi/README.md#values).

## Components

```
                 Gateway / Ingress  (TLS terminates here)
                          │  HTTP
                          ▼
                Service <release>-glpi :80
                          │
  ┌─────────────────── GLPI pod (Deployment, 1 replica) ────────────────────┐
  │                                                                         │
  │  init: copy-assets ── copies public/ into an emptyDir, creates data dirs │
  │  init: wait-for-database ── until the database accepts a login           │
  │  init: migrate     ── database:install or database:update                │
  │                                                                         │
  │  ┌──────────────── nginx ────────────────┐   ┌────────── glpi ─────────┐ │
  │  │ :8080 app server  (Service → here)    │   │ php-fpm                 │ │
  │  │   static files from public/           │──▶│ 127.0.0.1:9000 only     │ │
  │  │   everything else → index.php         │   │                         │ │
  │  │ :8081 health server (/fpm-ping)       │──▶│                         │ │
  │  └───────────────────────────────────────┘   └─────────────────────────┘ │
  │  ┌──────────────── cron ─────────────────┐                               │
  │  │ php front/cron.php every 60 s         │                               │
  │  └───────────────────────────────────────┘                               │
  └─────────────────────────────────────────────────────────────────────────┘
                          │  3306
                          ▼
        MariaDB StatefulSet (optional) ── or an external database
```

| Workload | Kind | Image |
|----------|------|-------|
| GLPI | Deployment, `Recreate` strategy | `ghcr.io/jaturu/glpi` (php-fpm, cron) + `nginxinc/nginx-unprivileged` |
| MariaDB (optional) | StatefulSet, 1 replica | `mariadb` (official) |

### Why separate containers

The GLPI image contains only the application and PHP. nginx runs as a sidecar
from the upstream unprivileged image. Each process has its own resource limits
and liveness probe, so a hung php-fpm restarts only the `glpi` container, and
nginx can be patched independently of the application image.

php-fpm listens on `127.0.0.1:9000`, so FastCGI is reachable only from inside
the pod. The only port the Service exposes is nginx's `http` port.

GLPI's automatic actions (notifications, mail collection, cleanups) need the
PHP CLI on a schedule. The `cron` container runs `php front/cron.php` in a
loop from the same image. It sits in the GLPI pod because it needs the same
data volume, which is `ReadWriteOnce`. Set `cron.enabled: false` to drop it.

## Startup sequence

1. `copy-assets` copies `public/` (compiled CSS and JavaScript, pictures)
   from the image into an `emptyDir` that nginx serves, and creates the four
   data directories on the volume if they are missing. Existing data is never
   touched.
2. `wait-for-database` retries a database login every two seconds until it
   succeeds. On a first install the built-in MariaDB spends a minute or so
   initialising. Errors that waiting cannot fix (bad credentials, a missing
   database) fail at once with a clear message, and the wait gives up after
   `migrations.waitForDatabase.timeoutSeconds` (default 300). The script is
   [`charts/glpi/files/wait-for-database.php`](../charts/glpi/files/wait-for-database.php),
   run with the image's own PHP.
3. `migrate` runs
   [`charts/glpi/files/migrate.sh`](../charts/glpi/files/migrate.sh). If the
   database holds no GLPI tables it runs `bin/console database:install`.
   Otherwise it runs `database:configure` followed by `database:update`, so
   an image upgrade migrates the schema before GLPI serves a request. When
   `glpi.url` is set it also writes GLPI's `url_base` setting.
4. `glpi` (php-fpm), `nginx` and `cron` start.

`migrate`, `glpi` and `cron` share identical mounts, rendered from one helper.

### Database configuration

GLPI reads its database connection from a file, `config/config_db.php`, not
from the environment, and rewrites that file itself during some updates. The
chart therefore keeps the file on the data volume and has `migrate` write it
from the chart's database values and the password Secret on every start. A
changed host or a rotated password takes effect at the next pod start.

`migrate` passes the password to `bin/console` as a command-line option,
because GLPI offers no other non-interactive way to supply it. It is visible
only in that init container's process list for the few seconds the command
runs.

## Request handling

nginx's application server:

- serves files that exist under `public/` directly,
- passes every other request to `public/index.php`, GLPI's front controller.
  That includes the legacy script paths (`/front/*.php`, `/ajax/*.php`,
  `/apirest.php`, `/api.php`) and plugin files, all of which GLPI routes and
  permission-checks itself,
- denies dotfiles, except the `/.well-known/` routes GLPI answers.

nginx cannot read anything outside `public/`: the rest of the application and
the data volume are not mounted in its container.

`X-Forwarded-For` and `X-Forwarded-Proto` from the gateway reach PHP
unchanged. GLPI honours them for the proxies listed in `glpi.trustedProxies`.

## Volumes

| Volume | Backing | Mounted in | Path | Mode |
|--------|---------|------------|------|------|
| `data` | PVC | glpi, cron, migrate, copy-assets | `/var/glpi` | rw |
| `public` | emptyDir | nginx | `/var/www/glpi/public` | ro |
| `public` | emptyDir | copy-assets | `/public` | rw (copy only) |
| `app-tmp` / `nginx-tmp` | emptyDir | each container | `/tmp` | rw |
| `nginx-conf` | ConfigMap | nginx | `/etc/nginx/conf.d` | ro |
| `php-conf` | ConfigMap | glpi, cron, migrate | `/etc/glpi/php.d` | ro |
| `glpi-conf` | ConfigMap | glpi, cron, migrate | `/var/www/glpi/config/local_define.php` | ro |

The data volume holds four directories:

- `config/`: `config_db.php`, `glpicrypt.key` and the OAuth key pair.
  `glpicrypt.key` decrypts the passwords GLPI stores in the database, so back
  it up together with the database.
- `files/`: uploaded documents, pictures, sessions and cache.
- `logs/`: GLPI's log files.
- `marketplace/`: plugins installed from the marketplace.

All containers that mount it are in one pod, so `ReadWriteOnce` is
sufficient. That is also why the Deployment is fixed at one replica with the
`Recreate` strategy: the old pod must release the volume before the new one
mounts it. The chart refuses `replicaCount` values other than 1.

## Security model

Every container, including init containers and MariaDB, runs with:

- `runAsNonRoot: true`: the GLPI pod as uid/gid 33, MariaDB as 999 (`mysql`),
- `readOnlyRootFilesystem: true`, with writable paths limited to the volumes
  listed above,
- `allowPrivilegeEscalation: false`, all capabilities dropped,
  `seccompProfile: RuntimeDefault`.

This satisfies the `restricted` Pod Security Standard, so the release
namespace can be labelled `pod-security.kubernetes.io/enforce: restricted`.

Pods also disable service-account token mounting and service-link
environment variables. GLPI needs neither.

Inside the image, the application code is owned by root and read-only to the
runtime user. Only `/var/glpi` is writable, and in the pod that is the data
volume.

## Health checks

| Container | Probe | Check |
|-----------|-------|-------|
| glpi | liveness | `GET :8081/fpm-ping`, through nginx's health server to php-fpm |
| nginx | liveness | TCP connect to `:8080` |
| nginx | readiness | `GET :8081/fpm-ping`: nginx can reach php-fpm |
| mariadb | startup / liveness / readiness | `healthcheck.sh` from the official image |

The health server on port 8081 is not part of the Service, so `/fpm-ping` is
reachable only by the kubelet. php-fpm's `/fpm-status` page is not routed
anywhere.

The probes deliberately stay out of GLPI. Every request GLPI answers,
including `/status.php`, starts a PHP session and writes a session file to the
data volume, so a probe every ten seconds would leave thousands of them a day.
`helm test` checks `/status.php` and the login page instead.

## Configuration flow

| Source | Becomes | Used by |
|--------|---------|---------|
| Database values and password Secret | `GLPI_DB_*` env on `wait-for-database` and `migrate` | written to `config_db.php` |
| `glpi.trustedProxies`, `glpi.constants` | ConfigMap `<release>-glpi-config` (`local_define.php`) | GLPI constants |
| `glpi.uploadLimitMB`, `glpi.timezone`, `php.extraIni` | ConfigMap `<release>-glpi-php` | PHP ini |
| `glpi.uploadLimitMB`, ports | ConfigMap `<release>-glpi-nginx` | nginx |
| `glpi.extraEnv` / `extraEnvFrom` | passed through | container env |

Everything else (mail, LDAP, entities, rules) is configured in the GLPI UI
and stored in the database. Pods carry checksums of the three ConfigMaps, so
a configuration change rolls the pod.
