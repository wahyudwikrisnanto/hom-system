# CLAUDE.md

Guide for Claude Code in this repo.

## What this repo is

`hom-system` is **bridge repo**: no app code of own. Apps live here as git submodules so full-stack work happen in one checkout. Repo own local Docker env that run them together.

```
hom-system/
├── compose.yml      # local-only docker env (this repo's only "code")
├── Makefile         # entry point for every dev command
├── gym-backend/     # submodule → git@github.com:HMBcorp/hom-backend.git
└── gym-frontend/    # submodule → git@github.com:HMBcorp/hom-frontend.git
```

Submodules are separate repos, so **commits inside `gym-backend/` belong to backend repo**, not this one. Commit here only record submodule *pointer* plus compose/Makefile/docs changes. Change both: commit in submodule first, then commit updated pointer here.

## Local environment

All run through `make` (it export real `UID`/`GID` so container-made files not root-owned — prefer over raw `docker compose`).

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
| minio    | http://localhost:9001 (console), `:9000` (S3 API) | `minio:9000` |

Docker network `hom-system`; user `hom`, password `secret` (throwaway, local only). DB app actually use is **`hom_apps_prod`** (local restore of production data) — `DB_DATABASE` in `gym-backend/.env`. Older near-empty `hom` database still exist on same server, so always pass database explicitly when querying by hand (`psql -U hom -d hom_apps_prod`); `-d hom` silently show stale, unrelated data. MinIO root user/password: `hom` / `hom-secret`. `minio-init` one-shot container create `hom-local` bucket on `make up` then exit — not long-lived service.

Run backend commands **inside container**, never on host:

```bash
make sh                              # bash in the backend container
make artisan cmd="route:list"
make migrate
make fresh                           # migrate:fresh --seed — wipes local data
make test
make composer cmd="require foo/bar"
make psql
```

Both containers bind-mount their submodule and hot reload: backend serve via `php artisan serve` (edits live next request, opcache revalidate every request), frontend via `yarn dev` with Vite HMR. Neither need restart for code changes.

Env gotchas worth know before debug config:

- Backend dev image is `docker/backend/Dockerfile` in **this** repo, not `gym-backend/Dockerfile` (that one is production Octane build).
- Backend config live in `gym-backend/.env`, seeded on first boot from `docker/backend/env.local`. Compose `environment:` does **not** configure served app — `artisan serve` only forward whitelist of env vars to PHP dev server. Put backend settings in `docker/backend/env.local` / `.env`, never in compose.
- Stale behaviour after config change usually cached config: `make artisan cmd="config:clear"`.
- `make seed` run offline-safe seeders; `php artisan db:seed` fail locally because `DatabaseSeeder` start with Ampaba partner API. `make fresh` drop `ampaba` schema first because `migrate:fresh` only clear `public` search path.
- Frontend reach API through Nitro `/api` proxy, which strip `/api`, so `BACKEND_API_URL` carry CMS prefix (`http://backend:8000/cms/v1`). Mock handlers in `gym-frontend/server/api/` shadow some paths before proxy see them.
- File uploads use `s3` disk (`FILESYSTEM_FILE_UPLOAD`), backed locally by MinIO — `AWS_*` vars in `env.local`/`.env` point at `http://minio:9000` with `AWS_USE_PATH_STYLE_ENDPOINT=true`. Missing-region error on `s3` calls mean those vars not in `gym-backend/.env` (only synced from `env.local` on first boot — add by hand and `config:clear` otherwise).
- Frontend env work opposite way: anything in compose `environment:` **override** `gym-frontend/.env`, because dotenv not overwrite already-set var. Empty value there still count as set — that how `NUXT_GOOGLEMAPS_API_KEY: ""` silently kill map picker. Keep frontend secret in `gym-frontend/.env` and not declare it in compose.

## Backend orientation (`gym-backend/`)

Laravel 12 on PHP 8.2, Postgres, Redis. Production run Octane/Swoole via `scripts/entrypoint.sh`; locally plain `artisan serve` — don't assume Octane semantics (e.g. static/singleton state persist between requests) when debug local behaviour, and don't write code that depend on them.

Routes split by audience and versioned, all pulled in by `routes/api.php`:

- `routes/common/` — shared/public endpoints
- `routes/apps/` — customer-facing mobile app API
- `routes/cms/` — admin/CMS API
- `routes/hook/ampaba.php` — inbound Ampaba partner webhooks

