# Steps

**Steps** (`/steps`, key `STP-n`) are the building blocks of test cases: a
reusable Cypress snippet with declared parameters. A case lists steps in order
and gives each use its own values, so one "Visit page" step serves every case
that opens a screen, and fixing a selector means fixing one step.

## What a step is made of

| Field | Notes |
|---|---|
| **Name** | What the step does, as a case reads it: "Fill login form", "Expect path". Up to 120 characters. |
| **Description** | What the step leaves behind — the next step starts from there. Shown in the step picker. |
| **Module** | The area it belongs to, or **Shared — no module** for steps every module uses (signing in, visiting a page). |
| **Parameters** | Up to 20 inputs, each with a name, label, type, default and required flag. |
| **Snippet** | The Cypress code that runs. Up to 20,000 characters. |

### Parameters

Each parameter declares:

- **name** — an identifier the snippet reads as `params.<name>`. Names are
  unique within the step.
- **label** — the hint shown beside the input in the case editor
  (`click | enter`, `Token name | empty | invalid`).
- **type** — `string`, `number`, `boolean` or `secret`. The value reaches the
  snippet already converted: a `number` is a number, a `boolean` is
  `true` only for the text `true`. `secret` masks the input.
- **default** — used when a case leaves the value empty.
- **required** — the run fails with `Missing required parameter "<name>"` if
  the resolved value is empty.

A value — typed in a case, or as a default — can be:

| Value | Resolves to |
|---|---|
| plain text | itself |
| `env:<key>` | `Cypress.env(<key>)` — the run's environment variables. Use it for accounts and passwords so secrets never sit in a case (`env:adminEmail`, `env:adminPassword`). |
| `data:<key>` | that column of the current data-set row (see [test-cases.md](test-cases.md#data-sets)). |

### The snippet

The snippet is the body of a function the case runner builds per step:

```js
new Function(cy, expect, params, vars, env, sel, api, data)
```

| Name | What it is |
|---|---|
| `cy` | Cypress. |
| `expect` | Chai assertions. |
| `params` | This use's parameter values, resolved and typed. |
| `vars` | A scratch object shared by every step of one test. A step stores what later steps need: `vars.login = response`. Starts empty for each test (and each data-set row). |
| `env` | All environment variables — `env.apiUrl`, `env.adminEmail`, … |
| `sel` | Admin selectors from `cypress/support/selectors.ts`. A name that no longer exists fails with `Unknown selector "sel.<name>"` instead of a vague "element not found". |
| `api(method, path, body)` | A CMS API request with the environment admin's bearer token (one cached login). It **never fails on status**, so a step can assert on the 403 or 422 it is testing for. Every call shows up in the run report. |
| `data` | The current data-set row's values (`{}` when the case has none). |

Example — "API: attempt login":

```js
const pick = (v) => { const s = String(v ?? ""); return s.startsWith("env:") ? String(env[s.slice(4)] ?? "") : s; };
const body = {};
if (pick(params.email)) body.email = pick(params.email);
if (pick(params.password)) body.password = pick(params.password);
cy.request({ method: "POST", url: env.apiUrl + "/auth/login", body, failOnStatusCode: false })
  .then((response) => { vars.login = response; });
```

A snippet is **syntax-checked when saved** — a typo is refused at save time
rather than showing up as a red run. The server never executes it; only
Cypress does.

## Versioning

- Every change to **name, parameters or snippet** creates a new version
  (`v1`, `v2`, …). A change to the description or module alone saves without
  a new version ("Saved — no new version (details only)").
- A **case draft** always follows a step's latest version.
- **Publishing a case** pins the version of each step it uses and copies the
  step's name, parameters and snippet into the case version. Editing the step
  afterwards does not change what that published case runs.
- When a step moves ahead of the version a published case pins, the case page
  says how many steps have a newer version; saving and publishing a new draft
  picks them up.

So a step edit is safe: it reaches drafts at once, and published cases only
when someone republishes them on purpose.

## The step page

- **Editor** — name, description, module, parameters and snippet.
- **History** — every version, each a read-only snapshot of name, parameters
  and snippet.
- **Used by** — the case versions that can still run the step: each case's
  draft and its current published version.

## Archive and restore

Steps are archived, never deleted. Archiving is **refused while any draft
case uses the step** ("Used by N draft case(s) — remove it there first").
Published versions keep their own copy, so they still run. An archived step
cannot be added to a case and cannot be edited until it is restored.

## The step list

Newest edit first, searchable by name or key, and filtered by the module rail
(**All steps**, a module, or **Shared**).

## Library step or inline snippet?

A case item can also be an **inline snippet** that lives only in that case.
Use a library step when the action or check will repeat across cases; use
inline for a one-off. Repetition across a module's cases is pulled into
library steps later — the assistant never creates new library steps, it uses
existing ones and inline snippets.

Good steps:

- do one thing and say so in the name ("Submit login form", not "Login
  stuff");
- take what varies as parameters, with sensible defaults (`env:adminEmail`);
- leave the page in a state the description names, so the next step can rely
  on it;
- assert on what they did when that is cheap (the logout request answered
  200).
