-- ============================================================================
-- snow-cuffs · 01 · AI cost observability
-- ----------------------------------------------------------------------------
-- Spend attribution views over SNOWFLAKE.ACCOUNT_USAGE. Deploy first: every
-- other lever in this repo is prioritized by what these views show.
--
-- Requires: a role with the ACCOUNT_USAGE viewer grants (e.g. via
--   GRANT DATABASE ROLE SNOWFLAKE.USAGE_VIEWER TO ROLE <role>;
--   GRANT DATABASE ROLE SNOWFLAKE.GOVERNANCE_VIEWER TO ROLE <role>;
-- ACCOUNT_USAGE latency is up to ~2-3 hours for most of these views.
-- ============================================================================

CREATE DATABASE IF NOT EXISTS SNOWCUFFS;
CREATE SCHEMA IF NOT EXISTS SNOWCUFFS.OBSERVABILITY;
USE SCHEMA SNOWCUFFS.OBSERVABILITY;

-- ----------------------------------------------------------------------------
-- Cortex AI SQL functions: daily credits by function and model.
-- (CORTEX_AI_FUNCTIONS_USAGE_HISTORY is the newer AI_* view; keep the legacy
-- CORTEX_FUNCTIONS_USAGE_HISTORY union if you still call SNOWFLAKE.CORTEX.*.)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW AI_FUNCTION_SPEND_DAILY AS
SELECT
    DATE_TRUNC('day', start_time)          AS usage_date,
    function_name,
    model_name,
    SUM(token_credits)                     AS token_credits,
    SUM(tokens)                            AS tokens
FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_FUNCTIONS_USAGE_HISTORY
GROUP BY 1, 2, 3;

-- ----------------------------------------------------------------------------
-- Per-query attribution: who ran the expensive AI queries?
-- Join to QUERY_HISTORY to get user, warehouse, and query text.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW AI_FUNCTION_SPEND_BY_QUERY AS
SELECT
    q.user_name,
    q.warehouse_name,
    c.query_id,
    c.function_name,
    c.model_name,
    c.token_credits,
    c.tokens,
    q.start_time,
    q.query_text
FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_FUNCTIONS_QUERY_USAGE_HISTORY c
JOIN SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY q
  ON c.query_id = q.query_id;

CREATE OR REPLACE VIEW AI_SPEND_BY_USER_DAILY AS
SELECT
    DATE_TRUNC('day', start_time)          AS usage_date,
    user_name,
    SUM(token_credits)                     AS token_credits,
    COUNT(DISTINCT query_id)               AS ai_queries
FROM AI_FUNCTION_SPEND_BY_QUERY
GROUP BY 1, 2;

-- ----------------------------------------------------------------------------
-- Cortex Code (CoCo) CLI + desktop sessions: this is your agent spend.
-- TOKEN_CREDITS aggregates per user let you spot context-stuffing sessions.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW COCO_SPEND_DAILY AS
SELECT usage_date, surface, user_name, token_credits
FROM (
    SELECT DATE_TRUNC('day', start_time) AS usage_date,
           'cli'                         AS surface,
           user_name,
           SUM(token_credits)            AS token_credits
    FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_CODE_CLI_USAGE_HISTORY
    GROUP BY 1, 3
    UNION ALL
    SELECT DATE_TRUNC('day', start_time) AS usage_date,
           'desktop'                     AS surface,
           user_name,
           SUM(token_credits)            AS token_credits
    FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_CODE_DESKTOP_USAGE_HISTORY
    GROUP BY 1, 3
);

-- ----------------------------------------------------------------------------
-- Cortex Search: serving is billed GB/month even at zero queries ("idle tax"),
-- plus embedding tokens on insert/update. Watch both.
-- Use the DAILY view (not the hourly SERVING view as well — pick one).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW CORTEX_SEARCH_SPEND_DAILY AS
SELECT
    usage_date,
    service_name,
    consumption_type,
    SUM(credits) AS credits
FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_SEARCH_DAILY_USAGE_HISTORY
GROUP BY 1, 2, 3;

-- ----------------------------------------------------------------------------
-- Roll-up: one row per day per cost source. This is the number to chart and
-- the input to the burn-rate alert in 03_guardrails.sql.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW AI_SPEND_ROLLUP_DAILY AS
SELECT usage_date, 'ai_functions'  AS source, SUM(token_credits) AS credits
  FROM AI_FUNCTION_SPEND_DAILY GROUP BY 1
UNION ALL
SELECT usage_date, 'cortex_code'   AS source, SUM(token_credits) AS credits
  FROM COCO_SPEND_DAILY GROUP BY 1
UNION ALL
SELECT usage_date, 'cortex_search' AS source, SUM(credits)       AS credits
  FROM CORTEX_SEARCH_SPEND_DAILY GROUP BY 1;

-- Sanity check after ~3h of latency:
--   SELECT * FROM AI_SPEND_ROLLUP_DAILY ORDER BY usage_date DESC, credits DESC;
