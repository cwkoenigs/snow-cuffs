-- ============================================================================
-- snow-cuffs · 02 · Pre-flight cost estimation
-- ----------------------------------------------------------------------------
-- Price an AI SQL job BEFORE running it, using:
--   * AI_COUNT_TOKENS (GA 2026-01-27): estimates INPUT tokens for an AISQL
--     function call at compute-only cost. Lowercase function/model names.
--     Not usable with legacy SNOWFLAKE.CORTEX.* functions or fine-tuned
--     models; text inputs only; input tokens only.
--   * A pricing table of credits per million tokens, per model.
--
-- !! PRICING IS DATA. The seed values below are ILLUSTRATIVE, taken from
-- !! public consumption-table snapshots, and WILL drift. Refresh them from
-- !! the current Snowflake Service Consumption Table before trusting output.
-- ============================================================================

CREATE DATABASE IF NOT EXISTS SNOWCUFFS;
CREATE SCHEMA IF NOT EXISTS SNOWCUFFS.PUBLIC;
USE SCHEMA SNOWCUFFS.PUBLIC;

CREATE TABLE IF NOT EXISTS MODEL_PRICING (
    model_name                 VARCHAR      NOT NULL,
    credits_per_m_input_tokens NUMBER(10,4) NOT NULL,
    -- Most Cortex models bill one rate over input+output; if a model ever has
    -- a distinct output rate, set it here, else keep equal to input rate.
    credits_per_m_output_tokens NUMBER(10,4) NOT NULL,
    capability_tier            VARCHAR      NOT NULL,  -- 'small' | 'medium' | 'large'
    updated_at                 TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    PRIMARY KEY (model_name)
);

-- Seed: ILLUSTRATIVE rates — verify against the current consumption table.
MERGE INTO MODEL_PRICING t
USING (
    SELECT * FROM VALUES
        ('llama3.1-8b',       0.19, 0.19, 'small'),
        ('mistral-7b',        0.12, 0.12, 'small'),
        ('mixtral-8x7b',      0.22, 0.22, 'small'),
        ('llama3.1-70b',      1.21, 1.21, 'medium'),
        ('mistral-large2',    1.95, 1.95, 'medium'),
        ('llama3.1-405b',     3.00, 3.00, 'large'),
        ('claude-3-5-sonnet', 2.55, 2.55, 'large')
      AS v(model_name, credits_per_m_input_tokens,
           credits_per_m_output_tokens, capability_tier)
) s
ON t.model_name = s.model_name
WHEN NOT MATCHED THEN INSERT
    (model_name, credits_per_m_input_tokens, credits_per_m_output_tokens, capability_tier)
    VALUES (s.model_name, s.credits_per_m_input_tokens,
            s.credits_per_m_output_tokens, s.capability_tier);

-- ----------------------------------------------------------------------------
-- ESTIMATE_AI_CREDITS: credits for a batch job, from sampled token counts.
--   avg_input_tokens        — e.g. AVG(AI_COUNT_TOKENS('ai_complete', col))
--                             over a representative sample
--   expected_output_tokens  — your assumption per row (AI_COUNT_TOKENS cannot
--                             know this; classification ≈ 1-10, summaries more)
--   row_count               — rows the real job will process
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ESTIMATE_AI_CREDITS(
    function_name          VARCHAR,
    model_name             VARCHAR,
    avg_input_tokens       FLOAT,
    expected_output_tokens FLOAT,
    row_count              FLOAT
)
RETURNS OBJECT
AS
$$
    SELECT OBJECT_CONSTRUCT(
        'function',          function_name,
        'model',             model_name,
        'rows',              row_count,
        'est_input_tokens',  avg_input_tokens * row_count,
        'est_output_tokens', expected_output_tokens * row_count,
        'est_credits',
            (avg_input_tokens * row_count / 1e6) * p.credits_per_m_input_tokens
          + (expected_output_tokens * row_count / 1e6) * p.credits_per_m_output_tokens,
        'pricing_updated_at', p.updated_at
    )
    FROM SNOWCUFFS.PUBLIC.MODEL_PRICING p
    WHERE p.model_name = ESTIMATE_AI_CREDITS.model_name
$$;

-- ----------------------------------------------------------------------------
-- Model tiering helper: cheapest model at or above a capability tier.
-- Agents/rules should call this instead of hardcoding a large model.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION CHEAPEST_MODEL_FOR_TIER(tier VARCHAR)
RETURNS VARCHAR
AS
$$
    SELECT model_name
    FROM SNOWCUFFS.PUBLIC.MODEL_PRICING
    WHERE capability_tier = tier
    ORDER BY credits_per_m_input_tokens ASC
    LIMIT 1
$$;

-- ----------------------------------------------------------------------------
-- Example: price a 10M-row AI_COMPLETE job from a 1,000-row sample.
-- ----------------------------------------------------------------------------
-- WITH sample_tokens AS (
--     SELECT AVG(AI_COUNT_TOKENS('ai_complete', prompt_col)) AS avg_in
--     FROM my_db.my_schema.my_table SAMPLE (1000 ROWS)
-- )
-- SELECT ESTIMATE_AI_CREDITS('ai_complete', 'llama3.1-8b', avg_in, 200, 1e7)
-- FROM sample_tokens;
