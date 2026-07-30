# AI cost-reduction strategy

Assessment of the options on the table, why the framework is shaped the way
it is, and a rollout order. Written for the infra owner of an ML/AI team on
Snowflake using Cortex Code (CoCo) CLI + desktop, with skills/hooks already
in play.

## Where agent money actually goes

Agent spend is dominated by **input tokens**: every file read, every retry,
every re-derivation of context is billed again on the next model call. So the
levers rank:

1. Cut context volume per task (retrieval instead of file-stuffing).
2. Route to the smallest capable model.
3. Prevent expensive mistakes (pre-flight estimation, gates).
4. Make waste visible fast (observability, alerts).

Everything below serves one of those four.

## Option 1 — CI/CD-embedded Cortex Search service over the codebase

**Verdict: yes; this is the anchor investment.** (`sql/04`, `indexer/`,
`.github/workflows/index-codebase.yml`)

A code search service turns "read 15 files to find the auth logic" into "one
retrieval call returning 5 chunks". For a team of engineers running CoCo
daily, context reduction compounds on every session.

The design choices that keep the service itself cheap:

- **Content-hash chunk IDs.** Embedding bills per token on insert/update
  only. The indexer never rewrites unchanged chunks, so re-embedding cost
  tracks merge volume, not repo size.
- **One service, code-only corpus.** Serving bills per GB-month of indexed
  data *even at zero queries*. Don't index vendored deps, build output, or
  one service per repo.
- **Generous `TARGET_LAG` (1 day) + CI on merge-to-main only.** Code search
  that's minutes stale is worthless to nobody; refresh compute is real money.

Watch `CORTEX_SEARCH_SPEND_DAILY` after launch: serving cost is flat and
predictable, so if the service costs more per month than the input tokens it
saves (back-of-envelope: chunks-returned vs files-that-would-have-been-read),
prune the corpus.

## Option 2 — simultaneous local embedded index

**Verdict: not as a default — it's double infrastructure for one benefit.**

Maintaining a second, local index means drift management, another embedding
pipeline, and per-laptop state, while saving only the (cheap, bounded)
Cortex Search query cost. The serving idle-tax argument cuts the other way
too: you'd still keep the Cortex service for CI/agents in Snowflake.

Two cases where it *is* worth it, later:

- Retrieval latency in the inner dev loop genuinely hurts.
- You want retrieval with zero marginal cost during heavy local iteration.

If you get there: generate the local index **from the same `CODE_CHUNKS`
artifacts** the CI pipeline produces (export table → embed locally with an
open model → FAISS/sqlite-vec). Same chunker, same IDs — drift bounded by
CI, and the local embedding cost is zero credits. Keep it Phase 5, pull it
forward only on demonstrated pain.

## Option 3 — CocoPlus runtime

**Verdict: adopt, and point snow-cuffs at it.**

CocoPlus gives you structured multi-agent phases (spec → plan → build → test
→ review → ship), per-session token tracking, and the CocoConsole Cost view —
i.e., the *session-level* observability that `ACCOUNT_USAGE` views can't see
(they show credits per user per day, not which workflow burned them).

Integration points with this repo:

- Put `coco/rules/cost-rules.md` into the CocoPlus project rules so every
  persona inherits search-first + model tiering.
- Register the `$preflight` skill (`.cortex/skills/snowcuffs/`) so plan/build phases price batch AI
  SQL before running it.
- Structured phases are themselves a cost feature: a spec/plan phase on a
  small-model budget prevents the expensive failure mode of a large model
  wandering the repo. Watch that multi-agent fan-out doesn't quietly multiply
  tokens — the Cost console makes that visible; set a per-workflow token
  budget and treat overruns as review findings.

## Option 4 — pre-flight cost functions

**Verdict: yes, and make it mandatory, not available.** (`sql/02`, the skill)

`AI_COUNT_TOKENS` (GA Jan 2026) estimates input tokens for an AI SQL call at
compute-only cost. Alone it's trivia; the framework makes it a gate:

- `ESTIMATE_AI_CREDITS()` turns sampled token counts + a pricing table into a
  credit number anyone can read.
- The `preflight-cost` skill makes agents do this automatically; the batch
  AI SQL gate in `.cortex/hooks/pre-tool-use.js` makes it unskippable.
- The 5-credit confirmation threshold is a starting point — tune it.

Limits to keep in mind: input tokens only (output is your assumption), AISQL
functions only (not legacy `SNOWFLAKE.CORTEX.*`, not fine-tuned models), and
the pricing table is only as fresh as your last consumption-table sync.

## Semantic layer over the databases

**Verdict: highest-leverage Phase 4 — do it after the basics are earning.**

For agents that write SQL against your warehouses (Cortex Analyst, CoCo
answering data questions), a semantic layer (semantic views/models: tables,
joins, metrics, synonyms) is a cost feature disguised as a correctness
feature: without it, agents burn tokens exploring `INFORMATION_SCHEMA`,
retrying wrong joins, and re-deriving metric definitions per session. With
it, one small retrieval replaces that exploration — same shape as the code
search win, applied to your data estate.

Start with the 2-3 schemas your team queries most through AI, measure the
retry-rate drop, then expand. Full-estate modeling up front is how semantic
layers die.

## Rollout order

| Phase | What | Why this order |
|-------|------|----------------|
| 0 | `sql/01` observability + `sql/03` guardrails | Baseline before/after; alerts catch anomalies from day one |
| 1 | `sql/02` estimator + `preflight-cost` skill + AI SQL gate hook | Stops the worst single-event losses immediately, cheap to ship |
| 2 | `sql/04` search service + CI indexer, starting with 1-2 highest-traffic repos | The anchor lever; per-repo rollout keeps the corpus lean |
| 3 | Cost rules + big-read hook into CoCo/CocoPlus project config | Converts the search service from "available" to "default behavior" |
| 4 | Semantic layer over the top AI-queried schemas | Biggest remaining token sink once code retrieval is solved |
| 5 | Local embedded index (only on demonstrated latency/offline pain) | Optional; derived from Phase 2 artifacts, never parallel-built |

Success metric: **credits per merged PR** (or per completed workflow) from
`AI_SPEND_ROLLUP_DAILY`, not raw daily credits — raw spend should be allowed
to grow with adoption; waste per unit of work is what you're cutting.
