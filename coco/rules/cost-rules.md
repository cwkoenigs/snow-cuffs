# snow-cuffs cost rules for Cortex Code

Drop these into your project rules (per-repo CoCo config, or your CocoPlus
project rules) so every agent session inherits cost discipline. Wording is
intentionally imperative — these are instructions to the agent, not docs.

---

## Retrieval before reading

- Before opening more than 2 files to answer a question about our code, query
  the team code search service and read only the returned chunks:
  `SNOWCUFFS.CODE_INDEX.TEAM_CODE_SEARCH` (via `SNOWFLAKE.CORTEX.SEARCH_PREVIEW`
  or the search tool if configured). Open a full file only when a returned
  chunk is insufficient.
- Never paste whole files into a prompt when a chunk or symbol excerpt
  answers the question.

## Model tiering

- Default every `AI_*` / Cortex LLM call to the smallest capable model. Look
  up the current cheapest option with
  `SNOWCUFFS.PUBLIC.CHEAPEST_MODEL_FOR_TIER('small' | 'medium' | 'large')`.
- Use a `large`-tier model only for: multi-step reasoning over ambiguous
  requirements, code generation touching >3 files, or when a smaller model
  demonstrably failed the same task in this session.
- Classification, extraction, routing, and yes/no judgments are `small`-tier
  tasks. Summarization of <5k tokens is `small`; above that, `medium`.

## Pre-flight estimation (mandatory for batch jobs)

- Before running any AI SQL function over a table (not a literal), estimate
  cost first using the `preflight-cost` skill. If the estimate exceeds
  **5 credits**, stop and show the estimate to the user before executing.
- Never run an AI function over a table without a `LIMIT`/sample first to
  validate output quality — wasted full-table runs are the most expensive
  failure mode we have.

## Session hygiene

- Do not re-derive context that is already in the session; do not re-read
  files you have already read unless they changed.
- Prefer one precise search over several broad ones.
- For long tasks, summarize progress and drop stale context rather than
  carrying the entire history forward.
