#!/usr/bin/env node
/**
 * snow-cuffs PostToolUse hook — cross-platform (Node.js)
 *
 * Stdin JSON format from Coco:
 *   { "tool": "SnowflakeSqlExecute", "parameters": { "sql": "..." },
 *     "result": { "success": true }, "session_id": "sess-..." }
 *
 * Never blocks and writes nothing to stdout (mirrors CocoPlus post-tool-use).
 * Responsibilities:
 *   1. Detect search-service usage (TEAM_CODE_SEARCH / DB_SCHEMA_SEARCH /
 *      SEARCH_PREVIEW in parameters or result) and replenish GATE A's grace
 *      read budget — this is what makes "search first, then read" cheap.
 *   2. Append a 'tool' audit event for every tool call.
 *
 * Skill invocations are NOT observable at this layer: verified against
 * CocoPlus, $-prefixed skill commands arrive as {"message":"$de ..."} on the
 * user-prompt-submit hook and no skill-runner tool crosses PostToolUse.
 * snow-cuffs skills therefore self-report their own 'skill' audit events as
 * part of their procedure (see the $-skills' Output steps).
 *
 * Must complete in <100ms — structural checks only, no child processes.
 */

'use strict';

const {
  isoUtc,
  readStdinJson,
  logError,
  loadConfig,
  sessionIdFrom,
  sessionState,
  saveSessionState,
  auditEvent,
} = require('./_common.js');

/** Fixed markers plus the configured service names, matched case-insensitively */
function searchMarkers(config) {
  return [
    'SEARCH_PREVIEW',
    'TEAM_CODE_SEARCH',
    'DB_SCHEMA_SEARCH',
    String(config.codeSearchService || '').toUpperCase(),
    String(config.schemaSearchService || '').toUpperCase(),
  ].filter(Boolean);
}

function main() {
  const ts       = isoUtc();
  const event    = readStdinJson();
  const toolName = event.tool || process.env.COCO_TOOL_NAME || 'unknown';
  const params   = event.parameters || {};
  const result   = event.result || {};
  const config   = loadConfig();
  const sessionId = sessionIdFrom(event);

  const paramsJson = JSON.stringify(params);

  // ok is tri-state: true/false when the result carries a success/error
  // signal, null when indeterminable.
  let ok = null;
  if (result.success !== undefined) ok = result.success !== false;
  else if (result.error !== undefined) ok = false;

  // 1. Search-service usage → replenish GATE A grace reads. Scoped tightly:
  // only the SQL text of a SnowflakeSqlExecute counts (a Read of a file whose
  // *name or contents* mention SEARCH_PREVIEW must not mint grace), and a
  // result that signals failure earns nothing.
  const sqlText    = String(params.sql || params.query || params.statement || '').toUpperCase();
  const usedSearch =
    toolName === 'SnowflakeSqlExecute' &&
    ok !== false &&
    searchMarkers(config).some((marker) => sqlText.indexOf(marker) !== -1);

  // 2. AI-SQL run tracking for the stop-gate reconciliation: count executed
  // (not blocked) statements invoking a metered AI_* function.
  const ranAiSql =
    toolName === 'SnowflakeSqlExecute' &&
    ok !== false &&
    /AI_(COMPLETE|CLASSIFY|FILTER|AGG|SUMMARIZE|EXTRACT|SENTIMENT|TRANSLATE)\s*\(/.test(sqlText) &&
    !/\b(AI_COUNT_TOKENS|ESTIMATE_AI_CREDITS)\b/.test(sqlText);

  if (usedSearch || ranAiSql) {
    const state = sessionState(sessionId);
    if (usedSearch) {
      state.search_calls             += 1;
      state.search_calls_since_flood  = Number(config.searchGraceReads) || 0;
    }
    if (ranAiSql) state.ai_sql_runs = (state.ai_sql_runs || 0) + 1;
    saveSessionState(sessionId, state);
  }

  // 3. 'tool' audit event for every call.
  auditEvent({
    ts,
    session_id: sessionId,
    event_type: 'tool',
    tool_name:  toolName,
    payload: {
      ok:          ok,
      param_bytes: paramsJson.length,
      used_search: usedSearch,
    },
  });
}

try {
  main();
} catch (err) {
  logError('post-tool-use', err.message);
}
