# Plan: move a running package's start into the future, with admin-chosen add-on replay

## Context

Moving a **running** membership/PT package's start to a **later** day makes it `pending` again. Its term is
then rebuilt at activation by `UserProductActiveActivationService::term()`, which only replays
Extension add-ons applied *while it waited* (`extensionsWhilePending()` filters `data->before->status = pending`).
Extensions applied while it ran would silently vanish, so `EntitlementStartService::refusal()` blocks the move
(`extended` message, via `extendedWhileRunning()`). Result: admin sees a red block and cannot reschedule.

Goal: allow the move. On a future day the admin sees every non-reverted Extension add-on, pre-ticked
(recommended), and can untick any. Unticked add-ons are **excluded, not destroyed**: kept as a reversible
ledger so they can be re-applied, reverted or re-bought later. Scope = start-date move only
(not quota/freeze add-ons, not a detail-page reinstate UI). Existing locks (check-in, PT cutting,
`used_balances`, transfer/freeze/upgrade history, status) are untouched (`lock()`).

Also in the same change: the English-only refusal text (CMS sends no locale) is already routed through `$t()`
in the frontend (done earlier this session: `EntitlementStartPackage.vue`, `EntitlementStartDialog.vue`,
`utils/locales/{en,id}.json`) — new strings below follow the same route.

## Design

**Ledger on the activity trail** (`app/Services/UserProductActivity/Enum/Action.php`):
- add `ADD_ON_EXCLUDED = 'add_on.excluded'` and `ADD_ON_REINSTATED = 'add_on.reinstated'`;
  `data`: `order_item_id`, `type`, `admin_id`, `approval_id`, optional `note`.
- State of an add-on on a package = latest of {EXCLUDED, REINSTATED} per `order_item_id`; EXCLUDED = "paid, not applied".
- Never write ADD_ON_REVERTED for an exclusion (that triggers reward/refund semantics elsewhere).
- Neither action is in `Action::memberFeed()` → mobile activity tab unaffected (app contract safe).

**Replay set** (`UserProductActiveActivationService`):
- `extensionsWhilePending()` → every Extension `ADD_ON_APPLIED` not reverted and not currently excluded
  (drop the `before.status = pending` filter). Add helper `excludedAddOnItemIds()` next to `revertedAddOnItemIds()`.
- Add `extensionCandidates()` (all non-reverted, with their excluded flag) for the preview/dialog.
- `term()`, `expectedExpiry()`, receipt/TnC/transaction resource/app membership resource all go through `term()` → stay consistent.

**Start service** (`app/Services/UserProductActive/EntitlementStartService.php`):
- `refusal()`: remove the `extended` branch and `extendedWhileRunning()`.
- `previewMove()`/`describe()`: for the own package on a future day add `replayable_extensions[]`
  (`order_item_id`, label, size, applied_at, `recommended`, `excluded`). `expectedExpiry()` must take the chosen set.
- `change()`/`changeTogether()`: accept `replayExcludedIds`; inside the existing `DB::transaction`, write
  EXCLUDED events for newly unticked and REINSTATED for previously-excluded-now-ticked, then `START_CHANGED`
  (include `excluded_item_ids` in its `data` for the reviewer/history).
- `restart()` (move to today/earlier, package stays running): `term()` now includes running-applied extensions in
  both `$previous` and the new term, so the `carried` diff cancels them — behaviour unchanged; add a test to prove it.

**Request / approval path** (extension of the existing start-change approval, no new permission):
- `ChangeEntitlementStartRequest` + `PreviewEntitlementStartRequest`: new `exclude_ids` (`sometimes|array|max:20`, ints, distinct);
  validate each id is a replay candidate of this package (use `$route->hasParameter(...)` — replay has no bound route).
- Capture: key must ride in the payload (`$request->merge([...])` before `ApprovalService::capture()` + `extraPayloadKeys()`
  in the start handler/config) — mirror how `with_ids` is carried.
- `EntitlementStartApprovalHandler::apply()` passes `exclude_ids` to `changeTogether()`, re-validating against current state;
  `impact()` pending/applied output shows dropped add-ons; `snapshot()` only lists what the request can write (unchanged keys + nothing new on the target).
- Controllers: `CustomerMembershipController` / `CustomerPersonalTrainerController` (startPreview/startChange) thread `exclude_ids` through.