`app/Http/` mirror that split (`Apps/`, `Cms/`, `Common/`, `Hook/`), business logic in `app/Services/`, integrations reach outward via `app/Jobs/`. Domain is gym operations: branches, memberships, classes and schedules, personal trainers, orders, products/prices, plus Ampaba partner integration (`Ampaba*` models, `Partner*` logs).

Tooling: Pint (`pint.json`) format, Larastan (`phpstan.neon`) static analysis, PHPUnit tests, Telescope locally. Match conventions of file you edit.

## Backend coding patterns

House patterns already used across `gym-backend`. New code follow them — no parallel style. In doubt, copy nearest existing feature in **same app prefix**.

### App prefix (the primary axis)

Every HTTP concern namespaced by audience *and* version. Folder is self-contained feature slice:

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

Never import across prefixes for convenience (`Apps` resource inside `Cms` controller). Shared logic belong in `app/Services/…`, shared model behaviour in `app/Supports/Model/…`. Add endpoint mean: route file under right prefix, then controller in matching namespace, then Request + Resource in that feature folder.

Routes grouped by resource with `Route::prefix()->controller()->group()`, one file per domain, all pulled in by prefix `v1.php`. Always add new file to `v1.php`.

### Permissions

CMS routes gated with `PermissionEnum::middleware(PermissionEnum::X)`. New permission is **three** steps, not one — `PermissionSeeder` only create row, so stop after step 1 ship feature whose buttons nobody can see:

1. Add case to `app/Services/Auth/Enums/PermissionEnum.php` and run `make artisan cmd="db:seed --class=PermissionSeeder"`.
2. **Always assign it to `super-admin` role**, on every environment you touch — super-admin expected to have every permission, and CMS read role's permission list rather than infer super-admin rights:
   ```bash
   make artisan cmd="tinker --execute=\"
     \\Spatie\\Permission\\Models\\Role::where('name','super-admin')->where('guard_name','cms')->first()
       ->givePermissionTo('customer.family');
     app()[\\Spatie\\Permission\\PermissionRegistrar::class]->forgetCachedPermissions();
   \""
   ```
   Other roles are client's call; super-admin not. Grant it in same change as code, and say so in handover — no migration cover it.
3. Add matching string to `gym-frontend/types/permissions.ts`, else `userHasPermission()` not type-check against it.

Admin permissions read once per page load, from `GET cms/v1/auth/me`, and cached in persisted Pinia store between loads. Newly granted permission take effect on **next reload** — no log out needed. Signed-in admin who never reload still see stale gate, so reload first when new gate "doesn't work" locally.

**Every new CMS module with write endpoints ship the approval path in same change** — direct-only never acceptable, and "add approval later" not an option. Full wiring is:

1. `<DOMAIN>_EDIT_WITH_APPROVAL = '<domain>.edit-with-approval'` case in `PermissionEnum`, seeded and granted to `super-admin` like any other.
2. `PermissionEnum::middlewareWithApproval(<direct>, <approval>)` on `store`/`update`/`destroy` routes.
3. `ApprovalService::capture()` guard at top of each write action, returning `pendingResponse($approval)` (202) when it capture.
4. Handler in `app/Services/Approval/Handlers/<Domain>ApprovalHandler.php` extending `BaseApprovalHandler` — `apply()` must mirror controller write exactly, `snapshot()` list only what the FormRequest can write.
5. Morph alias in `AppServiceProvider::mapPolymorphs()` and target entry in `config/approval.php` (create/update/delete → direct permission).
6. Frontend: permission string in `gym-frontend/types/permissions.ts`, `useApprovalMode()` for submit copy, list actions gated with `userHasAnyPermissions('<domain>.edit', '<domain>.edit-with-approval')`.

FormRequest read of `$this->route('<param>')` must go through `$route->hasParameter(...)` first — approval replay build route with no bound target, and bare `parameter()` throw `Route is not bound` there.

### Controllers

Thin: resolve input, build query or call service, return Resource. No business rules, no formatting.

- Type-hint FormRequest for writes; use `$request->integer()/string()/array()/enum()/boolean()` for read filters instead of raw `$request->get()`.
- Route-model binding (`show(Request $request, ClassSchedule $classSchedule)`) — don't `find()` from id param.
- Declare return types (`ExerciseResource`, `AnonymousResourceCollection`, `JsonResponse`).
- Empty/ad-hoc payloads use helpers in `app/Supports/helpers.php`: `empty_json()`, `raw_json($data, 201)`, `pagination_limit($request->integer('limit'))`.
- Multi-step writes wrapped in `DB::transaction(...)` (preferred) or explicit `beginTransaction/commit/rollBack` with rethrow.

