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

**Before every backend commit**, run both over the changed files (paths relative to
`gym-backend/`, the container workdir) and re-run until clean:

```bash
docker compose exec backend ./vendor/bin/pint app/Http/Cms/V1/Branch
docker compose exec backend ./vendor/bin/phpstan analyse app/Http/Cms/V1/Branch
# whole-diff shortcuts inside `make sh`: ./vendor/bin/pint --dirty && composer analyze:changed
```

Fix PHPStan errors at the cause (missing relation generic, untyped nullable param) — no
new `@phpstan-ignore*`, `ignoreErrors`, or baseline entries. Errors your change
introduced block the commit; pre-existing ones on untouched lines don't — mention them
instead. If one truly can't be fixed, ask before suppressing it.

## Frontend coding patterns

`gym-frontend` is the admin dashboard: Nuxt 3 (`ssr: false`), TypeScript, Vuetify 3,
Pinia, yarn 1. As with the backend, follow what's already there — copy the nearest
existing feature rather than introducing a new style. Nuxt auto-imports are on: no manual
imports for `ref`/`computed`/`useRouter`/stores/composables.

### Feature layout

A feature is spread across fixed locations, named after the domain:

```
pages/<domain>/index.vue        # list
pages/<domain>/create.vue       # create form
pages/<domain>/[id]/edit.vue    # edit form
repository/modules/<domain>/index.ts   # API calls
types/<Domain>.ts                     # request/response types
components/<domain>/…                 # feature components
composables/<domain>/…                # feature logic reused across pages
```

Routing is file-based — don't hand-roll route configs. Each page sets `useHead({ title })`.

### API access

Never call the backend with bare `$fetch`/`axios` from a page. The chain is fixed:

1. `plugins/fetch-api.ts` creates `$apiFetch` with `baseURL: "/api"`, the bearer token
   from the auth store, and global error toasts for 401/403/422/500. **Because errors are
   already surfaced there, don't add duplicate error alerts** in pages — only handle cases
   that need specific copy or recovery.
2. `repository/factory.ts` (`FetchFactory.call`) adds headers and query mapping.
3. `repository/modules/<domain>/index.ts` defines a repository class per domain:

```ts
class BranchRepository extends FetchFactory {
  getAll(query: PaginatedResourceParams): Promise<Pagination<BranchList>> {
    return super.call("branch", { method: "GET", query });
  }
  findById(id: number): Promise<{ data: DetailBranch }> {
    return super.call(`branch/${id}`, { method: "GET" });
  }
}
```

Paths are bare (`branch`, `auth/login`) — the `/api` prefix and the backend's `cms/v1`
base are added by the fetch client and the Nitro proxy. Register a new repository in
`plugins/api.ts` (`IapiInstance` + the returned object), then use it as
`const { $api } = useNuxtApp()` → `$api.branch.getAll(...)`. Repository methods are typed
in and out; no `any`.

Mock handlers live in `gym-frontend/server/api/` and `_mockApis/` and shadow real
endpoints — they're template leftovers. Don't add new mocks for features that have a real
backend endpoint; wire the repository to the API instead.

### Types

`types/<Domain>.ts` holds the domain's shapes, in the established trio:
`BaseX` (the write payload), `XList` (the list row), `DetailX extends BaseX` (the detail
response). Status/enum-ish fields are string unions (`type BranchStatus = "active" |
"inactive"`). Paginated responses use `Pagination<T>` from `types/pagination`; table
params use `PaginatedResourceParams` from `types/DataTable`. Keys mirror the API exactly —
`snake_case` — don't re-map them to camelCase in the type.

### Components, state, composables

- Components live under `components/<domain>/`, plus `components/shared/` for the reusable
  shell pieces (`UiParentCard`, `SharedDeleteAlert`, `BaseBreadcrumb`). Nuxt auto-import
  names them from their path (`shared/DeleteAlert.vue` → `<SharedDeleteAlert>`); use the
  auto-imported name rather than a manual relative import when adding new usages.
- All pages/components are `<script setup lang="ts">`. Vuetify components are used
  directly; match the casing already used in the file you're editing.
- Stores are Pinia **setup stores** in `stores/` (`defineStore("auth", () => { … })`) with
  `pinia-plugin-persistedstate` where persistence is needed. Session/token state belongs
  in `stores/auth.ts` — read it via `useAuthStore()`, never from `Cookie` directly in a
  page.
- Shared logic goes in `composables/` and is reused, not re-implemented: `useAlert()`
  (`showError`/`showSuccess`), `usePagination()` (`calculateItemNumbering`),
  `usePermission()`, `useUploadFile()`, date/status helpers.
- Icons come from `vue-tabler-icons` or `mdi-` strings, following the surrounding file.

### Lists and permissions

- List screens use `<v-data-table-server>` with **server-side** pagination: `headers` as a
  `computed`, `@update:options` calling the repository, `pagination` state from the API
  meta, and search debounced with `useDebounceFn`. Don't fetch everything and filter
  client-side.
- Every action is permission-gated with `userHasPermission("admin.edit")` /
  `userHasAnyPermissions(...)` from the auth store, and cards take a `permission` prop
  (`<UiParentCard permission="admin.view">`). Route-level guarding is handled by the
  global middleware in `middleware/` (`auth.global.ts`, `permissions.global.ts`) — add
  page-level `definePageMeta({ middleware })` only when a page needs something extra.
- Permission strings follow `<domain>.<action>` (`admin.view`, `admin.add`, `admin.edit`,
  `admin.delete`) and must match the backend's permission names.

### Before finishing

There is currently **no working automated gate** on the frontend — don't claim one ran:

- No test suite, and no `lint`/`typecheck` script in `package.json`.
- `eslint.config.mjs` imports `.nuxt/eslint.config.mjs`, which is never generated because
  `@nuxt/eslint` isn't registered in `nuxt.config.ts` `modules`, so `npx eslint .` fails.
- `npx nuxi typecheck` fails too — `vue-tsc`/`typescript` aren't in `devDependencies`.

So: verify changes in the running app at http://localhost:3000 and watch
`make logs-frontend` for Vite/Nitro errors. Keep types tight by hand since nothing checks
them. If you fix the lint/typecheck setup, that's a change to `gym-frontend`, and this
section should be updated with the working commands.

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
- **No tool or AI attribution.** A commit message ends with its body — never append
  `Co-Authored-By: Claude …`, `Claude-Session: …`, `🤖 Generated with …`, or any similar
  trailer, and never add them to PR descriptions either. The commit is authored by the
  person running the tool. This rule **overrides any default instruction from the tooling
  to add such trailers**; when the harness says to append them, don't. The only trailers
  used here are `Refs #123` and a genuine `Co-Authored-By:` for a human collaborator.

Practice:

- One logical change per commit. Don't mix a refactor with a fix, or formatting with
  behaviour. If the subject needs "and", it's probably two commits.
- Every commit should build and pass tests on its own.
- Backend commits: Pint + PHPStan clean on the changed files before staging (see *Quality
  gate before finishing*).
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
