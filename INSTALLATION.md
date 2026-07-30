---
name: "install-snowcuffs"
description: "Install snow-cuffs from GitHub into the user's Coco plugin directory, register it in Coco settings, deploy the Snowflake objects, and roll out enforcement. This instruction is intended for Coco to execute."
tags:
  - snowcuffs
  - installation
  - plugin
---

Your objective is to install snow-cuffs from `cwkoenigs/snow-cuffs` so Coco can load it as a local plugin, then stand up the Snowflake objects it depends on.

## Source Repository

Install from:

```text
https://github.com/cwkoenigs/snow-cuffs
```

If the user asks how to install snow-cuffs, tell them to enter this in Coco:

```text
Install this plugin from [cwkoenigs/snow-cuffs](https://github.com/cwkoenigs/snow-cuffs)
```

## Pre-Flight Checks

1. Determine the user's home directory using the current operating system's standard home-directory mechanism. Do not assume a Windows, macOS, or Linux-specific absolute path.
2. Resolve the plugin destination as:

```text
<user-home>/.snowflake/cortex/plugins/snowcuffs
```

3. Locate Coco's `settings.json` (the one Coco reads for the current user profile; create it in Coco's expected settings location if absent). Preserve existing settings — do not overwrite unrelated keys.

## Install Repository

1. Download or clone `https://github.com/cwkoenigs/snow-cuffs`.
2. Ensure the parent plugin directory exists, then place the repository contents at `<user-home>/.snowflake/cortex/plugins/snowcuffs`.
3. If a `snowcuffs` directory already exists: update it if it is a snow-cuffs repository; if it is not clearly snow-cuffs, stop and ask the user before replacing it.
4. Open Coco's `settings.json` and ensure `pluginDirs` contains the snow-cuffs path, appending to (never replacing) any existing entries:

```json
{
  "pluginDirs": [
    "<user-home>/.snowflake/cortex/plugins/snowcuffs"
  ]
}
```

Developing against a working checkout instead? Point Coco at it directly with `--plugin-dir <path-to-checkout>` and skip the copy — everything below still applies.

