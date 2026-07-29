---
name: preflight-cost
description: >
  Estimate the credit cost of a Cortex AI SQL job BEFORE running it. Use
  whenever the user (or a plan step) is about to run AI_COMPLETE, AI_CLASSIFY,
  AI_FILTER, AI_AGG, or any Cortex LLM function over a table rather than a
  literal, or asks "what would this cost".
---

# Pre-flight cost estimation

Estimate before executing. `AI_COUNT_TOKENS` bills compute only — an estimate
costs pennies; a mispriced 10M-row job costs thousands of credits.

## Procedure

1. Identify the target: AI function name (lowercase), model, source table,
   prompt/column expression, and expected row count
   (`SELECT COUNT(*) FROM <table>` if unknown).

2. Sample input tokens (adjust sample size to table size; 1000 is plenty):

   ```sql
   SELECT AVG(AI_COUNT_TOKENS('<function>', <prompt_expr>)) AS avg_in
   FROM <table> SAMPLE (1000 ROWS);
   ```

   Notes: lowercase function/model names; text inputs only; not supported for
   legacy `SNOWFLAKE.CORTEX.*` functions or fine-tuned models. For
   `ai_classify`, pass the label array too — labels count as input tokens.

3. Assume output tokens per row. State the assumption explicitly:
   classification/filter ≈ 1–10; short extraction ≈ 50; summaries ≈ 150–500;
   free-form generation ≈ 500+.

4. Price it:

   ```sql
   SELECT SNOWCUFFS.PUBLIC.ESTIMATE_AI_CREDITS(
       '<function>', '<model>', <avg_in>, <expected_out>, <row_count>);
   ```

5. Report to the user: estimated credits, the assumptions (sample avg,
   output guess), and the cheaper-model alternative — re-run step 4 with
   `SNOWCUFFS.PUBLIC.CHEAPEST_MODEL_FOR_TIER(...)` and show both numbers.

6. **Gate:** if the estimate exceeds 5 credits, do not execute until the user
   confirms. Whatever the estimate, run a small `LIMIT 20` quality probe and
   show sample outputs before the full job.

## Caveats to always mention

- Input-only: output tokens are your assumption, not a measurement.
- Pricing comes from `SNOWCUFFS.PUBLIC.MODEL_PRICING`; if `pricing_updated_at`
  is older than ~90 days, flag that rates should be re-verified against the
  current Snowflake Service Consumption Table.
