-- Outbound Ampaba lookups whose member came back with no birth date
-- ("0000-00-00", empty or null tanggal_lahir).
--
-- Why it matters: AmpabaService::syncUser() creates a new user with password
-- YYYYMMDD taken from tanggal_lahir, and falls back to the sync day's date when
-- the birth date is blank. The member doesn't know that password. A later sync that
-- does carry the real date overwrites customers.birth_date but never the password,
-- so only an admin reset (which reads customers.birth_date) lets them in.
--
-- Run against the app database: psql -U hom -d hom_apps_prod -f find-ampaba-blank-birthdate.sql
-- outbound_requests.response has no index: keep the created_at window
-- (outbound_requests_created_at_index) narrow on production.

-- Plain SQL, no psql variables, so it runs the same in psql, DataGrip or DBeaver.
-- Edit the date in `params` (start of the window on outbound_requests.created_at,
-- stored in UTC with no offset).

WITH params AS (
    SELECT TIMESTAMP '2026-09-01 00:00:00' AS since
),
members AS (
    SELECT DISTINCT ON (o.id, a.anggota ->> 'nomor_anggota')
        o.id            AS outbound_id,
        o.created_at    AS requested_at,
        o.url,
        o.status_code,
        a.anggota ->> 'nomor_anggota' AS nomor_anggota,
        a.anggota ->> 'nama_anggota'  AS nama_anggota,
        a.anggota ->> 'tanggal_lahir' AS tanggal_lahir
    FROM params p
    CROSS JOIN outbound_requests o
    -- every object anywhere in the body that carries tanggal_lahir: covers
    -- membership-transaction (data.anggota), membership-member(-number) and the PT lookups
    CROSS JOIN LATERAL jsonb_path_query(
        o.response,
        'strict $.** ? (exists(@.tanggal_lahir))'
    ) AS a(anggota)
    WHERE o.created_at >= p.since
      AND o.response::text LIKE '%tanggal_lahir%'
      AND (
          a.anggota ->> 'tanggal_lahir' IS NULL
          OR a.anggota ->> 'tanggal_lahir' IN ('0000-00-00', '')
      )
    ORDER BY o.id, a.anggota ->> 'nomor_anggota'
)
SELECT
    m.requested_at,
    m.url,
    m.status_code,
    m.nomor_anggota,
    m.nama_anggota,
    m.tanggal_lahir,
    c.id                         AS customer_id,
    c.user_id,
    c.birth_date                 AS birth_date_now,
    c.property ->> 'tanggal_lahir' AS tanggal_lahir_now,
    u.created_at                 AS user_created_at
FROM members m
-- containment, so customers_nomor_anggota_index (gin on property -> 'nomor_anggota') serves it
LEFT JOIN customers c ON c.property -> 'nomor_anggota' @> to_jsonb(m.nomor_anggota)
LEFT JOIN users u ON u.id = c.user_id
ORDER BY m.requested_at DESC;
