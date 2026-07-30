-- ============================================================================
-- snow-cuffs · 06 · Schema context service
-- ----------------------------------------------------------------------------
-- "What's in the orders table?" should not cost 30k tokens. Without this,
-- every database question sends the agent crawling INFORMATION_SCHEMA,
-- sampling tables with SELECT *, and retrying joins it guessed wrong —
-- warehouse credits AND context bloat, repeated per session per developer.
--
-- Fix: pre-bake one small "schema card" per table (fqn, comment, row count,
-- columns, clustering key) and serve them from a tiny Cortex Search service.
-- A database question becomes one retrieval instead of a discovery loop.
--
-- Cost model (same shape as 04):
--   * Embedding: billed per token, ONLY for inserted/updated rows.
--     -> card_id is a content hash (like CODE_CHUNKS.chunk_id); an unchanged
--        card is never rewritten, so it is never re-embedded. Row counts are
--        rounded inside the card text so ordinary daily growth does not
--        churn hashes.
--   * Serving: billed per GB-month of indexed data, even at zero queries.
--     -> a card corpus is KB-scale; idle serving cost is negligible.
--   * Refresh: nightly task on the XS warehouse from 04; a no-change night
--     is two metadata queries and a zero-row MERGE.
-- Deploy after 04 (creates SNOWCUFFS_WH) and 01 (creates the cost-watch view
-- referenced at the bottom of this file).
-- ============================================================================

CREATE DATABASE IF NOT EXISTS SNOWCUFFS;
CREATE SCHEMA IF NOT EXISTS SNOWCUFFS.DB_CONTEXT;
USE SCHEMA SNOWCUFFS.DB_CONTEXT;

-- ----------------------------------------------------------------------------
-- Card table. One row per base table of each carded database. card_id is a
-- hash of the card's identity AND text, so the refresh proc's MERGE inserts
-- only new-or-changed cards and change tracking (required by Cortex Search
-- for incremental refresh) sees churn only when a card really changed.
-- row_count is exact as of the card's last content change; it is deliberately
-- NOT updated in place between changes — touching matched rows would create
-- change-tracking noise for the search service to reprocess.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS SCHEMA_CARDS (
    card_id        VARCHAR NOT NULL,   -- md5(db.schema.table || '|' || card)
    database_name  VARCHAR NOT NULL,
    schema_name    VARCHAR NOT NULL,
    table_name     VARCHAR NOT NULL,
    card           VARCHAR NOT NULL,   -- the retrievable text (what gets embedded)
    row_count      NUMBER,             -- exact, as of last card change
    refreshed_at   TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    PRIMARY KEY (card_id)
);

ALTER TABLE SCHEMA_CARDS SET CHANGE_TRACKING = TRUE;

-- ----------------------------------------------------------------------------
-- Refresh procedure. INFORMATION_SCHEMA is per-database, so the target's
-- TABLES/COLUMNS are snapshotted via dynamic SQL into session temp tables;
-- everything downstream (card build, MERGE, stale delete) is static SQL.
--
-- Card layout (typical table lands around 30 lines; the 60-column cap
-- bounds the pathological wide table, and keeps LISTAGG orders of magnitude
-- under its 16MB result limit because we cap BEFORE aggregating):
--
--   TABLE ANALYTICS.SALES.FCT_ORDERS
--   -- one row per order line, grain: order_id x line_no
--   -- rows: ~12000000
--   -- clustering: LINEAR(ORDER_DATE)
--   columns:
--     ORDER_ID NUMBER  -- surrogate key
--     ...
--     (+14 more columns)
--
-- Cards reflect what the executing role can SEE: INFORMATION_SCHEMA only
-- shows objects the role has privileges on.
-- VERIFY: EXECUTE AS CALLER means whoever runs it (you, or the task owner)
-- needs USAGE on each target database + visibility of its tables. Switch to
-- EXECUTE AS OWNER if you'd rather centralize those grants on one role.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE REFRESH_SCHEMA_CARDS(TARGET_DATABASE VARCHAR)
    RETURNS VARCHAR
    LANGUAGE SQL
    EXECUTE AS CALLER
    COMMENT = 'Rebuild schema cards for one database. Idempotent; hash-keyed MERGE means unchanged cards are untouched (and never re-embedded).'
AS
$$
DECLARE
    db            VARCHAR;
    stmt          VARCHAR;
    merged_rows   NUMBER DEFAULT 0;
    deleted_rows  NUMBER DEFAULT 0;
    invalid_name  EXCEPTION (-20061, 'target_database must be a simple unquoted identifier');
