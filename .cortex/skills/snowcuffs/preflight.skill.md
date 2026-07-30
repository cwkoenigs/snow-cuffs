---
name: preflight
description: "Pre-flight credit estimation and approval gate for batch AI SQL. Prices an AI_* function over a table from a token sample BEFORE running it, shows a cheaper-tier alternative, and gates execution above the configured credit threshold. Usage: $preflight \"<planned AI SQL or description>\""
version: "0.1.0"
author: cwkoenigs
tags:
  - snowcuffs
  - cost-governance
  - preflight
  - finops
commands: ["$preflight"]
user-invocable: true
blocking: true
---

## Objective

Estimate the credit cost of a batch AI SQL job before executing it, offer a cheaper-tier alternative, and stop for explicit user confirmation when the estimate exceeds the configured gate. `AI_COUNT_TOKENS` bills compute only — an estimate costs pennies; a mispriced 10M-row job is discovered on the bill.

If no argument is provided and no AI SQL statement is pending in the conversation, ask: "What job should I price? Example: `$preflight \"ai_complete over SALES.PUBLIC.TICKETS with mistral-large2\"`"

## Steps

1. Identify the target: AI function name (lowercase), model, source table, and prompt/column expression. If any of these is ambiguous, ask before estimating — a guessed model prices the wrong job.

2. Count the source rows:

   ```sql
   SELECT COUNT(*) AS n_rows FROM <db>.<schema>.<table>;
   ```

3. Sample input tokens over a representative sample:

   ```sql
   SELECT AVG(AI_COUNT_TOKENS('<function>', <prompt_expr>)) AS avg_in
   FROM <db>.<schema>.<table> SAMPLE (1000 ROWS);
   ```

   Notes: lowercase function/model names; text inputs only; not supported for legacy `SNOWFLAKE.CORTEX.*` functions or fine-tuned models. For `ai_classify`, include the label array in the expression — labels count as input tokens.

4. State the output-token assumption **out loud** — `AI_COUNT_TOKENS` measures input only, so the output side is your assumption, not a measurement. Say it in the form: "Assuming ~N output tokens per row because <task type>." Reference points: classification/filter ≈ 1–10, short extraction ≈ 50, summaries ≈ 150–500, free-form generation ≈ 500+.

5. Price it:

   ```sql
   SELECT SNOWCUFFS.PUBLIC.ESTIMATE_AI_CREDITS(
       '<function>', '<model>', <avg_in>, <assumed_out>, <n_rows>) AS estimate;
   ```

   If `pricing_updated_at` in the result is older than ~90 days, flag that `SNOWCUFFS.PUBLIC.MODEL_PRICING` should be re-verified against the current Snowflake Service Consumption Table.

6. Re-price with the tier below and show both numbers side by side:

   ```sql
   SELECT SNOWCUFFS.PUBLIC.CHEAPEST_MODEL_FOR_TIER('<tier-below>') AS alt_model;
   SELECT SNOWCUFFS.PUBLIC.ESTIMATE_AI_CREDITS(
       '<function>', <alt_model>, <avg_in>, <assumed_out>, <n_rows>) AS alt_estimate;
   ```

7. Gate. Resolve the threshold: `.snowcuffs/config.json` `preflightGateCredits` (default 5.0); if `cocoplus.toml` sets `[cost] per_session_threshold_credits`, that value wins so both frameworks gate on the same number. If the estimate exceeds the threshold, present both estimates and **stop — require explicit user confirmation before the full run**. Silence is not confirmation.

8. Regardless of the estimate, run a `LIMIT 20` quality probe of the actual statement and show sample outputs before any full-table run. A cheap job with a bad prompt is still a wasted job.

9. Self-report the skill invocation to the audit trail (this is how `SNOWCUFFS.AUDIT.SKILL_ADOPTION` counts adoption):

   ```bash
   node -e "require('./.cortex/hooks/_common.js').auditEvent({event_type:'skill',skill_name:'preflight',payload:{function:'<function>',model:'<model>',rows:<n_rows>,est_credits:<estimate>,gate:'<within|exceeds-approved|exceeds-stopped>'}})"
   ```

   This appends a `{"event_type":"skill","skill_name":"preflight",...}` line to `.snowcuffs/audit/<YYYY-MM-DD>.jsonl` in the shared hook/shipper contract shape.

## Output

```
$preflight · ai_complete over SALES.PUBLIC.TICKETS (842,113 rows)
──────────────────────────────────────────────────────────────────
Sampled input:      avg 512 tokens/row   (SAMPLE (1000 ROWS))
Output assumption:  ~200 tokens/row      (short summary — stated, not measured)

  Model                       Est. credits
  mistral-large2  (medium)          612.4
  llama3.1-8b     (small)            59.7   ← CHEAPEST_MODEL_FOR_TIER('small')

Gate: 612.4 credits EXCEEDS preflightGateCredits (5.0, from cocoplus.toml [cost])
→ Stopping. Confirm explicitly to run the full job, or switch to the small-tier model.
Quality probe: LIMIT 20 run complete — sample outputs shown above.
Audit: skill event appended to .snowcuffs/audit/2026-07-30.jsonl
```

## Anti-Rationalization

| Shortcut / Temptation | Why It Fails |
|-----------------------|--------------|
| Eyeball the row count instead of `COUNT(*)` | The estimate scales linearly with rows; a guessed row count is a guessed bill |
| Leave the output assumption implicit | `AI_COUNT_TOKENS` measures input only — an unstated output guess is the silent half of the bill, and nobody can challenge a number they never saw |
| Skip the cheaper-tier re-price | Tier-down is the single biggest cost lever; showing one number hides the alternative the user would usually pick |
| Treat user silence (or warn mode) as approval | The gate exists to force a decision; proceeding without explicit confirmation is exactly the failure the gate prevents |
| Skip the `LIMIT 20` probe because the estimate is cheap | Wasted full-table runs from bad prompts are the most expensive failure mode at any price point |
| Skip the audit event because the job was small | `SKILL_ADOPTION` and `INIT_COST_COMPARISON` cannot count what never lands in the JSONL |

## Exit Criteria

- [ ] Row count comes from `COUNT(*)`, input tokens from `AI_COUNT_TOKENS` over a sample
- [ ] Output-token assumption stated explicitly with its rationale
- [ ] Requested model AND cheaper-tier alternative priced, both numbers shown
- [ ] Estimate compared to the resolved gate threshold; over-threshold runs stopped pending explicit confirmation
- [ ] `LIMIT 20` quality probe run and sample outputs shown before any full run
- [ ] `skill` audit event appended to `.snowcuffs/audit/<date>.jsonl`
