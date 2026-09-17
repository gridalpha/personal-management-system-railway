#!/bin/sh
set -eu

log() { echo "[pms-front-entrypoint] $*"; }

: "${PORT:=8080}"
# No apostrophes in this message: bash processes quotes inside ${VAR:?...} and one
# there fails the whole script at EOF, pointing nowhere near this line.
: "${PMS_BACKEND_URL:?PMS_BACKEND_URL must be set to the public origin of the backend service, e.g. https://backend-production.up.railway.app}"

# The SPA concatenates this with each API path, so a trailing slash yields '//login'.
BACKEND_URL="${PMS_BACKEND_URL%/}"

case "${BACKEND_URL}" in
  http://*|https://*) ;;
  *)
    log "FATAL: PMS_BACKEND_URL must start with http:// or https:// (got '${BACKEND_URL}')"
    exit 1
    ;;
esac

log "serving the SPA against ${BACKEND_URL}"

rm -rf /srv/www
mkdir -p /srv/www
cp -a /opt/pms-front/dist/. /srv/www/

# Only the freshly copied text assets carry the token; the .gz siblings are rebuilt below.
find /srv/www -type f \( -name '*.js' -o -name '*.html' -o -name '*.css' -o -name '*.json' \) \
  -exec sed -i "s|__PMS_BACKEND_URL__|${BACKEND_URL}|g" {} +

find /srv/www -type f -name '*.gz' -delete
find /srv/www -type f -name '*.js' -exec gzip -k -f {} +

if grep -rqI '__PMS_BACKEND_URL__' /srv/www; then
  log "FATAL: the placeholder survived the substitution"
  exit 1
fi

chown -R nginx:nginx /srv/www

log "rendering the nginx configuration for port ${PORT}"
PORT="${PORT}" envsubst '${PORT}' < /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf
if grep -q '\${' /etc/nginx/nginx.conf; then
  log "FATAL: an unsubstituted placeholder survived in nginx.conf"
  exit 1
fi
nginx -t

log "starting nginx on ${PORT}"
exec nginx
