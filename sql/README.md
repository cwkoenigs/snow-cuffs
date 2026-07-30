# sql/ — deploy order

Each file is deployable top-to-bottom in a Snowsight worksheet (or `snow sql -f`).
Deploy in number order — later files reference earlier objects. Thresholds and
pricing seeds in every file are illustrative; tune before trusting.

| # | File | What it creates | One line |
|---|------|-----------------|----------|
| 01 | `01_ai_cost_observability.sql` | `SNOWCUFFS.OBSERVABILITY` views | Spend attribution over ACCOUNT_USAGE: AI functions, CoCo (all surfaces), Cortex Search, platform rollup. Deploy first — everything else is prioritized by what these show. |
| 02 | `02_preflight_estimation.sql` | `SNOWCUFFS.PUBLIC` MODEL_PRICING, `ESTIMATE_AI_CREDITS()`, `CHEAPEST_MODEL_FOR_TIER()` | Price a batch AI SQL job before running it (AI_COUNT_TOKENS x pricing table). |
| 03 | `03_guardrails.sql` | Burn-rate alert, resource monitor, budgets note | Catch runaway spend in hours, not at month-end. Uses 01's rollup view. |
| 04 | `04_code_search_service.sql` | `SNOWCUFFS.CODE_INDEX` CODE_CHUNKS, `TEAM_CODE_SEARCH`, `SNOWCUFFS_WH` | One Cortex Search service over team code so agents retrieve chunks instead of reading whole files. |
| 05 | `05_usage_audit.sql` | `SNOWCUFFS.AUDIT` AGENT_EVENTS + skill/session/blocked views | Audit how skills and sessions are actually used: adoption, search-first hygiene, block counts, init-style cost comparison. |
| 06 | `06_schema_context_service.sql` | `SNOWCUFFS.DB_CONTEXT` SCHEMA_CARDS, `DB_SCHEMA_SEARCH` | Schema cards + a Cortex Search service so agents look up table shapes instead of running discovery queries. |

## What feeds each schema

| Target | Fed by | Cadence |
|--------|--------|---------|
| 04 `CODE_INDEX.CODE_CHUNKS` | CI indexer: `indexer/chunker.py` + `indexer/upsert.py` (`.github/workflows/index-codebase.yml`) | On merge to main; service refreshes at TARGET_LAG |
| 05 `AUDIT.AGENT_EVENTS` | Local CoCo hooks and $-skills append `.snowcuffs/audit/*.jsonl`; `indexer/ship_audit.py` merges them (idempotent on event_id) | Per-developer, on demand or wired to session-end |
| 06 `DB_CONTEXT.SCHEMA_CARDS` | Nightly task inside 06 regenerating cards from ACCOUNT_USAGE / INFORMATION_SCHEMA | Nightly |

01–03 read only from `SNOWFLAKE.ACCOUNT_USAGE` (~2–3 h latency) and need no
feeder; 02's MODEL_PRICING is hand-refreshed from the current Service
Consumption Table.
