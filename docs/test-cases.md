# Test cases

A **test case** (`/cases`, key `TC-n`) checks one behaviour of the app: an
ordered list of items that Cypress runs top to bottom. Each item is either a
**library step** with values for its parameters (see
[test-steps.md](test-steps.md)) or an **inline snippet** that lives only in
this case.

## What a case is made of

**Details** — not versioned; changing them never needs a publish:

| Field | Notes |
|---|---|
| **Title** | The behaviour checked, as a sentence: "Logout revokes only its own token". Up to 200 characters. |
| **Description** | Optional context: setup, why, what it guards. |
| **Module** | Exactly one, and it must be live. |
| **Tags** | Free text, lowercased, up to 20 (`smoke`, `api`, `approval`). Tags select cases for runs and suites. |
| **Priority** | `P1`, `P2` (default) or `P3`. Runs can be narrowed to priorities. |

**Content** — versioned:

- **Items** — up to 100, in order. A library item holds the step, its
  parameter values and an optional note ("why this step is here"). An inline
  item holds a name and a snippet.
- **Data sets** — optional input rows.

## Life cycle

```
New case ──▶ draft v1 ──Save draft──▶ draft v1 ──Publish──▶ published v1
                                                                │
                      edit and Save draft (opens draft v2) ◀────┘
                                                                │
                                         draft v2 ──Publish──▶ published v2
```

### Create

**New test case** asks for details only; the case opens on an empty draft v1
and steps are added on the next screen.

### Edit the draft

The **Steps** tab is the draft editor:

- **Add a step** searches the step library, scoped to the case's module,
  shared steps or the whole library. Its parameters appear as inputs, labelled from the step's
  definition; an empty value falls back to the step's default.
- **Add an inline snippet** for a one-off action or check: a name ("What
  this snippet does") and a snippet.
- **Move up / Move down** and **Remove step** reorder the list; each item can
  carry a note.
- **Save draft** stores the draft; **Discard changes** drops unsaved edits.

A case has **at most one draft**. With no draft open, the editor shows the
published version; saving opens the next draft version on top of it. Library
steps in a draft always follow their **latest** version, and the editor marks
a step that has been archived. A draft cannot be saved with a step that is
missing or archived.

### Run the draft

**Run draft** queues the saved draft with every library step at its latest
version, recorded against the draft (its test title reads `TC-7 v3 (draft)`).
This is the authoring loop: edit, save, run draft, read the report, repeat.

### Publish

**Publish** turns the draft into the case's published version, with an
optional changelog ("What changed and why"). At that moment each library step
is **pinned** at its current version and its name, parameters and snippet are
copied into the version. A published version is never written again — later
step edits don't change it. A draft with no items cannot be published.

Every normal run — **Run**, module, tag, suite, schedule, CLI — executes the
**published** version. A case that was never published is skipped by them.

When steps it uses have moved on since publishing, the case page says
"N steps have a newer version than published vN pins" — save and publish a
draft to take them.

## Data sets

A version can carry up to 50 named rows of input values. Each row runs as
**its own test**, titled `TC-n vN · <title> [data: <row name>]`, so one case
covers several inputs and each row passes or fails on its own. No rows: the
case runs once.

- Columns are named with letters, digits and `_`; row names are unique.
- A parameter reads a column as `data:<column>`; a snippet reads `data.<column>`.
- Rows are edited under the steps and frozen with the version on publish.

Example — one login case for two refusals:

| Row | `email` | `password` |
|---|---|---|
| wrong password | `env:adminEmail` | `not-the-password` |
| unknown email | `nobody.auth-check@mail.com` | `not-the-password` |

with the step "Fill login form" given `email = data:email`,
`password = data:password`.

## Accounts and secrets

Cases sign in with the run's environment variables, never with typed
credentials: `env:adminEmail` / `env:adminPassword` is the environment's
standing account. Locally that is `tester@mail.com`, which holds
`-with-approval` twins and no direct `.edit`, so its writes queue for
approval.

A case that checks what one permission set may do signs in as its own admin
through dedicated variables — today `env:branchViewerEmail` (`branch.view`
only) and `env:branchDirectEmail` (`branch.view|add|edit|delete`, no twin).
Environments and their variables are managed under **Environments**; secret
values are never shown again once saved.

## The case page

- Header — key, title, module, priority, tags, published version and open
  draft; **Run**, **Run draft**, **Publish**, and under *More actions*
  **Edit details**, **Clone case**, **Archive case**.
- **Steps** — the draft editor.
- **Versions** — every version with status, changelog, step count and dates.
  Open one to read it (a draft shows "library steps follow their latest
  version", a published one is a snapshot) or **Compare** two versions.
- **Runs** — every recorded result of the case, newest first: version,
  status, duration, the step it failed in, error, environment, and the
  fix or issue it belongs to.
- **Issues** — the issues its failures are filed under.

**Clone case** copies details and the newest content (draft, else published)
into a new case, "Copy of …", as an unpinned draft v1.

## Archive and restore

Cases are archived, never deleted. An archived case is read-only and no run
selects it. **Archived** on the list (`?archived=1`) shows them for
**Restore**; a case whose module was archived meanwhile must be moved to a
live module first.

## The case list

- Filter by module (rail), tag, priority and a search over key and title;
  newest edit first.
- Each row shows the newest result and **passed/runs** over its last 20
  results, with a **flaky** badge when a test passed only on retry.
- **Bulk actions** on selected rows (up to 200, all or nothing): move to
  another module, archive, restore, **Run** (published versions; never
  published cases are skipped) and **Add to suite** (type a new name to create
  one).

## How a case runs

1. A run request resolves to exact case version ids when it is queued — a
   case published a minute later is not in a run queued before.
2. `cypress-runner` picks requests up one at a time and runs the single spec
   `cypress/e2e/cases/case-runner.cy.ts` with the bundle: one `describe` per
   module, one `it` per case (or per data-set row).
3. For each item, the runner resolves parameters (`env:`, `data:`, defaults),
   then runs the snippet. A failure is prefixed with the step it happened in —
   `[step 2 · Submit login form] …` — so the report names the failing step.
4. The report (`/runs/:id`) shows every step with its timing and a screenshot
   after it, the API calls made, console output, a failure screenshot and the
   recording; "Play from" seeks the video to a step.
5. The case's newest result is stored with the run and shown on the list.

The test title `TC-n vN · title` and the `[step N · name]` prefix are how a
result maps back to its case version and failing step.

## Cases drafted by the assistant

The **Assistant** (`/assists`) is given an entry path, what to test and a
module. It walks the flow in a real Chrome, reads the code and answers with a
plan — flow map, coverage matrix, Given/When/Then scenarios and open
questions — for review. It then drafts one case per kept scenario from
existing library steps plus inline snippets, checked with the same rules as
the case editor.

Nothing is authored until **Accept**: the draft becomes a case tagged
`assist` with that list as its **unpublished draft**. **Dry run** queues it
without filing issues. Publish it like any other draft.

Work sessions may also **propose case changes** when the app changed on
purpose — the complete new step list, with the reason and what the case still
checks. A person applies it as the case's next version.

## Writing good cases

- One behaviour per case; the title states the expected outcome.
- Prefer library steps; keep inline snippets for genuine one-offs.
- Make data unique per run (a timestamp in names) rather than depending on
  existing rows; test data is left in the local database.
- Use a data set instead of copying a case to vary inputs.
- Tag what a run should select (`smoke`, `api`, `ui`) and set priority by
  impact — suites and schedules filter on both.
