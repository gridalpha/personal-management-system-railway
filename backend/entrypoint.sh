#!/bin/bash
set -euo pipefail

log() { echo "[pms-entrypoint] $*"; }

: "${PMS_ROLE:=web}"
: "${PORT:=8080}"
: "${APP_SECRET:?APP_SECRET must be set - it is the JWT passphrase and the seed for the at-rest encryption key}"
: "${DATABASE_URL:?DATABASE_URL must be set}"
: "${RAILWAY_VOLUME_MOUNT_PATH:=/data}"
: "${PMS_SCHEDULER_INTERVAL_SECONDS:=3600}"
: "${UPLOAD_DIR:=upload}"
: "${IMAGES_UPLOAD_DIR:=upload/images}"
: "${FILES_UPLOAD_DIR:=upload/files}"
: "${VIDEOS_UPLOAD_DIR:=upload/videos}"
: "${MINIATURES_UPLOAD_DIR:=upload/miniatures}"

APP_DIR=/application
DATA_DIR="${RAILWAY_VOLUME_MOUNT_PATH}"
CONSOLE="php ${APP_DIR}/bin/console"

cd "${APP_DIR}"

# ---------------------------------------------------------------------------
# At-rest encryption key.
#
# Upstream commits a working encrypt_key into config/packages/config/encryption.yaml
# and its own entrypoint only replaces an *empty* one, so a stock install encrypts
# every stored password under a key that is public on GitHub. Derive a per-deployment
# key from APP_SECRET instead: deterministic, so it survives losing the volume, and
# overridable by anyone who wants to bring their own.
# ---------------------------------------------------------------------------
if [ -z "${PMS_ENCRYPTION_KEY:-}" ]; then
  PMS_ENCRYPTION_KEY="$(printf %s "${APP_SECRET}:pms-encryption" | openssl dgst -sha256 -binary | openssl base64 -A)"
  log "derived the at-rest encryption key from APP_SECRET"
else
  log "using the operator-supplied PMS_ENCRYPTION_KEY"
fi

mkdir -p "${APP_DIR}/config/packages/config"
printf "parameters:\n    encrypt_key: '%s'\n" "${PMS_ENCRYPTION_KEY}" > "${APP_DIR}/config/packages/config/encryption.yaml"
if grep -q 'IK9aghdoR1yIPYv8ov8xedRcIHUqF7ziRdVCuGEKofE=' "${APP_DIR}/config/packages/config/encryption.yaml"; then
  log "FATAL: the upstream demo encryption key is still in place"
  exit 1
fi

# ---------------------------------------------------------------------------
# Persistent state. Only the web role owns a volume; the scheduler keeps its
# (unused) JWT keys in the container layer.
# ---------------------------------------------------------------------------
if [ "${PMS_ROLE}" = "web" ]; then
  mkdir -p "${DATA_DIR}/upload" "${DATA_DIR}/jwt"

  # Uploads live on the volume but have to stay reachable under the web root. The
  # volume is mounted at /data rather than at public/upload so its lost+found never
  # lands inside a directory the storage modules enumerate.
  rm -rf "${APP_DIR}/public/upload"
  ln -sfn "${DATA_DIR}/upload" "${APP_DIR}/public/upload"

  # JWT keys signed with APP_SECRET: regenerating them on every deploy would log
  # every session out, so they belong on the volume too - and never under the web
  # root, where nginx would serve the private key.
  rm -rf "${APP_DIR}/config/jwt/prod"
  mkdir -p "${APP_DIR}/config/jwt"
  ln -sfn "${DATA_DIR}/jwt" "${APP_DIR}/config/jwt/prod"

  for dir in "${UPLOAD_DIR}/PROFILE_IMAGE" "${IMAGES_UPLOAD_DIR}" "${FILES_UPLOAD_DIR}" "${VIDEOS_UPLOAD_DIR}" "${MINIATURES_UPLOAD_DIR}"; do
    mkdir -p "${APP_DIR}/public/${dir}"
  done

  chown -R www-data:www-data "${DATA_DIR}/upload" "${DATA_DIR}/jwt"
  chown -h www-data:www-data "${APP_DIR}/public/upload" "${APP_DIR}/config/jwt/prod"