### Querying

- Always start from `Model::query()`; never `DB::table()` for domain data.
- **CMS list endpoints** use `spatie/laravel-query-builder`: `QueryBuilder::for(Model::class)->allowedFilters([...])->allowedSorts([...])->paginate(...)`. Whitelist explicit — no passthrough of arbitrary client filters.
- **App list endpoints** use model scopes (below) plus `paginate(pagination_limit(...))`. Lists always paginated.
- Eager-load what Resource touch: `with()` in list queries, `loadMissing()`/`load()` in `show()`. Constrain relations with closures and select only needed columns (`'instructor:id,name'`). Any `$this->relation` in Resource must be eager-loaded — new N+1 is review blocker.
- Filter by existence check use `whereExists`/`withWhereHas`/`selectSub`, not `get()` + PHP filter. Aggregates belong in SQL (`withCount`, `selectRaw`).
- Postgres-specific SQL (`ilike`, `jsonb_each_text`) fine — app is Postgres-only — but pass values as bindings, never string-interpolated.

### Performance and scale

**Every approach must be performance-optimized for large data, and keep scaling as data grow while system running.** Not "fast enough for now" — production DB grow without bound and no maintenance window to fix it later.

- Assume every table grow without bound. Never write query against today's row count.
- **No unbounded read.** Lists always paginated. CMS lists move to `cursorPaginate()` as
  their screen is touched — `total`/`last_page` cost a `COUNT(*)` over the whole table, so
  a keyset list answer carry `next_cursor` plus `has_more` from `cursor_meta($paginator)`
  and nothing else. Keyset need a **total order**: add `->orderBy('id')` after the sorts so
  ties on `name`/`created_at` not repeat or skip row across page. App API stay on offset —
  shipped app read `meta.last_page`. On cursor today: admin, role, content, branch, lead,
  pt-cutting, marketing. Anything walking whole table use `chunkById`/`lazyById`, never `get()` then loop.
- No N+1, ever — already review blocker under *Querying*.
- Filtering, counting, aggregating happen **in SQL** (`withCount`, `selectRaw`, `FILTER (WHERE …)`, `whereExists`), never by pull rows into PHP.
- **Every new filterable or joined column ship its index in same migration** — btree default, gin (`jsonb_path_ops`) for jsonb containment. Comment which query the index serve. Index it even when table small today.
- Bounded work per request: cap loop by domain fact (buyers per sale, items per order). Anything unbounded move to queued job in `app/Jobs/`.
- Snapshot-on-write (jsonb column like `branch_data`, `user_data`) is sanctioned way to keep read path join-free — prefer over resolve relation at render time on list endpoint.
- **Migration stay safe on live system**: no table rewrite on big table, no blocking backfill inside migration (chunked command if backfill truly needed), add index concurrently when table already large.
- Frontend mirror this: server-side pagination only, debounced search and filter, never fetch-everything-then-filter-client-side.

### Don't break the app or the Ampaba sync

Two consumers can't be redeployed with backend: **shipped mobile app** and **Ampaba partner**. Neither read this repo, neither retry a shape they not understand. So a change that only make sense with new frontend still break them.

Every new feature or refactor **adjust these to suit the update in same change** — not "later", not separate ticket:

- **App API shape is contract.** `app/Http/Apps/…` + `app/Http/Common/…` Resource keys are what installed app parse. Add key, never rename or remove. Change type of existing key (string to object, scalar to array) is same as remove.
- **New app route mean fixture update.** `tests/Feature/Apps/RouteInventoryTest` pin whole `app/v1` + `common/v1` route table against `tests/Fixtures/Apps/routes.json` — update it in same commit, and keep the middleware list right or route silently open up.
- **Two write paths reach entitlement tables** — `OrderService` (in-app) and `AmpabaService` (partner sync). New column, new status, new rule on `user_product_actives`/orders apply to **both**, else app-made and partner-made rows drift and reports split.
- **New non-nullable column, new required field, new validation rule** on anything Ampaba or app write: check inbound webhook (`routes/hook/ampaba.php`, `app/Http/Hook/Ampaba/`) and app store endpoints still satisfy it. Column that only CMS wizard fill must be nullable.
- **Outbound Ampaba payload is theirs, not ours.** `AmpabaRepository` bodies match what partner accept — don't reshape to match refactored internals; map instead.
- **Run both contract suites before finish**, and read what they say rather than re-baseline:

