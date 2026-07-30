#!/usr/bin/env node
/**
 * snow-cuffs PreToolUse hook — cross-platform (Node.js)
 *
 * Stdin JSON format from Coco:
 *   { "tool": "SnowflakeSqlExecute", "parameters": { "sql": "..." }, "session_id": "sess-..." }
 *   { "tool": "Read", "parameters": { "file_path": "..." }, "session_id": "sess-..." }
 *
 * Stdout JSON response (exactly one line):
 *   {"action":"allow"}
 *   {"action":"block","reason":"..."}
 *   {"action":"allow","warning":"..."}
 *
 * Two cost gates, mode from .snowcuffs/config.json (off | warn | block):
 *   GATE A — big-read guard. Bulk file reads are the largest avoidable token
 *     cost in a CoCo session. Reads past the per-file or per-session line
 *     budget are redirected to the Cortex Search code index; a completed
 *     search replenishes a grace budget of further reads.
 *   GATE B — batch-AI-SQL gate. An unbounded AI_* function over a full table
 *     is the largest avoidable credit cost. Unbounded calls are redirected to
 *     $preflight, which estimates credits with AI_COUNT_TOKENS +
 *     SNOWCUFFS.PUBLIC.ESTIMATE_AI_CREDITS before any batch run.
 *
 * Anything else is allowed fast. Malformed stdin allows. Must complete in
 * <100ms — structural checks only, no child processes, no network.
 * Fail-open: any hook error results in {"action":"allow"}.
 */

'use strict';

const fs   = require('fs');
const path = require('path');
const {
  isoUtc,
  readStdinJson,
  respond,
  logError,
  loadConfig,
  sessionIdFrom,
  sessionState,
  saveSessionState,
  auditEvent,
} = require('./_common.js');

const READ_TOOLS      = ['Read', 'NotebookRead'];
const LINE_SCAN_CAP   = 1024 * 1024; // count lines over at most 1MB, extrapolate beyond
const MISSING_FILE_EST = 200;        // assumed line count when the file is not local

/**
 * GATE B structural SQL patterns. These are deliberately regex-level, not a
 * SQL parser, to stay inside the <100ms hook budget.
 *
 * Known false negatives (documented, accepted — $preflight discipline and the
 * audit shipper catch what slips through). The LIMIT/SAMPLE/TOP check is
 * statement-global, so a bound anywhere suppresses the gate even when it does
 * not bound the rows the AI function scans:
 *   1. CTE-wrapped: `WITH t AS (SELECT ... FROM small LIMIT 10)
 *      SELECT AI_COMPLETE(...) FROM full_table` — the CTE's LIMIT satisfies
 *      the check while the AI scan over full_table stays unbounded.
 *   2. Nested subquery with the limit on the outer leg: `SELECT x FROM
 *      (SELECT AI_COMPLETE(...) AS x FROM huge_table) LIMIT 5` — the outer
 *      LIMIT satisfies the check, but the inner AI scan runs over every row
 *      before the limit applies.
 * Note `FROM (subquery)` itself is still caught when the subquery contains a
 * plain `FROM <identifier>` — only the limit placement is blind, not the
 * nesting. Fixing either case would require a real SQL parser, which does not
 * fit the <100ms structural budget.
 */
