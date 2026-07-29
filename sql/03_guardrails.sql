-- ============================================================================
-- snow-cuffs · 03 · Guardrails
-- ----------------------------------------------------------------------------
-- Catch runaway AI spend in hours, not at month-end. Three layers:
--   1. Alert on daily AI credit burn (uses 01's rollup view)
--   2. Resource monitor on the warehouse(s) that run AI SQL jobs
--   3. Budgets (account-level, optional — see note at bottom)
-- Adjust thresholds/emails before deploying.
-- ============================================================================

USE SCHEMA SNOWCUFFS.OBSERVABILITY;

-- ----------------------------------------------------------------------------
-- 1. Daily burn alert. Fires when yesterday's total AI credits exceed the
--    threshold. ACCOUNT_USAGE latency (~2-3h) means evaluate mid-morning.
-- ----------------------------------------------------------------------------
CREATE NOTIFICATION INTEGRATION IF NOT EXISTS SNOWCUFFS_EMAIL_INT
    TYPE = EMAIL
    ENABLED = TRUE;
    -- ALLOWED_RECIPIENTS = ('ai-infra-team@yourco.com');

SET AI_DAILY_CREDIT_THRESHOLD = 25;  -- tune to ~2-3x your normal daily burn

CREATE OR REPLACE ALERT AI_BURN_RATE_ALERT
    WAREHOUSE = SNOWCUFFS_WH          -- any XS warehouse
    SCHEDULE  = 'USING CRON 0 10 * * * UTC'
    IF (EXISTS (
        SELECT 1
        FROM SNOWCUFFS.OBSERVABILITY.AI_SPEND_ROLLUP_DAILY
        WHERE usage_date = CURRENT_DATE() - 1
        GROUP BY usage_date
        HAVING SUM(credits) > $AI_DAILY_CREDIT_THRESHOLD
    ))
    THEN CALL SYSTEM$SEND_EMAIL(
        'SNOWCUFFS_EMAIL_INT',
        'ai-infra-team@yourco.com',
        'snow-cuffs: daily AI credit threshold exceeded',
        'Yesterday''s AI spend exceeded the configured threshold. '
        || 'Check SNOWCUFFS.OBSERVABILITY.AI_SPEND_BY_USER_DAILY and '
        || 'AI_FUNCTION_SPEND_BY_QUERY for attribution.'
    );

ALTER ALERT AI_BURN_RATE_ALERT RESUME;

-- ----------------------------------------------------------------------------
-- 2. Resource monitor for warehouses that execute batch AI SQL. This caps the
--    WAREHOUSE compute side and, more importantly, suspends the runaway query
--    vehicle. (Token credits themselves are serverless and not stopped by a
--    resource monitor — that's what the alert above is for.)
-- ----------------------------------------------------------------------------
CREATE RESOURCE MONITOR IF NOT EXISTS AI_BATCH_RM
    WITH CREDIT_QUOTA = 100
    FREQUENCY = MONTHLY
    START_TIMESTAMP = IMMEDIATELY
    TRIGGERS
        ON 75  PERCENT DO NOTIFY
        ON 100 PERCENT DO SUSPEND
        ON 110 PERCENT DO SUSPEND_IMMEDIATE;

-- ALTER WAREHOUSE AI_BATCH_WH SET RESOURCE_MONITOR = AI_BATCH_RM;

-- ----------------------------------------------------------------------------
-- 3. Budgets (optional). Snowflake Budgets (SNOWFLAKE.CORE.BUDGET) can group
--    the SNOWCUFFS search service + AI warehouses into one spending plan with
--    its own notifications. Set up via Snowsight (Admin » Cost Management »
--    Budgets) or SQL; keep the budget scoped to AI resources so the signal
--    isn't diluted by general warehouse spend.
-- ----------------------------------------------------------------------------
