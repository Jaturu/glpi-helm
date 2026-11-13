# syntax=docker/dockerfile:1
#
# GLPI on Alpine's php-fpm (PHP 8.4), non-root.
# Pairs with an nginx-unprivileged sidecar in the Helm chart. This image serves
# FastCGI on 127.0.0.1:9000 only.

ARG ALPINE_VERSION=3.24
ARG PHP_VERSION=84

# Extensions GLPI requires or recommends. Alpine packages each one separately
# (php84-<name>). filter, hash, json, libxml and zlib are compiled into PHP.
ARG PHP_PACKAGES="bcmath bz2 ctype curl dom exif fileinfo gd iconv intl ldap mbstring mysqli mysqlnd opcache openssl phar posix session simplexml sodium tokenizer xml xmlreader xmlwriter zip"

# ---------------------------------------------------------------------------
# build: fetch the GLPI release archive and lay out the application
#   GLPI_VERSION has no default: the single source is appVersion in
#   charts/glpi/Chart.yaml, passed in by `make image` and CI.
# ---------------------------------------------------------------------------
FROM alpine:${ALPINE_VERSION} AS build

SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

ARG GLPI_VERSION
ARG GLPI_RELEASES=https://github.com/glpi-project/glpi/releases/download

# The release archive already holds vendor/ and the compiled front-end assets.
RUN set -eux; \
    test -n "${GLPI_VERSION}" || { echo "GLPI_VERSION build arg is required (set from Chart.yaml appVersion; use make image)" >&2; exit 1; }; \
    mkdir -p /var/www; \
    wget -q -O /tmp/glpi.tgz "${GLPI_RELEASES}/${GLPI_VERSION}/glpi-${GLPI_VERSION}.tgz"; \
    tar -xzf /tmp/glpi.tgz -C /var/www; \
    rm /tmp/glpi.tgz; \
    # The archive carries its packager's uid, but the code must be root-owned.
    chown -R 0:0 /var/www/glpi; \
    chmod -R go-w /var/www/glpi

WORKDIR /var/www/glpi

# Data lives under /var/glpi (see downstream.php), so the in-tree data
# directories go. config/ stays as the mount point for local_define.php.
RUN set -eux; \
    rm -rf files marketplace; \
    test -f bin/console; test -f public/index.php; test -d vendor; \
    test "$(ls version)" = "${GLPI_VERSION}"

COPY glpi/downstream.php inc/downstream.php

# ---------------------------------------------------------------------------
# runtime
# ---------------------------------------------------------------------------
FROM alpine:${ALPINE_VERSION} AS runtime

SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

ARG PHP_VERSION
ARG PHP_PACKAGES
ARG GLPI_VERSION

LABEL org.opencontainers.image.title="glpi" \
      org.opencontainers.image.description="GLPI on Alpine php-fpm, non-root" \
      org.opencontainers.image.source="https://github.com/Jaturu/glpi-helm" \
      org.opencontainers.image.licenses="GPL-3.0-or-later" \
      org.opencontainers.image.version="${GLPI_VERSION}"

# Alpine has one php.ini and one conf.d for both the CLI and php-fpm.
# Alpine's default pool (php-fpm.d/www.conf) is replaced by our php-fpm.conf
# as the single source of fpm settings.
# The package list is expanded unquoted on purpose: one word per package.
# hadolint ignore=SC2046
RUN set -eux; \
    apk upgrade --no-cache; \
    apk add --no-cache "php${PHP_VERSION}" "php${PHP_VERSION}-fpm" \
        $(for p in ${PHP_PACKAGES}; do printf 'php%s-%s ' "${PHP_VERSION}" "$p"; done); \
    rm -f "/etc/php${PHP_VERSION}/php-fpm.d/www.conf"; \
    [ -e /usr/bin/php ] || ln -s "php${PHP_VERSION}" /usr/bin/php; \
    ln -s "/usr/sbin/php-fpm${PHP_VERSION}" /usr/local/bin/php-fpm; \
    m=$(php -m); for e in mysqli gd intl bcmath sodium zlib 'Zend OPcache'; do echo "$m" | grep -qx "$e"; done

COPY php/php-fpm.conf /etc/php${PHP_VERSION}/php-fpm.conf
COPY php/glpi.ini     /etc/php${PHP_VERSION}/conf.d/99-glpi.ini

# Extra ini directory scanned after the image's conf.d (a leading ":" appends
# to the compiled-in scan dir). The Helm chart mounts its generated ini here,
# so its settings override glpi.ini without depending on the PHP path.
ENV PHP_INI_SCAN_DIR=":/etc/glpi/php.d"
RUN mkdir -p /etc/glpi/php.d

# Application code is root-owned and read-only to the runtime user.
COPY --from=build /var/www/glpi /var/www/glpi

# Only the data paths are owned by uid/gid 33 (a PVC in the chart):
#   config/       config_db.php and the encryption keys
#   files/        documents, sessions, cache, pictures, ...
#   logs/         GLPI log files
#   marketplace/  plugins installed from the marketplace
RUN set -eux; \
    mkdir -p /var/glpi/config /var/glpi/files /var/glpi/logs /var/glpi/marketplace; \
    chown -R 33:33 /var/glpi; \
    chmod -R u+rwX,go-w /var/glpi

WORKDIR /var/www/glpi
USER 33:33
EXPOSE 9000
CMD ["php-fpm", "--nodaemonize", "--force-stderr"]