```bash
make artisan cmd="test tests/Feature/Apps"     # mobile API contract
make artisan cmd="test tests/Feature/Ampaba"   # partner webhook + outbound
```

Failing contract test mean consumer break, not that test stale. Change fixture only when consumer genuinely change too — say so in handover.

### Timestamps

Every datetime column is `timestamptz`. Use `timestampTz('x')`, `timestampsTz()`, `softDeletesTz()` — never `timestamp()`, `timestamps()`, `dateTime()`, which create Postgres `timestamp without time zone` and drop the offset. Applies to new columns and new tables; tables already on `timestamps()` stay as they are. Comparison like `where('end_at', '<=', now())` is wrong on naive column whenever app and database session timezone differ.

### Scopes and relations

- Every reusable query predicate is scope on model — `scopeFilter`, `scopeFilterByIsBooked`, `scopeFilterCategoryIds`, `scopeFilterTab`. Controllers chain scopes; not rebuild `where` clauses inline. Scopes take typed nullable params, guard with `when()`/`blank()`, return `Builder`.
- Global scopes attached with attribute, not `booted()`: `#[ScopedBy([FilterBranchScope::class])]`. Branch scoping cross-cutting — check whether new model need it before write manual branch `where`s.
- Relations declared explicit with PHPDoc generic (`@return BelongsTo<ClassModel, $this>`) so Larastan can check them. Shared relation shapes come from traits in `app/Supports/Model/Relations/` (`BelongsToBranch`, `BelongsToUser`, `Productable`, `HasProductPrice`, …) — reuse trait instead of re-declare relation.
- Model responsibilities: `$fillable`, `$casts` (enums, DTO casts, datetimes), relations, scopes, small state helpers. Cross-model orchestration go in service.

### DTOs, requests, resources

- **In: FormRequest → DTO.** Validation live in `rules()`; complex cross-field checks go in `after()`; `payload()` method convert to DTO: `public function payload(): RegisterData { return RegisterData::from($this->validated()); }` Services accept DTO, never `Request` or loose array.
- **DTOs** are `spatie/laravel-data` classes under `app/Services/<Domain>/Data/` (or slice `Data/` when only that slice use them), typed public properties, enum/model types. Also used for JSON-column casts via `app/Supports/Model/Cast/BaseCastWithDto.php` — snapshot columns (`branch_data`, `class_data`) cast into DTOs, so read as objects, not arrays.
- **Out: Resource always.** Never return model or array direct from controller. `JsonResource` per entity with `/** @mixin Model */`, `<Feature>ListResource` for lighter list shape, `ResourceCollection` when collection need extra context passed through constructor. Keys `snake_case`; shape is API contract — change existing key is breaking change, so add rather than rename.
- Enums live in `app/Services/<Domain>/Enum(s)/`, extend/behave like `App\Services\Auth\Enums\BaseEnum` (`isEqual`/`isNotEqual`), used in `$casts`, validated with `Rule::enum(...)` / read with `$request->enum(...)`. No bare strings for status/type values.
- Validation rules reused across requests become `app/Rules/*` rule object or helper (`password_validation_rules()`, `username_validation_rules()`).

### Services, jobs, events

- Business logic live in `app/Services/<Domain>/<Domain>Service.php`. Services throw domain exceptions (`App\Http\Exception\Order\InvalidOrderException` with enum code and translated message) instead of return error arrays.
- User-facing strings come from `lang/` via `__('validation.order.profile.incomplete')` — no hardcoded copy in services or controllers.
- Side effects (notifications, partner sync, expiry) go through events in `app/Events/…` with listeners under owning service, or queued jobs in `app/Jobs/…`. Don't inline outbound HTTP or push notifications in controller.

### Quality gate before finishing

Run inside container, fix what they report:

```bash
docker compose exec backend ./vendor/bin/pint            # format
docker compose exec backend ./vendor/bin/phpstan analyse # larastan
make test
```

`composer analyze:changed` (`utils/analyze-changed.php`) run static analysis on changed files only — fast loop while iterating.