BEGIN
    db := UPPER(TARGET_DATABASE);

    -- db is spliced into dynamic SQL below: refuse anything that is not a
    -- plain identifier (no quotes, dots, semicolons — no injection surface).
    -- VERIFY: if your databases use quoted mixed-case names, extend this
    -- guard and the splice below rather than deleting the check.
    IF (NOT REGEXP_LIKE(db, '^[A-Z_][A-Z0-9_$]*$')) THEN
        RAISE invalid_name;
    END IF;

    -- Never card the plumbing: SNOWCUFFS internals are not analyst data.
    IF (db = 'SNOWCUFFS') THEN
        RETURN 'skipped SNOWCUFFS: snow-cuffs internals are not analyst data';
    END IF;

    -- ------------------------------------------------------------------
    -- 1/4 · Snapshot the target's INFORMATION_SCHEMA (the only dynamic
    -- SQL). Base tables only — views belong to code search territory —
    -- and never the target's own INFORMATION_SCHEMA. A nonexistent
    -- database fails here with Snowflake's own clear error.
    -- ------------------------------------------------------------------
    stmt := 'CREATE OR REPLACE TEMPORARY TABLE SNOWCUFFS.DB_CONTEXT._SC_TABLES AS '
         || 'SELECT table_catalog, table_schema, table_name, comment, row_count, clustering_key '
         || 'FROM ' || db || '.INFORMATION_SCHEMA.TABLES '
         || 'WHERE table_type = ''BASE TABLE'' '
         || 'AND table_schema <> ''INFORMATION_SCHEMA''';
    EXECUTE IMMEDIATE :stmt;

    stmt := 'CREATE OR REPLACE TEMPORARY TABLE SNOWCUFFS.DB_CONTEXT._SC_COLUMNS AS '
         || 'SELECT table_schema, table_name, ordinal_position, column_name, data_type, comment '
         || 'FROM ' || db || '.INFORMATION_SCHEMA.COLUMNS '
         || 'WHERE table_schema <> ''INFORMATION_SCHEMA''';
    EXECUTE IMMEDIATE :stmt;

    -- ------------------------------------------------------------------
    -- 2/4 · Build the cards. Columns capped at 60 INSIDE the aggregate
    -- (LISTAGG skips the NULLs the CASE produces past the cap); comments
    -- truncated so one chatty COMMENT cannot bloat a card. data_type is
    -- the coarse type ('NUMBER', 'TEXT') — enough for join and filter
    -- planning; precision detail is token noise. Row counts are rounded
    -- to 2 significant figures in the text so daily growth does not
    -- change the hash.
    -- ------------------------------------------------------------------
    CREATE OR REPLACE TEMPORARY TABLE SNOWCUFFS.DB_CONTEXT._SC_CARDS AS
    WITH col_block AS (
        SELECT
            table_schema,
            table_name,
            COUNT(*) AS col_count,
            LISTAGG(
                CASE WHEN ordinal_position <= 60 THEN
                    '  ' || column_name || ' ' || data_type
                    || COALESCE('  -- ' || LEFT(NULLIF(comment, ''), 100), '')
                END,
                CHR(10)
            ) WITHIN GROUP (ORDER BY ordinal_position) AS cols_text
        FROM SNOWCUFFS.DB_CONTEXT._SC_COLUMNS
        GROUP BY table_schema, table_name
    ),
    cards AS (
        SELECT
            t.table_catalog  AS database_name,
            t.table_schema   AS schema_name,
            t.table_name     AS table_name,
            t.row_count      AS row_count,
               'TABLE ' || t.table_catalog || '.' || t.table_schema || '.' || t.table_name
            || COALESCE(CHR(10) || '-- ' || LEFT(NULLIF(t.comment, ''), 200), '')
            || CHR(10) || '-- rows: '
            || CASE
                   WHEN t.row_count IS NULL THEN 'unknown'
                   WHEN t.row_count < 1000  THEN TO_VARCHAR(t.row_count)
                   ELSE '~' || TO_VARCHAR(ROUND(t.row_count,
                            (1 - FLOOR(LOG(10, t.row_count)))::INT))
               END
            || COALESCE(CHR(10) || '-- clustering: ' || t.clustering_key, '')
            || CHR(10) || 'columns:'
            || CHR(10) || COALESCE(c.cols_text, '  (no columns visible)')
            || CASE WHEN c.col_count > 60
                    THEN CHR(10) || '  (+' || TO_VARCHAR(c.col_count - 60) || ' more columns)'
                    ELSE ''
               END AS card
        FROM SNOWCUFFS.DB_CONTEXT._SC_TABLES t
        LEFT JOIN col_block c
          ON  c.table_schema = t.table_schema
          AND c.table_name   = t.table_name
    )
    SELECT
        MD5(database_name || '.' || schema_name || '.' || table_name || '|' || card) AS card_id,
        database_name,
        schema_name,
        table_name,
        card,
        row_count
    FROM cards;

    -- ------------------------------------------------------------------
    -- 3/4 · Insert new-or-changed cards. No WHEN MATCHED clause on
    -- purpose: a matched card_id means byte-identical card text, and
    -- touching the row would create change-tracking churn for the search
    -- service (and re-embedding cost) with nothing new to embed.
    -- ------------------------------------------------------------------
    MERGE INTO SNOWCUFFS.DB_CONTEXT.SCHEMA_CARDS AS tgt
    USING SNOWCUFFS.DB_CONTEXT._SC_CARDS AS src
        ON tgt.card_id = src.card_id
    WHEN NOT MATCHED THEN INSERT
        (card_id, database_name, schema_name, table_name, card, row_count, refreshed_at)
        VALUES
        (src.card_id, src.database_name, src.schema_name, src.table_name,
         src.card, src.row_count, CURRENT_TIMESTAMP());
    merged_rows := SQLROWCOUNT;

    -- ------------------------------------------------------------------
    -- 4/4 · Drop this database's stale cards: dropped tables, and the
    -- superseded versions of any card whose text (hence card_id) changed.
    -- ------------------------------------------------------------------
    DELETE FROM SNOWCUFFS.DB_CONTEXT.SCHEMA_CARDS
    WHERE database_name = :db
      AND card_id NOT IN (SELECT card_id FROM SNOWCUFFS.DB_CONTEXT._SC_CARDS);
    deleted_rows := SQLROWCOUNT;

    RETURN db || ': ' || TO_VARCHAR(merged_rows) || ' cards written (new or changed), '
              || TO_VARCHAR(deleted_rows) || ' stale cards deleted';
