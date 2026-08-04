# hom-system

Bridge repo for full-stack work on HOM. Backend (and later frontend) live here as git
submodules so one checkout gives you the whole system plus a local Docker environment.

## Layout

```
hom-system/
├── compose.yml      # local-only docker environment
├── Makefile         # shortcuts (make help)
├── gym-backend/     # submodule → HMBcorp/hom-backend (Laravel 12 / PHP 8.2)
└── gym-frontend/    # submodule → HMBcorp/hom-frontend (Nuxt 3 admin, SPA)
```

## Getting started

```bash
make init     # clone submodules
make build    # build the backend image
make up       # start backend + frontend + postgres + redis + mailpit
make logs     # watch it boot
```

First boot of `backend` copies `docker/backend/env.local` → `gym-backend/.env`, runs
`composer install`, generates `APP_KEY`, and migrates. `frontend` runs `yarn install`.
Both take a few minutes; after that startup is fast because `vendor/` and `node_modules/`
live in the bind-mounted submodules. Then seed some data:

```bash
make seed     # or `make fresh` to wipe and reseed from scratch
```

Both services hot reload: the backend runs `php artisan serve` over the bind mount (edits
apply on the next request), the frontend runs `yarn dev` with Vite HMR.

## Services

| Service   | Host URL / port         | Notes                          |
|-----------|-------------------------|--------------------------------|
| backend   | http://localhost:8881   | `php artisan serve`            |
| frontend  | http://localhost:3000   | `yarn dev` (Nuxt 3, SSR off)   |
| pgsql     | localhost:5433          | db/user `hom`, password `secret` |
| redis     | localhost:6378          |                                |
| mailpit   | http://localhost:8025   | catches all outgoing mail      |

Inside the network, services talk over their names: `pgsql:5432`, `redis:6379`,
`backend:8000`.

The frontend calls the API through relative `/api` paths, which Nitro proxies
server-side to `BACKEND_API_URL` (`http://backend:8000` in compose) — so no CORS setup
and no host ports involved in that hop.

Queue worker and scheduler are behind a profile so they don't run unless you want them:

```bash
make up-workers
```

## Common tasks

```bash
make sh                          # bash in the backend container
make artisan cmd="route:list"
make migrate
make seed                        # local-safe seeders
make fresh                       # drop, migrate, seed
make test
make psql
make sh-frontend                 # bash in the frontend container
make yarn cmd="add foo"
make destroy                     # tear down + delete db/redis volumes
```

## Notes

- This environment is **local only** — credentials are throwaway, `APP_DEBUG=true`,
  and nothing here is meant for staging or production.
- Files are created by the container as UID/GID 1000 by default. The Makefile exports
  your real `UID`/`GID` so ownership matches your host user.

## Backend notes

- The dev image is `docker/backend/Dockerfile`, **not** `gym-backend/Dockerfile` — that
  one is the production build (source COPYed in, `composer install` at build time,
  Octane/Swoole entrypoint). Locally we want no baked-in source and `php artisan serve`,
  so an edit is live on the next request. Opcache is set to revalidate every request.
- Backend config comes from `gym-backend/.env`, seeded on first boot from
  `docker/backend/env.local`. It is **not** driven by compose `environment:`, because
  `artisan serve` only forwards a whitelist of env vars to the PHP dev server — anything
  else set in compose silently never reaches the served app. Edit `gym-backend/.env` for
  local tweaks; delete it and restart to reset. If things look stale after a config
  change: `make artisan cmd="config:clear"`.
- `make seed` skips `AmpabaSeeder` and `ampaba:sync:branch`: they call the Ampaba partner
  API and fail without credentials, which is why plain `php artisan db:seed` doesn't work
  offline. Fill in the `AMPABA_*` vars in `.env` if you need that data.
- `make fresh` drops the `ampaba` Postgres schema before `migrate:fresh`. Laravel only
  drops tables in the search path (`config/database.php` pins it to `public`), so without
  that the ampaba create-table migration fails on a re-run.

## Frontend notes

- Nuxt 3 + Vuetify admin dashboard, `ssr: false`, package manager **yarn 1**.
- Local dev deliberately ignores `gym-frontend/Dockerfile` — that's a production
  multi-stage build (`yarn build` → `node .output/server/index.mjs`). Compose runs
  `yarn dev` on a plain `node:22-slim` image over the bind mount so HMR works.
- Env comes from compose, not `.env`: `BACKEND_API_URL`, `APP_URL`,
  `NUXT_SESSION_PASSWORD`, `NUXT_GOOGLEMAPS_API_KEY` (empty locally — set it if you touch
  the maps screens).
- `BACKEND_API_URL` is `http://backend:8000/cms/v1`, not the bare host. The repositories
  call bare paths (`branch`, `auth/login`) prefixed with `/api`, and Nitro's proxy strips
  `/api` before forwarding — so the CMS version prefix has to live in the base URL.
  Verified: `curl localhost:3000/api/branch` reaches Laravel's `cms/v1/branch`.
- Some `/api/*` paths are intercepted by the mock handlers in `gym-frontend/server/api/`
  before the proxy sees them. If an endpoint returns fake data, that's why.
- HMR works over the bind mount (inotify). If your setup misses changes, add
  `server: { watch: { usePolling: true } }` to the frontend's Vite config — the
  `CHOKIDAR_USEPOLLING` env var does nothing for Vite.
