/**
 * snow-cuffs hook shared utilities — cross-platform (Node.js)
 * Required by all hook scripts via require('./_common.js')
 *
 * State convention: everything snow-cuffs owns lives under .snowcuffs/ in the
 * project root. CocoPlus state under .cocoplus/ is read-only to us — we never
 * write there (CocoPlus owns those formats).
 */

'use strict';

const fs     = require('fs');
const path   = require('path');
const crypto = require('crypto');

const SNOWCUFFS_DIR = '.snowcuffs';

/**
 * Built-in defaults, overridable via .snowcuffs/config.json. Thresholds are
 * illustrative — tune per team in config.json, not here.
 */
const DEFAULT_CONFIG = {
  maxReadLines:         400,     // GATE A: per-file line budget for Read/NotebookRead
  maxSessionReads:      8,       // GATE A: files readable per session before a search is required
  searchGraceReads:     8,       // GATE A: reads granted after a completed search call
  mode:                 'warn',  // off | warn | block
  codeSearchService:    'SNOWCUFFS.CODE_INDEX.TEAM_CODE_SEARCH',
  schemaSearchService:  'SNOWCUFFS.DB_CONTEXT.DB_SCHEMA_SEARCH',
  preflightGateCredits: 5.0,     // GATE B: $preflight approval gate, in credits
};

/** ISO 8601 UTC timestamp */
function isoUtc() {
  return new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
}

/**
 * Append a JSON-lines record to a file. Creates parent dirs as needed.
 * Never throws — all errors are silently swallowed to keep hooks non-fatal.
 */
function appendJsonLine(filePath, record) {
  try {
    fs.mkdirSync(path.dirname(filePath), { recursive: true });
    fs.appendFileSync(filePath, JSON.stringify(record) + '\n');
  } catch (_) { /* non-fatal */ }
}

/** Log an error to the snow-cuffs hook error log (never .cocoplus/) */
function logError(hookName, message) {
  appendJsonLine(path.join(SNOWCUFFS_DIR, 'hook-errors.log'), {
    ts:    isoUtc(),
    hook:  hookName,
    error: message,
  });
}

/**
 * Read all of stdin synchronously as a string.
 * Returns empty string if stdin has no data (e.g. no pipe).
 *
 * Reads in a retry loop rather than one fs.readFileSync(stdin.fd): large piped
 * payloads (>~256KB) raise transient EAGAIN on non-blocking pipes, and a
 * swallowed EAGAIN would silently bypass the gates for exactly the biggest —
 * most expensive — events. Capped at 8MB to preserve the hook time budget.
 */
const STDIN_MAX_BYTES = 8 * 1024 * 1024;
function readStdin() {
  try {
    if (process.stdin.isTTY) return '';
    const chunks = [];
    const buf = Buffer.alloc(65536);
    let total = 0;
    for (;;) {
      let n;
      try {
        n = fs.readSync(process.stdin.fd, buf, 0, buf.length, null);
      } catch (err) {
        if (err && (err.code === 'EAGAIN' || err.code === 'EWOULDBLOCK')) continue;
        if (err && err.code === 'EOF') break;
        throw err;
      }
      if (n === 0) break;
      total += n;
      if (total > STDIN_MAX_BYTES) break;
      chunks.push(Buffer.from(buf.subarray(0, n)));
    }
    return Buffer.concat(chunks).toString('utf8');
  } catch (_) { /* ignore */ }
  return '';
}

/**
 * Parse stdin as JSON. Returns empty object on parse failure, non-object
 * payload, or no input. Optional callback form: readStdinJson(cb) invokes
 * cb(event) with the parsed event and returns its result.
 */
function readStdinJson(cb) {
  const raw = readStdin().trim();
  let event = {};
  if (raw) {
    try { event = JSON.parse(raw); } catch (_) { event = {}; }
  }
  if (!event || typeof event !== 'object' || Array.isArray(event)) event = {};
  if (typeof cb === 'function') return cb(event);
  return event;
}

/** Emit the single JSON response line to stdout. Hooks call this at most once. */
function respond(obj) {
  try {
    process.stdout.write(JSON.stringify(obj) + '\n');
  } catch (_) { /* non-fatal */ }
}

/**
 * Load snow-cuffs config: .snowcuffs/config.json merged over DEFAULT_CONFIG.
 * If ./cocoplus.toml exists, [cost] per_session_threshold_credits overrides
 * preflightGateCredits so both frameworks gate on the same number. That read
 * is a flat line-regex parse (section header + key=value) — no TOML library,
 * non-fatal on any malformation.
 */
