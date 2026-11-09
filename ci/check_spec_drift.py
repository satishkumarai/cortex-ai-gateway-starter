#!/usr/bin/env python3
"""Detect drift between the versioned gateway spec and the live gateway.

The gateway spec is full-replacement state (ALTER ... FROM SPECIFICATION).
This script compares config/gateway-spec.production.yaml against what
DESCRIBE AI GATEWAY SNOWFLAKE reports, and exits non-zero on mismatch.

Run on a schedule (e.g. hourly) and after every apply.

Usage:
    python ci/check_spec_drift.py --expected config/gateway-spec.production.yaml

Requirements:
    * snowflake-connector-python and PyYAML
    * Connection via env vars (SNOWFLAKE_ACCOUNT, SNOWFLAKE_USER, and an
      authenticator such as SNOWFLAKE_PRIVATE_KEY / externalbrowser) or
      the default connections.toml. VERIFY: adapt to your auth setup.

Note on parsing: DESCRIBE AI GATEWAY returns rows describing the gateway,
including the current specification. The exact column layout may vary by
release; this script looks for a spec payload in any returned column and
parses it as YAML. If your account returns the spec differently, adjust
extract_live_spec() — the comparison logic is generic.
"""

import argparse
import sys

import yaml


def extract_live_spec(cursor) -> dict:
    cursor.execute("DESCRIBE AI GATEWAY SNOWFLAKE")
    rows = cursor.fetchall()
    for row in rows:
        for cell in row:
            if isinstance(cell, str) and "schema_version" in cell:
                return yaml.safe_load(cell)
    raise RuntimeError(
        "Could not locate a spec payload in DESCRIBE AI GATEWAY output. "
        "Inspect the result set and update extract_live_spec()."
    )


def normalize(spec: dict) -> dict:
    """Drop comments/ordering effects; keep only semantically meaningful keys."""
    if not isinstance(spec, dict):
        return {}
    return {k: normalize(v) if isinstance(v, dict) else v for k, v in sorted(spec.items())}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--expected", required=True, help="Path to expected spec YAML")
    args = parser.parse_args()

    with open(args.expected) as f:
        expected = yaml.safe_load(f)

    try:
        import snowflake.connector  # noqa: F401
    except ImportError:
        print("snowflake-connector-python is required: pip install snowflake-connector-python")
        return 2

    conn = snowflake.connector.connect()  # uses default connection parameters
    try:
        live = extract_live_spec(conn.cursor())
    finally:
        conn.close()

    if normalize(expected) == normalize(live):
        print("OK: live gateway spec matches versioned spec")
        return 0

    print("DRIFT DETECTED")
    print("--- expected (config/) ---")
    print(yaml.safe_dump(expected, sort_keys=True))
    print("--- live (DESCRIBE) ---")
    print(yaml.safe_dump(live, sort_keys=True))
    print("Remediate: re-apply the full spec from config/ (sql/03_apply_spec.sql),")
    print("or review and commit the live change into config/.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
