-- ============================================================================
-- snow-cuffs · 04 · Code search service
-- ----------------------------------------------------------------------------
-- One Cortex Search service over your team's code so CoCo retrieves the few
-- relevant chunks instead of reading whole files into context.
--
-- Cost model (why this file is shaped the way it is):
--   * Embedding: billed per token, but ONLY for inserted/updated rows.
--     -> chunk IDs are content hashes (indexer/chunker.py); unchanged code is
--        never rewritten, so it is never re-embedded.
--   * Serving: billed per GB-month of indexed data, even at zero queries.
--     -> ONE service for all repos, code-only corpus, no build artifacts.
--   * Refresh: change detection billed via cloud services; indexing runs on
--     the warehouse below.
--     -> generous TARGET_LAG; CI only merges on main-branch merges anyway.
-- ============================================================================

CREATE DATABASE IF NOT EXISTS SNOWCUFFS;
CREATE SCHEMA IF NOT EXISTS SNOWCUFFS.CODE_INDEX;
USE SCHEMA SNOWCUFFS.CODE_INDEX;

-- Dedicated XS warehouse for indexing; auto-suspend aggressively.
CREATE WAREHOUSE IF NOT EXISTS SNOWCUFFS_WH
    WAREHOUSE_SIZE = 'XSMALL'
    AUTO_SUSPEND = 60
    AUTO_RESUME = TRUE
    INITIALLY_SUSPENDED = TRUE;

-- ----------------------------------------------------------------------------
-- Corpus table. CI (indexer/upsert.py) MERGEs on chunk_id and deletes chunks
-- whose file was removed or changed. Change tracking is required by Cortex
-- Search for incremental refresh.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS CODE_CHUNKS (
    chunk_id     VARCHAR NOT NULL,   -- md5(repo || path || content)
    repo         VARCHAR NOT NULL,
    file_path    VARCHAR NOT NULL,
    language     VARCHAR,
    start_line   INTEGER,
    end_line     INTEGER,
    content      VARCHAR NOT NULL,   -- the searchable text
    indexed_at   TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    PRIMARY KEY (chunk_id)
);

ALTER TABLE CODE_CHUNKS SET CHANGE_TRACKING = TRUE;

-- ----------------------------------------------------------------------------
-- The search service. TARGET_LAG of 1 day is plenty: CI pushes changes on
-- merge, and stale-by-hours code search is fine — cheap beats instant here.
-- EMBEDDING_MODEL is optional; the default is fine unless you have a reason.
-- ----------------------------------------------------------------------------
CREATE CORTEX SEARCH SERVICE IF NOT EXISTS TEAM_CODE_SEARCH
    ON content
    ATTRIBUTES repo, file_path, language
    WAREHOUSE = SNOWCUFFS_WH
    TARGET_LAG = '1 day'
    AS (
        SELECT chunk_id, content, repo, file_path, language, start_line, end_line
        FROM SNOWCUFFS.CODE_INDEX.CODE_CHUNKS
    );

-- ----------------------------------------------------------------------------
-- Query it (from CoCo, a skill, or SQL):
--
-- SELECT PARSE_JSON(SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
--     'SNOWCUFFS.CODE_INDEX.TEAM_CODE_SEARCH',
--     '{"query": "how do we authenticate to the feature store",
--       "columns": ["file_path", "content", "start_line"],
--       "limit": 5}'
-- ));
--
-- Grant usage to the roles your team / CoCo runs under:
-- GRANT USAGE ON DATABASE SNOWCUFFS TO ROLE ML_ENGINEER;
-- GRANT USAGE ON SCHEMA SNOWCUFFS.CODE_INDEX TO ROLE ML_ENGINEER;
-- GRANT USAGE ON CORTEX SEARCH SERVICE TEAM_CODE_SEARCH TO ROLE ML_ENGINEER;
-- ----------------------------------------------------------------------------

-- Cost watch: SNOWCUFFS.OBSERVABILITY.CORTEX_SEARCH_SPEND_DAILY splits this
-- service's serving (GB-month) vs embedding credits. If serving cost creeps,
-- prune the corpus (drop generated code, vendored deps, stale repos).
