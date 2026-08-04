# CLAUDE.md

Guidance for Claude Code working in this repository.

## What this repo is

`hom-system` is a **bridge repo**: it contains no application code of its own. The apps
live here as git submodules so full-stack work happens in one checkout, and it owns the
local Docker environment that runs them together.

```
hom-system/
├── compose.yml      # local-only docker env (this repo's only "code")
├── Makefile         # entry point for every dev command
├── gym-backend/     # submodule → git@github.com:HMBcorp/hom-backend.git
└── gym-frontend/    # submodule → git@github.com:HMBcorp/hom-frontend.git
```

Because submodules are separate repos, **commits inside `gym-backend/` belong to the
backend repo**, not to this one. A commit here only ever records the submodule *pointer*
plus changes to compose/Makefile/docs. When you change both, commit in the submodule
first, then commit the updated pointer here.

## Local environment

Everything runs through `make` (it exports your real `UID`/`GID` so container-created
files aren't root-owned — prefer it over raw `docker compose`).

```bash
make init          # git submodule update --init --recursive
make build         # build hom-backend:local
make up            # backend + frontend + pgsql + redis + mailpit
make up-workers    # ...plus queue worker and scheduler (compose profile "workers")
make logs-backend / make logs-frontend
make down / make destroy   # destroy also drops db+redis volumes
```

| Service  | Host                  | In-network      |
|----------|-----------------------|-----------------|
| backend  | http://localhost:8881 | `backend:8000`  |
| frontend | http://localhost:3000 | `frontend:3000` |
| pgsql 17 | localhost:5433        | `pgsql:5432`    |
| redis    | localhost:6378        | `redis:6379`    |
| mailpit  | http://localhost:8025 | `mailpit:1025`  |

Docker network is `hom-system`; db/user `hom`, password `secret` (throwaway, local only).

Run backend commands **inside the container**, never on the host:

```bash
make sh                              # bash in the backend container
make artisan cmd="route:list"
make migrate
make fresh                           # migrate:fresh --seed — wipes local data
make test
make composer cmd="require foo/bar"
make psql
```

Both containers bind-mount their submodule and hot reload: the backend serves via
`php artisan serve` (edits live on the next request, opcache revalidates every request),
the frontend via `yarn dev` with Vite HMR. Neither needs a restart for code changes.

Environment gotchas worth knowing before debugging config:

- The backend dev image is `docker/backend/Dockerfile` in **this** repo, not
  `gym-backend/Dockerfile` (that one is the production Octane build).
- Backend config lives in `gym-backend/.env`, seeded on first boot from
  `docker/backend/env.local`. Compose `environment:` does **not** configure the served
  app — `artisan serve` only forwards a whitelist of env vars to the PHP dev server. Put
  backend settings in `docker/backend/env.local` / `.env`, never in compose.
- Stale behaviour after a config change is usually cached config:
  `make artisan cmd="config:clear"`.
- `make seed` runs the offline-safe seeders; `php artisan db:seed` fails locally because
  `DatabaseSeeder` starts with the Ampaba partner API. `make fresh` drops the `ampaba`
  schema first because `migrate:fresh` only clears the `public` search path.
- The frontend reaches the API through Nitro's `/api` proxy, which strips `/api`, so
  `BACKEND_API_URL` carries the CMS prefix (`http://backend:8000/cms/v1`). Mock handlers
  in `gym-frontend/server/api/` shadow some paths before the proxy sees them.

## Backend orientation (`gym-backend/`)

Laravel 12 on PHP 8.2, Postgres, Redis. Production runs Octane/Swoole via
`scripts/entrypoint.sh`; locally it's plain `artisan serve` — don't assume Octane
semantics (e.g. static/singleton state persisting between requests) when debugging local
behaviour, and don't introduce code that depends on them.

Routes are split by audience and versioned, all pulled in by `routes/api.php`:

- `routes/common/` — shared/public endpoints
- `routes/apps/` — customer-facing mobile app API
- `routes/cms/` — admin/CMS API
- `routes/hook/ampaba.php` — inbound Ampaba partner webhooks

`app/Http/` mirrors that split (`Apps/`, `Cms/`, `Common/`, `Hook/`), with business logic
in `app/Services/` and integrations reaching outward via `app/Jobs/`. Domain is gym
operations: branches, memberships, classes and schedules, personal trainers, orders,
products/prices, plus an Ampaba partner integration (`Ampaba*` models, `Partner*` logs).

Tooling: Pint (`pint.json`) for formatting, Larastan (`phpstan.neon`) for static analysis,
PHPUnit for tests, Telescope locally. Match the conventions of the file you're editing.

## Backend coding patterns

These are the house patterns already used across `gym-backend`. New code follows them —
don't introduce a parallel style. When in doubt, copy the nearest existing feature in the
**same app prefix**.

### App prefix (the primary axis)

Every HTTP concern is namespaced by audience *and* version, and the folder is a
self-contained feature slice:

```
app/Http/<Prefix>/V1/<Feature>/
├── <Feature>Controller.php
├── Requests/     # FormRequests
├── Resources/    # API resources / collections
└── Data/         # slice-local DTOs (only if not shared)
```

| Prefix   | Guard  | Consumer                          | Routes            |
|----------|--------|-----------------------------------|-------------------|
| `Apps`   | `app`  | customer mobile app (Sanctum)     | `routes/apps/v1/` |
| `Cms`    | `cms`  | admin panel (Sanctum + permissions)| `routes/cms/`     |
| `Common` | mixed  | shared/public (auth, region, fcm) | `routes/common/`  |
| `Hook`   | `hook` | partner webhooks (Ampaba)         | `routes/hook/`    |

Never import across prefixes for convenience (an `Apps` resource inside a `Cms`
controller). Shared logic belongs in `app/Services/…`, shared model behaviour in
`app/Supports/Model/…`. Adding an endpoint means: route file under the right prefix →
controller in the matching namespace → Request + Resource in that feature folder.

Routes are grouped by resource with `Route::prefix()->controller()->group()`, one file per
domain, all pulled in by the prefix's `v1.php`. Always add the new file to `v1.php`.

### Controllers

Thin: resolve input, build the query or call a service, return a Resource. No business
rules, no formatting.

- Type-hint the FormRequest for writes; use `$request->integer()/string()/array()/enum()/boolean()`
  for read filters instead of raw `$request->get()`.
- Route-model binding (`show(Request $request, ClassSchedule $classSchedule)`) — don't
  `find()` from an id parameter.
- Declare return types (`ExerciseResource`, `AnonymousResourceCollection`, `JsonResponse`).
- Empty/ad-hoc payloads use the helpers in `app/Supports/helpers.php`: `empty_json()`,
  `raw_json($data, 201)`, `pagination_limit($request->integer('limit'))`.
- Multi-step writes are wrapped in `DB::transaction(...)` (preferred) or explicit
  `beginTransaction/commit/rollBack` with a rethrow.

### Querying

- Always start from `Model::query()`; never `DB::table()` for domain data.
- **CMS list endpoints** use `spatie/laravel-query-builder`:
  `QueryBuilder::for(Model::class)->allowedFilters([...])->allowedSorts([...])->paginate(...)`.
  Whitelist explicitly — no passthrough of arbitrary client filters.
- **App list endpoints** use model scopes (below) plus `paginate(pagination_limit(...))`.
  Lists are always paginated.
- Eager-load what the Resource touches: `with()` in list queries, `loadMissing()`/`load()`
  in `show()`. Constrain relations with closures and select only needed columns
  (`'instructor:id,name'`). Any `$this->relation` in a Resource must be eager-loaded — a
  new N+1 is a review blocker.
- Filtering by an existence check uses `whereExists`/`withWhereHas`/`selectSub`, not a
  `get()` + PHP filter. Aggregates belong in SQL (`withCount`, `selectRaw`).
- Postgres-specific SQL (`ilike`, `jsonb_each_text`) is fine — the app is Postgres-only —
  but pass values as bindings, never string-interpolated.

### Scopes and relations

- Every reusable query predicate is a scope on the model — `scopeFilter`,
  `scopeFilterByIsBooked`, `scopeFilterCategoryIds`, `scopeFilterTab`. Controllers chain
  scopes; they don't rebuild `where` clauses inline. Scopes take typed nullable params,
  guard with `when()`/`blank()`, and return `Builder`.
- Global scopes are attached with the attribute, not `booted()`:
  `#[ScopedBy([FilterBranchScope::class])]`. Branch scoping is cross-cutting — check
  whether a new model needs it before writing manual branch `where`s.
- Relations are declared explicitly with a PHPDoc generic
  (`@return BelongsTo<ClassModel, $this>`) so Larastan can check them. Shared relation
  shapes come from the traits in `app/Supports/Model/Relations/` (`BelongsToBranch`,
  `BelongsToUser`, `Productable`, `HasProductPrice`, …) — reuse the trait instead of
  re-declaring the relation.
- Model responsibilities: `$fillable`, `$casts` (enums, DTO casts, datetimes), relations,
  scopes, and small state helpers. Cross-model orchestration goes in a service.

### DTOs, requests, resources

- **In: FormRequest → DTO.** Validation lives in `rules()`; complex cross-field checks go
  in `after()`; a `payload()` method converts to the DTO:
  `public function payload(): RegisterData { return RegisterData::from($this->validated()); }`
  Services accept the DTO, never `Request` or a loose array.
- **DTOs** are `spatie/laravel-data` classes under `app/Services/<Domain>/Data/`
  (or the slice's `Data/` when only that slice uses them), with typed public properties
  and enum/model types. They're also used for JSON-column casts via
  `app/Supports/Model/Cast/BaseCastWithDto.php` — snapshot columns (`branch_data`,
  `class_data`) cast into DTOs, so read them as objects, not arrays.
- **Out: Resource always.** Never return a model or array directly from a controller.
  `JsonResource` per entity with `/** @mixin Model */`, `<Feature>ListResource` for the
  lighter list shape, `ResourceCollection` when the collection needs extra context passed
  through the constructor. Keys are `snake_case`; the shape is the API contract — changing
  an existing key is a breaking change, so add rather than rename.
- Enums live in `app/Services/<Domain>/Enum(s)/`, extend/behave like
  `App\Services\Auth\Enums\BaseEnum` (`isEqual`/`isNotEqual`), are used in `$casts`, and
  are validated with `Rule::enum(...)` / read with `$request->enum(...)`. No bare strings
  for status/type values.
- Validation rules reused across requests become a `app/Rules/*` rule object or a helper
  (`password_validation_rules()`, `username_validation_rules()`).

### Services, jobs, events

- Business logic lives in `app/Services/<Domain>/<Domain>Service.php`. Services throw
  domain exceptions (`App\Http\Exception\Order\InvalidOrderException` with an enum code
  and a translated message) instead of returning error arrays.
- User-facing strings come from `lang/` via `__('validation.order.profile.incomplete')` —
  no hardcoded copy in services or controllers.
- Side effects (notifications, partner sync, expiry) go through events in `app/Events/…`
  with listeners under the owning service, or queued jobs in `app/Jobs/…`. Don't inline
  outbound HTTP or push notifications in a controller.

### Quality gate before finishing

Run inside the container, and fix what they report:

```bash
docker compose exec backend ./vendor/bin/pint            # format
docker compose exec backend ./vendor/bin/phpstan analyse # larastan
make test
```

`composer analyze:changed` (`utils/analyze-changed.php`) runs static analysis on changed
files only — the fast loop while iterating.

## Commits

Format — Conventional Commits, imperative mood, no trailing period:

```
<type>(<scope>): <subject>

<body, only if it adds something the diff doesn't say>
```

- **Types**: `feat`, `fix`, `refactor`, `perf`, `docs`, `test`, `chore`, `build`, `ci`.
- **Scope** (optional): the area touched — here `compose`, `makefile`, `docs`,
  `gym-backend` (submodule bump); in the backend, the module, e.g. `cms`, `apps`,
  `ampaba`, `orders`.
- **Keep it short.** Subject ≤ 60 chars. Body wrapped at 72, and at most ~3 short lines —
  skip it entirely for small, self-evident changes. Never paste file lists, command
  output, or a rundown of the diff; git already has those.
- Body answers *why*, not *what*. Reference issues/incidents as `Refs #123` on their own
  line at the end.

Practice:

- One logical change per commit. Don't mix a refactor with a fix, or formatting with
  behaviour. If the subject needs "and", it's probably two commits.
- Every commit should build and pass tests on its own.
- Commit submodule content in `gym-backend/` first, then bump the pointer here with a
  separate `chore(gym-backend): bump to <short-sha or summary>`.
- Never commit secrets, `.env` files, or local-only debug code. Check `git status` before
  staging; prefer explicit paths over `git add -A`.
- Only commit when asked, and never push unless asked.

Good:

```
fix(orders): reject schedule booking past class start
feat(cms): add branch filter to membership list
chore(compose): rename docker network to hom-system
```

Avoid: `update code`, `fix bug`, `wip`, or a 200-char subject describing every file.

## Conventions

- Keep this repo thin. Application changes go in the submodule; only environment,
  orchestration, and cross-repo docs belong here.
- `compose.yml` is **local-only**. Never add production credentials, and don't repurpose
  it for staging/deploys — the backend has its own `deploy/` setup for that.
- Adding the frontend submodule: `git submodule add <url> gym-frontend`, then uncomment
  the `frontend` service in `compose.yml` and fix its dev command/port.
