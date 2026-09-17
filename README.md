# Personal Management System on Railway

Deployment files for [Volmarg/personal-management-system](https://github.com/Volmarg/personal-management-system)
(Symfony API) and [Volmarg/personal-management-system-front](https://github.com/Volmarg/personal-management-system-front)
(Vue SPA). Upstream publishes no container image for either half, so both are built
from source here.

One repository backs two Railway services. Each picks its Dockerfile with the
`RAILWAY_DOCKERFILE_PATH` variable, which keeps the repository root as the build
context for both.

| Path | Service | Role |
|---|---|---|
| `backend/Dockerfile` | `backend` | nginx + php-fpm serving the Symfony API |
| `backend/Dockerfile` | `scheduler` | the same image with `PMS_ROLE=scheduler`, running the recurring-payments job |
| `frontend/Dockerfile` | `frontend` | nginx serving the built Vue SPA |

## Why this is not a plain image deployment

- **The SPA bakes its API origin at build time.** `VITE_BACKEND_BASE_URL` is inlined by
  Vite, and on Railway the backend's public domain does not exist when the image is
  built. The bundle is built once against `__PMS_BACKEND_URL__` and the entrypoint
  substitutes `PMS_BACKEND_URL` on every boot, rebuilding the `.js.gz` siblings so
  `gzip_static` cannot serve a stale origin. A surviving placeholder fails the boot.
- **The at-rest encryption key is committed upstream.** `config/packages/config/encryption.yaml`
  ships a working key, and upstream's entrypoint only replaces an *empty* one — so a
  stock install encrypts every saved password under a key that is public on GitHub.
  `backend/entrypoint.sh` derives a per-deployment key from `APP_SECRET`
  (`sha256 -> base64`, the same 32-byte shape the app's own `encrypt:genkey` emits) and
  refuses to start if the upstream key is still in place. `PMS_ENCRYPTION_KEY` overrides it.
- **Registration is open until the first account exists.** `railway:create-first-user`
  (added to the app's own `src/Command/`) runs from the entrypoint before nginx binds
  the public port, so there is no window in which a stranger can claim the deployment.
  It is a no-op once any active user exists.
- **php-fpm hides Railway variables twice over.** The stock pool sets `clear_env = yes`
  and PHP's default `variables_order` omits `E`, while this app reads `$_ENV` directly.
  Both are corrected in `backend/fpm-pool.conf` and `backend/php.ini`, and asserted in a
  build layer.

## Source pinning

Both halves track `main` rather than the newest release tag (`v2.0.4` / `v2.0.7`,
2026-04-25): the hardening of the public `/public/get-file` download route landed
2026-08-19 and is in no release. The two repositories are developed in lockstep, so
they are pinned together — override with the `PMS_BACKEND_REF` / `PMS_FRONTEND_REF`
build arguments.

## Variables

See `deployments/` in the pipeline repository for the full list. The ones this repo's
own code reads:

| Variable | Service | Purpose |
|---|---|---|
| `APP_SECRET` | backend, scheduler | JWT passphrase and the seed for the encryption key |
| `PMS_ENCRYPTION_KEY` | backend | override for the derived at-rest key |
| `PMS_ADMIN_EMAIL` / `PMS_ADMIN_USERNAME` / `PMS_ADMIN_PASSWORD` / `PMS_ADMIN_LOCK_PASSWORD` | backend | the seeded first account |
| `PMS_ROLE` | scheduler | `web` (default) or `scheduler` |
| `PMS_SCHEDULER_INTERVAL_SECONDS` | scheduler | seconds between recurring-payment runs |
| `PMS_BACKEND_URL` | frontend | the backend's public origin, substituted into the bundle |

Licence: the deployment files here are MIT, matching both upstream projects.
