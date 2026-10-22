-- Lost Extension add-ons on scheduled packages: do we need the backfill?
--
-- READ-ONLY. Every statement is a SELECT; nothing here writes.
-- Run against the app database:  psql -d <app db> -f verify-lost-extensions.sql
--
-- Bug: an Extension add-on bought for a membership/PT package that was scheduled to start
-- later was measured from the sale day, and when the package started, activation wrote the
-- plain term over it. Each such extension left an `add_on.applied` audit row whose
-- before.status is 'pending' — that is how the packages are found below.
--
-- Cases:
--   A_pending        not started yet. Carries a wrong sale-day expiry, but the fixed code
--                    recomputes the whole term (extension included) when it starts, and
--                    documents/detail already print the right date. Backfill only tidies
--                    the stored date. Optional.
--   B_lost_running   started, extension missing, still running. NEEDS BACKFILL.
--   C_lost_expired   started, extension missing, already expired. NEEDS BACKFILL + a
--                    decision whether to reactivate (see should_be_until).
--   D_ok_extended    start date already includes the extension. Nothing to do.
--   E_check_by_hand  edited by an admin since it started, or a PT package with the
--                    bundle rule — the numbers can't be read automatically.
--   F_gone           cancelled / transferred / deleted. Nothing to do.

\pset pager off

-- 1) Summary: one row per case. If B and C are both 0, the backfill is not needed.
WITH ext AS (
    SELECT a.activityable_id                         AS upa_id,
           (a.data ->> 'order_item_id')::bigint      AS order_item_id
    FROM user_product_activities a
    WHERE a.activityable_type = 'user_product_active'
      AND a.action = 'add_on.applied'
      AND a.data ->> 'type' = 'extension'
      AND a.data -> 'before' ->> 'status' = 'pending'
),
ext_span AS (
    -- period × qty of each extension line, 'week' read as 7 days like the backend does
    SELECT e.upa_id,
           e.order_item_id,
           make_interval(
               years  => CASE oi.price_data -> 'settings' -> 'period' ->> 'unit' WHEN 'year'  THEN (oi.price_data -> 'settings' -> 'period' ->> 'value')::int * oi.qty ELSE 0 END,
               months => CASE oi.price_data -> 'settings' -> 'period' ->> 'unit' WHEN 'month' THEN (oi.price_data -> 'settings' -> 'period' ->> 'value')::int * oi.qty ELSE 0 END,
               days   => CASE oi.price_data -> 'settings' -> 'period' ->> 'unit'
                             WHEN 'day'  THEN (oi.price_data -> 'settings' -> 'period' ->> 'value')::int * oi.qty
                             WHEN 'week' THEN (oi.price_data -> 'settings' -> 'period' ->> 'value')::int * oi.qty * 7
                             ELSE 0 END
           ) AS span
    FROM ext e
    JOIN order_items oi ON oi.id = e.order_item_id
),
per_pkg AS (
    SELECT upa_id, sum(span) AS total_span, count(*) AS extension_lines
    FROM ext_span
    GROUP BY upa_id
),
pkg AS (
    SELECT u.id, u.code, u.status, u.activable_type, u.deleted_at,
           u.activate_at, u.activated_at, u.expires_at, u.original_expires_at, u.expiry_rule,
           p.total_span, p.extension_lines,
           -- the expiry activation wrote: what the first later change says it was before,
           -- or the stored one when nothing has changed it since
           coalesce((
               SELECT (a.data -> 'before' ->> 'expires_at')::timestamptz
               FROM user_product_activities a
               WHERE a.activityable_type = 'user_product_active'
                 AND a.activityable_id = u.id
                 AND a.action IN ('entitlement.edit', 'freeze.ended', 'add_on.applied', 'upgrade.applied', 'upgrade.reverted')
                 AND a.created_at >= u.activated_at
               ORDER BY a.id
               LIMIT 1
           ), u.expires_at) AS written_at_start,
           EXISTS (
               SELECT 1 FROM user_product_activities a
               WHERE a.activityable_type = 'user_product_active'
                 AND a.activityable_id = u.id
                 AND a.action = 'entitlement.edit'
                 AND a.created_at >= u.activated_at
           ) AS edited_by_hand
    FROM user_product_actives u
    JOIN per_pkg p ON p.upa_id = u.id
),
classified AS (
    SELECT pkg.*,
           CASE
               WHEN deleted_at IS NOT NULL OR status IN ('canceled', 'transferred') THEN 'F_gone'
               WHEN status = 'pending'                                             THEN 'A_pending'
               WHEN edited_by_hand OR activated_at IS NULL OR original_expires_at IS NULL THEN 'E_check_by_hand'
               WHEN (written_at_start AT TIME ZONE 'Asia/Jakarta')::date
                    = ((original_expires_at AT TIME ZONE 'Asia/Jakarta')::date + total_span)::date
                                                                                   THEN 'D_ok_extended'
               WHEN (written_at_start AT TIME ZONE 'Asia/Jakarta')::date
                    = (original_expires_at AT TIME ZONE 'Asia/Jakarta')::date
                    AND status = 'expired'                                         THEN 'C_lost_expired'
               WHEN (written_at_start AT TIME ZONE 'Asia/Jakarta')::date
                    = (original_expires_at AT TIME ZONE 'Asia/Jakarta')::date      THEN 'B_lost_running'
               ELSE 'E_check_by_hand'
           END AS case_
    FROM pkg
)
SELECT case_, count(*) AS packages, sum(extension_lines) AS extension_lines
FROM classified
GROUP BY case_
ORDER BY case_;

