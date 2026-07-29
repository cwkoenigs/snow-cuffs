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
5. **Agent behavior** — `coco/` ships project rules and a pre-flight skill so
   CoCo (and CocoPlus workflows) search first, use the smallest capable model,
   and estimate cost before batch jobs.

## Repository layout

```
sql/
  01_ai_cost_observability.sql   Spend attribution views (functions, search, CoCo)
  02_preflight_estimation.sql    Pricing table + ESTIMATE_AI_CREDITS() UDF
  03_guardrails.sql              Alerts, resource monitor, budget notes
  04_code_search_service.sql     Code corpus table + Cortex Search service DDL
indexer/
  chunker.py                     Deterministic file→chunk splitter (stable IDs)
  upsert.py                      Incremental MERGE into the corpus table
.github/workflows/
  index-codebase.yml             CI: re-index changed code on merge to main
coco/
  rules/cost-rules.md            Project rules for CoCo: search-first, model tiering
  skills/preflight-cost/SKILL.md Skill: estimate credits before batch AI SQL
  hooks/README.md                Hook patterns for token budgets in sessions
docs/
  strategy.md                    Full assessment: search service, local index,
                                 CocoPlus, semantic layer, rollout phases
```

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
