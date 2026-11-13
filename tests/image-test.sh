#!/usr/bin/env bash
# Contract tests for the GLPI image: the things the chart relies on.
# Needs: docker, and the image built (make image).
#
#   tests/image-test.sh                     # tests glpi:dev
#   IMAGE=ghcr.io/jaturu/glpi:12.0.2 tests/image-test.sh
set -uo pipefail

cd "$(dirname "$0")/.." || exit 2
IMAGE=${IMAGE:-glpi:dev}
VERSION=$(make -s version)
failed=0

# Run like the chart does: non-root, read-only root filesystem, writable /tmp
# and a writable data volume at /var/glpi.
run() { docker run --rm --read-only --tmpfs /tmp --tmpfs /var/glpi:uid=33,gid=33 --entrypoint sh "$@"; }
check() {
  local name=$1; shift
  if out=$("$@" 2>&1); then echo "PASS $name"
  else echo "FAIL $name"; echo "$out" | sed 's/^/    /'; failed=1; fi
}

echo "Testing $IMAGE (expect GLPI $VERSION)"

check "runs as uid/gid 33" \
  run "$IMAGE" -c '[ "$(id -u):$(id -g)" = "33:33" ]'
check "contains GLPI $VERSION" \
  run "$IMAGE" -c "[ \"\$(ls version)\" = '$VERSION' ]"
check "has the PHP extensions GLPI requires and recommends" \
  run "$IMAGE" -c 'm=$(php -m); for e in bcmath bz2 ctype curl dom exif fileinfo filter gd iconv intl ldap libxml mbstring mysqli openssl Phar session SimpleXML sodium tokenizer xmlreader xmlwriter zip zlib "Zend OPcache"; do echo "$m" | grep -qix "$e" || { echo "missing $e"; exit 1; }; done'
check "php-fpm config is valid" \
  run "$IMAGE" -c 'php-fpm -t'
check "php-fpm listens on loopback only, with the ping endpoint" \
  run "$IMAGE" -c 'c=$(php-fpm -tt 2>&1); echo "$c" | grep -q "listen = 127.0.0.1:9000" && echo "$c" | grep -q "ping.path = /fpm-ping"'
check "GLPI console boots and passes its own requirements check" \
  run "$IMAGE" -c 'mkdir -p /var/glpi/config /var/glpi/files /var/glpi/logs /var/glpi/marketplace && php bin/console system:check_requirements'
check "data paths point at /var/glpi" \
  run "$IMAGE" -c 'for d in config files logs marketplace; do grep -q "/var/glpi/$d" inc/downstream.php || { echo "$d"; exit 1; }; done'
check "ini files in /etc/glpi/php.d override the image (cli + fpm)" \
  bash -c "docker run --rm --read-only --tmpfs /tmp --tmpfs /etc/glpi/php.d:uid=33,gid=33 --entrypoint sh '$IMAGE' -c \
    'printf \"upload_max_filesize = 77M\n\" > /etc/glpi/php.d/zz.ini && [ \"\$(php -r \"echo ini_get(\\\"upload_max_filesize\\\");\")\" = 77M ] && php-fpm -i | grep -q \"^upload_max_filesize => 77M\"'"
check "data paths are owned by uid/gid 33" \
  docker run --rm --entrypoint sh "$IMAGE" -c 'for d in /var/glpi /var/glpi/config /var/glpi/files /var/glpi/logs /var/glpi/marketplace; do [ "$(stat -c %u:%g $d)" = "33:33" ] || { echo "$d"; exit 1; }; done'
check "application code is not writable by the runtime user" \
  run "$IMAGE" -c 'for p in bin/console src vendor public/index.php inc/downstream.php config; do [ ! -w "$p" ] || { echo "$p writable"; exit 1; }; [ "$(stat -c %u $p)" = 0 ] || { echo "$p not root-owned"; exit 1; }; done'
check "public/ holds the compiled assets and one PHP file" \
  run "$IMAGE" -c '[ -f public/lib/base.min.js ] && [ -d public/build ] && [ "$(find public -name "*.php")" = public/index.php ]'
check "in-tree data directories are removed" \
  run "$IMAGE" -c 'for p in files marketplace .git; do [ ! -e "$p" ] || { echo "$p present"; exit 1; }; done'
check "no build tools in the runtime image" \
  run "$IMAGE" -c 'for t in git composer gcc cc make curl; do ! command -v $t >/dev/null 2>&1 || { echo "$t present"; exit 1; }; done'

[ $failed -eq 0 ] && echo "IMAGE TESTS PASSED" || echo "IMAGE TESTS FAILED"
exit $failed
