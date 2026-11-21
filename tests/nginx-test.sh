#!/usr/bin/env bash
# Run the chart's rendered nginx configuration in the real nginx sidecar image
# and check what PHP receives. nginx (read-only root, non-root, envsubst
# templates rendered into a tmpfs like the chart's emptyDir) shares a network
# namespace with a php-fpm container, as in the pod. A stub index.php reports
# REMOTE_USER and the HTTP_X_* parameters it sees.
#
# Covers: nginx -t for each mode, nginx.extraServerConfig, remoteUserAuth off /
# allowFrom / sharedKey / both, and the startup key checks.
# Needs: helm, docker, python3 with PyYAML.
#
#   tests/nginx-test.sh
#   PHP_IMAGE=php:8.4-fpm-alpine tests/nginx-test.sh
set -uo pipefail

cd "$(dirname "$0")/.." || exit 2
CHART=charts/glpi
PHP_IMAGE=${PHP_IMAGE:-php:8.4-fpm-alpine}

for tool in helm docker python3; do
  command -v "$tool" >/dev/null || { echo "missing: $tool" >&2; exit 2; }
done

# The nginx image the chart deploys by default.
NGINX_IMAGE=$(helm show values "$CHART" | python3 -c '
import sys, yaml
i = yaml.safe_load(sys.stdin)["nginx"]["image"]
print(i["repository"] + ("@" + i["digest"] if i["digest"] else ":" + i["tag"]))')
echo "nginx image: $NGINX_IMAGE, php image: $PHP_IMAGE"
WORK=$(mktemp -d)
KEY=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
pass=0; failn=0
ok()  { echo "PASS $*"; pass=$((pass+1)); }
bad() { echo "FAIL $*"; failn=$((failn+1)); }

mkdir -p "$WORK/public"
cat > "$WORK/public/index.php" <<'PHP'
<?php
$out = ['REMOTE_USER' => $_SERVER['REMOTE_USER'] ?? null];
foreach ($_SERVER as $k => $v) { if (str_starts_with($k, 'HTTP_X_')) { $out[$k] = $v; } }
foreach (getenv() as $k => $v) { if (str_contains($k, 'KEY')) { $out['ENV_'.$k] = $v; } }
header('Content-Type: application/json');
echo json_encode($out);
PHP
chmod -R a+rX "$WORK"

cleanup() { docker rm -f e2e-ngx e2e-fpm >/dev/null 2>&1; rm -rf "$WORK"; }
trap cleanup EXIT

render_conf() { # $1 = out file, rest = helm args
  local out=$1; shift
  helm template desk "$CHART" -s templates/configmap-nginx.yaml "$@" \
    | python3 -c 'import sys,yaml; print(yaml.safe_load(sys.stdin)["data"]["glpi.conf"], end="")' > "$out"
}

start() { # $1 = mode (plain|template), $2 = key env value or "-"
  docker rm -f e2e-ngx e2e-fpm >/dev/null 2>&1
  docker run -d --name e2e-fpm -v "$WORK/public:/var/www/glpi/public:ro" "$PHP_IMAGE" >/dev/null
  local args=(--name e2e-ngx --network container:e2e-fpm --read-only --tmpfs "/tmp:uid=33,gid=33"
              --user 33:33 --cap-drop ALL --security-opt no-new-privileges
              -v "$WORK/public:/var/www/glpi/public:ro")
  if [ "$1" = template ]; then
    args+=(-v "$WORK/conf:/etc/nginx/templates:ro" --tmpfs "/etc/nginx/conf.d:uid=33,gid=33"
           -e NGINX_ENVSUBST_FILTER='^GLPI_REMOTE_USER_KEY$')
    [ "$2" != "-" ] && args+=(-e "GLPI_REMOTE_USER_KEY=$2")
    # Same command as the chart's Deployment.
    local script
    script="$(cat "$CHART/files/check-remote-user-key.sh")
exec /docker-entrypoint.sh nginx -g 'daemon off;'"
    docker run -d "${args[@]}" --entrypoint /bin/sh "$NGINX_IMAGE" -c "$script" >/dev/null
  else
    args+=(-v "$WORK/conf:/etc/nginx/conf.d:ro")
    docker run -d "${args[@]}" "$NGINX_IMAGE" >/dev/null
  fi
  sleep 2
}

get() { docker exec e2e-ngx curl -s -o /dev/stdout -w '\n%{http_code}' "$@" http://127.0.0.1:8080/ 2>/dev/null; }
nginx_t() { docker exec e2e-ngx nginx -t 2>&1 | tail -1; }

rm -rf "$WORK/conf"; mkdir -p "$WORK/conf"

# ---------------------------------------------------------------- off
echo "== remoteUserAuth off"
render_conf "$WORK/conf/glpi.conf" --set-string 'nginx.extraServerConfig=location = /robots.txt { return 200 "User-agent: *\nDisallow: /\n"; }'
start plain -
[[ $(nginx_t) == *successful* ]] && ok "nginx -t" || bad "nginx -t: $(nginx_t)"
r=$(get -H 'X-Forwarded-User: alice')
[[ $r == *'"REMOTE_USER":null'* && $r == *'"HTTP_X_FORWARDED_USER":"alice"'* ]] \
  && ok "off: header passes as before, no REMOTE_USER" || bad "off: $r"
r=$(docker exec e2e-ngx curl -s http://127.0.0.1:8080/robots.txt)
[[ $r == *"Disallow: /"* ]] && ok "extraServerConfig location served" || bad "extraServerConfig: $r"

# ---------------------------------------------------------------- allowFrom
echo "== allowFrom only (127.0.0.1 allowed)"
render_conf "$WORK/conf/glpi.conf" --set remoteUserAuth.enabled=true,remoteUserAuth.header=X-Forwarded-User \
  --set 'remoteUserAuth.allowFrom={127.0.0.1/32}'
start plain -
[[ $(nginx_t) == *successful* ]] && ok "nginx -t" || bad "nginx -t: $(nginx_t)"
r=$(get -H 'X-Forwarded-User: alice')
[[ $r == *'"REMOTE_USER":"alice"'* && $r != *'HTTP_X_FORWARDED_USER":"alice'* ]] \
  && ok "allowed client: REMOTE_USER=alice, raw header blank" || bad "allowed: $r"
r=$(get)
[[ $r == *'"REMOTE_USER":""'* ]] && ok "allowed client, no header: REMOTE_USER empty" || bad "no header: $r"

echo "== allowFrom only (client not listed)"
render_conf "$WORK/conf/glpi.conf" --set remoteUserAuth.enabled=true,remoteUserAuth.header=X-Forwarded-User \
  --set 'remoteUserAuth.allowFrom={192.0.2.10}'
start plain -
r=$(get -H 'X-Forwarded-User: alice')
[[ ${r##*$'\n'} == 403 ]] && ok "other client: 403" || bad "other client: $r"

# ---------------------------------------------------------------- sharedKey
SK=(--set "remoteUserAuth.enabled=true,remoteUserAuth.header=X-authentik-username"
    --set "remoteUserAuth.sharedKey.header=X-GLPI-Proxy-Key,remoteUserAuth.sharedKey.existingSecret=s,remoteUserAuth.sharedKey.secretKey=k")
echo "== sharedKey only"
rm -f "$WORK/conf/glpi.conf"; render_conf "$WORK/conf/glpi.conf.template" "${SK[@]}"
start template "$KEY"
[[ $(nginx_t) == *successful* ]] && ok "nginx -t (rendered template)" || bad "nginx -t: $(nginx_t)"
docker exec e2e-ngx grep -q "~^$KEY\\$" /etc/nginx/conf.d/glpi.conf && ok "key substituted into conf.d" || bad "key not substituted"
docker exec e2e-ngx grep -q '\$http_x_authentik_username;' /etc/nginx/conf.d/glpi.conf && ok "nginx variables left alone by envsubst" || bad "envsubst touched nginx variables"
r=$(get -H 'X-authentik-username: alice' -H "X-GLPI-Proxy-Key: $KEY")
[[ $r == *'"REMOTE_USER":"alice"'* && $r != *'HTTP_X_AUTHENTIK_USERNAME":"alice'* && $r != *"$KEY"* ]] \
  && ok "valid key: REMOTE_USER=alice, PHP sees neither header nor key" || bad "valid key: $r"
r=$(get -H 'X-authentik-username: alice' -H "X-GLPI-Proxy-Key: ${KEY^^}")
[[ $r == *'"REMOTE_USER":""'* && ${r##*$'\n'} == 200 ]] && ok "key in other case: anonymous, 200" || bad "case: $r"
r=$(get -H 'X-authentik-username: alice' -H "X-GLPI-Proxy-Key: ${KEY}x")
[[ $r == *'"REMOTE_USER":""'* ]] && ok "longer key: anonymous" || bad "longer: $r"
r=$(get -H 'X-authentik-username: alice' -H "X-GLPI-Proxy-Key: ${KEY:0:40}")
[[ $r == *'"REMOTE_USER":""'* ]] && ok "key prefix: anonymous" || bad "prefix: $r"
r=$(get -H 'X-authentik-username: alice')
[[ $r == *'"REMOTE_USER":""'* && ${r##*$'\n'} == 200 ]] && ok "no key: anonymous, 200" || bad "no key: $r"
r=$(get -H 'X-authentik-username: alice' -H "X-GLPI-Proxy-Key: $KEY" -H "X-GLPI-Proxy-Key: $KEY")
[[ $r == *'"REMOTE_USER":""'* ]] && ok "key header sent twice: anonymous" || bad "twice: $r"
r=$(get -H 'X_authentik_username: alice' -H "X-GLPI-Proxy-Key: $KEY")
[[ $r == *'"REMOTE_USER":""'* && $r != *alice* ]] && ok "underscore variant of the header is dropped" || bad "underscore: $r"

echo "== both (allowFrom 127.0.0.1 + key)"
render_conf "$WORK/conf/glpi.conf.template" "${SK[@]}" --set 'remoteUserAuth.allowFrom={127.0.0.1}'
start template "$KEY"
[[ $(nginx_t) == *successful* ]] && ok "nginx -t" || bad "nginx -t: $(nginx_t)"
r=$(get -H 'X-authentik-username: alice' -H "X-GLPI-Proxy-Key: $KEY")
[[ $r == *'"REMOTE_USER":"alice"'* ]] && ok "both: valid key -> alice" || bad "both: $r"
r=$(get -H 'X-authentik-username: alice' -H "X-GLPI-Proxy-Key: wrong")
[[ $r == *'"REMOTE_USER":""'* ]] && ok "both: wrong key -> anonymous" || bad "both wrong: $r"

echo "== startup key checks"
for bad_key in "-" "" REPLACE_ME short0123456789 'has space 0123456789012345678901234567' 'quote"0123456789012345678901234567890'; do
  start template "$bad_key"
  state=$(docker inspect -f '{{.State.Running}} {{.State.ExitCode}}' e2e-ngx)
  log=$(docker logs e2e-ngx 2>&1 | tail -1)
  [[ $state == "false 1" ]] && ok "refuses key [${bad_key}]: $log" || bad "key [${bad_key}] state=$state log=$log"
done

echo "passed=$pass failed=$failn"
[ "$failn" -eq 0 ]