else
  mkdir -p "${APP_DIR}/config/jwt/prod"
fi
mkdir -p "${APP_DIR}/var"

# ---------------------------------------------------------------------------
# Railway has no service ordering, so the database is raced on every cold deploy.
# ---------------------------------------------------------------------------
log "waiting for the database"
db_ready=0
for i in $(seq 1 60); do
  if php /opt/pms/healthz.php > /dev/null 2>&1; then
    log "database reachable after attempt ${i}"
    db_ready=1
    break
  fi
  sleep 5
done
if [ "${db_ready}" -ne 1 ]; then
  log "FATAL: database still unreachable after 60 attempts"
  exit 1
fi

# The compiled container embeds encrypt_key, which is written above, so the cache can
# only be warmed here and never in a build layer.
log "warming the Symfony cache"
${CONSOLE} cache:clear --no-warmup --no-interaction
${CONSOLE} cache:warmup --no-interaction

log "generating the JWT key pair if none exists yet"
${CONSOLE} lexik:jwt:generate-keypair --skip-if-exists --no-interaction

if [ "${PMS_ROLE}" = "web" ]; then
  log "running database migrations"
  ${CONSOLE} doctrine:database:create --if-not-exists --no-interaction
  ${CONSOLE} doctrine:migrations:migrate --no-interaction --allow-no-migration

  # Registration is open to anyone until the first active user exists, so this has to
  # happen before anything binds the public port - not in a background subshell.
  log "seeding the first account"
  ${CONSOLE} railway:create-first-user --no-interaction

  log "registering files already present on the volume"
  ${CONSOLE} storage:upload-files-into-entities --no-interaction || log "storage registration reported a problem - continuing"

  chown -R www-data:www-data "${APP_DIR}/var" "${APP_DIR}/config/jwt" || true

  log "rendering the nginx configuration for port ${PORT}"
  PORT="${PORT}" envsubst '${PORT}' < /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf
  if grep -q '\${' /etc/nginx/nginx.conf; then
    log "FATAL: an unsubstituted placeholder survived in nginx.conf"
    exit 1
  fi
  nginx -t

  log "starting php-fpm"
  php-fpm --nodaemonize &
  fpm_up=0
  for i in $(seq 1 30); do
    if (exec 3<>/dev/tcp/127.0.0.1/9000) 2>/dev/null; then
      fpm_up=1
      break
    fi
    sleep 1
  done
  if [ "${fpm_up}" -ne 1 ]; then
    log "FATAL: php-fpm never opened 127.0.0.1:9000"
    exit 1
  fi

  log "starting nginx on ${PORT}"
  exec nginx
fi

if [ "${PMS_ROLE}" = "scheduler" ]; then
  chown -R www-data:www-data "${APP_DIR}/var" || true

  # A worker with no HTTP surface reads SUCCESS forever. PHP's built-in server plus the
  # same probe script gives it a real dependency check in one line.
  log "starting the health endpoint on ${PORT}"
  php -S "[::]:${PORT}" /opt/pms/healthz.php > /dev/null 2>&1 &

  log "scheduler loop, every ${PMS_SCHEDULER_INTERVAL_SECONDS}s"
  while true; do
    if ${CONSOLE} cron:set-recurring-payments --no-interaction; then
      log "cron:set-recurring-payments finished"
    else
      log "cron:set-recurring-payments failed - retrying on the next tick"
    fi
    sleep "${PMS_SCHEDULER_INTERVAL_SECONDS}"
  done
fi

log "FATAL: unknown PMS_ROLE '${PMS_ROLE}' (expected 'web' or 'scheduler')"
exit 1
