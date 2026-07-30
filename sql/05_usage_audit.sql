-- ============================================================================
-- snow-cuffs · 05 · Usage audit
-- ----------------------------------------------------------------------------
-- Complete audit of HOW the team's agents are being used: which skills run,
-- who runs them, whether sessions search before reading, and what the hooks
-- actually blocked. ACCOUNT_USAGE (01) tells you what agent time COSTS;
-- this schema tells you WHY — the behavior behind the credits.
--
-- Feed: local CoCo hooks and $-skills append events to .snowcuffs/audit/
-- YYYY-MM-DD.jsonl; indexer/ship_audit.py MERGEs them here on event_id, so
-- shipping is idempotent and safe to re-run.
--
-- Event contract (shared with hooks + shipper — do not change one side alone):
--   {"event_id": sha256-16hex, "ts": ISO-8601, "session_id", "user_name",
--    "repo", "event_type": tool|skill|blocked_batch_ai_sql|blocked_big_read|
--    session_start|session_end, "tool_name", "skill_name", "payload": object}
-- All thresholds below (30d stale, 14d window, 8 files) are illustrative.
-- ============================================================================

CREATE DATABASE IF NOT EXISTS SNOWCUFFS;
CREATE SCHEMA IF NOT EXISTS SNOWCUFFS.AUDIT;
USE SCHEMA SNOWCUFFS.AUDIT;

-- ----------------------------------------------------------------------------
-- Landing table. One row per event; event_id is a content hash computed by
-- the emitting hook, which is what makes the shipper's MERGE idempotent.
-- loaded_at records ship time; ts records emit time.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS AGENT_EVENTS (
    event_id    VARCHAR NOT NULL,        -- sha256[:16] computed hook-side
    ts          TIMESTAMP_NTZ,           -- when the event happened (UTC)
    session_id  VARCHAR,
    user_name   VARCHAR,
    repo        VARCHAR,
    event_type  VARCHAR,                 -- tool | skill | blocked_* | session_*
    tool_name   VARCHAR,
    skill_name  VARCHAR,
    payload     VARIANT,
    loaded_at   TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    PRIMARY KEY (event_id)
);

-- ----------------------------------------------------------------------------
-- Skill invocations per skill / user / day. The raw activity series.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW SKILL_USAGE_DAILY
    COMMENT = 'Decision: which skills are pulling their weight day to day — the trend line to check after announcing or changing a skill.'
AS
SELECT
    DATE_TRUNC('day', ts)          AS usage_date,
    skill_name,
    user_name,
    COUNT(*)                       AS invocations,
    COUNT(DISTINCT session_id)     AS sessions
FROM AGENT_EVENTS
WHERE event_type = 'skill'
GROUP BY 1, 2, 3;

-- ----------------------------------------------------------------------------
-- Per-skill adoption summary. stale = nobody has invoked it in 30 days.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW SKILL_ADOPTION
    COMMENT = 'Decision: which skills to promote, fix, or delete — stale skills are maintenance cost with no return; single-user skills need evangelism or an owner.'
AS
SELECT
    skill_name,
    COUNT(DISTINCT user_name)      AS distinct_users,
    COUNT(DISTINCT session_id)     AS distinct_sessions,
    MIN(ts)                        AS first_seen,
    MAX(ts)                        AS last_seen,
    COUNT_IF(ts >= DATEADD('day', -30, CURRENT_TIMESTAMP()))
                                   AS invocations_30d,
    MAX(ts) < DATEADD('day', -30, CURRENT_TIMESTAMP())
                                   AS stale
FROM AGENT_EVENTS
WHERE event_type = 'skill'
GROUP BY 1;

-- ----------------------------------------------------------------------------
-- One row per session, built from the session_end counters with the
-- session_start payload joined in. search_first = the session touched the
-- Cortex Search service at least once instead of raw-reading files.
-- duration is NULL when the start event never shipped (crash, kill -9).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW SESSION_HYGIENE
    COMMENT = 'Decision: whether sessions follow the cheap pattern (context pack + search-first, few raw reads) — the per-session ledger every view below aggregates.'
AS
WITH session_ends AS (
    SELECT
        session_id,
        user_name,
        repo,
        ts                                  AS ended_at,
        payload:files_read::NUMBER          AS files_read,
        payload:est_lines_read::NUMBER      AS est_lines_read,
        payload:search_calls::NUMBER        AS search_calls,
        payload:blocks::NUMBER              AS blocks
    FROM AGENT_EVENTS
    WHERE event_type = 'session_end'
    QUALIFY ROW_NUMBER() OVER (PARTITION BY session_id ORDER BY ts DESC) = 1
),
session_starts AS (
    SELECT
        session_id,
        ts                                          AS started_at,
        COALESCE(payload:has_context_pack::BOOLEAN, FALSE)
                                                    AS has_context_pack
    FROM AGENT_EVENTS
    WHERE event_type = 'session_start'
    QUALIFY ROW_NUMBER() OVER (PARTITION BY session_id ORDER BY ts ASC) = 1
)
SELECT
    e.session_id,
    e.user_name,
    e.repo,
    s.started_at,
    e.ended_at,
    DATEDIFF('minute', s.started_at, e.ended_at)   AS duration_minutes,
    e.files_read,
    e.est_lines_read,
    e.search_calls,
    e.blocks,
    COALESCE(e.search_calls, 0) > 0                AS search_first,
    COALESCE(s.has_context_pack, FALSE)            AS has_context_pack
