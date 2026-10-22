# Suites

A **suite** (`/suites`, key `TS-n`) is a named group of test cases that run
together for a reason — "Critical Path", "Release smoke", "CMS Auth". Where a
module says *where a case lives*, a suite says *why cases run together*, and
it can span modules.

A suite is not a Cypress spec file. The `*.cy.ts` specs under
`automation/cypress/e2e/` run only from the Makefile (`make cypress`,
`make cypress-panel`); the panel neither lists nor queues them.

## What a suite is made of

| Field | Notes |
|---|---|
| **Name** | Unique among live suites, ignoring case. Archiving frees it. |
| **Description** | When it runs and what it guards. |
| **Priorities** | Default priorities a run includes. None ticked = every priority. |
| **Entries** | What the suite includes — up to 100. |

### Entries

Each entry is one of three kinds:

| Kind | Includes |
|---|---|
| **Module** | Every live case in the module — now and later. |
| **Tag** | Every live case carrying the tag, in any module — now and later. |
| **Case** | One picked case. |

Module and tag entries are **live**: a case that joins the module or gets the
tag later is in the suite without touching it. Picked cases are fixed — a new
case must be added by hand.

A case selected by more than one entry runs **once**. The suite page lists it
with the entry that brought it in, in this order: picked, then module, then
tag.

The 100-entry cap bounds entries, not cases: a single module entry can bring
in any number of cases.

## Creating a suite and adding to it

- **Suites → New suite** — name, description, priorities.
- **Add to suite** on the suite page — pick a **Module**, a **Tag** or
  **Cases** (search by title or key).
- **Module rail → Add to suite…** — adds the whole module.
- **Case list bulk bar → Add to suite** — adds the selected cases.

Each of the last three can create the suite on the spot by typing a new name.
Entries already in the suite are left alone.

## What a run executes

Membership is **resolved when a run is queued**, not stored:

1. Take every case the entries select.
2. Drop archived cases and cases never published.
3. Keep the priorities of the run — or, if the run names none, the suite's
   default priorities.
4. Run each remaining case's **published** version.

The suite page's case list ("Cases a run executes") uses the same query as
the queue, so what it shows is exactly what a run will execute. Its header
counts the live cases within the suite's priorities and how many of them are
published (runnable).

## Running a suite

- **Run suite** on the suite page — pick the environment; the priorities
  open pre-ticked from the suite and can be narrowed for this run.
- **Schedules** (`/schedules`) — queue a suite (or a module or tag) on a cron
  schedule, optionally narrowed to priorities.
- **CLI**:

  ```bash
  make cypress-cases suite=TS-1          # by key
  make cypress-cases suite="cms auth"    # or by name, any casing
  ```

A suite run records which suite it came from, so run history and issues can be
filtered by suite, and the suite's newest result is shown on the suite list.
Failures are reported to the notification targets (email/Slack) and filed
under issues like any other queued run.

## Archive and restore

Suites are archived, never deleted. A suite cannot be archived while a
schedule runs it — change the schedule first. A module that a suite includes
cannot be archived; merging that module into another moves the suite's entry
to the target.

## Choosing entries

- **Module** for "everything in this area" — stays complete as cases are
  added.
- **Tag** for a cross-module slice that authors opt into (`smoke`,
  `release`): tagging a case is enough to include it.
- **Picked cases** for a fixed, hand-curated list that must not grow on its
  own.
- **Priorities** to keep a fast suite fast — a "Critical Path" suite of whole
  modules at P1 only.
