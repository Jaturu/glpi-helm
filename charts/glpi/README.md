# glpi

![Version: 0.1.0](https://img.shields.io/badge/Version-0.1.0-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 12.0.2](https://img.shields.io/badge/AppVersion-12.0.2-informational?style=flat-square)

GLPI IT asset management and service desk on a non-root php-fpm image with an nginx-unprivileged sidecar, optional built-in MariaDB (official image), and Gateway API HTTPRoute support.

[GLPI](https://glpi-project.org/) is an IT asset management and service desk
application: inventory, tickets, changes, contracts and a knowledge base. This
chart runs it on a purpose-built, non-root image and is designed to pass the
Kubernetes `restricted` Pod Security Standard.

## Features

- Non-root php-fpm + nginx-unprivileged in one pod, read-only root
  filesystems, all capabilities dropped, `RuntimeDefault` seccomp.
- Optional built-in MariaDB (official `mariadb` image, LTS series) or any
  external MySQL 8.0+ / MariaDB 10.11+.
- Database installed on first start and updated on every image upgrade, in an
  init container, before GLPI serves requests.
- Scheduled tasks run by a `cron` container in the same pod.
- Generated database passwords that survive upgrades and are kept on
  uninstall.
- Gateway API `HTTPRoute` and/or `Ingress`.
- Render-time validation of required and conflicting values.

## Installing

```console
helm repo add glpi https://jaturu.github.io/glpi-helm
helm repo update
helm install desk glpi/glpi \
  --namespace glpi --create-namespace \
  --set glpi.url=https://glpi.example.com
```

Or install straight from the OCI registry, without `helm repo add`:

```console
helm install desk oci://ghcr.io/jaturu/charts/glpi --version 0.1.0 \
  --namespace glpi --create-namespace \
  --set glpi.url=https://glpi.example.com
```

No value is required. `glpi.url` is recommended: GLPI uses it for links in
notifications, and an https URL marks the session cookie Secure.

The first login is `glpi` / `glpi`. GLPI ships four default accounts (`glpi`,
`tech`, `normal`, `post-only`). Change their passwords or disable them
immediately.

For a production install, follow
[Installing](https://github.com/Jaturu/glpi-helm/blob/main/docs/installing.md).

### Example: Gateway API

```yaml
glpi:
  url: https://glpi.example.com
  # Pod network of the gateway, so GLPI trusts X-Forwarded-* headers.
  trustedProxies:
    - 10.244.0.0/16

httpRoute:
  enabled: true
  parentRefs:
    - name: my-gateway
      namespace: gateway-system
      sectionName: https
  hostnames:
    - glpi.example.com

persistence:
  storageClass: fast-rwo
mariadb:
  persistence:
    storageClass: fast-rwo
```

### Example: Ingress with cert-manager

```yaml
glpi:
  url: https://glpi.example.com
  trustedProxies:
    - 10.0.0.0/8

ingress:
  enabled: true
  className: nginx
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt
    nginx.ingress.kubernetes.io/proxy-body-size: 55m
  hosts:
    - glpi.example.com
  tls:
    - secretName: glpi-tls
      hosts:
        - glpi.example.com
```

## Data to back up

GLPI keeps state in two places, and a restore needs both from the same point
in time:

- the database,
- the data volume mounted at `/var/glpi`. Its `config/` directory holds
  `glpicrypt.key`, which decrypts the passwords GLPI stores in the database
  (LDAP, mail collectors, API tokens). Without that file those values cannot
  be recovered.

See [Backup and restore](https://github.com/Jaturu/glpi-helm/blob/main/docs/database.md#backup-and-restore).

## Guides

| Guide | Covers |
|-------|--------|
| [Installing](https://github.com/Jaturu/glpi-helm/blob/main/docs/installing.md) | A production install behind a gateway, from namespace to first login |
| [Architecture](https://github.com/Jaturu/glpi-helm/blob/main/docs/architecture.md) | Pod layout, startup sequence, volumes, security model, probes |
| [Database](https://github.com/Jaturu/glpi-helm/blob/main/docs/database.md) | Built-in vs external database, secrets and keys, backup and restore |
| [Exposure](https://github.com/Jaturu/glpi-helm/blob/main/docs/exposure.md) | HTTPRoute and Ingress, TLS, trusted proxies, upload size limits |
| [Email](https://github.com/Jaturu/glpi-helm/blob/main/docs/email.md) | Sending and receiving mail, configured in the GLPI UI |
| [Upgrading](https://github.com/Jaturu/glpi-helm/blob/main/docs/upgrading.md) | GLPI and MariaDB upgrades, plugins, what uninstall leaves behind |
| [Image](https://github.com/Jaturu/glpi-helm/blob/main/docs/image.md) | How the container image is built and versioned |
| [Testing](https://github.com/Jaturu/glpi-helm/blob/main/docs/testing.md) | Unit, schema and image tests |

## Uninstalling

```console
helm uninstall desk -n glpi
```

By design this keeps the MariaDB Secret, the GLPI data PVC and the MariaDB
data PVC. Delete them explicitly to remove all data. See
[Upgrading](https://github.com/Jaturu/glpi-helm/blob/main/docs/upgrading.md#uninstalling).

## Requirements

Kubernetes: `>=1.29.0-0`

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` | Affinity rules for the GLPI pod. |
| cron.enabled | bool | `true` | Run GLPI's automatic actions in a container of the GLPI pod. |
| cron.intervalSeconds | int | `60` | Seconds between two runs of front/cron.php. |
| externalDatabase.database | string | `"glpi"` | Database name. |
| externalDatabase.existingSecret | string | `""` | Secret holding the user's password. REQUIRED when mariadb.enabled=false. |
| externalDatabase.host | string | `""` | Database hostname. Required when mariadb.enabled=false. |
| externalDatabase.passwordKey | string | `"password"` | Key in externalDatabase.existingSecret holding the password. |
| externalDatabase.port | int | `3306` | Database port. |
| externalDatabase.username | string | `"glpi"` | Database user. |
| fullnameOverride | string | `""` | Override the full resource name prefix (default: <release>-<chart>). |
| glpi.constants | object | `{}` | Additional GLPI constants, rendered into config/local_define.php. Values may be strings, numbers, booleans or lists. Example:   GLPI_MARKETPLACE_ENABLE: 1   GLPI_LOG_LVL: info The data path constants and the two proxy constants above are set by the chart and cannot be repeated here. |
| glpi.defaultLanguage | string | `"en_GB"` | Default UI language, applied when the database is first installed. |
| glpi.extraEnv | list | `[]` | Extra container env entries (full EnvVar objects, e.g. secretKeyRef), applied to the php-fpm, cron and migrate containers. |
| glpi.extraEnvFrom | list | `[]` | Extra envFrom sources (whole Secrets/ConfigMaps), applied likewise. |
| glpi.reverseProxyHeaders | list | `["X-Forwarded-For","X-Forwarded-Proto"]` | Headers trusted from those proxies (GLPI_REVERSE_PROXY_HEADERS). |
| glpi.timezone | string | `"UTC"` | PHP timezone (date.timezone). |
| glpi.trustedProxies | list | `[]` | Reverse proxies whose forwarding headers GLPI trusts (GLPI_TRUSTED_REVERSE_PROXIES). A list of IPs or CIDRs. Set this to the gateway/ingress pod network so GLPI sees the real scheme and client IP. |
| glpi.uploadLimitMB | int | `50` | Upload size limit in MB. Single source for the limits inside the pod: PHP upload_max_filesize (N M) and post_max_size (N+5 M), and nginx client_max_body_size (N+5 m). The Gateway / Ingress in front of the pod must allow at least N+5 MB too. GLPI's own document size limit is set in its UI (Setup > General > Management). |
| glpi.url | string | `""` | Public base URL, including scheme, no trailing slash, e.g. https://glpi.example.com. Written to GLPI's url_base setting on every start (used for links in notifications). An https URL also marks the session cookie Secure. Empty leaves url_base as set in the GLPI UI. |
| httpRoute.annotations | object | `{}` | HTTPRoute annotations. |
| httpRoute.enabled | bool | `false` | Create a Gateway API HTTPRoute. |
| httpRoute.hostnames | list | `[]` | Hostnames, e.g. [glpi.example.com]. Usually matches glpi.url. |
| httpRoute.parentRefs | list | `[]` | Gateways to attach to, e.g.   - name: my-gateway     namespace: gateway-system     sectionName: https |
| image.digest | string | `""` | Optional image digest (sha256:...). When set, takes precedence over tag. |
| image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| image.repository | string | `"ghcr.io/jaturu/glpi"` | Image repository. |
| image.tag | string | `""` | Defaults to the chart's appVersion when empty. |
| imagePullSecrets | list | `[]` | Pull secrets applied to every pod in the release. |
| ingress.annotations | object | `{}` | Controller-specific annotations. Most controllers cap request bodies below the 50 MB upload limit by default, so raise theirs too, e.g.   nginx.ingress.kubernetes.io/proxy-body-size: 55m   cert-manager.io/cluster-issuer: my-issuer |
| ingress.className | string | `""` | IngressClass to use. Empty = cluster default class. |
| ingress.enabled | bool | `false` | Create an Ingress. |
| ingress.hosts | list | `[]` | Hostnames, e.g. [glpi.example.com]. Usually matches glpi.url. |
| ingress.path | string | `"/"` | Path matched on every host. |
| ingress.pathType | string | `"Prefix"` | Ingress pathType. |
| ingress.tls | list | `[]` | TLS blocks, e.g.   - secretName: glpi-tls     hosts: [glpi.example.com] |
| mariadb.affinity | object | `{}` | Affinity rules for the MariaDB pod. |
| mariadb.auth.database | string | `"glpi"` | Database created on first start (MARIADB_DATABASE). |
| mariadb.auth.existingSecret | string | `""` | Use an existing Secret for the passwords instead of the chart-managed one (generated on first install, reused on upgrades, kept on uninstall). |
| mariadb.auth.passwordKey | string | `"mariadb-password"` | Key in the MariaDB Secret holding the GLPI user's password. |
| mariadb.auth.rootPasswordKey | string | `"mariadb-root-password"` | Key in the MariaDB Secret holding the root password. |
| mariadb.auth.username | string | `"glpi"` | User created on first start (MARIADB_USER). |
| mariadb.config | string | `"[mysqld]\ncharacter-set-server  = utf8mb4\ncollation-server      = utf8mb4_unicode_ci\nskip-name-resolve\ninnodb_buffer_pool_size = 256M\n"` | Extra server settings, rendered into a ConfigMap mounted at /etc/mysql/conf.d/zz-chart.cnf. |
| mariadb.enabled | bool | `true` | Deploy MariaDB with the chart. Set false to use externalDatabase. |
| mariadb.image.digest | string | `""` | Optional MariaDB image digest (sha256:...). Takes precedence over tag. |
| mariadb.image.pullPolicy | string | `"IfNotPresent"` | MariaDB image pull policy. |
| mariadb.image.repository | string | `"docker.io/library/mariadb"` | MariaDB image repository (official image). |
| mariadb.image.tag | string | `"11.8"` | 11.8 is the current MariaDB LTS series. The tag follows its patches. |
| mariadb.nodeSelector | object | `{}` | Node selector for the MariaDB pod. |
| mariadb.persistence.accessModes | list | `["ReadWriteOnce"]` | Access modes for the data volume. |
| mariadb.persistence.size | string | `"8Gi"` | Size of the data volume. |
| mariadb.persistence.storageClass | string | `""` | StorageClass for the data volume. Empty = cluster default. |
| mariadb.podSecurityContext | object | `{"fsGroup":999,"runAsGroup":999,"runAsNonRoot":true,"runAsUser":999,"seccompProfile":{"type":"RuntimeDefault"}}` | MariaDB pod security context. uid/gid 999 is the mysql user in the official image. |
| mariadb.resources | object | `{"limits":{"memory":"768Mi"},"requests":{"cpu":"50m","memory":"384Mi"}}` | MariaDB container resources. Raise the memory limit with innodb_buffer_pool_size. |
| mariadb.securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"readOnlyRootFilesystem":true}` | MariaDB container security context. /var/lib/mysql, /run/mysqld and /tmp are the only writable paths. |
| mariadb.tolerations | list | `[]` | Tolerations for the MariaDB pod. |
| migrations.enabled | bool | `true` | Install or update the database in an init container before GLPI starts. |
| migrations.waitForDatabase.enabled | bool | `true` | Wait in an init container until the database accepts a login before migrating. Avoids failed attempts while MariaDB initialises. |
| migrations.waitForDatabase.timeoutSeconds | int | `300` | How long to wait, in seconds, before failing the pod start. |
| nameOverride | string | `""` | Override the chart name used in resource names. |
| nginx.image.digest | string | `""` | Optional nginx image digest (sha256:...). Takes precedence over tag. |
| nginx.image.pullPolicy | string | `"IfNotPresent"` | nginx image pull policy. |
| nginx.image.repository | string | `"docker.io/nginxinc/nginx-unprivileged"` | nginx sidecar image repository. |
| nginx.image.tag | string | `"1.30-alpine"` | nginx sidecar image tag (1.30 = current stable branch). |
| nginx.port | int | `8080` | Container port nginx listens on (unprivileged, >1024). |
| nodeSelector | object | `{}` | Node selector for the GLPI pod. |
| persistence.accessModes | list | `["ReadWriteOnce"]` | Access modes for the data volume. |
| persistence.annotations | object | `{}` | Extra annotations on the PVC (helm.sh/resource-policy: keep is always set). |
| persistence.enabled | bool | `true` | Persist /var/glpi. When false an emptyDir is used (data and the encryption keys are lost on pod restart). |
| persistence.existingClaim | string | `""` | Use an existing PVC instead of creating one. |
| persistence.size | string | `"10Gi"` | Size of the data volume. |
| persistence.storageClass | string | `""` | StorageClass for the data volume. Empty = cluster default. |
| php.extraIni | string | `""` | Extra PHP ini settings, appended after the derived settings. Do not set upload_max_filesize or post_max_size here, use glpi.uploadLimitMB. Example:   memory_limit = 512M |
| podAnnotations | object | `{}` | Extra annotations on the GLPI pod. |
| podLabels | object | `{}` | Extra labels on the GLPI pod. |
| podSecurityContext | object | `{"fsGroup":33,"fsGroupChangePolicy":"OnRootMismatch","runAsGroup":33,"runAsNonRoot":true,"runAsUser":33,"seccompProfile":{"type":"RuntimeDefault"}}` | Pod-level security context. uid/gid 33 owns the data paths in the GLPI image. |
| probes.healthPort | int | `8081` | Port of nginx's health server (/fpm-ping). Not exposed by the Service. |
| probes.liveness | object | `{"failureThreshold":3,"initialDelaySeconds":10,"periodSeconds":20,"timeoutSeconds":3}` | Liveness probe timings (php-fpm via /fpm-ping, nginx via TCP). |
| probes.readiness | object | `{"failureThreshold":3,"initialDelaySeconds":5,"periodSeconds":10,"timeoutSeconds":5}` | Readiness probe timings (php-fpm answering through nginx). |
| replicaCount | int | `1` | Fixed at 1: the data volume is ReadWriteOnce and the Deployment uses the Recreate strategy so the old pod releases it before the new one starts. |
| resources.app | object | `{"limits":{"memory":"1Gi"},"requests":{"cpu":"100m","memory":"256Mi"}}` | php-fpm container resources (also used by the init containers). |
| resources.cron | object | `{"limits":{"memory":"512Mi"},"requests":{"cpu":"10m","memory":"64Mi"}}` | cron container resources. |
| resources.nginx | object | `{"limits":{"memory":"128Mi"},"requests":{"cpu":"10m","memory":"32Mi"}}` | nginx sidecar resources. |
| securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"readOnlyRootFilesystem":true}` | Container security context (applied to php-fpm, cron, nginx and init containers). The root filesystem is read-only. The chart mounts the data volume at /var/glpi and emptyDirs for /tmp. |
| service.annotations | object | `{}` | Service annotations. |
| service.port | int | `80` | Service port (targets nginx's http port). |
| service.type | string | `"ClusterIP"` | Service type. |
| tests.enabled | bool | `true` | Render the `helm test` pod (templates/test-connection.yaml). |
| tolerations | list | `[]` | Tolerations for the GLPI pod. |

----------------------------------------------
Autogenerated from chart metadata using [helm-docs v1.14.2](https://github.com/norwoodj/helm-docs/releases/v1.14.2)