const AI_FUNCTION_RE = /AI_(COMPLETE|CLASSIFY|FILTER|AGG|SUMMARIZE|EXTRACT|SENTIMENT|TRANSLATE)\s*\(/i;
const FROM_TABLE_RE  = /\bFROM\s+(?!\()"?[A-Za-z_][A-Za-z0-9_$]*"?(\s*\.\s*"?[A-Za-z_][A-Za-z0-9_$]*"?){0,2}/i;
const ROW_BOUND_RE   = /\b(LIMIT|SAMPLE|TOP)\b/i;
const ESTIMATION_RE  = /\b(AI_COUNT_TOKENS|ESTIMATE_AI_CREDITS)\b/i;

// Exactly-one-response guard: the fail-open catch below calls allow(), so the
// helpers must be idempotent to keep stdout a single JSON object.
let responded = false;

function allow(warning) {
  if (responded) return;
  responded = true;
  respond(warning ? { action: 'allow', warning } : { action: 'allow' });
}

function block(reason) {
  if (responded) return;
  responded = true;
  respond({ action: 'block', reason });
}

/**
 * Count lines of a local file, reading at most LINE_SCAN_CAP bytes and
 * extrapolating for larger files. Returns null when the file is missing or
 * unreadable (caller falls back to MISSING_FILE_EST).
 */
function countFileLines(filePath) {
  let fd = null;
  try {
    const stat = fs.statSync(filePath);
    if (!stat.isFile()) return null;
    if (stat.size === 0) return 0;
    const bytes = Math.min(stat.size, LINE_SCAN_CAP);
    fd = fs.openSync(filePath, 'r');
    const buf = Buffer.alloc(bytes);
    const read = fs.readSync(fd, buf, 0, bytes, 0);
    let lines = 0;
    let offset = 0;
    while (offset < read) {
      const nl = buf.indexOf(10, offset);
      if (nl === -1) break;
      lines++;
      offset = nl + 1;
    }
    if (read > 0 && buf[read - 1] !== 10) lines++; // trailing partial line
    if (stat.size > bytes) lines = Math.round(lines * (stat.size / bytes));
    return lines;
  } catch (_) {
    return null;
  } finally {
    if (fd !== null) { try { fs.closeSync(fd); } catch (_) { /* ignore */ } }
  }
}

/** GATE A — big-read guard. Returns true when it produced the response. */
function bigReadGuard(config, sessionId, toolName, params, ts) {
  const filePath = params.file_path || '';
  if (!filePath) { allow(); return true; }

  const counted   = countFileLines(filePath);
  const lineCount = counted === null ? MISSING_FILE_EST : counted;
  const state     = sessionState(sessionId);

  const singleTooBig = lineCount > config.maxReadLines;
  const sessionFlood = state.files_read >= config.maxSessionReads;

  if (!singleTooBig && !sessionFlood) {
    state.files_read     += 1;
    state.est_lines_read += lineCount;
    saveSessionState(sessionId, state);
    allow();
    return true;
  }

  // Flood condition — a completed search grants searchGraceReads reads,
  // consumed one per gated read here and replenished by post-tool-use.
  if (state.search_calls_since_flood > 0) {
    state.search_calls_since_flood -= 1;
    state.files_read     += 1;
    state.est_lines_read += lineCount;
    saveSessionState(sessionId, state);
    allow();
    return true;
  }

  const detail = singleTooBig
    ? `${filePath} is ~${lineCount} lines (per-file budget: ${config.maxReadLines})`
    : `${state.files_read} files already read this session (per-session budget before a search: ${config.maxSessionReads})`;
  const reason =
    `snow-cuffs big-read guard: ${detail}. Search before you read — run:\n` +
    `SELECT SNOWFLAKE.CORTEX.SEARCH_PREVIEW('${config.codeSearchService}', ` +
    `'{"query": "<what you are looking for>", "limit": 5}');\n` +
    `A completed search grants another ${config.searchGraceReads} reads. ` +
    `If you only need part of this file, re-read with offset/limit.`;

  auditEvent({
    ts,
    session_id: sessionId,
    event_type: 'blocked_big_read',
    tool_name:  toolName,
    payload: {
      file_path:      filePath,
      est_lines:      lineCount,
      files_read:     state.files_read,
      single_too_big: singleTooBig,
      session_flood:  sessionFlood,
      mode:           config.mode,
      enforced:       config.mode === 'block',
    },
  });

  if (config.mode === 'block') {
    state.blocks += 1;
    saveSessionState(sessionId, state);
    block(reason);
  } else {
    // warn mode: the read proceeds, so counters still accumulate
    state.files_read     += 1;
    state.est_lines_read += lineCount;
    saveSessionState(sessionId, state);
    allow(reason);
  }
  return true;
}

/** GATE B — batch-AI-SQL gate. Returns true when it produced the response. */
function batchAiSqlGate(config, sessionId, params, ts) {
  const sql = params.sql || params.query || params.statement || '';
  if (!sql) { allow(); return true; }

  // Estimation statements are always allowed — they are the cheap path we
  // are steering toward.
  if (ESTIMATION_RE.test(sql)) { allow(); return true; }

  const unboundedAiScan =
    AI_FUNCTION_RE.test(sql) &&
    FROM_TABLE_RE.test(sql) &&
    !ROW_BOUND_RE.test(sql);

  if (!unboundedAiScan) { allow(); return true; }

  const reason =
    'snow-cuffs batch-AI gate: this statement runs a metered Cortex AI_* function over a table ' +
    'with no LIMIT/SAMPLE/TOP bound. Run the $preflight skill first ' +
    `(approval gate: ${config.preflightGateCredits} credits). Two-step estimate recipe:\n` +
    `  1. SELECT COUNT(*) AS n_rows, AVG(AI_COUNT_TOKENS('<model>', <text_column>)) AS avg_tokens ` +
    'FROM <table> SAMPLE (100 ROWS);\n' +
    `  2. SELECT SNOWCUFFS.PUBLIC.ESTIMATE_AI_CREDITS('<model>', <n_rows>, <avg_tokens>) AS est_credits;\n` +
    'Estimation statements (AI_COUNT_TOKENS / ESTIMATE_AI_CREDITS) always pass this gate. ' +
    'Re-submit with a LIMIT/SAMPLE, or as-is once $preflight approves the estimate.';

  const state = sessionState(sessionId);
  auditEvent({
    ts,
    session_id: sessionId,
    event_type: 'blocked_batch_ai_sql',
    tool_name:  'SnowflakeSqlExecute',
    payload: {
      sql_prefix: sql.slice(0, 200),
      sql_bytes:  sql.length,
      mode:       config.mode,
      enforced:   config.mode === 'block',
    },
  });

  if (config.mode === 'block') {
    state.blocks += 1;
    saveSessionState(sessionId, state);
    block(reason);
  } else {
    saveSessionState(sessionId, state);
    allow(reason);
  }
  return true;
}

function main() {
  const ts       = isoUtc();
  const event    = readStdinJson();
  const toolName = event.tool || process.env.COCO_TOOL_NAME || 'unknown';
  const params   = event.parameters || {};
  const config   = loadConfig();

  // Gates off: pass everything through immediately
  if (config.mode === 'off') { allow(); return; }

  const sessionId = sessionIdFrom(event);

  // --- GATE A: big-read guard (Read / NotebookRead) ---
  if (READ_TOOLS.indexOf(toolName) !== -1) {
    bigReadGuard(config, sessionId, toolName, params, ts);
    return;
  }

  // --- GATE B: batch-AI-SQL gate (SnowflakeSqlExecute) ---
  if (toolName === 'SnowflakeSqlExecute') {
    batchAiSqlGate(config, sessionId, params, ts);
    return;
  }

  // Anything else: allow fast
  allow();
}

try {
  main();
} catch (err) {
  logError('pre-tool-use', err.message);
  allow(); // fail-open: never block on hook error
}
