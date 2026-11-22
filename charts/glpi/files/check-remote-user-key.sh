# remoteUserAuth.sharedKey: nginx does not start without a usable key.
# Runs in the nginx container before the image's entrypoint. Kubernetes
# expands dollar-parenthesis references in container args, so the script
# avoids that syntax.
key="${GLPI_REMOTE_USER_KEY:-}"
fail() {
  echo "remoteUserAuth: the shared key $1. Put a random key in the Secret (e.g. openssl rand -hex 32)." >&2
  exit 1
}
case "$key" in
  "") fail "is empty" ;;
  REPLACE_ME) fail "is the REPLACE_ME placeholder" ;;
  *[!A-Za-z0-9_-]*) fail "may only hold letters, digits, - and _" ;;
esac
[ "${#key}" -ge 32 ] || fail "is shorter than 32 characters"