FROM session_ends e
LEFT JOIN session_starts s USING (session_id);

-- ----------------------------------------------------------------------------
-- Who keeps bulk-reading files without ever hitting TEAM_CODE_SEARCH.
-- Threshold (> 8 files, 0 searches, last 14 days) is illustrative.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW SEARCH_BYPASS_LEADERBOARD
    COMMENT = 'Decision: who to coach this sprint — users whose recent sessions bulk-read files with zero search calls are paying the context-stuffing tax the search service exists to remove.'
AS
SELECT
    user_name,
    COUNT(*)               AS bypass_sessions_14d,
    SUM(files_read)        AS files_read_total,
    AVG(est_lines_read)    AS avg_est_lines_read,
    MAX(ended_at)          AS latest_bypass
FROM SESSION_HYGIENE
WHERE ended_at >= DATEADD('day', -14, CURRENT_TIMESTAMP())
  AND files_read > 8
  AND COALESCE(search_calls, 0) = 0
GROUP BY 1
ORDER BY bypass_sessions_14d DESC;

-- ----------------------------------------------------------------------------
-- Do context packs + search-first actually make sessions cheaper? Sessions
-- bucketed into the 2x2 of has_context_pack × search_first, with credits
-- context from 01's COCO_SPEND_DAILY.
--
-- GRANULARITY CAVEAT — read before quoting numbers: COCO_SPEND_DAILY is
-- per-USER-per-DAY (Snowflake does not expose per-session CoCo credits), so
-- each session inherits its user's WHOLE day of credits; a user with three
-- sessions in one day contributes that day's total to all three, smearing
-- credits across buckets. avg_user_day_credits is directional context —
-- "days containing sessions like these tend to burn X" — not per-session
-- attribution. The behavioral columns (files/lines/blocks) ARE per-session
-- and are the trustworthy comparison. Also assumes hook-side user_name
-- matches the Snowflake USER_NAME; if your hooks log git identities, map
-- them before believing the join.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW INIT_COST_COMPARISON
    COMMENT = 'Decision: whether to keep mandating context packs and search-first session init — compares avg context pulled (and directional credits) across the four init styles.'
AS
WITH sessions AS (
    SELECT h.*, DATE_TRUNC('day', h.ended_at) AS usage_date
    FROM SESSION_HYGIENE h
    WHERE h.ended_at IS NOT NULL
),
user_day_credits AS (
    SELECT usage_date, user_name, SUM(token_credits) AS day_credits
    FROM SNOWCUFFS.OBSERVABILITY.COCO_SPEND_DAILY
    GROUP BY 1, 2
)
SELECT
    s.has_context_pack,
    s.search_first,
    COUNT(*)                AS sessions,
    AVG(s.files_read)       AS avg_files_read,
    AVG(s.est_lines_read)   AS avg_est_lines_read,
    AVG(s.blocks)           AS avg_blocks,
    AVG(c.day_credits)      AS avg_user_day_credits   -- directional; see caveat
FROM sessions s
LEFT JOIN user_day_credits c
  ON c.user_name  = s.user_name
 AND c.usage_date = s.usage_date
GROUP BY 1, 2;

-- ----------------------------------------------------------------------------
-- What the pre-tool-use hooks actually stopped, per day per user. This is
-- the evidence file for keeping enforcement on (and for the warn-only ->
-- blocking rollout argument in coco/hooks/README.md).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW BLOCKED_EVENTS_DAILY
    COMMENT = 'Decision: whether the guardrail hooks stay in blocking mode — each row is an expensive mistake that did not happen; a flat zero for weeks argues the team has internalized the rules.'
AS
SELECT
    DATE_TRUNC('day', ts)                            AS usage_date,
    user_name,
    COUNT_IF(event_type = 'blocked_big_read')        AS big_read_blocks,
    COUNT_IF(event_type = 'blocked_batch_ai_sql')    AS batch_ai_sql_blocks,
    COUNT(*)                                         AS total_blocks
FROM AGENT_EVENTS
WHERE event_type IN ('blocked_big_read', 'blocked_batch_ai_sql')
GROUP BY 1, 2;

-- Sanity checks once events start shipping:
--   SELECT * FROM SKILL_ADOPTION ORDER BY invocations_30d DESC;
--   SELECT * FROM SEARCH_BYPASS_LEADERBOARD;
--   SELECT * FROM INIT_COST_COMPARISON ORDER BY 1, 2;