-- 2) Detail: every package, with the date it has and the date it should have.
--    should_be_until = today's expiry + the lost extension(s), Jakarta date.
WITH ext AS (
    SELECT a.activityable_id                         AS upa_id,
           (a.data ->> 'order_item_id')::bigint      AS order_item_id
    FROM user_product_activities a
    WHERE a.activityable_type = 'user_product_active'
      AND a.action = 'add_on.applied'
      AND a.data ->> 'type' = 'extension'
      AND a.data -> 'before' ->> 'status' = 'pending'
),
ext_span AS (
    SELECT e.upa_id,
           e.order_item_id,
           oi.qty,
           oi.price_data -> 'settings' -> 'period' AS period,
           make_interval(
               years  => CASE oi.price_data -> 'settings' -> 'period' ->> 'unit' WHEN 'year'  THEN (oi.price_data -> 'settings' -> 'period' ->> 'value')::int * oi.qty ELSE 0 END,
               months => CASE oi.price_data -> 'settings' -> 'period' ->> 'unit' WHEN 'month' THEN (oi.price_data -> 'settings' -> 'period' ->> 'value')::int * oi.qty ELSE 0 END,
               days   => CASE oi.price_data -> 'settings' -> 'period' ->> 'unit'
                             WHEN 'day'  THEN (oi.price_data -> 'settings' -> 'period' ->> 'value')::int * oi.qty
                             WHEN 'week' THEN (oi.price_data -> 'settings' -> 'period' ->> 'value')::int * oi.qty * 7
                             ELSE 0 END
           ) AS span
    FROM ext e
    JOIN order_items oi ON oi.id = e.order_item_id
),
per_pkg AS (
    SELECT upa_id,
           sum(span) AS total_span,
           count(*) AS extension_lines,
           string_agg(order_item_id::text || ' (' || (period ->> 'value') || ' ' || (period ->> 'unit') || ' x' || qty || ')', ', ' ORDER BY order_item_id) AS extensions
    FROM ext_span
    GROUP BY upa_id
),
pkg AS (
    SELECT u.id, u.code, u.user_id, u.status, u.activable_type, u.deleted_at,
           u.activate_at, u.activated_at, u.expires_at, u.original_expires_at, u.expiry_rule,
           p.total_span, p.extension_lines, p.extensions,
           coalesce((
               SELECT (a.data -> 'before' ->> 'expires_at')::timestamptz
               FROM user_product_activities a
               WHERE a.activityable_type = 'user_product_active'
                 AND a.activityable_id = u.id
                 AND a.action IN ('entitlement.edit', 'freeze.ended', 'add_on.applied', 'upgrade.applied', 'upgrade.reverted')
                 AND a.created_at >= u.activated_at
               ORDER BY a.id
               LIMIT 1
           ), u.expires_at) AS written_at_start,
           EXISTS (
               SELECT 1 FROM user_product_activities a
               WHERE a.activityable_type = 'user_product_active'
                 AND a.activityable_id = u.id
                 AND a.action = 'entitlement.edit'
                 AND a.created_at >= u.activated_at
           ) AS edited_by_hand
    FROM user_product_actives u
    JOIN per_pkg p ON p.upa_id = u.id
),
classified AS (
    SELECT pkg.*,
           CASE
               WHEN deleted_at IS NOT NULL OR status IN ('canceled', 'transferred') THEN 'F_gone'
               WHEN status = 'pending'                                             THEN 'A_pending'
               WHEN edited_by_hand OR activated_at IS NULL OR original_expires_at IS NULL THEN 'E_check_by_hand'
               WHEN (written_at_start AT TIME ZONE 'Asia/Jakarta')::date
                    = ((original_expires_at AT TIME ZONE 'Asia/Jakarta')::date + total_span)::date
                                                                                   THEN 'D_ok_extended'
               WHEN (written_at_start AT TIME ZONE 'Asia/Jakarta')::date
                    = (original_expires_at AT TIME ZONE 'Asia/Jakarta')::date
                    AND status = 'expired'                                         THEN 'C_lost_expired'
               WHEN (written_at_start AT TIME ZONE 'Asia/Jakarta')::date
                    = (original_expires_at AT TIME ZONE 'Asia/Jakarta')::date      THEN 'B_lost_running'
               ELSE 'E_check_by_hand'
           END AS case_
    FROM pkg
)
SELECT case_,
       c.code,
       c.activable_type                                              AS kind,
       c.status,
       (c.activate_at  AT TIME ZONE 'Asia/Jakarta')::date            AS starts,
       (c.activated_at AT TIME ZONE 'Asia/Jakarta')::date            AS started,
       (c.original_expires_at AT TIME ZONE 'Asia/Jakarta')::date     AS package_alone_until,
       (c.expires_at AT TIME ZONE 'Asia/Jakarta')::date              AS until_now,
       CASE WHEN case_ IN ('B_lost_running', 'C_lost_expired')
            THEN ((c.expires_at AT TIME ZONE 'Asia/Jakarta')::date + c.total_span)::date
       END                                                           AS should_be_until,
       CASE WHEN case_ = 'C_lost_expired'
            THEN ((c.expires_at AT TIME ZONE 'Asia/Jakarta')::date + c.total_span)::date >= (now() AT TIME ZONE 'Asia/Jakarta')::date
       END                                                           AS still_entitled_today,
       c.expiry_rule,
       c.extensions                                                  AS extension_lines_qty,
       cu.name                                                       AS member
FROM classified c
LEFT JOIN users cu ON cu.id = c.user_id
ORDER BY case_, c.id;
