# hom-system

Bridge repo for full-stack work on HOM. Backend (and later frontend) live here as git
submodules so one checkout gives you the whole system plus a local Docker environment.

## Layout

```
hom-system/
├── compose.yml      # local-only docker environment
├── Makefile         # shortcuts (make help)
├── gym-backend/     # submodule → HMBcorp/hom-backend (Laravel 12 / PHP 8.2)
└── gym-frontend/    # submodule → TBD
```

## Getting started

```bash
make init     # clone submodules
make build    # build the backend image
make up       # start backend + postgres + redis + mailpit
make logs     # watch it boot
```

First boot of `backend` copies `.env.example` → `.env`, runs `composer install`,
generates `APP_KEY`, and runs migrations. It takes a few minutes; after that startup
is fast because `vendor/` lives in the bind-mounted submodule.

## Services

| Service   | Host URL / port         | Notes                          |
|-----------|-------------------------|--------------------------------|
| backend   | http://localhost:8881   | `php artisan serve`            |
| pgsql     | localhost:5433          | db/user `hom`, password `secret` |
| redis     | localhost:6378          |                                |
| mailpit   | http://localhost:8025   | catches all outgoing mail      |
| frontend  | http://localhost:3000   | commented out until the submodule exists |

Inside the network, services talk over their names: `pgsql:5432`, `redis:6379`,
`backend:8000`.

Queue worker and scheduler are behind a profile so they don't run unless you want them:

```bash
make up-workers
```

## Common tasks

```bash
make sh                          # bash in the backend container
make artisan cmd="route:list"
make migrate
make fresh                       # migrate:fresh --seed
make test
make psql
make destroy                     # tear down + delete db/redis volumes
```

## Notes

- This environment is **local only** — credentials are throwaway, `APP_DEBUG=true`,
  and nothing here is meant for staging or production.
- Env values in `compose.yml` override the container's `.env` (Laravel reads real env
  vars first), so DB/Redis hosts stay correct even if you edit `gym-backend/.env`.
  If you cached config (`config:cache`) and things look stale, run
  `make artisan cmd="config:clear"`.
- Files are created by the container as UID/GID 1000 by default. The Makefile exports
  your real `UID`/`GID` so ownership matches your host user.

## Adding the frontend submodule

```bash
git submodule add git@github.com:HMBcorp/<frontend-repo>.git gym-frontend
```

Then uncomment the `frontend` service in `compose.yml` and adjust the dev command/port
to whatever the frontend uses.