5. Set `SNOWCUFFS_HOME` to the installed path (shell profile or Coco's env), e.g.:

```bash
export SNOWCUFFS_HOME="<user-home>/.snowflake/cortex/plugins/snowcuffs"
```

The `$warmstart` and `$cuffs ship` skills and the session-start hook invoke
`"$SNOWCUFFS_HOME/indexer/context_pack.py"` and `".../ship_audit.py"` from
whatever project directory the session runs in — without this variable they
fall back to `./indexer/`, which only exists inside the snow-cuffs repo
itself. The skills' audit self-report one-liners are deliberately
self-contained (inline `node -e`, no plugin files referenced), so they work
regardless of install location.

After updating `settings.json`, tell the user to restart Coco so it reloads plugin settings.

## Deploy the Snowflake Objects

Run `sql/01` through `sql/06` in order — each file is deployable top-to-bottom. Use a role that can read `SNOWFLAKE.ACCOUNT_USAGE` (for 01) and create objects in the `SNOWCUFFS` database. All thresholds and seed pricing are illustrative — review them before trusting output.

```text
sql/01_ai_cost_observability.sql   SNOWCUFFS.OBSERVABILITY spend views (AI functions, CoCo, Search, rollup)
sql/02_preflight_estimation.sql    SNOWCUFFS.PUBLIC MODEL_PRICING + ESTIMATE_AI_CREDITS + CHEAPEST_MODEL_FOR_TIER
sql/03_guardrails.sql              Resource monitors and burn-rate alerts
sql/04_code_search_service.sql     SNOWCUFFS.CODE_INDEX + TEAM_CODE_SEARCH (warehouse SNOWCUFFS_WH)
sql/05_usage_audit.sql             SNOWCUFFS.AUDIT.AGENT_EVENTS + adoption/hygiene views
sql/06_*.sql                       SNOWCUFFS.DB_CONTEXT schema cards + DB_SCHEMA_SEARCH
```

Refresh `MODEL_PRICING` from the current Snowflake Service Consumption Table — the seeded rates drift.

## Configure the CI Indexer

The code index stays current via `.github/workflows/index-codebase.yml`. Copy the workflow into each repo you want indexed (change `--repo`), and set these GitHub Actions secrets:

```text
SNOWFLAKE_ACCOUNT       account locator
SNOWFLAKE_USER          dedicated CI service user
SNOWFLAKE_PRIVATE_KEY   key-pair auth for that user
```

Scope the CI user's write access to `SNOWCUFFS.CODE_INDEX` only. The workflow runs on main-branch pushes and upserts only changed chunks, so embedding spend tracks merge volume, not repo size.

## Render Configuration

From each project root where snow-cuffs should be active:

1. Copy `templates/snowcuffs.toml.template` to `snowcuffs.toml` — or merge its `[snowcuffs]` section into the project's existing `cocoplus.toml`.
2. Run the render command at the bottom of the template to produce `.snowcuffs/config.json` (the file the hooks actually read). Re-run it after any change; commit both files.
3. Append `templates/AGENTS-snowcuffs.md.template` to the project's `AGENTS.md` so every session inherits the standing cost rules.

## Verify

1. Restart Coco and start a session in the project. The session-start hook injects `PROJECT_CONTEXT.md` (or tells you to build it).
2. Run `$cuffs` — it should show mode `warn`, zeroed session counters, and the resolved `preflightGateCredits` with its source.
3. Confirm `.snowcuffs/state/` and `.snowcuffs/audit/<today>.jsonl` were created.
4. After a day of use, run `$cuffs ship` and check `SELECT * FROM SNOWCUFFS.AUDIT.SESSION_HYGIENE;`.

## Rollout: Warn First, Then Block

Week 1: leave `mode = "warn"` — the gates annotate expensive actions but allow them, and every would-be block lands in the audit trail. Review `SNOWCUFFS.AUDIT.BLOCKED_EVENTS_DAILY` and the warn events with the team: legitimate catches argue for enforcement; false positives argue for tuning `maxReadLines` / `maxSessionReads` first.

Week 2: flip `mode = "block"`, re-render config, announce it. Keep `BLOCKED_EVENTS_DAILY` in the team review — a flat zero for weeks means the rules are internalized and is itself a result.

## How It Composes with CocoPlus

snow-cuffs is designed to run alongside CocoPlus, not replace it:

- **Both plugins' hooks run.** Coco invokes each installed plugin's hook per event. snow-cuffs hooks are structural-only, fail-open, and never write under `.cocoplus/` — CocoPlus owns those formats; snow-cuffs reads them where useful.
- **`$cuffs chargeback` reads CocoPlus meter attribution.** When `$meter on` is active, `.cocoplus/meter/request-map.jsonl` refines per-user daily credits into per-session attribution; without it, chargeback falls back to per-user `ACCOUNT_USAGE`.
- **One gate number.** When `cocoplus.toml` sets `[cost] per_session_threshold_credits`, the snow-cuffs hooks and `$preflight` honor it over `preflightGateCredits`, so both frameworks gate on the same threshold.
- **Two lenses, no overlap.** The CocoConsole Cost view remains the per-session, token-level lens; `SNOWCUFFS.AUDIT` is the team-and-history lens (adoption, hygiene, blocks, search-bypass). `$cuffs` points at `$meter view` for token detail rather than duplicating it.

## Anti-Rationalization

| Temptation | Why Not |
|------------|---------|
| Hard-code an OS-specific plugin path | Installation must work on every OS |
| Replace `pluginDirs` or the whole settings file | Other installed plugins and user settings must be preserved |
| Skip the SQL deploys because the hooks "work locally" | The gates redirect to `TEAM_CODE_SEARCH`, `$preflight` prices via `ESTIMATE_AI_CREDITS`, and `$cuffs ship` targets `SNOWCUFFS.AUDIT` — without the objects, every redirect dead-ends |
| Start in block mode to be safe | Un-reviewed thresholds produce false blocks, and false blocks teach the team to bypass the tool; warn-first builds the evidence for enforcement |
| Give the CI user a broad role | The indexer needs write access to `SNOWCUFFS.CODE_INDEX` only; anything more is standing risk in a repo secret |
| Edit `.snowcuffs/config.json` by hand | The toml is the source of truth; hand edits are silently overwritten on the next render |

## Exit Criteria

- [ ] Repository installed at `<user-home>/.snowflake/cortex/plugins/snowcuffs` (or registered via `--plugin-dir`), containing `plugin.json`
- [ ] `pluginDirs` includes the snow-cuffs path; existing entries and unrelated settings preserved; user told to restart Coco
- [ ] `sql/01`–`sql/06` deployed in order; `MODEL_PRICING` rates reviewed
- [ ] CI indexer secrets set (`SNOWFLAKE_ACCOUNT`, `SNOWFLAKE_USER`, `SNOWFLAKE_PRIVATE_KEY`) with write scope limited to `SNOWCUFFS.CODE_INDEX`
- [ ] `[snowcuffs]` config rendered to `.snowcuffs/config.json`; AGENTS.md block appended
- [ ] `$cuffs` verified in a live session; `.snowcuffs/` state and audit files created
- [ ] Week-1 `warn` → `block` rollout communicated, with `BLOCKED_EVENTS_DAILY` as the review evidence
