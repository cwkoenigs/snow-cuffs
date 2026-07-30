---
name: warmstart
description: "Cheap project initiation: load the pre-built context pack instead of exploring the repo file-by-file, then one code-search query per task concept. Usage: $warmstart"
version: "0.1.0"
author: cwkoenigs
tags:
  - snowcuffs
  - cost-governance
  - session-init
  - context-pack
commands: ["$warmstart"]
user-invocable: true
blocking: false
---

## Objective

Initialize project context at minimum token cost. The context pack (`PROJECT_CONTEXT.md`) is the pre-paid orientation — read it once, then retrieve code with targeted search calls. Bulk file reads at session start are the largest avoidable token cost in a CoCo session (GATE A exists because of them).

## Steps

1. Check whether the session-start hook already injected `PROJECT_CONTEXT.md` into this session's context (the injection is labeled with the snow-cuffs standing instructions). If it did, **do not re-read the file** — cite what is already in context.

2. Otherwise, read `PROJECT_CONTEXT.md` from the project root.

3. If the file is missing, or its generation stamp is older than 30 days, rebuild it and read the result:

   ```bash
   python "${SNOWCUFFS_HOME:-.}/indexer/context_pack.py" --root . --repo <org/name>
   ```

4. For each distinct concept in the task at hand, run **one** code-search query and read only the returned chunks:

   ```sql
   SELECT SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
       'SNOWCUFFS.CODE_INDEX.TEAM_CODE_SEARCH',
       '{"query": "<task concept>", "limit": 5}'
   );
   ```

   Open a full file only when a returned chunk is insufficient — and prefer a ranged read (offset/limit) over the whole file.

5. Prohibitions, in force for the rest of the session:
   - No recursive tree dumps (`tree`, `find .`, `ls -R`) — the pack's layout section is the map.
   - No more than 2 file reads before the first search call.
   - No re-deriving what the pack already states (build commands, directory layout, conventions) — cite the pack's lines instead.

6. Self-report the skill invocation:

   ```bash
   node -e "const c=require('crypto'),f=require('fs');const ts=new Date().toISOString().replace(/\.\d+Z$/,'Z');f.mkdirSync('.snowcuffs/audit',{recursive:true});f.appendFileSync('.snowcuffs/audit/'+ts.slice(0,10)+'.jsonl',JSON.stringify({event_id:c.randomBytes(8).toString('hex'),ts:ts,session_id:process.env.COCO_SESSION_ID||'unknown-'+ts.slice(0,10).replace(/-/g,'')+'-'+process.pid,user_name:process.env.SNOWFLAKE_USER||process.env.USER||null,repo:require('path').basename(process.cwd()),event_type:'skill',tool_name:null,skill_name:'warmstart',payload:{pack:'<injected|read|rebuilt|missing>',pack_age_days:<n>,searches:<n>}})+'\n')"
   ```

## Output

```
$warmstart
─────────────────────────────────────────────────────────────
Context pack:  PROJECT_CONTEXT.md (generated 2026-07-18, 12d old) — injected
               by session-start hook; not re-read.
Task concepts: "retry queue", "billing webhook" → 2 search calls, 9 chunks read
Files opened:  1 (src/billing/webhook.py, chunk was truncated mid-function)

Ready. Standing prohibitions active: no tree dumps, search before reads,
cite the pack instead of re-deriving it.
Audit: skill event appended to .snowcuffs/audit/2026-07-30.jsonl
```

## Anti-Rationalization

| Shortcut / Temptation | Why It Fails |
|-----------------------|--------------|
| Re-read `PROJECT_CONTEXT.md` after the hook injected it | The same tokens billed twice, in the same context window — pure waste |
| Tree-dump the repo "to get oriented" | The pack IS the orientation, built once and amortized; a tree dump pays for a worse map on every session |
| Read files 3..N before the first search | The 8-read session budget (GATE A) exists because bulk reads are the top avoidable token cost; search returns the 5 relevant chunks instead |
| Rebuild the pack when it is fresh | Pack builds cost compute and embedding updates; the 30-day stamp is the trigger, not vibes |
| Re-derive build commands or layout the pack already states | Re-derivation burns tokens to produce a worse copy of what one citation provides |

## Exit Criteria

- [ ] Context pack loaded exactly once (hook injection honored; no double read)
- [ ] Stale/missing pack rebuilt via `$SNOWCUFFS_HOME/indexer/context_pack.py` before use
- [ ] One `TEAM_CODE_SEARCH` query per task concept; chunks read before any full file
- [ ] No tree dumps; at most 2 file reads before the first search
- [ ] `skill` audit event appended to `.snowcuffs/audit/<date>.jsonl`