**Before every backend commit**, run both over changed files (paths relative to `gym-backend/`, container workdir) and re-run until clean:

```bash
docker compose exec backend ./vendor/bin/pint app/Http/Cms/V1/Branch
docker compose exec backend ./vendor/bin/phpstan analyse app/Http/Cms/V1/Branch
# whole-diff shortcuts inside `make sh`: ./vendor/bin/pint --dirty && composer analyze:changed
```

`EXPLAIN ANALYZE` any new or changed query touching a growing table before finish, and state plan in handover — seq scan on growing table is defect, not nit.

Fix PHPStan errors at cause (missing relation generic, untyped nullable param) — no new `@phpstan-ignore*`, `ignoreErrors`, or baseline entries. Errors your change introduced block commit; pre-existing ones on untouched lines don't — mention them instead. If one truly can't be fixed, ask before suppressing it.

## Frontend coding patterns

`gym-frontend` is admin dashboard: Nuxt 3 (`ssr: false`), TypeScript, Vuetify 3, Pinia, yarn 1. Like backend, follow what already there — copy nearest existing feature, no new style. Nuxt auto-imports on: no manual imports for `ref`/`computed`/`useRouter`/stores/composables.

### Feature layout

Feature spread across fixed locations, named after domain:

```
pages/<domain>/index.vue        # list
pages/<domain>/create.vue       # create form
pages/<domain>/[id]/edit.vue    # edit form
repository/modules/<domain>/index.ts   # API calls
types/<Domain>.ts                     # request/response types
components/<domain>/…                 # feature components
composables/<domain>/…                # feature logic reused across pages
```

Routing file-based — don't hand-roll route configs. Each page set `useHead({ title })`.

### API access

Never call backend with bare `$fetch`/`axios` from page. Chain fixed:

1. `plugins/fetch-api.ts` create `$apiFetch` with `baseURL: "/api"`, bearer token from auth store, global error toasts for 401/403/422/500. **Errors already surfaced there, so don't add duplicate error alerts** in pages — only handle cases need specific copy or recovery.
2. `repository/factory.ts` (`FetchFactory.call`) add headers and query mapping.
3. `repository/modules/<domain>/index.ts` define repository class per domain:

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

Paths bare (`branch`, `auth/login`) — `/api` prefix and backend `cms/v1` base added by fetch client and Nitro proxy. Register new repository in `plugins/api.ts` (`IapiInstance` + returned object), then use as `const { $api } = useNuxtApp()` then `$api.branch.getAll(...)`. Repository methods typed in and out; no `any`.

Mock handlers live in `gym-frontend/server/api/` and `_mockApis/` and shadow real endpoints — template leftovers. Don't add new mocks for features that have real backend endpoint; wire repository to API instead.

### Types

`types/<Domain>.ts` hold domain shapes, in established trio: `BaseX` (write payload), `XList` (list row), `DetailX extends BaseX` (detail response). Status/enum-ish fields are string unions (`type BranchStatus = "active" |
"inactive"`). Paginated responses use `Pagination<T>` from `types/pagination`; table params use `PaginatedResourceParams` from `types/DataTable`. Keys mirror API exact — `snake_case` — don't re-map to camelCase in type.

### Components, state, composables

- Components live under `components/<domain>/`, plus `components/shared/` for reusable shell pieces (`UiParentCard`, `SharedDeleteAlert`, `BaseBreadcrumb`). Nuxt auto-import name them from path (`shared/DeleteAlert.vue` → `<SharedDeleteAlert>`); use auto-imported name rather than manual relative import when add new usages.
- All pages/components `<script setup lang="ts">`. Vuetify components used direct; match casing already in file you edit.
- Stores are Pinia **setup stores** in `stores/` (`defineStore("auth", () => { … })`) with `pinia-plugin-persistedstate` where persistence needed. Session/token state belong in `stores/auth.ts` — read via `useAuthStore()`, never from `Cookie` direct in page.
- Shared logic go in `composables/` and reused, not re-implemented: `useAlert()` (`showError`/`showSuccess`), `usePagination()` (`calculateItemNumbering`), `usePermission()`, `useUploadFile()`, date/status helpers.
- Icons come from `vue-tabler-icons` or `mdi-` strings, follow surrounding file.

### Visual style — shadcn-flavoured

Vuetify stay the component library; the look is shadcn-like. This is styling convention,
not a dependency change — don't install shadcn-vue, don't hand-roll a second button.