**Revert safety** (`app/Services/Transaction/BuddyReferralRemovalService.php`):
- `extensionEffect()` already returns `drop_pending_extension` (no date change) for a pending target — safe.
- Guard the running case: if the add-on's latest ledger state is EXCLUDED, write ADD_ON_REVERTED without shortening `expires_at`
  (it was never applied). Without this, reverting an excluded add-on after activation would remove days that were never added.

**Frontend** (`gym-frontend`):
- `types/` start types: add `replayable_extensions`, `exclude_ids` on the payload; repositories `customer-membership` / `customer-personal-trainer`
  `startPreview`/`startChange` send `exclude_ids`.
- `components/customer/EntitlementStartDialog.vue`: checklist (reuse the companion-list look: checkbox + title + code) inside step 3, shown only
  when picked day is future and candidates exist; ticking re-triggers the debounced preview so expected expiry updates live;
  consequence line: "Unticked add-ons stay on the sale and can be re-applied later; the member does not get these days until then".
  Remove no existing `data-testid`; add `entitlement-start-replay-<id>` hooks.
- `components/approval/EntitlementStartPackage.vue`: show the dropped add-ons for the reviewer.
- `utils/locales/en.json` + `id.json`: new strings (key = English text). Remove the now-unused `extended` entry only if nothing else uses it
  (backend lang `validation.user_product_active.start.extended` can be left or deleted in en+id together).
- Guide: update `content/guide/customer-membership` and `customer-personal-trainer` topics (en.ts + id.ts, bump `reviewed`, use `[[...]]` screen words that exist in en.json).
  Screenshots only if the dialog picture no longer matches. No new topic.

## Out of scope / follow-ups
- Detail-page UI to review/reinstate excluded add-ons (data model supports it).
- Quota and freeze add-ons; the `history` lock for freezes stays.
- Backend locale for CMS (middleware + `x-app-locale`) — would remove the need for client-side `$t()` of server messages.

## Risks to check while building
- Callers of `extensionsWhilePending()`: `EntitlementTransferService.php:280` (pending transferred package — its trail has no running-applied
  extensions, expected unchanged; add an assertion/test) and `EntitlementTransferService.php:466`.
- Ampaba-linked packages (`external_id`): move always queues for review; Ampaba's next sync may rewrite expiry. Both write paths
  (`OrderService`, `AmpabaService`) must not drift — verify the ledger is not read by `AmpabaService`.
- Assumption (unanswered earlier, defaulting to uniform): extensions applied while pending are listed and droppable the same way as running-applied ones.
- Contract suites must stay green unchanged: `make artisan cmd="test tests/Feature/Apps"` and `tests/Feature/Ampaba`.

## Verification
1. Tests (`tests/Feature/Cms/CustomerEntitlement/EntitlementStartTest.php` + `tests/Feature/Transaction/ScheduledExtensionTest.php`):
   - running + extension, move to future, all ticked → pending; activate → expiry = new start + period + extension.
   - unticked → expiry excludes it; EXCLUDED event + `START_CHANGED` written; second move re-ticks → REINSTATED, expiry includes it.
   - reverted extension never listed; revert of an excluded add-on after activation does not shorten expiry.
   - move to today/earlier unchanged (no double count of extension days); other locks still refuse.
   - approval path: capture → approve → same events; approver `impact()` lists dropped add-ons; replay with `exclude_ids` no longer valid fails cleanly.
   - `lock()` regression: check-in / cutting / `used_balances` still → `checked_in`.
2. `make artisan cmd="test tests/Feature/Cms/CustomerEntitlement"`, then `tests/Feature/Apps` and `tests/Feature/Ampaba`.
3. `docker compose exec backend ./vendor/bin/pint <changed>` and `phpstan analyse <changed>`; `EXPLAIN ANALYZE` the activity lookups
   (`activityable` + `action` + `data->order_item_id`) on `user_product_activities`; add an index in the same migration only if the plan shows a seq scan.
4. Browser (headless Playwright, per memory): local package from the screenshot (REGULER 3 MONTHS + extension) → pick a future day →
   checklist appears pre-ticked, expiry preview updates on untick, submit enabled, Indonesian copy shown; check spacing (14px icon/label gap, 42px controls).
5. Leave test data in the local DB and say what was left (project rule); do not commit unless asked.
