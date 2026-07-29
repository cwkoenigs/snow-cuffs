# Hook patterns for cost control

You're already writing CoCo hooks — these are the three that pay for
themselves fastest. Pseudocode below; adapt to your CoCo hooks schema (hook
event names and payload fields vary by CoCo version, so wire these to
whatever your version exposes — the *pattern* is the point).

## 1. Big-read interceptor (pre-tool-use)

Fire before file-read / glob-read tool calls. If the call would pull more
than N lines (or M files) into context, block with a message redirecting the
agent to the search service:

> "Reading 14 files (~9k lines) into context. Use TEAM_CODE_SEARCH first and
> read only the matching chunks. Re-run the read only if retrieval fails."

This single hook converts the rules in `coco/rules/cost-rules.md` from
"please" into "must".

## 2. Batch AI SQL gate (pre-tool-use on SQL execution)

Regex the outgoing SQL for `AI_COMPLETE|AI_CLASSIFY|AI_FILTER|AI_AGG|AI_SUMMARIZE`
combined with a `FROM` over a non-literal source and no `LIMIT`/`SAMPLE`.
On match, block and instruct the agent to run the `preflight-cost` skill
first. Allowlist statements that already contain `ESTIMATE_AI_CREDITS` or
`AI_COUNT_TOKENS` so the estimation queries themselves pass.

## 3. Session burn reporter (session-end / stop)

On session end, append the session's token usage to a small team log table
(or just print it), so `SNOWCUFFS.OBSERVABILITY.COCO_SPEND_DAILY` has a
per-session narrative to correlate against. If you run CocoPlus, its Cost
console already tracks per-session tokens — then this hook only needs to
export, not measure.

## Rollout tip

Ship hook 1 in warn-only mode for a week (log what *would* have been
blocked), share the numbers, then flip to blocking. Enforcement lands better
when the team has seen the waste it prevents.