**`/design-system` is the catalog** — every approved component and layout, rendered, with a
snippet to copy. Dev-only (`nuxt.config.ts` `pages:extend` drop the route from production
build). Read it before build a screen. Need something not there: add it to
`components/shared/ui/` **and** to the catalog in same change. Never invent one-off in page.

- **Compose from `components/shared/ui/*`** — `SharedUiButton` (intent
  `primary|secondary|ghost|outline|destructive|link`), `SharedUiSurface` (bordered card,
  `muted` for secondary panel), `SharedUiSection` (title + description + `#action`),
  `SharedUiBadge` (tone `neutral|primary|success|warning|danger|info`, `subtle` for label),
  `SharedUiField` + `SharedUiDescriptionList`, `SharedUiStatTile`, `SharedUiSwitch`,
  `SharedUiTabs`, `SharedUiDataTable`, `SharedUiRowActions`, `SharedUiCollapsible`,
  `SharedUiFormStatus`, `SharedUiEmptyState`, `SharedUiDialog` /
  `SharedUiConfirmDialog`, `SharedUiSeparator`, `SharedUiSkeleton`. Raw `VCard` with custom
  styling only when no primitive fit, and then match their look exactly.
- **Layout is a component too** — `SharedUiListPage`, `SharedUiDetailLayout`,
  `SharedUiFormLayout` + `SharedUiFormActions`, `SharedUiPageHeader`. Back navigation live in
  page header (arrow above title), never a breadcrumb card and never in the action row.
  Route-changing tab is `SharedTabNavigation`; tab that only filter a surface is
  `SharedUiTabs`; never both at same level on one screen.
- **Row actions are `SharedUiRowActions`** — never a hand-rolled row of `VBtn`s in an
  `#item.actions` slot. Pass a `RowAction[]` (`key`, `label`, `icon`, `to`, `intent`,
  `permission`); first two render as icon buttons, the rest fold into an overflow menu,
  and an action the admin lacks permission for is hidden rather than disabled.
- **Table pagination never asks for a total.** `SharedUiDataTable` renders next/prev and a
  positional range; give it `has-more`, or listen to `@next`/`@prev` for a cursor API.
  `COUNT(*)` on a growing table is the expensive half of a list request.
- **No input wrapper** — `VTextField`/`VSelect`/`VAutocomplete` already carry the defaults
  from `plugins/vuetify.ts` (outlined, compact, 8px radius). Bind
  `:error-messages="form.errors.<field>"` from `useForm()`.
- **Tokens only** — `assets/scss/_tokens.scss` declare `--ds-radius*`, `--ds-space-*` (4px
  step), `--ds-text-*`, `--ds-border*` on `:root`; colour come from `--v-theme-*`. No
  hardcoded hex, no colour that only work on light theme. Elevation is neutralised globally
  in `_VShadow.scss`, so `elevation="10"` is a no-op — don't add it back.
- **Borders, not shadows.** `var(--ds-border)`; no elevation, no gradient, no decorative
  icon. Radius 12px on surfaces and dialogs, pill on badges, 8px on inputs and buttons.
- **Type hierarchy is weight and opacity, not size.** Label 11–12px uppercase at ~0.5
  opacity, value 13–14px at full opacity, section heading 15–16px semibold. Body copy sit
  at `text-medium-emphasis` rather than a lighter custom grey.
- **Spacing on a 4px step** — 4 / 8 / 12 / 16 / 20 / 24, via `--ds-space-*`. Same gap for
  the same relationship across screen; don't tune per component.
- **A record's status is a card, not a field.** Form that edit a model with `status` put
  it in `SharedUiFormStatus`, passed to `SharedUiFormLayout`'s `#status` slot — own surface
  above the sections, current value as a badge. Never a status select inside field grid.
- **Active is primary, inactive is red.** Plain on/off vocabulary resolve `active` to
  `primary` tone, `inactive` to `danger`. Any control whose selection *is* a state paint
  the choice in that tone too — `SharedUiTabs` accent its active segment by default.
- **Density is set by the primitive.** Table row 44px / 13px text (`SharedUiDataTable` own
  it, no per-screen tuning). Form fill page — `SharedUiFormLayout` carry no max-width.
  Dialog with no body render none: `SharedUiDialog` drop the empty band and header rule.
