---
name: cuffs
description: "snow-cuffs session cost status — files read vs search calls, blocks, gate configuration, and enforcement mode, from local .snowcuffs/ state. Usage: $cuffs"
version: "0.1.0"
author: cwkoenigs
tags:
  - snowcuffs
  - cost-governance
  - status
commands: ["$cuffs"]
user-invocable: true
blocking: false
---

## Objective

Show the developer where this session stands against the snow-cuffs cost gates: how many files have been read vs how many search calls were made, what was blocked, and which enforcement mode is active. This is a behavior report, not a token report — token detail belongs to CocoMeter.

Before proceeding, verify that `.snowcuffs/` exists. If not, output: "No .snowcuffs/ state found — the snow-cuffs hooks have not run here yet. Check the plugin is installed (see INSTALLATION.md) and start a new session." Then stop.

## Steps

1. Load configuration. Read `.snowcuffs/config.json` and merge over the built-in defaults (`mode: warn`, `maxReadLines: 400`, `maxSessionReads: 8`, `searchGraceReads: 8`, `preflightGateCredits: 5.0`). If `cocoplus.toml` exists and `[cost] per_session_threshold_credits` is set, that value overrides `preflightGateCredits` — report which source won.

2. Read the current session's counters from `.snowcuffs/state/session-<id>.json` (the file matching the current session id; if unknown, the most recently modified file in `.snowcuffs/state/`). Report `files_read`, `est_lines_read`, `search_calls`, `search_calls_since_flood` (grace reads remaining), and `blocks`.

3. Tally today's audit events (UTC date) from `.snowcuffs/audit/<YYYY-MM-DD>.jsonl`:

   ```bash
   node -e 'const fs=require("fs");const f=".snowcuffs/audit/"+new Date().toISOString().slice(0,10)+".jsonl";const c={};try{for(const l of fs.readFileSync(f,"utf8").split("\n")){if(!l.trim())continue;const e=JSON.parse(l);c[e.event_type]=(c[e.event_type]||0)+1}}catch(_){}console.log(JSON.stringify(c))'
   ```

   Report counts per `event_type` — especially `blocked_big_read` and `blocked_batch_ai_sql` (the expensive mistakes that did not happen) and `skill` (adoption signal).

4. Check `.snowcuffs/audit/` for unshipped `*.jsonl` files older than today; if any exist, suggest `$cuffs ship`.

5. CocoPlus integration check: if `.cocoplus/meter/request-map.jsonl` exists, note that CocoPlus metering is active and `$meter view` has the token-level detail — do not duplicate it here. `$cuffs` reports behavior (reads, searches, blocks); CocoMeter reports tokens and credits.

## Output

```
snow-cuffs · session cost status                          mode: warn
─────────────────────────────────────────────────────────────────────
Session sess-4f2a1 (started 2026-07-30T14:02:11Z)
  files_read:       6 / 8 before a search is required
  est_lines_read:   1,240
  search_calls:     2        grace reads remaining: 5
  blocks:           0

Today (.snowcuffs/audit/2026-07-30.jsonl)
  tool: 41   skill: 3   blocked_big_read: 1   blocked_batch_ai_sql: 0

Gates
  GATE A big-read:  maxReadLines=400  maxSessionReads=8  grace=8
  GATE B batch-AI:  $preflight approval gate at 5.0 credits
                    (source: cocoplus.toml [cost] per_session_threshold_credits)

2 unshipped audit files — run $cuffs ship to update SNOWCUFFS.AUDIT.
CocoPlus metering active — run $meter view for token-level detail.
```

## Anti-Rationalization

| Shortcut / Temptation | Why It Fails |
|-----------------------|--------------|
| Summarize counters from memory instead of reading the state files | The hooks own the ledger; a from-memory summary reports what the session *feels* like, not what the gates counted |
| Quote token or credit spend from these counters | snow-cuffs counts behavior; tokens live in CocoMeter and ACCOUNT_USAGE — inventing token numbers here double-counts and contradicts `$meter` |
| Skip the audit tally because state files exist | State holds per-session counters only; blocks and skill events for the day live in the audit JSONL |
| Hide warn-mode warnings because nothing was blocked | Warn-mode events are the evidence base for the warn→block rollout decision; they are the point of warn mode |

## Exit Criteria

- [ ] Enforcement mode shown, with the resolved `preflightGateCredits` and its source (config.json default vs cocoplus.toml `[cost]`)
- [ ] Current session counters shown: files_read, est_lines_read, search_calls, grace reads remaining, blocks
- [ ] Today's audit event tally shown by event_type
- [ ] Unshipped audit files flagged with `$cuffs ship` suggestion when present
- [ ] `$meter view` cross-reference shown when `.cocoplus/meter/request-map.jsonl` exists — no token numbers duplicated
