---
name: cuffs-chargeback
description: "Team chargeback by user/day/surface: joins CocoPlus meter attribution (when active) with SNOWCUFFS.OBSERVABILITY spend views. Usage: $cuffs chargeback [--days N]"
version: "0.1.0"
author: cwkoenigs
tags:
  - snowcuffs
  - cost-governance
  - chargeback
  - finops
  - cocoplus-integration
commands: ["$cuffs chargeback"]
user-invocable: true
blocking: false
---

## Objective

Produce a team chargeback table — credits by user, day, and surface — by joining CocoPlus's local request attribution with the account-level spend views in `SNOWCUFFS.OBSERVABILITY`. This is the integration join: CocoMeter owns token attribution, snow-cuffs owns the account-level rollup; this skill combines them instead of re-metering.

Default window is 14 days; honor `--days N` if provided.

## Steps

1. Read CocoPlus attribution from `.cocoplus/meter/request-map.jsonl` (read-only — snow-cuffs never writes under `.cocoplus/`). If the file is absent or empty, output: "CocoPlus metering not active — run $meter on; falling back to per-user ACCOUNT_USAGE." and continue with steps 2–5 in fallback mode (per-user/day granularity only, no session/stage attribution).

2. Query per-user CoCo spend by day and surface:

   ```sql
   SELECT usage_date, user_name, surface, SUM(token_credits) AS coco_credits
   FROM SNOWCUFFS.OBSERVABILITY.COCO_SPEND_DAILY
   WHERE usage_date >= DATEADD('day', -14, CURRENT_DATE())
   GROUP BY 1, 2, 3
   ORDER BY 1 DESC, 4 DESC;
   ```

3. Pull the rollup for context — what share of total AI spend the CoCo line is:

   ```sql
   SELECT usage_date, source, credits
   FROM SNOWCUFFS.OBSERVABILITY.AI_SPEND_ROLLUP_DAILY
   WHERE usage_date >= DATEADD('day', -14, CURRENT_DATE())
   ORDER BY 1 DESC, 3 DESC;
   ```

   The rollup includes non-CoCo sources (`ai_functions`, `cortex_search`, `cortex_analyst`, ...) — it is context, not the chargeback base. Only `COCO_SPEND_DAILY` rows are charged to users here.

4. If meter attribution is active, join it in: request-map entries attribute each user's day of credits to the sessions/stages that spent them, refining "whose day" into "which work". Where a day has credits but no request-map entries (other machine, metering off part of the day), label the remainder `unattributed` — do not spread it proportionally.

5. Output a markdown table by user/day/surface (attribution column only when metering is active), followed by the rollup context line.

6. Latency note — always include it: the `ACCOUNT_USAGE` Cortex Code usage views lag ~2–3 hours (the same latency window `$meter sync` waits out). Today's rows are incomplete; label the trailing day provisional.

## Output

```
$cuffs chargeback · last 14 days
─────────────────────────────────────────────────────────────────────

| date       | user     | surface | credits | attribution            |
|------------|----------|---------|---------|------------------------|
| 2026-07-30 | ML_KAI   | cli     |   3.12* | sess-4f2a1 (feat/etl)  |
| 2026-07-30 | ML_PRIYA | desktop |   1.88* | sess-9c07d, +unattrib. |
| 2026-07-29 | ML_KAI   | cli     |   5.40  | sess-1a44e (backfill)  |
| 2026-07-29 | ML_JUN   | cli     |   2.05  | unattributed           |

* provisional — ACCOUNT_USAGE lags ~2–3h; re-run after the window (cf. $meter sync)

Context (AI_SPEND_ROLLUP_DAILY, 14d): cortex_code 41.2 cr of 96.7 cr total
(ai_functions 38.1, cortex_search 12.3, cortex_analyst 5.1)
```

## Anti-Rationalization

| Shortcut / Temptation | Why It Fails |
|-----------------------|--------------|
| Present today's numbers as final | The usage views lag ~2–3h — quoting the trailing day as complete under-bills it and erodes trust in the whole table |
| Rebuild token attribution instead of reading request-map.jsonl | CocoMeter owns attribution; a second implementation drifts from `$meter` and the two reports contradict each other |
| Charge the whole rollup to CoCo users | `AI_SPEND_ROLLUP_DAILY` includes AI SQL, search serving, and Analyst spend that no CoCo user caused — chargeback base is `COCO_SPEND_DAILY` only |
| Spread unattributed credits proportionally across sessions | Fabricated attribution is worse than labeled uncertainty; `unattributed` is a signal to turn `$meter on` everywhere |
| Skip the fallback when metering is inactive | Per-user `ACCOUNT_USAGE` still supports a real per-user/day chargeback — coarser, but honest |

## Exit Criteria

- [ ] Meter attribution read from `.cocoplus/meter/request-map.jsonl`, or the exact fallback line shown and per-user fallback used
- [ ] Chargeback base is `COCO_SPEND_DAILY` by user/day/surface; rollup shown as context only
- [ ] Markdown table output, with attribution column when metering is active and `unattributed` labeled honestly
- [ ] ~2–3h ACCOUNT_USAGE latency note included, trailing day marked provisional
- [ ] Nothing written under `.cocoplus/`