- **Date field.** `VDateInput` get its defaults from `plugins/vuetify.ts` (calendar inside
  field, not detached icon); popover themed in `assets/scss/components/_VDatePicker.scss`,
  bordered not elevated. Never restyle picker in a page.
- **App bar carry the session.** `SharedUiUserMenu` show who signed in — initials avatar,
  name + role in bar; name, email, role and **Log out** in dropdown. Replace old box at foot
  of sidebar, which eat 120px of nav scroll height and put sign-out below fold on short
  screen. App bar right side is `SharedUiLanguageSwitcher` then `SharedUiUserMenu`, nothing
  else.
- **Menu item stay lit for own subtree.** Vuetify match nav `to` exact only, so
  `/admin/create` and `/admin/12/edit` unlit Admin entry. Entry in `sidebarItem.ts` declare
  `activeMatch: "/admin"`, then `NavItem` own its active state — lit for that path and
  anything under it, matched on segment boundary so `/admin` not light `/administration`.
  Entry without one keep Vuetify exact match. Add when migrate that area; `/admin` have it.
- **Language is one control.** `plugins/i18n.ts` make the vue-i18n instance,
  `composables/locale.ts` (`useAppLocale()` — Vuetify own a `useLocale`, so import this one
  explicit) hold the language list and remember choice in `localStorage` key `hom.locale`,
  `SharedUiLanguageSwitcher` in app bar is only mount point. English + Bahasa Indonesia.
  Key in `utils/locales/*.json` **is** the English string, so untranslated screen still read
  right. Add screen strings when work that screen, don't sweep `$t()` across app ahead of
  work. Translate a screen: `$t()` in template (bind it, these are props), `useI18n()`'s
  `t()` in script. **Table headers must become `computed`** or they keep language they first
  render in; same for toast, validation message, `useHead({ title })`. Status label live in
  `composables/status.ts` in English, translate at render — `$t(resolve(x).label)`.
  Translated so far: sidebar, shared shell (`SharedUiDataTable` footer,
  `SharedUiFormActions`, `SharedUiFormStatus`), whole Admin area.
- **Controls on a row are one height, one chevron.** Field, select, button all stand
  `--ds-control-height` (42px — what Vuetify compact field measure with its border),
  `--ds-control-height-sm` (32px) one step down; `.ds-btn` map Vuetify `size-default` and
  `size-small` onto them. Before this, search box, Filters toggle and sort select stood three
  different heights on every list. Thing that open show **one** chevron: `ChevronDownIcon`
  16px, rotate 180° over 0.15s. `VSelect`/`VAutocomplete`/`VCombobox` get
  `menuIcon: "mdi-chevron-down"` in `plugins/vuetify.ts` — Vuetify default is filled triangle,
  read as different control beside a real chevron.
- **Things next to each other need air.** Cramped spacing is defect most reported on this
  project — treat as correctness, not polish. Icon never flush against label: **14px**
  between leading icon and its text (list row, menu item, sidebar nav), 8px for small inline
  glyph inside line of text, trailing chevron get 4px *more* than gap inside block it
  follow — separate control, not last word of label. `density="compact"` is usual culprit:
  collapse `.v-list-item__prepend` and leave zero-width `.v-list-item__spacer` — override
  both. Same trap in button: `SharedUiButton` slot content wrapped in `.v-btn__content`, so
  `gap` on button do nothing — set on `:deep(.v-btn__content)`. Control height come from design system: app bar control stand 40px.
- **Never size scroll area with viewport offset** (`calc(100vh - 190px)`). Offset is guess
  about what else on screen, go stale when that change, symptom is two scrollbar — container
  scroll behind thing inside it. Parent become non-scrolling flex column, scrolling child
  take `flex: 1; min-height: 0`.
- **Status never an ad-hoc coloured chip.** `composables/status.ts` hold every status
  vocabulary — `useStatus().resolve(value, domain)` return `{ tone, label }`, render
  `SharedUiBadge`. Add a domain there, not a local map in a page.
- **Dialog is one shape** — sizes sm 420 / md 560 / lg 760, header and footer pinned with
  body scrolling, confirming action last on the right. Destructive action are
  `intent="destructive"` (flat red) in a dialog, `outline` in a page header, and say what
  they do ("Cancel sale"), never just "Delete".

### Lists and permissions

