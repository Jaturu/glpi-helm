# Installing

A walkthrough for a production install behind a Gateway API gateway, from an
empty namespace to the first login. It assumes a Gateway with an HTTPS
listener and a default StorageClass. [Exposure](exposure.md) covers Ingress
instead.

## 1. Namespace

Create the namespace with the `restricted` Pod Security Standard enforced.
Every container in the chart, MariaDB included, runs under it.

```console
kubectl create namespace glpi
kubectl label namespace glpi pod-security.kubernetes.io/enforce=restricted
```

## 2. Values

Start from the chart's own defaults, so every setting and its documentation is
in front of you:

```console
helm show values oci://ghcr.io/jaturu/charts/glpi --version <chart version> > values.yaml
```

The settings a typical install changes:

```yaml
image:
  tag: 12.0.2-1                    # pin a build. The default follows <appVersion>

glpi:
  url: https://glpi.example.com
  trustedProxies:
    - 10.244.0.0/16                # the gateway's pod network
  timezone: America/New_York

persistence:
  storageClass: ""                 # empty = the cluster default

mariadb:
  persistence:
    storageClass: ""

httpRoute:
  enabled: true
  parentRefs:
    - name: my-gateway
      namespace: gateway-system
      sectionName: https
  hostnames:
    - glpi.example.com
```

- `glpi.url` should match the hostname users type, including `https://`. GLPI
  uses it for the links in notification emails, and an https URL marks the
  session cookie Secure.
- `glpi.trustedProxies` is what lets GLPI see the original scheme and client
  address. See [Trusted proxies](exposure.md#trusted-proxies).
- Image tags of the form `<GLPI version>-<build>` are immutable. The bare
  `<GLPI version>` tag moves to each new build. See
  [Supply chain](supply-chain.md).

## 3. DNS and TLS

Point the hostname at the gateway, for example a CNAME to the gateway's own
name. TLS is configured on the Gateway listener, not in this chart. A
wildcard certificate there covers GLPI without a certificate of its own.

## 4. Validate before installing

Render the chart and have the API server validate every object without
creating anything. The server-side dry run applies the namespace's Pod
Security admission and checks the HTTPRoute against the installed Gateway API
CRDs:

```console
helm template glpi oci://ghcr.io/jaturu/charts/glpi --version <chart version> \
  -n glpi -f values.yaml > rendered.yaml
sed -n '/^---$/,$p' rendered.yaml | kubectl apply -n glpi --dry-run=server -f -
```

Every line should end in `created (server dry run)`, with no
`would violate PodSecurity` warnings.

> Helm 4 and OCI charts. When `helm template` pulls a chart from an OCI
> registry, Helm 4 writes its `Pulled:` and `Digest:` lines to standard
> output, ahead of the manifests. Piped straight into `kubectl`, they fail
> with `apiVersion not set, kind not set`. The `sed` above drops everything
> before the first document. `helm install` and `helm upgrade` are not
> affected.

## 5. Install

```console
helm install glpi oci://ghcr.io/jaturu/charts/glpi --version <chart version> \
  -n glpi -f values.yaml --wait --timeout 15m
helm test glpi -n glpi
```

On a first install the built-in MariaDB initialises for a minute or so. The
`wait-for-database` init container holds the pod until it accepts a login,
then `migrate` installs the GLPI schema and default data, which takes a few
minutes more. See [Startup sequence](architecture.md#startup-sequence).

Follow it with:

```console
kubectl -n glpi logs deploy/glpi -c migrate -f
```

Check the route end to end. The login page answers `200`:

```console
curl -sS -o /dev/null -w '%{http_code}\n' https://glpi.example.com/
```

A certificate error here, with a private CA, means this machine does not
trust that CA yet. The deployment itself is fine. `curl -k` checks the route
alone.

## 6. First login

GLPI creates four accounts on install, each with a well-known password:

| Login | Password | Profile |
|-------|----------|---------|
| `glpi` | `glpi` | Super-Admin |
| `tech` | `tech` | Technician |
| `normal` | `normal` | Observer |
| `post-only` | `postonly` | Self-Service |

1. Sign in as `glpi` and change that password at once.
2. Change the passwords of the other three, or disable or delete the accounts
   you will not use. GLPI shows a warning on the home page until none of them
   still has its default password.
3. Under Setup > General, review the general settings. Under Setup >
   Authentication, configure LDAP or another external source if accounts
   should come from a directory.

The chart's `migrate` step has already installed the database, so the web
installer is never needed. Its URL only redirects to the login page.

## 7. Afterwards

- Email for notifications and ticket follow-ups: [Email](email.md).
- Backups of the database and the data volume, including `glpicrypt.key`:
  [Backup and restore](database.md#backup-and-restore). The key and the
  database passwords are generated inside the cluster. Keep a copy elsewhere.
- Upgrades: [Upgrading](upgrading.md).
