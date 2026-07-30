#!/usr/bin/env node
/**
 * snow-cuffs Stop hook — cross-platform (Node.js)
 * Fires when the main Coco agent stops.
 *
 * Two responsibilities, in order:
 *
 * 1. STOP GATE — a one-shot handoff check (the cost-native analogue of a
 *    "typecheck before you say you're done" Stop hook). Before the agent
 *    finishes, at most ONCE per session (state.stop_gate_fired guards the
 *    infinite-block loop):
 *      a. If the session executed metered AI SQL (state.ai_sql_runs > 0),
 *         ask it to reconcile actual vs. estimated credits against
 *         SNOWCUFFS.OBSERVABILITY.AI_FUNCTION_SPEND_BY_QUERY and append the
 *         delta to the audit log — the feedback loop that calibrates
 *         ESTIMATE_AI_CREDITS output-token assumptions.
 *      b. If the session was heavy-read/zero-search, ask for a 3-line session
 *         summary plus the search query that would have answered it, so the
 *         next session on this topic starts from retrieval.
 *    Contract note: CocoPlus's own stop hook is silent, so stop-time blocking
 *    is unverified in CoCo. If the runtime ignores stop stdout, this degrades
 *    harmlessly to audit-only; if honored, it behaves like PreToolUse block.
 *
 * 2. session_end audit safety net: some session paths fire stop without
 *    session-end (crash, interrupt). Appends the same session_end record as
 *    session-end.js unless already recorded (session_end_recorded flag).
 *    Skipped on the stop the gate fires on — the agent is about to continue.
 *
 * If CocoPlus is present, .cocoplus/session/*.json is read best-effort
 * (read-only — we never write into .cocoplus/) for flow/stage identifiers,
 * included as payload.flow_context.
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

const COCOPLUS_SESSION_DIR = path.join('.cocoplus', 'session');
const FLOW_KEY_RE = /(session|stage|run|flow|persona|feature|budget_state|phase)/i;

/**
 * Best-effort read of flow/feature identifiers from .cocoplus/session/*.json.
 * Returns a flat { "<file>.<key>": value } map or null. Never throws.
 */
function readFlowContext() {
  const context = {};
  try {
    if (!fs.existsSync(COCOPLUS_SESSION_DIR)) return null;
    for (const name of fs.readdirSync(COCOPLUS_SESSION_DIR)) {
      if (!name.endsWith('.json')) continue;
      let data;
      try {
        data = JSON.parse(fs.readFileSync(path.join(COCOPLUS_SESSION_DIR, name), 'utf8'));
      } catch (_) { continue; }
      if (!data || typeof data !== 'object' || Array.isArray(data)) continue;
      const stem = name.replace(/\.json$/, '');
      for (const key of Object.keys(data)) {
        if (!FLOW_KEY_RE.test(key)) continue;
        const value = data[key];
        if (typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean') {
          context[`${stem}.${key}`] = value;
        }
      }
    }
  } catch (_) { /* best-effort — never fail */ }
  return Object.keys(context).length ? context : null;
}

/**
 * Evaluate the one-shot stop gate. Returns the gate reason string when the
 * gate should fire, else null.
 */
function stopGateReason(config, state) {
  const parts = [];
  if ((state.ai_sql_runs || 0) > 0) {
    parts.push(
      `This session executed ${state.ai_sql_runs} metered AI SQL statement(s). ` +
      'Before finishing, reconcile actual vs. estimated credits: query ' +
      "SNOWCUFFS.OBSERVABILITY.AI_SPEND_BY_USER_DAILY or AI_FUNCTION_SPEND_BY_QUERY " +
      'for your query ids (note: ACCOUNT_USAGE lags ~2-3h — if rows are not there yet, ' +
      'record the estimate and flag it unreconciled), and append a one-line ' +
      `'skill' audit event (skill_name "reconcile") with {estimated, actual|null} to ` +
      '.snowcuffs/audit/<today>.jsonl.'
    );
  }
  if (state.files_read > config.maxSessionReads && (state.search_calls || 0) === 0) {
    parts.push(
      `This session read ${state.files_read} files without a single search-service call. ` +
      'Before finishing, append a 3-line session summary and the ONE ' +
      `SEARCH_PREVIEW('${config.codeSearchService}', ...) query that would have answered ` +
      'this task, so the next session starts from retrieval instead of re-reading.'
    );
  }
  return parts.length ? 'snow-cuffs stop gate (fires once per session): ' + parts.join(' ALSO: ') : null;
}

function main() {
  const ts        = isoUtc();
  const event     = readStdinJson();
  const config    = loadConfig();
  const sessionId = sessionIdFrom(event);
  const state     = sessionState(sessionId);

  // --- 1. Stop gate: at most once per session, never in off mode ---
  if (config.mode !== 'off' && !state.stop_gate_fired) {
    const reason = stopGateReason(config, state);
    if (reason) {
      state.stop_gate_fired = true;
      saveSessionState(sessionId, state);
      auditEvent({
        ts,
        session_id: sessionId,
        event_type: 'skill',
        skill_name: 'stop-gate',
        payload: {
          ai_sql_runs:  state.ai_sql_runs || 0,
          files_read:   state.files_read,
          search_calls: state.search_calls,
          mode:         config.mode,
          enforced:     config.mode === 'block',
        },
      });
      respond(config.mode === 'block'
        ? { action: 'block', reason }
        : { action: 'allow', warning: reason });
      // The agent is (potentially) about to continue — do not record
      // session_end on this stop; the next stop records it.
      return;
    }
  }

  // --- 2. session_end safety net ---
  // Dedupe: session-end already recorded this session's counters
  if (state.session_end_recorded) return;

  const payload = {
    files_read:     state.files_read,
    est_lines_read: state.est_lines_read,
    search_calls:   state.search_calls,
    blocks:         state.blocks,
    ai_sql_runs:    state.ai_sql_runs || 0,
    started_at:     state.started_at,
    source:         'stop',
  };
  const flowContext = readFlowContext();
  if (flowContext) payload.flow_context = flowContext;

  auditEvent({ ts, session_id: sessionId, event_type: 'session_end', payload });

  state.session_end_recorded = true;
  saveSessionState(sessionId, state);
}

try {
  main();
} catch (err) {
  logError('stop', err.message);
}