END;
$$;

-- ----------------------------------------------------------------------------
-- OPTIONAL ENRICHMENT (commented out): join partners from ACCESS_HISTORY.
--
-- The single highest-value upgrade for agent SQL accuracy. Wrong-join
-- retries are the most expensive failure loop an agent has: every retry
-- burns warehouse time AND drags the failed SQL plus its error text back
-- through context. ACCESS_HISTORY records which tables real queries touch
-- together, so appending "commonly queried with: ..." to each card lets the
-- agent start from the joins humans actually use instead of guessing from
-- column-name similarity.
--
-- Requirements — VERIFY on your account: SNOWFLAKE.ACCOUNT_USAGE.
-- ACCESS_HISTORY needs Enterprise edition and the GOVERNANCE_VIEWER
-- database role (or IMPORTED PRIVILEGES on the SNOWFLAKE database);
-- ~3 h latency, which is irrelevant at nightly cadence.
--
-- Working skeleton. Fold the result into the cards CTE inside
-- REFRESH_SCHEMA_CARDS (LEFT JOIN on the fully-qualified name, append a
-- '-- commonly queried with: ...' line BEFORE card_id is hashed). Do NOT
-- UPDATE cards in place afterwards — that would break card_id = hash(card)
-- and rewrite every row nightly, re-embedding the whole corpus.
--
-- WITH table_touches AS (
--     SELECT ah.query_id,
--            obj.value:"objectName"::VARCHAR AS table_fqn
--     FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY ah,
--          LATERAL FLATTEN(input => ah.base_objects_accessed) obj
--     WHERE ah.query_start_time >= DATEADD('day', -90, CURRENT_TIMESTAMP())
--       AND obj.value:"objectDomain"::VARCHAR = 'Table'
-- ),
-- pairs AS (
--     SELECT a.table_fqn AS table_a,
--            b.table_fqn AS table_b,
--            COUNT(DISTINCT a.query_id) AS queries_together
--     FROM table_touches a
--     JOIN table_touches b
--       ON  a.query_id  = b.query_id
--       AND a.table_fqn < b.table_fqn        -- each pair once
--     GROUP BY 1, 2
--     HAVING COUNT(DISTINCT a.query_id) >= 5 -- illustrative noise floor
-- ),
-- partners AS (
--     SELECT table_a AS table_fqn, table_b AS partner, queries_together FROM pairs
--     UNION ALL
--     SELECT table_b, table_a, queries_together FROM pairs
-- ),
-- top5 AS (
--     SELECT table_fqn, partner, queries_together
--     FROM partners
--     QUALIFY ROW_NUMBER() OVER (PARTITION BY table_fqn
--                                ORDER BY queries_together DESC) <= 5
-- )
-- SELECT table_fqn,
--        LISTAGG(partner || ' (' || queries_together || ' queries)', ', ')
--            WITHIN GROUP (ORDER BY queries_together DESC) AS commonly_queried_with
-- FROM top5
-- GROUP BY table_fqn;
-- ----------------------------------------------------------------------------

