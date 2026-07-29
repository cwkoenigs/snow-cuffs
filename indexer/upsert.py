"""Incrementally sync one repo's chunks into SNOWCUFFS.CODE_INDEX.CODE_CHUNKS.

Usage (CI):
    python indexer/upsert.py --repo my-org/my-repo --root .

Auth via env vars (key-pair recommended for CI):
    SNOWFLAKE_ACCOUNT, SNOWFLAKE_USER, SNOWFLAKE_PRIVATE_KEY (PEM string)
    or SNOWFLAKE_PASSWORD; optional SNOWFLAKE_ROLE, SNOWFLAKE_WAREHOUSE.

Strategy: stage all current chunk IDs + rows in a temp table, then
  1. DELETE corpus rows for this repo whose chunk_id is absent from the stage
     (covers edits and deletions — an edited chunk gets a new hash), and
  2. INSERT staged rows whose chunk_id is new.
Unchanged chunks are untouched, so Cortex Search never re-embeds them.
"""

from __future__ import annotations

import argparse
import os
import sys

import snowflake.connector

from chunker import chunk_repo

TABLE = "SNOWCUFFS.CODE_INDEX.CODE_CHUNKS"


def connect() -> snowflake.connector.SnowflakeConnection:
    kwargs = {
        "account": os.environ["SNOWFLAKE_ACCOUNT"],
        "user": os.environ["SNOWFLAKE_USER"],
        "warehouse": os.environ.get("SNOWFLAKE_WAREHOUSE", "SNOWCUFFS_WH"),
    }
    if role := os.environ.get("SNOWFLAKE_ROLE"):
        kwargs["role"] = role
    if pem := os.environ.get("SNOWFLAKE_PRIVATE_KEY"):
        from cryptography.hazmat.primitives import serialization

        key = serialization.load_pem_private_key(pem.encode(), password=None)
        kwargs["private_key"] = key.private_bytes(
            serialization.Encoding.DER,
            serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption(),
        )
    else:
        kwargs["password"] = os.environ["SNOWFLAKE_PASSWORD"]
    return snowflake.connector.connect(**kwargs)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True, help="repo label, e.g. org/name")
    parser.add_argument("--root", default=".", help="checkout directory")
    args = parser.parse_args()

    chunks = chunk_repo(args.repo, args.root)
    print(f"chunked {args.repo}: {len(chunks)} chunks")

    conn = connect()
    try:
        cur = conn.cursor()
        cur.execute(
            "CREATE TEMPORARY TABLE _staged_chunks LIKE " + TABLE
        )
        cur.executemany(
            "INSERT INTO _staged_chunks "
            "(chunk_id, repo, file_path, language, start_line, end_line, content) "
            "VALUES (%s, %s, %s, %s, %s, %s, %s)",
            [
                (c.chunk_id, c.repo, c.file_path, c.language,
                 c.start_line, c.end_line, c.content)
                for c in chunks
            ],
        )

        cur.execute(
            f"DELETE FROM {TABLE} t "
            f"WHERE t.repo = %s "
            f"AND NOT EXISTS (SELECT 1 FROM _staged_chunks s "
            f"                WHERE s.chunk_id = t.chunk_id)",
            (args.repo,),
        )
        deleted = cur.fetchone()[0]

        cur.execute(
            f"INSERT INTO {TABLE} "
            f"(chunk_id, repo, file_path, language, start_line, end_line, content) "
            f"SELECT s.chunk_id, s.repo, s.file_path, s.language, "
            f"       s.start_line, s.end_line, s.content "
            f"FROM _staged_chunks s "
            f"WHERE NOT EXISTS (SELECT 1 FROM {TABLE} t "
            f"                  WHERE t.chunk_id = s.chunk_id)"
        )
        inserted = cur.fetchone()[0]
        print(f"sync complete: {inserted} inserted, {deleted} deleted "
              f"(only these rows will be re-embedded)")
    finally:
        conn.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