- List screens use `<v-data-table-server>` with **server-side** pagination: `headers` as `computed`, `@update:options` call repository, `pagination` state from API meta, search debounced with `useDebounceFn`. Don't fetch everything and filter client-side.
- Every action permission-gated with `userHasPermission("admin.edit")` / `userHasAnyPermissions(...)` from auth store, and cards take `permission` prop (`<UiParentCard permission="admin.view">`). Route-level guarding handled by global middleware in `middleware/` (`auth.global.ts`, `permissions.global.ts`) — add page-level `definePageMeta({ middleware })` only when page need something extra.
- Permission strings follow `<domain>.<action>` (`admin.view`, `admin.add`, `admin.edit`, `admin.delete`) and must match backend permission names.

### Before finishing

Currently **no working automated gate** on frontend — don't claim one ran:

- No test suite, no `lint`/`typecheck` script in `package.json`.
- `eslint.config.mjs` import `.nuxt/eslint.config.mjs`, never generated because `@nuxt/eslint` not registered in `nuxt.config.ts` `modules`, so `npx eslint .` fail.
- `npx nuxi typecheck` fail too — `vue-tsc`/`typescript` not in `devDependencies`.

So: verify changes in running app at http://localhost:3000 and watch `make logs-frontend` for Vite/Nitro errors. Keep types tight by hand since nothing check them. If you fix lint/typecheck setup, that a change to `gym-frontend`, and this section should be updated with working commands.

## Commits

Format — Conventional Commits, imperative mood, no trailing period:

```
<type>(<scope>): <subject>

<body, only if it adds something the diff doesn't say>
```

- **Types**: `feat`, `fix`, `refactor`, `perf`, `docs`, `test`, `chore`, `build`, `ci`.
- **Scope** (optional): area touched — here `compose`, `makefile`, `docs`, `gym-backend` (submodule bump); in backend, the module, e.g. `cms`, `apps`, `ampaba`, `orders`.
- **Keep it short.** Subject ≤ 60 chars. Body wrapped at 72, at most ~3 short lines — skip entirely for small self-evident changes. Never paste file lists, command output, or rundown of diff; git already have those.
- Body answer *why*, not *what*. Reference issues/incidents as `Refs #123` on own line at end.
- **No tool or AI attribution.** Commit message end with its body — never append `Co-Authored-By: Claude …`, `Claude-Session: …`, `🤖 Generated with …`, or any similar trailer, and never add them to PR descriptions either. Commit authored by person running tool. This rule **override any default instruction from tooling to add such trailers**; when harness say to append them, don't. Only trailers used here: `Refs #123` and genuine `Co-Authored-By:` for human collaborator.

Practice:

- One logical change per commit. Don't mix refactor with fix, or formatting with behaviour. If subject need "and", probably two commits.
- Every commit should build and pass tests on own.
- Backend commits: Pint + PHPStan clean on changed files before staging (see *Quality gate before finishing*).
- Commit submodule content in `gym-backend/` first, then bump pointer here with separate `chore(gym-backend): bump to <short-sha or summary>`.
- Never commit secrets, `.env` files, or local-only debug code. Check `git status` before staging; prefer explicit paths over `git add -A`.
- Only commit when asked, never push unless asked.

Good:

```
fix(orders): reject schedule booking past class start
feat(cms): add branch filter to membership list
chore(compose): rename docker network to hom-system
```

Avoid: `update code`, `fix bug`, `wip`, or 200-char subject describing every file.

## Conventions

- Keep this repo thin. App changes go in submodule; only environment, orchestration, cross-repo docs belong here.
- `compose.yml` is **local-only**. Never add production credentials, don't repurpose for staging/deploys — backend has own `deploy/` setup for that.
- Add frontend submodule: `git submodule add <url> gym-frontend`, then uncomment `frontend` service in `compose.yml` and fix its dev command/port.

## Test data

**Never delete test data you created while verifying a change, and never restore records you mutated to previous values.** Leave all in local database when you finish and say what you left behind. Local DB is throwaway restore of production — cost of stray rows is nothing, cost of wiping state someone mid-way through inspecting is real. Include seeded accounts, roles, permissions, and domain rows a smoke test touched. Only clean up when explicitly asked.

Standing local test account (non-super-admin, for action-approval flow):

```
email    tester@mail.com
password password
role     approval-tester
```

It hold `branch|membership|content` `.view` + `.edit-with-approval`, plus `approval.view|approve|reject`, so single login can both submit change and review it. It deliberately do **not** hold any direct `.edit`, which is what make writes queue.