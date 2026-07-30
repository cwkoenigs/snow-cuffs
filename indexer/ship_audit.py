"""Ship local .snowcuffs/audit/*.jsonl agent events to SNOWCUFFS.AUDIT.AGENT_EVENTS.

Usage (from a repo root, or anywhere with --audit-dir):
    python indexer/ship_audit.py --audit-dir .snowcuffs/audit [--user X --repo Y]
    python indexer/ship_audit.py --selftest

Auth: same env vars as upsert.py (SNOWFLAKE_ACCOUNT, SNOWFLAKE_USER,
SNOWFLAKE_PRIVATE_KEY or SNOWFLAKE_PASSWORD; optional SNOWFLAKE_ROLE,
SNOWFLAKE_WAREHOUSE) — connect() is imported from there.

Strategy: parse every *.jsonl (skipping corrupt lines, counting them), stage
rows in a temp table, then MERGE on event_id — insert-only, so re-shipping a
file (or two machines shipping overlapping logs) never duplicates rows.
Shipped files are renamed to *.jsonl.shipped so the next run skips them.

Event contract (shared with the hooks and sql/05_usage_audit.sql):
    {"event_id": sha256-16hex, "ts": ISO-8601, "session_id", "user_name",
     "repo", "event_type", "tool_name", "skill_name", "payload": object}
event_id, ts, event_type are required; the rest default to null/{}.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import sys
import time
from datetime import datetime, timezone
from typing import Iterable

TABLE = "SNOWCUFFS.AUDIT.AGENT_EVENTS"
STAGE = "_staged_audit_events"

REQUIRED_FIELDS = ("event_id", "ts", "event_type")
OPTIONAL_FIELDS = ("session_id", "user_name", "repo", "tool_name", "skill_name")


def parse_events(lines: Iterable[str]) -> tuple[list[dict], int]:
    """Parse JSONL lines into event dicts. Pure: no I/O, no globals.

    Returns (events, corrupt_count). A line is corrupt if it is not a JSON
    object or lacks any required field; corrupt lines are skipped and
    counted. Blank lines are ignored silently (trailing newlines are normal).
    Missing optional fields default to None; a missing payload becomes {}.
    """
    events: list[dict] = []
    corrupt = 0
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            raw = json.loads(line)
        except (json.JSONDecodeError, RecursionError):
            # RecursionError: pathologically nested garbage must not abort
            # the whole ship run — it is corrupt like any other bad line.
            corrupt += 1
            continue
        if not isinstance(raw, dict) or any(
            not raw.get(f) for f in REQUIRED_FIELDS
        ):
            corrupt += 1
            continue
        if iso_to_utc_naive(str(raw["ts"])) is None:
            # A present-but-unparseable ts would ship as NULL and silently
            # vanish from every DATE_TRUNC-grouped view in sql/05.
            corrupt += 1
            continue
        event = {f: str(raw[f]) for f in REQUIRED_FIELDS}
        for f in OPTIONAL_FIELDS:
            value = raw.get(f)
            event[f] = str(value) if value is not None else None
        payload = raw.get("payload")
        event["payload"] = payload if isinstance(payload, dict) else {}
        events.append(event)
    return events, corrupt


def iso_to_utc_naive(ts: str) -> datetime | None:
    """ISO-8601 string -> tz-naive UTC datetime for TIMESTAMP_NTZ binding."""
    try:
        dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except ValueError:
        return None
    if dt.tzinfo is not None:
        dt = dt.astimezone(timezone.utc).replace(tzinfo=None)
    return dt


def dedupe(events: list[dict]) -> list[dict]:
    """Keep first occurrence per event_id (MERGE forbids duplicate sources)."""
    seen: set[str] = set()
    out = []
    for e in events:
        if e["event_id"] not in seen:
            seen.add(e["event_id"])
            out.append(e)
    return out


def ship(events: list[dict]) -> int:
    """Stage events and MERGE into TABLE. Returns rows actually inserted."""
    # Deferred import: pulls in snowflake.connector (and upsert's chunker),
    # neither of which --selftest or parse-only paths need.
    here = os.path.dirname(os.path.abspath(__file__))
    if here not in sys.path:
        sys.path.insert(0, here)
    from upsert import connect

    conn = connect()
    try:
        cur = conn.cursor()
        # connect() sets no default namespace; a dedicated CI/service user has
        # none, and an unqualified CREATE TEMPORARY TABLE would fail with
        # "session does not have a current database".
        cur.execute("USE SCHEMA SNOWCUFFS.AUDIT")
        cur.execute(
            f"CREATE TEMPORARY TABLE {STAGE} ("
            "  event_id VARCHAR, ts TIMESTAMP_NTZ, session_id VARCHAR,"
            "  user_name VARCHAR, repo VARCHAR, event_type VARCHAR,"
            "  tool_name VARCHAR, skill_name VARCHAR, payload_json VARCHAR)"
        )
        cur.executemany(
            f"INSERT INTO {STAGE} "
            "(event_id, ts, session_id, user_name, repo, event_type, "
            " tool_name, skill_name, payload_json) "
            "VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)",
            [
                (e["event_id"], iso_to_utc_naive(e["ts"]), e["session_id"],
                 e["user_name"], e["repo"], e["event_type"], e["tool_name"],
                 e["skill_name"], json.dumps(e["payload"]))
                for e in events
            ],
        )
        cur.execute(
            f"MERGE INTO {TABLE} t "
            f"USING (SELECT event_id, ts, session_id, user_name, repo, "
            f"              event_type, tool_name, skill_name, "
            f"              TRY_PARSE_JSON(payload_json) AS payload "
            f"       FROM {STAGE}) s "
            f"ON t.event_id = s.event_id "
            f"WHEN NOT MATCHED THEN INSERT "
            f"  (event_id, ts, session_id, user_name, repo, event_type, "
            f"   tool_name, skill_name, payload) "
            f"VALUES (s.event_id, s.ts, s.session_id, s.user_name, s.repo, "
            f"        s.event_type, s.tool_name, s.skill_name, s.payload)"
        )
        inserted = cur.fetchone()[0]
    finally:
        conn.close()
    return inserted


def selftest() -> int:
    lines = [
        # full event
        '{"event_id": "a1b2c3d4e5f60718", "ts": "2026-07-30T09:15:00Z",'
        ' "session_id": "s-1", "user_name": "dana", "repo": "org/repo",'
        ' "event_type": "skill", "tool_name": null,'
        ' "skill_name": "preflight-cost", "payload": {"est_credits": 0.4}}',
        # corrupt: truncated JSON
        '{"event_id": "deadbeef00000000", "ts": "2026-07-30T09:16',
        # corrupt: unparseable ts (would ship as NULL and vanish from views)
        '{"event_id": "feedface00000000", "ts": "garbage", "event_type": "tool"}',
        # valid but missing every optional field
        '{"event_id": "0123456789abcdef", "ts": "2026-07-30T09:17:00Z",'
        ' "event_type": "session_end"}',
        # duplicate event_id of line 1 (re-shipped log) — parses, then dedupes
        '{"event_id": "a1b2c3d4e5f60718", "ts": "2026-07-30T09:15:00Z",'
        ' "session_id": "s-1", "user_name": "dana", "repo": "org/repo",'
        ' "event_type": "skill", "skill_name": "preflight-cost"}',
    ]
    events, corrupt = parse_events(lines)
    assert corrupt == 2, f"expected 2 corrupt lines, got {corrupt}"
    assert len(events) == 3, f"expected 3 parsed events, got {len(events)}"

    full = events[0]
    assert full["skill_name"] == "preflight-cost"
    assert full["payload"] == {"est_credits": 0.4}

    bare = events[1]
    assert bare["event_type"] == "session_end"
    assert all(bare[f] is None for f in OPTIONAL_FIELDS)
    assert bare["payload"] == {}

    assert len(dedupe(events)) == 2, "duplicate event_id should collapse"

    ts = iso_to_utc_naive(full["ts"])
    assert ts == datetime(2026, 7, 30, 9, 15) and ts.tzinfo is None
    assert iso_to_utc_naive("not-a-timestamp") is None

    deep = "[" * 2000 + "]" * 2000
    assert parse_events([deep]) == ([], 1), "deep nesting must count corrupt, not crash"

    print("selftest ok: 3 parsed, 2 corrupt skipped, 1 duplicate deduped")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(__doc__ or "Ship local audit JSONL to Snowflake").splitlines()[0])
    parser.add_argument("--audit-dir", default=".snowcuffs/audit",
                        help="directory of *.jsonl audit logs")
    parser.add_argument("--user", default=None,
                        help="fill user_name where events lack it")
    parser.add_argument("--repo", default=None,
                        help="fill repo where events lack it")
    parser.add_argument("--selftest", action="store_true",
                        help="run parse_events checks and exit (no network)")
    args = parser.parse_args()

    if args.selftest:
        return selftest()

    paths = sorted(glob.glob(os.path.join(args.audit_dir, "*.jsonl")))
    if not paths:
        print(f"nothing to ship: no *.jsonl under {args.audit_dir}")
        return 0

    # Record each file's size at read time. Hooks append to today's file
    # continuously; renaming a file that grew after we read it would archive
    # events we never staged — permanent, silent loss. Grown files are left
    # in place for the next run (MERGE dedupes the re-shipped prefix).
    events: list[dict] = []
    corrupt = 0
    sizes: dict[str, int] = {}
    for path in paths:
        # errors="replace": a truncated multi-byte char (crash mid-write) must
        # fail json.loads on that one line and count corrupt, not abort the run.
        with open(path, encoding="utf-8", errors="replace") as fh:
            parsed, bad = parse_events(fh)
        sizes[path] = os.path.getsize(path)
        events.extend(parsed)
        corrupt += bad
    if corrupt:
        print(f"skipped {corrupt} corrupt line(s)", file=sys.stderr)

    for e in events:
        e["user_name"] = e["user_name"] or args.user
        e["repo"] = e["repo"] or args.repo
    events = dedupe(events)

    if events:
        inserted = ship(events)
    else:
        inserted = 0
        print(f"no valid events in {len(paths)} file(s); archiving processed files")

    # Archive fully-processed files (same lifecycle whether or not they held
    # valid events — corrupt-only files must not be re-warned forever). The
    # timestamped suffix keeps same-day re-ships from overwriting an earlier
    # archive; the *.jsonl glob above never matches *.shipped.
    shipped = 0
    for path in paths:
        try:
            if os.path.getsize(path) != sizes[path]:
                continue  # grew since read — leave for the next run
        except OSError:
            continue
        os.replace(path, f"{path}.{int(time.time())}.shipped")
        shipped += 1
    if events:
        print(f"shipped {shipped}/{len(paths)} file(s): {len(events)} events staged, "
              f"{inserted} new rows merged into {TABLE} "
              f"({len(events) - inserted} already present)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