function loadConfig() {
  const config = Object.assign({}, DEFAULT_CONFIG);
  try {
    const overrides = JSON.parse(fs.readFileSync(path.join(SNOWCUFFS_DIR, 'config.json'), 'utf8'));
    for (const key of Object.keys(DEFAULT_CONFIG)) {
      if (overrides[key] !== undefined) config[key] = overrides[key];
    }
  } catch (_) { /* config.json absent or malformed — defaults apply */ }

  // Normalize + validate mode so "BLOCK"/"Off" don't silently downgrade to warn.
  const mode = String(config.mode).toLowerCase();
  if (mode === 'off' || mode === 'warn' || mode === 'block') {
    config.mode = mode;
  } else {
    logError('config', `unrecognized mode "${config.mode}" — falling back to "${DEFAULT_CONFIG.mode}"`);
    config.mode = DEFAULT_CONFIG.mode;
  }

  try {
    if (fs.existsSync('cocoplus.toml')) {
      let section = null;
      for (const rawLine of fs.readFileSync('cocoplus.toml', 'utf8').split(/\r?\n/)) {
        const line = rawLine.replace(/#.*/, '').trim();
        if (!line) continue;
        const sectionMatch = line.match(/^\[([^\]]+)\]$/);
        if (sectionMatch) { section = sectionMatch[1]; continue; }
        const kv = line.match(/^per_session_threshold_credits\s*=\s*([0-9]+(?:\.[0-9]+)?)$/);
        if (kv && section === 'cost') {
          const value = Number(kv[1]);
          if (Number.isFinite(value) && value > 0) config.preflightGateCredits = value;
        }
      }
    }
  } catch (_) { /* cocoplus.toml unreadable — non-fatal */ }

  return config;
}

/**
 * Resolve the session id: event JSON field first (Coco sends session_id on
 * hook events — see CocoPlus user-prompt-submit/post-tool-use), then the
 * COCO_SESSION_ID env var, then a date-scoped fallback.
 */
function sessionIdFrom(event) {
  const fromEvent = event && (event.session_id || event.sessionId);
  if (fromEvent) return String(fromEvent);
  if (process.env.COCO_SESSION_ID) return process.env.COCO_SESSION_ID;
  // Include pid so concurrent session-id-less sessions don't share one state
  // file (counters, grace, and the session_end dedupe flag would bleed).
  return 'unknown-' + isoUtc().slice(0, 10).replace(/-/g, '') + '-' + process.pid;
}

/** Path of the per-session state file under .snowcuffs/state/ */
function sessionStatePath(sessionId) {
  const safeId = String(sessionId || 'unknown').replace(/[^A-Za-z0-9._-]/g, '-');
  return path.join(SNOWCUFFS_DIR, 'state', `session-${safeId}.json`);
}

/**
 * Load per-session counters. Missing or malformed state yields the zeroed
 * default shape so gates always have numbers to work with.
 */
function sessionState(sessionId) {
  const defaults = {
    session_id:               String(sessionId || 'unknown'),
    started_at:               null,
    files_read:               0,
    est_lines_read:           0,
    search_calls:             0,
    search_calls_since_flood: 0,
    blocks:                   0,
    ai_sql_runs:              0,
    stop_gate_fired:          false,
    session_end_recorded:     false,
  };
  try {
    const raw = JSON.parse(fs.readFileSync(sessionStatePath(sessionId), 'utf8'));
    return Object.assign(defaults, raw);
  } catch (_) {
    return defaults;
  }
}

/**
 * Persist per-session counters. Never throws. Atomic (tmp + rename) so an
 * overlapping reader never parses a truncated file and silently resets the
 * counters to zero.
 */
function saveSessionState(sessionId, state) {
  const filePath = sessionStatePath(sessionId);
  const tmp = filePath + '.tmp.' + process.pid;
  try {
    fs.mkdirSync(path.dirname(filePath), { recursive: true });
    fs.writeFileSync(tmp, JSON.stringify(state, null, 2) + '\n', 'utf8');
    fs.renameSync(tmp, filePath);
  } catch (_) {
    try { fs.unlinkSync(tmp); } catch (_2) { /* ignore */ }
  }
}

/**
 * Append an audit event to .snowcuffs/audit/<YYYY-MM-DD>.jsonl in the shared
 * shipper/SQL contract shape:
 *   {"event_id","ts","session_id","user_name","repo","event_type",
 *    "tool_name","skill_name","payload"}
 * event_id = first 16 hex chars of sha256 over session_id, millisecond
 * timestamp, event_type, tool/skill names, payload, and a random nonce.
 * The nonce guarantees same-second identical events stay distinct — the id
 * only needs to be unique at generation time; ship_audit.py dedupes re-reads
 * of the same line by this stored value, not by recomputing the hash.
 * Never throws; returns the record written (or null on failure).
 */
function auditEvent(record) {
  try {
    const ts        = record.ts || isoUtc();
    const sessionId = String(record.session_id || sessionIdFrom(null));
    const eventType = record.event_type || 'tool';
    const payload   = record.payload || {};
    const eventId   = crypto.createHash('sha256')
      .update(sessionId + new Date().toISOString() + eventType
        + (record.tool_name || '') + (record.skill_name || '')
        + JSON.stringify(payload) + crypto.randomBytes(8).toString('hex'))
      .digest('hex')
      .slice(0, 16);
    const line = {
      event_id:   eventId,
      ts:         ts,
      session_id: sessionId,
      user_name:  record.user_name || process.env.SNOWFLAKE_USER || process.env.USER || null,
      repo:       record.repo || path.basename(process.cwd()) || null,
      event_type: eventType,
      tool_name:  record.tool_name || null,
      skill_name: record.skill_name || null,
      payload:    payload,
    };
    appendJsonLine(path.join(SNOWCUFFS_DIR, 'audit', `${ts.slice(0, 10)}.jsonl`), line);
    return line;
  } catch (_) {
    return null;
  }
}

module.exports = {
  SNOWCUFFS_DIR,
  DEFAULT_CONFIG,
  isoUtc,
  appendJsonLine,
  logError,
  readStdin,
  readStdinJson,
  respond,
  loadConfig,
  sessionIdFrom,
  sessionState,
  saveSessionState,
  auditEvent,
};
