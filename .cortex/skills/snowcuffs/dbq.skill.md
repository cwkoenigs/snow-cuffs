---
name: dbq
description: "Answer a data question at minimum credit cost: retrieve schema cards from Cortex Search instead of crawling the catalog, prefer Cortex Analyst where a semantic model exists, draft one validated query. Usage: $dbq \"<data question>\""
version: "0.1.0"
author: cwkoenigs
tags:
  - snowcuffs
  - cost-governance
  - schema-retrieval
  - data-questions
commands: ["$dbq"]
user-invocable: true
blocking: false
---

## Objective

Answer a data question ("which table has X", "how many Y per Z") by retrieving the relevant schema cards, not by crawling metadata or sampling tables. Discovery should cost one search call; the query should be drafted once and validated cheaply before any full run.

If no question is provided, ask: "What is the data question? Example: `$dbq \"daily active users by plan tier\"`"

## Steps

1. Retrieve candidate tables from the schema card index:

   ```sql
   SELECT SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
       'SNOWCUFFS.DB_CONTEXT.DB_SCHEMA_SEARCH',
       '{"query": "<the data question in plain words>", "limit": 5}'
   );
   ```

   NEVER crawl `INFORMATION_SCHEMA` or run `SHOW TABLES` across databases to discover schema — the card index exists so discovery costs one search call instead of a metadata crawl. Sole exception: a scoped `SHOW TABLES IN SCHEMA <db>.<schema>` when you have concrete reason to believe a table is newer than the nightly card refresh.

2. Check the returned cards for a covering semantic view/model. If one covers the domain, prefer Cortex Analyst — ask it the question and stop. The semantic model amortizes the join knowledge; do not hand-rebuild it.

3. Draft **one** query from the cards (columns, join keys, and grain come from the card text, not from guessing). Validate it cheaply:

   ```sql
   <drafted query>
   LIMIT 100;
   ```

   Run the full query only if the limited result is insufficient to answer (aggregations over the full table need the full run; eyeballing row shape does not).

4. On a wrong join or empty result, re-retrieve that specific table's card attribute-filtered — do not start sampling the table with ad-hoc `SELECT`s to reverse-engineer its shape:

   ```sql
   SELECT SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
       'SNOWCUFFS.DB_CONTEXT.DB_SCHEMA_SEARCH',
       '{"query": "<table_name> join keys grain", "filter": {"@eq": {"table_name": "<TABLE_NAME>"}}, "limit": 1}'
   );
   ```

5. If the answer requires AI-function post-processing of the results (`ai_classify` over a result column, `ai_agg` over rows, ...), route that step through `$preflight` before running it — GATE B will redirect you there anyway.

6. Self-report the skill invocation:

   ```bash
   node -e "require('./.cortex/hooks/_common.js').auditEvent({event_type:'skill',skill_name:'dbq',payload:{question:'<short question>',tables:['<TABLE_1>','<TABLE_2>'],path:'<analyst|sql>'}})"
   ```

## Output

```
$dbq · "daily active users by plan tier"
─────────────────────────────────────────────────────────────
Schema cards (1 search call): PROD.CORE.USER_EVENTS, PROD.BILLING.PLANS
Path: SQL (no semantic model covers activity × billing)

Query (validated with LIMIT 100, then full run):
  SELECT e.event_date, p.plan_tier, COUNT(DISTINCT e.user_id) AS dau
  FROM PROD.CORE.USER_EVENTS e
  JOIN PROD.BILLING.PLANS p ON p.user_id = e.user_id
  GROUP BY 1, 2 ORDER BY 1 DESC;

Result: 90 rows — <answer summary>
Audit: skill event appended to .snowcuffs/audit/2026-07-30.jsonl
```

## Anti-Rationalization

| Shortcut / Temptation | Why It Fails |
|-----------------------|--------------|
| `SHOW TABLES` across databases "to be thorough" | The card index exists precisely so discovery costs one search call; a catalog crawl pays warehouse time and floods context with irrelevant names |
| Sample the table to figure out the join key | The card states the join key; ad-hoc sampling is the expensive way to read documentation |
| Skip `LIMIT 100` validation because the query looks right | A wrong full-table join bills the full scan; validation costs pennies and catches the join before the bill |
| Hand-write SQL when a semantic model covers the domain | Cortex Analyst amortizes the domain's join logic; re-deriving it burns tokens and risks a silently wrong answer |
| Post-process results with an inline `AI_*` call since the data is "already here" | Unbounded AI functions over result sets are exactly what GATE B and `$preflight` exist to price first |
| Draft several exploratory queries in parallel | One card-grounded query beats N guesses; each guess is a billed scan |

## Exit Criteria

- [ ] Table discovery done via `DB_SCHEMA_SEARCH` (or Cortex Analyst), not catalog crawling
- [ ] Semantic-model check performed before hand-writing SQL
- [ ] Exactly one drafted query, validated with `LIMIT 100` before any full run
- [ ] Join/empty-result failures handled by attribute-filtered card re-retrieval, not table sampling
- [ ] Any AI-function post-processing routed through `$preflight`
- [ ] `skill` audit event appended to `.snowcuffs/audit/<date>.jsonl`