-- ----------------------------------------------------------------------------
-- Nightly refresh. 02:30 UTC — after most ETL, before humans. Runs on the
-- XS warehouse from 04; a no-change night is seconds of compute. The body
-- is wrapped in EXECUTE IMMEDIATE so the multi-statement block survives
-- every client's statement splitting (plain AS BEGIN...END also works in
-- Snowsight).
-- ----------------------------------------------------------------------------
CREATE TASK IF NOT EXISTS REFRESH_SCHEMA_CARDS_NIGHTLY
    WAREHOUSE = SNOWCUFFS_WH          -- created in 04
    SCHEDULE = 'USING CRON 30 2 * * * UTC'
    COMMENT = 'Rebuild schema cards nightly. Hash-keyed MERGE: unchanged cards untouched, so a quiet night embeds nothing.'
AS
EXECUTE IMMEDIATE
$$
BEGIN
    -- Enumerate your analytical databases here — the ones agents actually
    -- query. Do NOT add SNOWCUFFS (the proc skips it anyway).
    CALL SNOWCUFFS.DB_CONTEXT.REFRESH_SCHEMA_CARDS('ANALYTICS');    -- placeholder
    CALL SNOWCUFFS.DB_CONTEXT.REFRESH_SCHEMA_CARDS('ML_FEATURES');  -- placeholder
END;
$$;

-- Tasks are created SUSPENDED. After editing the database list above:
--   ALTER TASK SNOWCUFFS.DB_CONTEXT.REFRESH_SCHEMA_CARDS_NIGHTLY RESUME;
-- First fill without waiting for tonight (or just CALL the proc directly):
--   EXECUTE TASK SNOWCUFFS.DB_CONTEXT.REFRESH_SCHEMA_CARDS_NIGHTLY;
-- VERIFY: RESUME / EXECUTE TASK need the EXECUTE TASK account privilege.

-- ----------------------------------------------------------------------------
-- The search service. Deliberately SEPARATE from TEAM_CODE_SEARCH (04):
-- the card corpus is KB-scale, so its GB-month serving cost is negligible,
-- while mixing schema cards into the code corpus would degrade retrieval in
-- both directions (code questions surfacing DDL cards and vice versa) and
-- chain the two corpora to one TARGET_LAG. Two tiny well-scoped services
-- beat one muddy one. TARGET_LAG '1 day' matches the nightly task — a
-- tighter lag would just spend refresh credits checking an unchanged table.
-- ----------------------------------------------------------------------------
CREATE CORTEX SEARCH SERVICE IF NOT EXISTS DB_SCHEMA_SEARCH
    ON card
    ATTRIBUTES database_name, schema_name, table_name
    WAREHOUSE = SNOWCUFFS_WH
    TARGET_LAG = '1 day'
    AS (
        SELECT card_id, card, database_name, schema_name, table_name
        FROM SNOWCUFFS.DB_CONTEXT.SCHEMA_CARDS
    );

-- ----------------------------------------------------------------------------
-- Query it (from CoCo, a skill, or SQL):
--
-- SELECT PARSE_JSON(SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
--     'SNOWCUFFS.DB_CONTEXT.DB_SCHEMA_SEARCH',
--     '{"query": "orders fact table with customer id and revenue",
--       "columns": ["card", "database_name", "schema_name", "table_name"],
--       "limit": 3}'
-- ));
--
-- Grant usage to the roles your team / CoCo runs under:
-- GRANT USAGE ON DATABASE SNOWCUFFS TO ROLE ML_ENGINEER;
-- GRANT USAGE ON SCHEMA SNOWCUFFS.DB_CONTEXT TO ROLE ML_ENGINEER;
-- GRANT USAGE ON CORTEX SEARCH SERVICE DB_SCHEMA_SEARCH TO ROLE ML_ENGINEER;
-- ----------------------------------------------------------------------------

-- Cost watch: SNOWCUFFS.OBSERVABILITY.CORTEX_SEARCH_SPEND_DAILY splits this
-- service's serving (GB-month) vs embedding credits alongside
-- TEAM_CODE_SEARCH's. Payoff model: one card retrieval is ~1-2k input
-- tokens; the loop it replaces — INFORMATION_SCHEMA crawling, SELECT *
-- sampling, wrong-join retries — routinely stuffs 10-50k+ tokens into
-- context per question, plus the warehouse time of the discovery queries
-- themselves. If embedding credits ever spike here, something is rewriting
-- unchanged cards: check that the refresh proc's MERGE is still hash-keyed.
