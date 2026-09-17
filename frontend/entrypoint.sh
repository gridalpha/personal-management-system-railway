#!/bin/sh
set -eu

log() { echo "[pms-front-entrypoint] $*"; }

: "${PORT:=8080}"
# No apostrophes in this message: bash processes quotes inside ${VAR:?...} and one
# there fails the whole script at EOF, pointing nowhere near this line.
: "${PMS_BACKEND_URL:?PMS_BACKEND_URL must be set to the public origin of the backend service, e.g. https://backend-production.up.railway.app}"
: "${PMS_BACKEND_PRIVATE_URL:=}"

BACKEND_URL="${PMS_BACKEND_URL%/}"

case "${BACKEND_URL}" in
  http://*|https://*) ;;
  *)
    log "FATAL: PMS_BACKEND_URL must start with http:// or https:// (got ${BACKEND_URL})"
    exit 1
    ;;
esac

# The key is fetched over the private network when possible: it is available before the
# backend has a public domain, and it keeps the request off the public internet.
KEY_URL="${PMS_BACKEND_PRIVATE_URL:-$BACKEND_URL}"
KEY_URL="${KEY_URL%/}/jwt_public_key"

export PMS_BACKEND_URL="${BACKEND_URL}"

render() {
  rm -rf /srv/www.new
  mkdir -p /srv/www.new
  cp -a /opt/pms-front/dist/. /srv/www.new/
  python3 /opt/pms-front/substitute.py /srv/www.new

  # The build script writes .js.gz siblings and nginx prefers them, so a stale one
  # would serve the placeholder no matter what was just substituted.
  find /srv/www.new -type f -name '*.gz' -delete
  find /srv/www.new -type f -name '*.js' -exec gzip -k -f {} +

  chown -R nginx:nginx /srv/www.new
  rm -rf /srv/www.old
  if [ -d /srv/www ]; then mv /srv/www /srv/www.old; fi
  mv /srv/www.new /srv/www
  rm -rf /srv/www.old
}

log "serving the SPA against ${BACKEND_URL}"
PMS_JWT_PUBLIC_KEY="$(curl -fsS --max-time 5 "${KEY_URL}" 2>/dev/null || true)"
export PMS_JWT_PUBLIC_KEY
if [ -n "${PMS_JWT_PUBLIC_KEY}" ]; then
  log "got the JWT public key from ${KEY_URL}"
else
  log "JWT public key not available yet - serving now and retrying in the background"
fi
render

if grep -rqI '__PMS_BACKEND_URL__' /srv/www; then
  log "FATAL: the backend URL placeholder survived the substitution"
  exit 1
fi

# The SPA renders and the health check passes without the key; only signing-in needs it.
# Retrying in the background rather than blocking keeps a cold template deploy - where
# this container and the backend start at the same moment - off a startup deadlock.
if [ -z "${PMS_JWT_PUBLIC_KEY}" ]; then
  (
    i=0
    while [ "$i" -lt 120 ]; do
      i=$((i + 1))
      sleep 10
      key="$(curl -fsS --max-time 5 "${KEY_URL}" 2>/dev/null || true)"
      case "${key}" in
        *"BEGIN PUBLIC KEY"*)
          log "JWT public key arrived after ${i} attempt(s) - re-rendering"
          export PMS_JWT_PUBLIC_KEY="${key}"
          render
          log "re-render complete"
          exit 0
          ;;
      esac
    done
    log "gave up waiting for the JWT public key after 20 minutes"
  ) &
fi

log "rendering the nginx configuration for port ${PORT}"
PORT="${PORT}" envsubst '${PORT}' < /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf
if grep -q '\${' /etc/nginx/nginx.conf; then
  log "FATAL: an unsubstituted placeholder survived in nginx.conf"
  exit 1
fi
nginx -t

log "starting nginx on ${PORT}"
exec nginx
