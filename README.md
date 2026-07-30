# snow-cuffs

Cost-control infrastructure for AI/ML teams running on Snowflake Cortex.

snow-cuffs is a framework for **measuring, estimating, and reducing** AI spend
across Cortex AI SQL functions, Cortex Code (CoCo) CLI/desktop sessions, and
Cortex Search. It combines Snowflake-side infrastructure (observability views,
pre-flight cost estimation, guardrails, a code search service) with CoCo-native
assets (project rules, skills, hook guidance) that steer agents toward cheap
behavior by default.

## The cost levers, in order of impact

1. **Measure before you optimize** — you cannot cut what you cannot attribute.
   `sql/01_ai_cost_observability.sql` builds per-user / per-model / per-day
   spend views over `SNOWFLAKE.ACCOUNT_USAGE`, covering every surface people
   spend through: AI SQL functions, CoCo (CLI, desktop, and Snowsight),
   Cortex Analyst, Cortex Agents, the Cortex REST API, and Cortex Search.
2. **Estimate before you run** — `AI_COUNT_TOKENS` (GA Jan 2026) returns the
   input-token count of a prompt *before* execution, at compute-only cost.
   `sql/02_preflight_estimation.sql` wraps it with a model pricing table into a
   one-call credit estimator, so a 10M-row `AI_COMPLETE` job gets priced from a
   1,000-row sample instead of discovered on the bill.
3. **Retrieval instead of context-stuffing** — a Cortex Search service over
   your codebase (`sql/04_code_search_service.sql` + `indexer/` + CI workflow)
   lets CoCo pull the 5 relevant chunks instead of reading 50 files into
   context. Input tokens are the bulk of agent spend; this is the biggest
   structural lever for CoCo sessions.
4. **Guardrails** — resource monitors, alerts on daily token-credit burn, and
   budget hooks (`sql/03_guardrails.sql`) so anomalies surface in hours, not at
   month-end.
5. **Agent behavior, enforced** — snow-cuffs is an installable CoCo plugin
   (`plugin.json` + `.cortex/`): Node hooks that block context-stuffing reads
   and un-estimated batch AI SQL (off → warn → block rollout), a one-shot stop
   gate that asks for estimate-vs-actual reconciliation at handoff, and six
   `$`-invocable skills (`$cuffs`, `$preflight`, `$dbq`, `$warmstart`,
   `$cuffs ship`, `$cuffs chargeback`) in CocoPlus's native idiom.

## Repository layout

```
plugin.json                      snow-cuffs as an installable CoCo plugin (entry: .cortex/)
.cortex/
  hooks/                         Node hooks: big-read guard + batch-AI-SQL gate
                                 (pre-tool-use), search/AI-run tracking (post-tool-use),
                                 context-pack injection (session-start), burn report +
                                 one-shot stop gate (session-end, stop)
  skills/snowcuffs/              $cuffs · $preflight · $dbq · $warmstart ·
                                 $cuffs ship · $cuffs chargeback (CocoPlus .skill.md idiom)
templates/
  snowcuffs.toml.template        Config defaults (mode, budgets, service names)
  AGENTS-snowcuffs.md.template   Standing cost rules to append to a project's AGENTS.md
sql/
  01_ai_cost_observability.sql   Spend views: AI functions, CoCo (CLI/desktop/Snowsight),
                                 Analyst, Agents, REST API, Search + daily rollup
  02_preflight_estimation.sql    Pricing table + ESTIMATE_AI_CREDITS() UDF
  03_guardrails.sql              Alerts, resource monitor, budget notes
  04_code_search_service.sql     Code corpus table + TEAM_CODE_SEARCH service DDL
  05_usage_audit.sql             AGENT_EVENTS + skill-adoption/session-hygiene views
  06_schema_context_service.sql  Schema cards + DB_SCHEMA_SEARCH service + nightly task
indexer/
  chunker.py                     Deterministic file→chunk splitter (stable IDs)
  upsert.py                      Incremental MERGE into the corpus table
  ship_audit.py                  Idempotent audit JSONL → SNOWCUFFS.AUDIT shipper
  context_pack.py                PROJECT_CONTEXT.md generator (session warm-start)
.github/workflows/
  index-codebase.yml             CI: re-index changed code on merge to main
docs/
  strategy.md                    Full assessment: search service, local index,
                                 CocoPlus, semantic layer, rollout phases
INSTALLATION.md                  Plugin install + SQL deploy + rollout runbook
```

See `INSTALLATION.md` for the full setup; the SQL side alone also works standalone:

## Quickstart

```sql
-- 1. Deploy observability (needs ACCOUNT_USAGE access)
!source sql/01_ai_cost_observability.sql

-- 2. Deploy the estimator
!source sql/02_preflight_estimation.sql

-- 3. Price a batch job before running it
SELECT SNOWCUFFS.PUBLIC.ESTIMATE_AI_CREDITS(
  'ai_complete', 'claude-3-5-sonnet',
  (SELECT AVG(AI_COUNT_TOKENS('ai_complete', prompt_col)) FROM my_table SAMPLE (1000 ROWS)),
  500,            -- expected output tokens per row
  10000000        -- row count
);
```

Then set up the code search service and CI indexing per `docs/strategy.md`.

## Design principles

- **Incremental everything.** Embedding is billed per token on insert/update;
  chunk IDs are content hashes so unchanged code never re-embeds.
- **One search service, small corpus.** Cortex Search bills GB/month for
  serving even at zero queries. Index code, not build artifacts.
- **Estimates are estimates.** `AI_COUNT_TOKENS` covers input tokens only;
  output tokens are assumptions you supply. Treat results as ±20%.
- **Pricing is data, not code.** Credits-per-million-token rates live in a
  table seeded with illustrative values — refresh them from the current
  Snowflake Service Consumption Table before trusting any estimate.
