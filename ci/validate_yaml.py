#!/usr/bin/env python3
"""Validate a Cortex AI Gateway specification file.

Checks the fields documented in the gateway specification reference:
  * schema_version == 1
  * models is a non-empty list of {name: ...} entries
  * logging.enabled is a bool
  * capture_payload only meaningful when logging.enabled is true
  * exclude_tags are fully qualified (database.schema.tag)

Usage: python ci/validate_yaml.py <spec.yaml>
"""

import sys

import yaml

ALLOWED_TOP_LEVEL = {"schema_version", "models", "logging"}
ALLOWED_LOGGING = {"enabled", "enable_client_telemetry", "capture_payload"}
ALLOWED_CAPTURE = {"request_response", "exclude_tags"}


def fail(msg: str) -> None:
    print(f"INVALID: {msg}")
    sys.exit(1)


def main() -> int:
    if len(sys.argv) != 2:
        fail("usage: validate_yaml.py <spec.yaml>")

    with open(sys.argv[1]) as f:
        spec = yaml.safe_load(f)

    if not isinstance(spec, dict):
        fail("spec must be a YAML mapping")

    unknown = set(spec) - ALLOWED_TOP_LEVEL
    if unknown:
        fail(f"unknown top-level keys: {sorted(unknown)}")

    if spec.get("schema_version") != 1:
        fail("schema_version must be 1")

    models = spec.get("models")
    if not isinstance(models, list) or not models:
        fail("models must be a non-empty list")
    for m in models:
        if not isinstance(m, dict) or set(m) != {"name"} or not isinstance(m["name"], str):
            fail(f"each model entry must be exactly {{name: <string>}}, got: {m!r}")

    logging_cfg = spec.get("logging", {})
    if not isinstance(logging_cfg, dict):
        fail("logging must be a mapping")
    unknown = set(logging_cfg) - ALLOWED_LOGGING
    if unknown:
        fail(f"unknown logging keys: {sorted(unknown)}")

    if not isinstance(logging_cfg.get("enabled"), bool):
        fail("logging.enabled is required and must be a boolean")

    capture = logging_cfg.get("capture_payload", {})
    if capture:
        if not isinstance(capture, dict):
            fail("logging.capture_payload must be a mapping")
        unknown = set(capture) - ALLOWED_CAPTURE
        if unknown:
            fail(f"unknown capture_payload keys: {sorted(unknown)}")
        if not logging_cfg["enabled"]:
            print("WARNING: capture_payload set but logging.enabled is false — nothing is recorded")
        for tag in capture.get("exclude_tags", []):
            if not isinstance(tag, str) or len(tag.split(".")) != 3:
                fail(f"exclude_tags entries must be database.schema.tag, got: {tag!r}")

    print(f"OK: {sys.argv[1]} is a valid gateway spec")
    return 0


if __name__ == "__main__":
    sys.exit(main())
