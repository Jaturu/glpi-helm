# Testing

Layers from fastest to most complete. Each catches a different class of
mistake.

| Layer | Command | Needs | Checks |
|-------|---------|-------|--------|
| Template unit tests | `make test-unit` | helm, helm-unittest plugin | Rendering logic: validation guards, derived limits, DB wiring, mounts, env, probes, security contexts, routes |
| Schema validation | `make test-schema` | helm, kubeconform | Rendered manifests are valid Kubernetes / Gateway API objects, across several values scenarios |
| File lint | `make lint-files` | shellcheck, hadolint | Test scripts and the Dockerfile |
| Report scripts | `make test-scripts` | python3, pytest, ruff | The release report and security status renderers |
| Image contract | `make test-image` | docker | The image provides what the chart relies on |
| Vulnerability gates | `make scan` | docker, grype, trivy | The release gates (fixable High and Critical), against the local image |

`make test` runs lint + unit + schema (seconds, no image). `make test-all`
runs everything except `scan`.

There is no automated install test on a cluster. `helm test` checks a real
release after you install it (see below).

## Tool setup

The Makefile needs GNU make 3.82 or newer. macOS ships 3.81, so install a
current one (`brew install make`, then use `gmake`).

```console
# helm-unittest (Helm 4 requires --verify=false for unsigned plugins)
helm plugin install https://github.com/helm-unittest/helm-unittest --version v1.0.3 --verify=false
# Helm 3:
helm plugin install https://github.com/helm-unittest/helm-unittest --version v1.0.3

brew install kubeconform shellcheck hadolint grype trivy

# Report-script tooling, hash-pinned
python3 -m venv .venv && .venv/bin/pip install --require-hashes -r requirements-dev.txt
```

## Template unit tests

Suites live in [`charts/glpi/tests/`](../charts/glpi/tests) and are excluded
from the packaged chart by `.helmignore`.

| Suite | Covers |
|-------|--------|
| `validation_test.yaml` | Every render-time guard fails with its message, and valid input renders |
| `deployment_test.yaml` | Images and digests, init container order, mounts, database env, the cron container, ports, probes, security contexts |
| `configmaps_test.yaml` | `local_define.php` constants and their escaping, derived PHP and nginx limits, nginx routing and hardening |
| `secrets_test.yaml` | Generated database passwords, reuse of existing values on upgrade (simulated cluster), existingSecret handling |
| `mariadb_test.yaml` | StatefulSet, Service, config, retention, security |
| `networking_test.yaml` | Service, PVC, HTTPRoute, Ingress |
| `test-connection_test.yaml` | The `helm test` hook pod |

Run one suite with `helm unittest -f 'tests/secrets_test.yaml' charts/glpi`.

When you change a template, add or update the test that covers it. When you
fix a bug, add a test that fails without the fix.

## Schema validation

[`tests/schema.sh`](../tests/schema.sh) renders the chart once per file in
[`tests/values/`](../tests/values) and validates the output with
`kubeconform -strict`, using the Kubernetes schemas plus the Gateway API CRD
schemas.

| Scenario | Exercises |
|----------|-----------|
| `default.yaml` | Minimal install |
| `full.yaml` | HTTPRoute + Ingress, trusted proxies, constants, extra env, PHP ini, scheduling |
| `external-db.yaml` | External database, existing Secret and PVC, migrations and cron off |
| `ephemeral.yaml` | No persistence |

Add a scenario file when you add a feature that changes which objects render.
`KUBE_VERSION=1.33.0 tests/schema.sh` pins the schema version.

## Image contract

[`tests/image-test.sh`](../tests/image-test.sh) runs the image the way the
chart does (non-root, read-only root filesystem, a writable `/var/glpi`) and
checks: uid/gid 33, the GLPI version matches `appVersion`, the required and
recommended PHP extensions, php-fpm config (loopback listener, ping endpoint),
that `bin/console` boots and GLPI's own requirements check passes, the data
paths point at `/var/glpi`, `/etc/glpi/php.d` overrides PHP settings for CLI
and fpm, ownership of writable vs read-only paths, that `public/` holds only
the front controller as PHP, and that no build tools remain.

## helm test

The hook pod in
[`templates/test-connection.yaml`](../charts/glpi/templates/test-connection.yaml)
checks a running release through its Service: the login page renders,
`/status.php` reports GLPI and the database OK, legacy script paths reach the
front controller, nginx serves static assets, dotfiles are denied, and config
and data files are not served.

```console
helm test desk -n glpi --logs
```

## CI

[`.github/workflows/ci.yaml`](../.github/workflows/ci.yaml) runs on every pull
request and push to `main`:

| Job | Runs |
|-----|------|
| `lint` | shellcheck, hadolint (checksum-pinned binary), ruff, report-script tests |
| `chart` | lint, unit tests, schema validation, chart README check, Trivy secret/misconfig scan of the tree (renders the chart). On pull requests also `ct lint` (Chart.yaml schema, yamllint, chart version bump required when the chart changed) |
| `image (amd64)`, `image (arm64)` | Native build, image contract tests, then the release gates: Syft SBOM, Grype (fixable High+), Trivy (fixable HIGH/CRITICAL) |

All actions are pinned by commit SHA with the version in a comment. Dependabot
updates both weekly. `ct.yaml` configures
[chart-testing](https://github.com/helm/chart-testing).
