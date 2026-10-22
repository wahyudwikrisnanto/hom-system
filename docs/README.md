# Docs

Cross-repo documentation for the HOM stack.

## Test authoring

End-to-end tests for the CMS (the Nuxt admin and the CMS API) are authored in
the automation control panel — `automation/`, http://localhost:5173 — instead
of being written as Cypress spec files. A tester composes tests from reusable
pieces, versions them, groups them and runs them from the browser; the panel
executes them with Cypress and records a report per run.

| Feature | Key | In one line | Doc |
|---|---|---|---|
| Steps | `STP-n` | A reusable Cypress snippet with declared parameters, kept in a library. | [test-steps.md](test-steps.md) |
| Test cases | `TC-n` | An ordered list of steps that checks one behaviour, versioned like code. | [test-cases.md](test-cases.md) |
| Suites | `TS-n` | A named group of cases — whole modules, tags or picked cases — run together. | [test-suites.md](test-suites.md) |

### How the pieces fit

```
Module (Auth, Branch, …)          groups cases and steps by area of the app
  │
  ├── Step library                STP-1 Visit page · STP-4 Sign in · …
  │        ▲  used by (with params)
  ├── Test case  TC-n             draft v3 ─publish─▶ published v3 (frozen)
  │        ▲  selected by
  └── Suite  TS-n                 module | tag | picked-case entries
                │
                ▼  Run / schedule / make cypress-cases
          Queue ─▶ cypress-runner ─▶ Run report (steps, timing, screenshots, video)
```

1. **Write steps once.** "Visit page", "Sign in", "Expect path" — each a small
   snippet with parameters.
2. **Compose a case** from library steps (filling their parameters) and, where
   nothing fits, inline one-off snippets. Optionally add a data set so the
   same case runs once per input row.
3. **Run the draft** while authoring, then **publish** it. Publishing freezes a
   version: later step edits never change what a published case runs.
4. **Group cases into suites** for the reasons they run together — "Critical
   Path", "Release smoke".
5. **Run** a case, module, tag or suite from the panel, the CLI or a schedule.
   Failures get a report, a notification and an issue.

### Modules

Modules (`Auth`, `Branch`, …) are the area of the app a case or step belongs
to. Every case has exactly one module. A step has one module or none — a step
with no module is **shared** and offered to every module (sign-in, visit
page).

The module rail beside the case and step lists is where modules are managed:

- **Create** and **rename**. A module is identified by its slug, so `Branch`
  and `branch ` are the same module.
- **Merge** moves every case, step, suite entry and schedule into another
  module, then archives the source.
- **Archive** only an empty module that no suite includes; its steps become
  shared. Archiving frees the name.
- **Filter**: picking a module narrows the list (`?module=<id>`, `none` for
  shared steps). The rail also shows how many cases in each module are
  failing, and its menu offers **Add to suite…**.

### Where the data lives

- **`automation/data/authored.sqlite`** — modules, steps, cases, suites and
  every version of them. It is **committed** in the automation repo: authoring
  in the panel changes that file and it goes in with the work like code. It is
  binary and does not merge, so pull before authoring and restart
  `automation` + `cypress-runner` after a pull changes it.
- **`automation/data/local.sqlite`** — runs, the queue, schedules,
  environments (with secret variables), notification targets and each case's
  newest result. Gitignored; never committed.

The panel's own test suite (`make cypress-panel`) runs on a separate copy
under `automation/data/test/` and never touches either file.

### Running from the command line

```bash
make cypress-cases module=Branch    # every published case of a module
make cypress-cases tag=smoke        # every published case with a tag
make cypress-cases suite=TS-1       # a suite, by key or name (any casing)
make logs-runner                    # watch the run-queue worker
```

These queue a run exactly like the panel's **Run** button; the report shows
up under **Runs**.

### Related features

- **Assistant** (`/assists`) — points Claude at a flow of the admin; it maps
  the flow, proposes scenarios and drafts one case per kept scenario from
  existing library steps plus inline snippets. Drafts become cases only on
  **Accept**. See [test-cases.md](test-cases.md#cases-drafted-by-the-assistant).
- **Issues** (`/issues`) — failures of a queued run are filed under issues
  grouped by root cause; a failed test shows its issue's status.
- **Tasks** — **Generate test cases** on a task designs scenarios per
  acceptance criterion and saves them as unpublished draft cases, tagged with
  the task key, in the task's module.

Full rules for the panel: `automation/CLAUDE.md`.
