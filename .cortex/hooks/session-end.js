#!/usr/bin/env node
/**
 * snow-cuffs SessionEnd hook — cross-platform (Node.js)
 * Fires when Coco ends a session.
 *
 * Responsibilities: append the session_end audit event carrying the session's
 * cost counters (files_read, est_lines_read, search_calls, blocks) so the
 * audit shipper can land per-session behavior in SNOWCUFFS.AUDIT.AGENT_EVENTS.
 * Marks the state file so stop.js does not double-record the same session.
 *
 * If CocoPlus is present, .cocoplus/session/*.json is read best-effort
 * (read-only — we never write into .cocoplus/) for flow/stage identifiers,
 * included as payload.flow_context.
 *
 * Writes nothing to stdout (mirrors CocoPlus session-end).
 */

'use strict';

const fs   = require('fs');
const path = require('path');
const {
  isoUtc,
  readStdinJson,
  logError,
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

function main() {
  const ts        = isoUtc();
  const event     = readStdinJson();
  const sessionId = sessionIdFrom(event);
  const state     = sessionState(sessionId);

  if (state.session_end_recorded) return; // already recorded this session

  const payload = {
    files_read:     state.files_read,
    est_lines_read: state.est_lines_read,
    search_calls:   state.search_calls,
    blocks:         state.blocks,
    ai_sql_runs:    state.ai_sql_runs || 0,
    started_at:     state.started_at,
    source:         'session-end',
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
  logError('session-end', err.message);
}
