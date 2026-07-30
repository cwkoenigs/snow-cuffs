---
name: cuffs-ship
description: "Ship local .snowcuffs/audit/*.jsonl events to SNOWCUFFS.AUDIT.AGENT_EVENTS so the team-level audit views update. Usage: $cuffs ship"
version: "0.1.0"
author: cwkoenigs
tags:
  - snowcuffs
  - cost-governance
  - audit
  - shipping
commands: ["$cuffs ship"]
user-invocable: true
blocking: false
---

## Objective

Merge the locally accumulated audit events into `SNOWCUFFS.AUDIT.AGENT_EVENTS`. Local JSONL is the per-machine buffer; the Snowflake table is the team ledger the `SNOWCUFFS.AUDIT` views read. Shipping is idempotent (MERGE on `event_id`), so it is always safe to run.

## Steps

1. Check `.snowcuffs/audit/` for unshipped `*.jsonl` files (shipped files are renamed `*.jsonl.shipped` and skipped). If there are none, output: "Nothing to ship — no unshipped audit files in .snowcuffs/audit/." Then stop.

2. Verify Snowflake auth is available in the environment: `SNOWFLAKE_ACCOUNT`, `SNOWFLAKE_USER`, and `SNOWFLAKE_PRIVATE_KEY` or `SNOWFLAKE_PASSWORD` (optional `SNOWFLAKE_ROLE`, `SNOWFLAKE_WAREHOUSE`). If missing, report which variable is absent and stop — do not prompt for credentials in-chat.

3. Run the shipper:

   ```bash
   python "${SNOWCUFFS_HOME:-.}/indexer/ship_audit.py" --audit-dir .snowcuffs/audit
   ```

4. Report from the shipper's output: files shipped, rows merged (new vs duplicate — duplicates are skipped by the MERGE on `event_id`), and corrupt lines skipped. A non-zero corrupt count means an emitting hook is malformed — flag it, do not hand-edit the lines.

5. Remind the developer that the `SNOWCUFFS.AUDIT` views update once the ship lands — `SKILL_ADOPTION`, `SESSION_HYGIENE`, and `SEARCH_BYPASS_LEADERBOARD` are the ones to check:

   ```sql
   SELECT * FROM SNOWCUFFS.AUDIT.SKILL_ADOPTION ORDER BY invocations_30d DESC;
   SELECT * FROM SNOWCUFFS.AUDIT.SESSION_HYGIENE ORDER BY ended_at DESC LIMIT 20;
   SELECT * FROM SNOWCUFFS.AUDIT.SEARCH_BYPASS_LEADERBOARD;
   ```

## Output

```
$cuffs ship
─────────────────────────────────────────────────────────────
Files shipped:  3   (renamed *.jsonl.shipped)
Rows merged:    128 new / 12 duplicate (skipped by MERGE on event_id)
Corrupt lines:  0

SNOWCUFFS.AUDIT views now reflect the ship:
  SELECT * FROM SNOWCUFFS.AUDIT.SKILL_ADOPTION ORDER BY invocations_30d DESC;
  SELECT * FROM SNOWCUFFS.AUDIT.SESSION_HYGIENE ORDER BY ended_at DESC LIMIT 20;
  SELECT * FROM SNOWCUFFS.AUDIT.SEARCH_BYPASS_LEADERBOARD;
```

## Anti-Rationalization

| Shortcut / Temptation | Why It Fails |
|-----------------------|--------------|
| Re-ship `*.jsonl.shipped` files "just in case" | MERGE on `event_id` makes duplicates harmless, but re-parsing shipped files wastes compute — the rename exists so the next run skips them |
| Hand-edit corrupt lines to make them ship | Corrupt lines are evidence of a broken emitter; fix the hook, don't launder its output into the ledger |
| Wait until end of day to ship | The MERGE is insert-only on `event_id` — partial-day ships are safe and keep the team views fresh |
| Skip the auth check and let the shipper fail | The shipper's connection error is slower and noisier than checking four env vars first |

## Exit Criteria

- [ ] `$SNOWCUFFS_HOME/indexer/ship_audit.py --audit-dir .snowcuffs/audit` run (or "nothing to ship" reported)
- [ ] Rows merged reported, split new vs duplicate; corrupt-line count reported
- [ ] Shipped files confirmed renamed to `*.jsonl.shipped`
- [ ] Developer reminded that SKILL_ADOPTION, SESSION_HYGIENE, and SEARCH_BYPASS_LEADERBOARD update after ship, with the sanity queries shown
