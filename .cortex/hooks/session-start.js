#!/usr/bin/env node
/**
 * snow-cuffs SessionStart hook — cross-platform (Node.js)
 * Fires when Coco starts a session.
 *
 * Responsibilities: initialize per-session cost counters, inject the project
 * context pack plus standing cost instructions, append a session_start audit
 * event.
 *
 * Output convention: CocoPlus's own session-start emits nothing on stdout, so
 * there is no injection precedent to copy; we reuse the single-JSON-line
 * allow envelope from pre-tool-use / pre-compact with an added "context" key:
 *   {"action":"allow","context":"..."}
 * CoCo builds that ignore unknown keys treat this as a plain allow; builds
 * that support context injection pick up the pack. Exactly one line, always.
 */

'use strict';

const fs = require('fs');
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

const CONTEXT_PACK_PATH = 'PROJECT_CONTEXT.md';
const CONTEXT_PACK_CAP  = 64 * 1024; // keep injection bounded for hook speed

// Exactly-one-response guard (the fail-open catch also responds)
let responded = false;

function respondOnce(obj) {
  if (responded) return;
  responded = true;
  respond(obj);
}

function main() {
  const ts        = isoUtc();
  const event     = readStdinJson();
  const config    = loadConfig();
  const sessionId = sessionIdFrom(event);

  // Initialize per-session cost counters for the gates
  const state = sessionState(sessionId);
  if (!state.started_at) state.started_at = ts;
  saveSessionState(sessionId, state);

  const hasContextPack = fs.existsSync(CONTEXT_PACK_PATH);
  let context;
  if (hasContextPack) {
    let pack = '';
    try {
      pack = fs.readFileSync(CONTEXT_PACK_PATH, 'utf8').slice(0, CONTEXT_PACK_CAP);
    } catch (_) { /* unreadable pack — instructions still inject */ }
    context = [
      pack.trim(),
      '',
      'snow-cuffs standing instructions (cost discipline):',
      '1. Code questions: query the team code index first — ' +
        `SNOWFLAKE.CORTEX.SEARCH_PREVIEW('${config.codeSearchService}', ...) — before reading files one by one.`,
      '2. Data questions: run $dbq first (Cortex Search over the schema cards); do not guess table shapes.',
      '3. Never crawl INFORMATION_SCHEMA manually to discover schema — the schema index exists so you do not have to.',
    ].join('\n');
  } else {
    context = 'snow-cuffs: no PROJECT_CONTEXT.md found — run $warmstart ' +
      '(or `python indexer/context_pack.py`) to build the context pack before exploring the repo file-by-file.';
  }

  auditEvent({
    ts,
    session_id: sessionId,
    event_type: 'session_start',
    payload:    { has_context_pack: hasContextPack },
  });

  respondOnce({ action: 'allow', context });
}

try {
  main();
} catch (err) {
  logError('session-start', err.message);
  respondOnce({ action: 'allow' }); // fail-open: never break session start
}
